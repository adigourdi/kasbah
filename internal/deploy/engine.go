package deploy

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/traefiknet"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// Spec is everything the manifest says that the server needs, sent on the
// engine's stdin: the manifest never reaches a server.
type Spec struct {
	Mode         string   `json:"mode"`
	Version      string   `json:"version"`
	Kasbah       string   `json:"kasbah"`
	SkipHooks    bool     `json:"skip_hooks"`
	NoHealthWait bool     `json:"no_health_wait"`
	AllowStopped bool     `json:"allow_stopped"`
	Images       []string `json:"images"`
	Pre          []string `json:"pre"`
	Post         []string `json:"post"`
	Health       Health   `json:"health"`
	Backup       *Backup  `json:"backup"`
	// Snapshot is the token of this run's `deploy snapshot`; a revert
	// restores only the snapshot carrying it.
	Snapshot string `json:"snapshot"`
}

// Health is the manifest's health: block; an empty Container waits on every
// container of the compose project.
type Health struct {
	Container string `json:"container"`
	Timeout   int    `json:"timeout"`
}

// Backup is the manifest's backup: block.
type Backup struct {
	Check     string `json:"check"`
	Container string `json:"container"`
	Command   string `json:"command"`
	Pipe      string `json:"pipe"`
	Extension string `json:"extension"`
	Retain    int    `json:"retain"`
}

// Report is the run's last act, printed only after the versions.log append:
// it is the completion marker as well as the facts only the server has.
type Report struct {
	Version        string `json:"version"`
	PrevVersion    string `json:"prev_version"`
	DeployedBefore bool   `json:"deployed_before"`
	Backup         string `json:"backup"`
	Digest         string `json:"digest"`
	// ArchiveOnly: the history behind DeployedBefore is versions.log.gz's
	// alone. Optional, so an older workstation reads the report unchanged.
	ArchiveOnly bool `json:"archive_only,omitempty"`
}

// ReportKey marks the protocol line on stdout.
const ReportKey = "kasbah_deploy_report"

// FailureKey marks a failed run's protocol line on stdout: what the server
// was left as, for the workstation to say.
const FailureKey = "kasbah_deploy_failed"

// Failure outcomes; PostHook and RevertFailed append deploy-failed.
const (
	Restored     = "restored"
	Unrestored   = "unrestored"
	Reverted     = "reverted"
	FirstFailed  = "first"
	PostHook     = "post-hook"
	RevertFailed = "revert-failed"
	Unrecorded   = "unrecorded"
)

// Failure is the line FailureKey marks.
type Failure struct {
	Outcome string `json:"outcome"`
	Reason  string `json:"reason"`
	Prev    string `json:"prev"`
	// Saved is where a restore kept the .env it replaced.
	Saved string `json:"saved,omitempty"`
}

// fatal stops the engine; its text is the run's last stderr line.
type fatal struct{ msg string }

func (f fatal) Error() string { return f.msg }

func failf(format string, a ...any) error { return fatal{fmt.Sprintf(format, a...)} }

type engine struct {
	archiveOnly  bool
	dir, project string
	sp           Spec
	stderr       io.Writer
	now          func() time.Time
	sleep        func(time.Duration)
	preName      string
	postName     string
	verb         string
	// lockFile and serverLock hold their flocks until the run returns; any
	// exit releases them.
	lockFile, serverLock *os.File
	// What a failure needs to say and undo.
	logRead, history, retagged bool
	prev, lastFail             string
	backupPath                 string
	digest                     string
	prevIDs                    map[string]string
	liveBefore                 []string
	failure                    *Failure
}

func (e *engine) note(format string, a ...any) {
	fmt.Fprintf(e.stderr, "remote: "+format+"\n", a...)
}

// docker runs with its stdout on stderr: stdout is the report's.
func (e *engine) docker(args ...string) *exec.Cmd {
	c := exec.Command("docker", args...)
	c.Env = append(os.Environ(), "LC_ALL=C")
	c.Dir = e.dir
	c.Stdout, c.Stderr = e.stderr, e.stderr
	return c
}

func (e *engine) query(args ...string) (string, error) {
	c := exec.Command("docker", args...)
	c.Env = append(os.Environ(), "LC_ALL=C")
	c.Dir = e.dir
	out, err := c.Output()
	return strings.TrimRight(strings.ReplaceAll(string(out), "\r", ""), "\n"), err
}

// Engine is `kasbah remote deploy run DIR`, the Spec on stdin.
func Engine(dir string, stdin io.Reader, stdout, stderr io.Writer) int {
	var sp Spec
	dec := json.NewDecoder(stdin)
	if err := dec.Decode(&sp); err != nil {
		fmt.Fprintf(stderr, "remote: deploy: no readable deploy spec on stdin (%v) — nothing was changed\n", err)
		return 1
	}
	e := &engine{dir: strings.TrimSuffix(dir, "/"), sp: sp, stderr: stderr, now: time.Now, sleep: time.Sleep}
	r, err := e.run()
	if e.lockFile != nil {
		defer e.lockFile.Close()
	}
	if e.serverLock != nil {
		defer e.serverLock.Close()
	}
	if err != nil {
		fmt.Fprintf(stderr, "remote: %v\n", err)
		if e.failure != nil {
			b, _ := json.Marshal(e.failure)
			fmt.Fprintf(stdout, "{\"%s\":1,%s\n", FailureKey, b[1:])
		}
		return 1
	}
	b, _ := json.Marshal(r)
	fmt.Fprintf(stdout, "{\"%s\":1,%s\n", ReportKey, b[1:])
	return 0
}

func (e *engine) run() (*Report, error) {
	sp := e.sp
	switch sp.Mode {
	case "deploy":
		e.preName, e.postName, e.verb = "pre-deploy", "post-deploy", "deploy"
	case "rollback":
		e.preName, e.postName, e.verb = "pre-rollback", "post-rollback", "roll back"
	default:
		return nil, failf("unknown mode '%s' (expected deploy or rollback)", sp.Mode)
	}
	if sp.Version == "" || strings.IndexFunc(sp.Version, blank) >= 0 || strings.HasPrefix(sp.Version, "-") {
		return nil, failf("the version '%s' is not one versions.log can carry", sp.Version)
	}
	if e.dir == "" || !filepath.IsAbs(e.dir) {
		return nil, failf("the project directory must be an absolute path (got '%s')", e.dir)
	}
	e.project = filepath.Base(e.dir)
	if sp.Health.Timeout <= 0 {
		sp.Health.Timeout = 120
		e.sp.Health.Timeout = 120
	}
	composeMissing := failf("%s/compose.yml is missing — the project's sync: list must map its compose file to compose.yml", e.dir)
	if fi, err := os.Stat(e.dir); err != nil || !fi.IsDir() {
		return nil, composeMissing
	}
	if err := e.lock(); err != nil {
		return nil, err
	}
	rep, err := e.locked(composeMissing)
	if err != nil && !e.retagged && e.failure == nil {
		err = e.unchanged(err)
	}
	return rep, err
}

// locked is the run under .deploy.lock.
func (e *engine) locked(composeMissing error) (*Report, error) {
	sp := e.sp
	if fi, err := os.Stat(filepath.Join(e.dir, "compose.yml")); err != nil || fi.IsDir() {
		return nil, composeMissing
	}
	if _, err := os.Stat(filepath.Join(e.dir, ".env")); err != nil {
		return nil, failf("%s/.env is missing — compose reads the project's values from it", e.dir)
	}
	data, err := os.ReadFile(filepath.Join(e.dir, vlog.Log))
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, failf("could not read %s/%s", e.dir, vlog.Log)
	}
	e.logRead = true
	// The previous version is the last entry that is not a failed run's; a
	// line no version can be read out of still says something ran.
	prev, before := "", false
	entries := vlog.Entries(strings.ReplaceAll(string(data), "\r", ""))
	for i := len(entries) - 1; i >= 0; i-- {
		if en := entries[i]; en.IsFailed() {
			if e.lastFail == "" {
				e.lastFail = en.Version
			}
		} else {
			prev, before = en.Version, true
			break
		}
	}
	// An absent active log is not a first deploy while the archive holds
	// entries: rotation never empties the log, so it was lost or replaced.
	if len(entries) == 0 {
		if fi, err := os.Stat(filepath.Join(e.dir, vlog.Archive)); err == nil && fi.Size() > 0 {
			e.archiveOnly = true
		}
	}
	before = before || e.archiveOnly
	e.prev, e.history = prev, len(entries) > 0 || e.archiveOnly
	if err := e.preflight(); err != nil {
		return nil, err
	}
	if err := e.outgoing(prev, before); err != nil {
		return nil, err
	}

	backup := "no-backup"
	if sp.Mode == "deploy" {
		if backup, err = e.backup(); err != nil {
			return nil, err
		}
	}
	e.backupPath, e.digest = backup, "-"
	if sp.SkipHooks {
		e.note("%s hooks skipped (--skip-hooks)", e.preName)
	} else if err := e.hooks(e.preName, true, prev, backup, sp.Pre); err != nil {
		return nil, err
	}
	ids, err := e.currentIDs()
	if err != nil {
		return nil, err
	}
	// The ids the live stack started from: a kept snapshot's, from the run
	// that first took it.
	e.prevIDs = pinIDs(e.dir, sp.Snapshot, sp.Images, ids, e.stderr)
	e.liveBefore = e.liveContainers()
	e.retagged = true
	if err := e.retag(); err != nil {
		return nil, e.failed("up", err)
	}
	digest, err := e.digests()
	if err != nil {
		return nil, e.failed("up", err)
	}
	e.digest = digest
	if e.up() != nil {
		return nil, e.failed("up", failf("docker compose -p %s up -d --remove-orphans failed in %s", e.project, e.dir))
	}
	if err := e.joinTraefik(); err != nil {
		return nil, e.failed("up", err)
	}
	if sp.NoHealthWait {
		e.note("health wait skipped (--no-health-wait)")
	} else if err := e.healthWaitFor(sp.Health.Container); err != nil {
		return nil, e.failed("health", err)
	}
	if sp.SkipHooks {
		e.note("%s hooks skipped (--skip-hooks)", e.postName)
	} else if err := e.hooks(e.postName, false, prev, backup, sp.Post); err != nil {
		return nil, e.postFailed(err)
	}

	dropSnapshot(e.dir)
	if err := e.record(sp.Mode); err != nil {
		e.failure = &Failure{Outcome: Unrecorded, Reason: "record", Prev: e.prev}
		return nil, failf("%v — %s %s is live: its containers are up and healthy and its hooks ran, and versions.log does not record it", err, e.project, sp.Version)
	}
	return &Report{Version: sp.Version, PrevVersion: prev, DeployedBefore: before, Backup: backup, Digest: digest, ArchiveOnly: e.archiveOnly}, nil
}

// record appends the run's versions.log line, extra pairs after by=, then
// rotates the log.
func (e *engine) record(action string, extra ...string) error {
	kv := e.sp.Kasbah
	if kv == "" {
		kv = "unknown"
	}
	line, err := vlog.Line(vlog.Stamp(e.now()), action, e.sp.Version, e.backupPath, kv, e.digest, serverlock.Who(), extra...)
	if err != nil {
		return fatal{err.Error()}
	}
	repaired, err := vlog.Append(e.dir, line)
	if repaired {
		e.note("the last line of versions.log had no newline on it — an append that was interrupted. Terminated it rather than writing into it; it is left exactly as it stands.")
	}
	if err != nil {
		return fatal{err.Error()}
	}
	// Never the run's status: a failed compaction must not cost the route.
	moved, cut, rerr := vlog.Rotate(e.dir, e.now())
	switch {
	case rerr != nil:
		e.note("%v", rerr)
	case moved > 0:
		e.note("versions.log: %d entries older than %s moved to versions.log.gz", moved, vlog.MonthName(cut))
	}
	return nil
}

func (e *engine) up() error {
	return e.docker("compose", "-p", e.project, "up", "-d", "--remove-orphans").Run()
}

// joinTraefik connects Traefik to the project's kasbah network, which the up
// may just have created; a project still on kasbah-net has none.
func (e *engine) joinTraefik() error {
	d := traefiknet.Docker(traefiknet.Exec)
	nets, err := d.Networks(e.project)
	if err == nil {
		var done []string
		if done, err = d.Join(nets); err == nil {
			for _, n := range done {
				e.note("connected traefik to %s", n)
			}
			return nil
		}
	}
	return failf("could not connect traefik to %s's kasbah network: %v", e.project, err)
}

// recordFailed appends the deploy-failed line; a line that cannot be written
// is said, never the run's new failure.
func (e *engine) recordFailed(reason string) bool {
	extra := []string{"reason=" + reason}
	if e.sp.Mode == "rollback" {
		extra = append(extra, "mode=rollback")
	}
	if err := e.record(vlog.Failed, extra...); err != nil {
		e.note("%v — versions.log does not record this failure", err)
		return false
	}
	return true
}

// was names what ran before this run, for the failure messages.
func (e *engine) was() string {
	switch {
	case e.lastFail != "":
		return "the stack it ran before this run (versions.log's last entry is a failed " + e.lastFail + ")"
	case e.prev != "":
		return e.prev
	}
	return "the version it ran before this run (versions.log's last line names none)"
}

// unchanged is a failure before the retag: nothing was started, so the files
// the run shipped are put back and the disk matches the live stack again.
func (e *engine) unchanged(cause error) error {
	if e.sp.Snapshot == "" || !e.logRead {
		return cause
	}
	if !e.history {
		dropSnapshot(e.dir)
		return cause
	}
	e.note("%v", cause)
	res, err := restore(e.dir, e.sp.Snapshot)
	saved := e.saved(res)
	switch {
	case errors.Is(err, errForeign):
		e.note("%v", err)
		return failf("the %s of %s stopped before anything was started; its files are on the server beside the running stack", e.sp.Mode, e.sp.Version)
	case err != nil:
		e.failure = &Failure{Outcome: Unrestored, Reason: "start", Prev: e.prev, Saved: res.Saved}
		return failf("the %s of %s stopped before anything was started, and putting back the files it had shipped failed: %v (%s) — %s/%s is kept, and the next run starts from it%s", e.sp.Mode, e.sp.Version, err, res.what(), e.dir, PrevDir, saved)
	}
	dropSnapshot(e.dir)
	e.failure = &Failure{Outcome: Restored, Reason: "start", Prev: e.prev, Saved: res.Saved}
	return failf("the %s of %s stopped before anything was started, and the files it had shipped were put back — the server is as it was%s", e.sp.Mode, e.sp.Version, saved)
}

// saved is the clause naming the .env a restore kept, "" for none.
func (e *engine) saved(res *restored) string {
	if res == nil || res.Saved == "" {
		return ""
	}
	e.note("the .env on the server differed from the one the running stack started from: it is kept as %s", res.Saved)
	return ". The .env it replaced is kept as " + res.Saved
}

// failed is a failure after the retag: back to what ran (files, :current,
// containers), logged only when that fails. It outlasts a signal.
func (e *engine) failed(reason string, cause error) error {
	e.note("%v", cause)
	v := e.sp.Version
	if !e.history {
		dropSnapshot(e.dir)
		e.failure = &Failure{Outcome: FirstFailed, Reason: reason}
		return failf("the %s of %s failed (%s), and this is the first deploy of %s here, so there is nothing to revert to — the stack is left as the run left it, :current names %s, and versions.log records nothing", e.sp.Mode, v, reason, e.project, v)
	}
	release := atexit.Hold(func(os.Signal) {})
	defer release()
	e.note("reverting: the files this run replaced, each :current back on the image it had, and %s brought up again", e.was())
	state, res, err := e.revert()
	saved := e.saved(res)
	if err == nil {
		dropSnapshot(e.dir)
		e.failure = &Failure{Outcome: Reverted, Reason: reason, Prev: e.prev, Saved: res.Saved}
		return failf("the %s of %s failed (%s) and was reverted — the server is back on %s: its files, its images and its containers. versions.log records nothing for %s%s", e.sp.Mode, v, reason, e.was(), v, saved)
	}
	e.note("the revert failed: %v", err)
	logged := "versions.log records it as deploy-failed (reason=revert)"
	if !e.recordFailed("revert") {
		logged = "and versions.log could not record it"
	}
	e.failure = &Failure{Outcome: RevertFailed, Reason: reason, Prev: e.prev}
	if res != nil {
		e.failure.Saved = res.Saved
	}
	return failf("the %s of %s failed (%s), and so did the revert to %s — %s. %s%s", e.sp.Mode, v, reason, e.was(), state, logged, saved)
}

// revert returns what the restore did and, on failure, the state it left
// the server in.
func (e *engine) revert() (string, *restored, error) {
	v := e.sp.Version
	res, err := restore(e.dir, e.sp.Snapshot)
	if err != nil {
		return res.what() + " — the rest of the files, :current and whatever compose up left are " + v + "'s", res, err
	}
	e.note("put back the files this run replaced (%s)", strings.Join(res.Done, ", "))
	st, err := e.retagBack()
	return st, res, err
}

// retagBack is the revert after the files: each :current on its old id, that
// stack up and waited on.
func (e *engine) retagBack() (string, error) {
	v := e.sp.Version
	for _, img := range e.sp.Images {
		id := e.prevIDs[img]
		if id == "" {
			// No :current before this run: the old stack never named it.
			if e.docker("image", "rm", img+":current").Run() != nil {
				return "the files are back, and " + img + ":current still names " + v, fmt.Errorf("could not untag %s:current", img)
			}
			e.note("untagged %s:current, which nothing named before this run", img)
			continue
		}
		if e.docker("tag", id, img+":current").Run() != nil {
			return "the files are back, and " + img + ":current still names " + v, fmt.Errorf("could not retag %s as %s:current", id, img)
		}
		e.note("retagged %s:current back to %s", img, id)
	}
	if e.up() != nil {
		return "the files and :current are back, and compose up of them failed — the stack may be down or partial", fmt.Errorf("docker compose -p %s up -d --remove-orphans failed in %s", e.project, e.dir)
	}
	if err := e.joinTraefik(); err != nil {
		return "the old stack is up again and Traefik is not on its network — its routes answer 502", err
	}
	if e.sp.NoHealthWait {
		return "", nil
	}
	// The containers that ran before: this run's health.container may be
	// one the old stack never had.
	if err := e.healthWait(e.liveBefore); err != nil {
		return "the old stack is up again and not healthy", err
	}
	return "", nil
}

// postFailed: the new version is live and its hook may have changed data, so
// nothing is reverted; deploy-failed records it.
func (e *engine) postFailed(cause error) error {
	e.note("%v", cause)
	dropSnapshot(e.dir)
	logged := "versions.log records it as deploy-failed (reason=post-hook)"
	if !e.recordFailed("post-hook") {
		logged = "versions.log could not record it"
	}
	e.failure = &Failure{Outcome: PostHook, Reason: "post-hook", Prev: e.prev}
	return failf("a %s hook of %s failed after its containers came up healthy — %s is live and was not reverted, since the hook may already have changed data; %s", e.postName, e.sp.Version, e.sp.Version, logged)
}

// currentIDs is each built image's :current id before the retag, absent for
// none; any other answer than "No such image" stops the run.
func (e *engine) currentIDs() (map[string]string, error) {
	ids := map[string]string{}
	for _, img := range e.sp.Images {
		c := exec.Command("docker", "image", "inspect", "-f", "{{.Id}}", img+":current")
		c.Env = append(os.Environ(), "LC_ALL=C")
		c.Dir = e.dir
		var stderr strings.Builder
		c.Stderr = &stderr
		out, err := c.Output()
		id := strings.TrimSpace(string(out))
		switch {
		case err == nil && id != "":
			ids[img] = id
		case err != nil && strings.Contains(strings.ToLower(stderr.String()), "no such image"):
		default:
			return nil, failf("could not read what %s:current is before retagging it (%s) — a revert would have nothing to go back to. Nothing was started.", img, strings.TrimSpace(stderr.String()))
		}
	}
	return ids, nil
}

// liveContainers is the names of the compose project's running containers.
func (e *engine) liveContainers() []string {
	out, err := e.query("compose", "-p", e.project, "ps", "-q")
	if err != nil {
		return nil
	}
	var names []string
	for _, id := range strings.Fields(out) {
		if n, err := e.query("inspect", "-f", "{{.Name}}", id); err == nil && n != "" {
			names = append(names, strings.TrimPrefix(n, "/"))
		}
	}
	return names
}

// lock is .deploy.lock, held until the process exits, then the server lock,
// shared, so no server-wide step runs under the deploy.
func (e *engine) lock() error {
	path := filepath.Join(e.dir, ".deploy.lock")
	f, holder, err := serverlock.Project(e.dir)
	if err != nil {
		return failf("could not open the lock file %s", path)
	}
	if f == nil {
		return failf("%s is running in %s — it holds the lock on %s", holder, e.dir, path)
	}
	e.lockFile = f
	sl, err := serverlock.Take(filepath.Dir(e.dir), serverlock.Shared, "")
	if err != nil {
		return failf("%s", strings.TrimSuffix(err.Error(), " Nothing was changed; re-run once it has finished."))
	}
	e.serverLock = sl
	return nil
}

func (e *engine) preflight() error {
	var missing []string
	for _, img := range e.sp.Images {
		ref := img + ":" + e.sp.Version
		if _, err := e.query("image", "inspect", ref); err != nil {
			missing = append(missing, ref)
		}
	}
	if len(missing) > 0 {
		return failf("not on this server: %s — run `kasbah build-push` for %s first. Nothing was changed.", strings.Join(missing, " "), e.sp.Version)
	}
	return nil
}

func (e *engine) running(c string) bool {
	s, err := e.query("inspect", "-f", "{{.State.Running}}", c)
	return err == nil && s == "true"
}

func (e *engine) stateClause(c string) string {
	s, err := e.query("inspect", "-f", "{{.State.Status}}", c)
	if err != nil || s == "" {
		return c + " does not exist on this server"
	}
	return c + " is " + s
}

// HookContainer is a hook line's first word, the container it runs in.
func HookContainer(h string) string {
	h = strings.TrimLeft(h, " \t")
	if i := strings.IndexAny(h, " \t\n\v\f\r"); i >= 0 {
		return h[:i]
	}
	return h
}

func (e *engine) backupInPlay() bool { return e.sp.Mode == "deploy" && e.sp.Backup != nil }

// outgoing judges the outgoing stack before any side effect. No versions.log
// entry is a first deploy and the outgoing steps are skipped; history and a
// stopped container is a refusal unless --allow-stopped.
func (e *engine) outgoing(prev string, before bool) error {
	var cs []string
	seen := map[string]bool{}
	isPre := map[string]bool{}
	if !e.sp.SkipHooks {
		for _, h := range e.sp.Pre {
			c := HookContainer(h)
			isPre[c] = true
			if !seen[c] {
				seen[c] = true
				cs = append(cs, c)
			}
		}
	}
	if e.backupInPlay() && !seen[e.sp.Backup.Container] {
		cs = append(cs, e.sp.Backup.Container)
	}
	var list, absent, hooksDown []string
	backupDown := false
	for _, c := range cs {
		if c == "" || e.running(c) {
			continue
		}
		clause := e.stateClause(c)
		list = append(list, clause)
		if strings.HasSuffix(clause, "does not exist on this server") {
			absent = append(absent, clause)
		}
		if e.backupInPlay() && c == e.sp.Backup.Container {
			backupDown = true
		}
		if isPre[c] {
			hooksDown = append(hooksDown, c)
		}
	}
	if len(list) == 0 {
		return nil
	}
	skipped := ""
	if backupDown {
		skipped = "the backup"
	}
	if len(hooksDown) > 0 {
		if skipped != "" {
			skipped += " and "
		}
		skipped += "the " + e.preName + " hooks in " + strings.Join(hooksDown, ", ")
	}
	if skipped == "" {
		skipped = "the outgoing steps that need them"
	}
	all := strings.Join(list, ", ")
	if !before {
		if e.sp.Mode == "deploy" {
			e.note("first deploy — versions.log has no entry for this project, and %s, so %s will not run", all, skipped)
		} else {
			e.note("versions.log has no entry for this project, and %s, so %s will not run", all, skipped)
		}
		return nil
	}
	if e.sp.AllowStopped {
		e.note("--allow-stopped: %s, so %s will not run", all, skipped)
		return nil
	}
	recorded := "versions.log has entries for it, though its last line is not one a version can be read out of"
	if e.archiveOnly {
		recorded = "versions.log holds no entry, and versions.log.gz holds archived ones"
	}
	if prev != "" {
		recorded = "versions.log records " + prev
	}
	if len(absent) > 0 {
		names := "the first word of a pre-rollback hook"
		if e.sp.Mode == "deploy" {
			names = "backup.container, or the first word of a pre-deploy hook"
		}
		e.note("%s, and this project has deployed here before (%s)", all, recorded)
		e.note("%s — the manifest names it (%s) and this server's compose file defines no container_name: that matches", strings.Join(absent, ", "), names)
		e.note("`kasbah check`'s HK01 catches that on the workstation, before any deploy")
		return failf("make kasbah.yml and the compose file agree on the name. --allow-stopped would %s past this, and would go on skipping %s silently on every %s after it. Nothing was changed.", e.verb, skipped, e.sp.Mode)
	}
	return failf("%s, and this project has deployed here before (%s) — refusing to %s over a stack that cannot run %s. Start it, or pass --allow-stopped if it is meant to be down. Nothing was changed.", all, recorded, e.verb, skipped)
}

func blank(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }

// sh runs project-authored shell under the locale the whole run has.
func (e *engine) sh(script string) *exec.Cmd {
	c := exec.Command("sh", "-c", script)
	c.Env = append(os.Environ(), "LC_ALL=C")
	c.Dir = e.dir
	c.Stdout, c.Stderr = e.stderr, e.stderr
	return c
}

// backup runs against the still-running outgoing version, so a backup exists
// before any hook touches live state. It returns versions.log's field 4.
func (e *engine) backup() (string, error) {
	b := e.sp.Backup
	if b == nil {
		return "no-backup", nil
	}
	if !e.running(b.Container) {
		e.note("no %s is running, so there is nothing to back up", b.Container)
		return "no-backup", nil
	}
	if e.sh(b.Check).Run() != nil {
		e.note("backup.check exited non-zero — no backup taken, the deploy continues")
		return "no-backup", nil
	}
	file := "backups/pre-deploy-" + e.now().UTC().Format("20060102-150405") + "." + b.Extension
	if err := os.MkdirAll(filepath.Join(e.dir, "backups"), 0o777); err != nil {
		return "", failf("could not create %s/backups", e.dir)
	}
	// A name the rotation glob cannot match until the dump is whole.
	tmp := filepath.Join(e.dir, file+".partial")
	// 660: a dump holds the project's data, the operators' group's and no one else's.
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o660)
	if err == nil {
		err = out.Chmod(0o660)
	}
	if err != nil {
		return "", failf("could not write %s", tmp)
	}
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	rc := e.dump(b, out)
	if cerr := out.Close(); cerr != nil && rc == 0 {
		rc = 1
	}
	if rc != 0 {
		os.Remove(tmp)
		return "", failf("the backup failed in %s (exit %d) — nothing has been deployed", b.Container, rc)
	}
	if os.Rename(tmp, filepath.Join(e.dir, file)) != nil {
		return "", failf("could not write %s/%s", e.dir, file)
	}
	e.note("backup written to %s", file)
	if err := e.rotateBackups(); err != nil {
		return "", err
	}
	return file, nil
}

// dump is `docker exec C sh -c CMD [| sh -c PIPE] > out`, with pipefail's
// status: the last non-zero one.
func (e *engine) dump(b *Backup, out *os.File) int {
	ex := exec.Command("docker", "exec", b.Container, "sh", "-c", b.Command)
	ex.Env = append(os.Environ(), "LC_ALL=C")
	ex.Dir, ex.Stderr = e.dir, e.stderr
	if b.Pipe == "" {
		ex.Stdout = out
		return exitStatus(ex.Run())
	}
	pr, pw, err := os.Pipe()
	if err != nil {
		return 1
	}
	ex.Stdout = pw
	p := e.sh(b.Pipe)
	p.Stdin, p.Stdout = pr, out
	if err := ex.Start(); err != nil {
		pr.Close()
		pw.Close()
		return 127
	}
	pw.Close()
	if err := p.Start(); err != nil {
		pr.Close()
		ex.Process.Kill()
		ex.Wait()
		return 127
	}
	pr.Close()
	exErr, pErr := ex.Wait(), p.Wait()
	if rc := exitStatus(pErr); rc != 0 {
		return rc
	}
	return exitStatus(exErr)
}

func exitStatus(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) && ee.ExitCode() > 0 {
		return ee.ExitCode()
	}
	return 1
}

// rotateBackups keeps the newest retain; names sort by their fixed-width
// timestamp.
func (e *engine) rotateBackups() error {
	b := e.sp.Backup
	files, _ := filepath.Glob(filepath.Join(e.dir, "backups", "pre-deploy-*."+globEscape(b.Extension)))
	var regular []string
	for _, f := range files {
		if fi, err := os.Stat(f); err == nil && fi.Mode().IsRegular() {
			regular = append(regular, f)
		}
	}
	if len(regular) <= b.Retain {
		return nil
	}
	for _, f := range regular[:len(regular)-b.Retain] {
		if os.Remove(f) != nil {
			return failf("could not remove the rotated-out backup %s", f)
		}
		e.note("rotated out %s (backup.retain is %d)", f, b.Retain)
	}
	return nil
}

func globEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(`*?[\`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// hooks run with no TTY: the first word is the container, the rest that
// container's /bin/sh command. Outgoing hooks skip a container that is not
// running; incoming ones fail on it.
func (e *engine) hooks(what string, outgoing bool, prev, backup string, list []string) error {
	for _, h := range list {
		h = strings.TrimLeft(h, " \t")
		c := HookContainer(h)
		rest := strings.TrimLeft(strings.TrimPrefix(h, c), " \t\n\v\f\r")
		if c == "" {
			return failf("a %s hook has no container name in it: '%s'", what, h)
		}
		if rest == "" {
			return failf("the %s hook '%s' names a container and no command", what, h)
		}
		if outgoing && !e.running(c) {
			e.note("%s hook skipped: no %s is running", what, c)
			continue
		}
		e.note("%s hook: %s: %s", what, c, rest)
		if e.docker("exec", "-e", "VERSION="+e.sp.Version, "-e", "PREV_VERSION="+prev,
			"-e", "DEPLOY_BACKUP="+backup, c, "sh", "-c", rest).Run() != nil {
			return failf("the %s hook failed in %s: %s", what, c, rest)
		}
	}
	return nil
}

func (e *engine) retag() error {
	for _, img := range e.sp.Images {
		if e.docker("tag", img+":"+e.sp.Version, img+":current").Run() != nil {
			return failf("could not retag %s:%s as %s:current", img, e.sp.Version, img)
		}
		e.note("retagged %s:%s as %s:current", img, e.sp.Version, img)
	}
	return nil
}

// digests is each built image's id on this server after the retag — the
// local daemon's, since save/load does not keep ids — comma-joined, or `-`.
func (e *engine) digests() (string, error) {
	var ids []string
	for _, img := range e.sp.Images {
		id, err := e.query("image", "inspect", "-f", "{{.Id}}", img+":current")
		if err != nil {
			return "", failf("could not read the image id of %s:current", img)
		}
		if id == "" {
			return "", failf("docker reported no image id for %s:current", img)
		}
		if strings.ContainsAny(id, " \t\n") {
			return "", failf("the image id of %s:current contains whitespace ('%s'), which versions.log cannot carry", img, id)
		}
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return "-", nil
	}
	return strings.Join(ids, ","), nil
}

func (e *engine) name(c string) string {
	n, err := e.query("inspect", "-f", "{{.Name}}", c)
	n = strings.TrimPrefix(n, "/")
	if err != nil || n == "" {
		return c
	}
	return n
}

// healthWaitFor waits on container, or on every container of the project.
func (e *engine) healthWaitFor(container string) error {
	if container != "" {
		return e.healthWait([]string{container})
	}
	out, err := e.query("compose", "-p", e.project, "ps", "-q")
	if err != nil {
		return failf("could not list the containers of compose project %s", e.project)
	}
	return e.healthWait(strings.Fields(out))
}

// healthWait polls under one deadline, health.timeout, for the whole wait. A
// container with no healthcheck passes at once.
func (e *engine) healthWait(targets []string) error {
	if len(targets) == 0 {
		e.note("health: compose project %s has no containers to wait on", e.project)
		return nil
	}
	deadline := e.now().Add(time.Duration(e.sp.Health.Timeout) * time.Second)
	for _, t := range targets {
		for {
			status, err := e.query("inspect", "--format", "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", t)
			if err != nil {
				status = "missing"
			}
			if status == "none" {
				e.note("health: %s declares no healthcheck — nothing to wait for", e.name(t))
				break
			}
			if status == "healthy" {
				e.note("health: %s is healthy", e.name(t))
				break
			}
			if !e.now().Before(deadline) {
				return failf("%s did not become healthy within %ds — its last state was '%s'", e.name(t), e.sp.Health.Timeout, status)
			}
			e.sleep(time.Second)
		}
	}
	return nil
}

// ParseReport finds the report line in the engine's stdout. The last one
// wins, so a stray line ahead of it cannot take its place.
func ParseReport(out string) (*Report, []string, bool) {
	var found map[string]json.RawMessage
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		if !strings.HasPrefix(l, "{\""+ReportKey+"\":") {
			continue
		}
		var m map[string]json.RawMessage
		if json.Unmarshal([]byte(l), &m) == nil {
			found = m
		}
	}
	if found == nil {
		return nil, nil, false
	}
	var missing []string
	for _, k := range []string{"version", "prev_version", "deployed_before", "backup", "digest"} {
		if _, ok := found[k]; !ok {
			missing = append(missing, k)
		}
	}
	if len(missing) > 0 {
		return nil, missing, true
	}
	var r Report
	b, _ := json.Marshal(found)
	if json.Unmarshal(b, &r) != nil {
		return nil, []string{"readable values"}, true
	}
	return &r, nil, true
}
