package deploy

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
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
	Mode         string `json:"mode"`
	Version      string `json:"version"`
	Kasbah       string `json:"kasbah"`
	SkipHooks    bool   `json:"skip_hooks"`
	NoHealthWait bool   `json:"no_health_wait"`
	// OnHookFailure answers a failed backup or pre-hook: continue or stop;
	// empty asks the workstation over the report channel.
	OnHookFailure string   `json:"on_hook_failure"`
	Images        []string `json:"images"`
	Pre           []string `json:"pre"`
	Post          []string `json:"post"`
	// Backup and Restore are the manifest's backup and restore hooks: a
	// deploy runs Backup; both are rendered into HooksFile.
	Backup  []string `json:"backup"`
	Restore []string `json:"restore"`
	// Targets is the snapshot's target list, for HooksFile.
	Targets []string `json:"targets"`
	Health  Health   `json:"health"`
	// Routed is the loadBalancer hosts of the fragment this run ships, which
	// name the routed services a deploy may roll rather than recreate.
	Routed []string `json:"routed"`
	// Snapshot is the token of this run's `deploy snapshot`; a revert
	// restores only the snapshot carrying it.
	Snapshot string `json:"snapshot"`
	// RestoreFrom is a rollback's target backup in backups/, "" for none:
	// extracted for the rollback hooks. RestoreData runs the Restore hooks.
	RestoreFrom string `json:"restore_from,omitempty"`
	RestoreData bool   `json:"restore_data,omitempty"`
}

// Health is the manifest's health: block; an empty Container waits on every
// container of the compose project.
type Health struct {
	Container string `json:"container"`
	Timeout   int    `json:"timeout"`
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
	// FailedOnly: versions.log holds entries, every one a failed run.
	FailedOnly bool `json:"failed_only,omitempty"`
	// Continued names each failed step the run carried on past.
	Continued []string `json:"continued,omitempty"`
}

// ReportKey marks the protocol line on stdout.
const ReportKey = "kasbah_deploy_report"

// FailureKey marks a failed run's protocol line on stdout: what the server
// was left as, for the workstation to say.
const FailureKey = "kasbah_deploy_failed"

// QuestionKey marks the line asking whether to carry on past a failed
// backup or pre-hook; the engine then reads one answer line on stdin.
const QuestionKey = "kasbah_deploy_question"

// Question is the line QuestionKey marks.
type Question struct {
	Step  string `json:"step"`
	Error string `json:"error"`
}

// AnswerWait is how long the engine waits for an answer before stopping.
const AnswerWait = 10 * time.Minute

// The answers to a Question. AnswerNoTTY is the workstation's "nothing could
// ask": the run stops and names the flag.
const (
	AnswerContinue = "continue"
	AnswerStop     = "stop"
	AnswerNoTTY    = "no-tty"
)

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
	// stdout carries the report and the question; in, the answer.
	stdout io.Writer
	in     *bufio.Reader
	// answerWait bounds the wait for an answer, both locks held meanwhile.
	answerWait time.Duration
	continued  []string
	now        func() time.Time
	sleep      func(time.Duration)
	preName    string
	postName   string
	verb       string
	// lockFile and serverLock hold their flocks until the run returns; any
	// exit releases them.
	lockFile, serverLock *os.File
	// What a failure needs to say and undo.
	logRead, history, retagged bool
	prev, lastFail             string
	// outgoing names the backup: the version live at the run's start. bdir
	// is the backup directory's name in broot, backups/, "" for none; modes
	// are the real modes of the directories its snapshot copies widened.
	outgoing, bdir string
	broot          *os.Root
	modes          map[string]fs.FileMode
	backupPath     string
	digest         string
	prevIDs        map[string]string
	liveBefore     []string
	// liveSvc is each live container's service, so a revert waits on the
	// replica that replaced a rolled one.
	liveSvc map[string]string
	failure *Failure
	// move is the snapshot's move's state (moveRenaming…); a signal's
	// cleanup freezes it at moveStopped.
	move atomic.Int32
	// raw is the process's own stderr, stderr's unwrapped: os.Exit does not
	// wait for stderr to drain, so a signal's cleanup writes here.
	raw io.Writer
	// rdir is a rollback's extraction of its target's backup, "" for none;
	// rpop unregisters its signal cleanup.
	rdir string
	rpop func()
	// unpackFailed: the extraction failed, so the restore hook never runs.
	unpackFailed bool
}

func (e *engine) note(format string, a ...any) {
	fmt.Fprintf(e.stderr, "remote: "+format+"\n", a...)
}

// noteRaw is note on raw, in one write, for a line written on the way out.
func (e *engine) noteRaw(format string, a ...any) {
	w := e.raw
	if w == nil {
		w = e.stderr
	}
	fmt.Fprintf(w, "remote: "+format+"\n", a...)
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

// Engine is `kasbah remote deploy run DIR`, the Spec on stdin; raw is the
// process's stderr that stderr wraps.
func Engine(dir string, stdin io.Reader, stdout, stderr, raw io.Writer) int {
	return engineMain(dir, stdin, stdout, stderr, raw, AnswerWait)
}

func engineMain(dir string, stdin io.Reader, stdout, stderr, raw io.Writer, answerWait time.Duration) int {
	// The spec is one line, read whole: what follows it is the answer channel.
	var sp Spec
	in := bufio.NewReader(stdin)
	line, err := in.ReadString('\n')
	if err == nil || (err == io.EOF && line != "") {
		err = json.Unmarshal([]byte(line), &sp)
	}
	if err != nil {
		fmt.Fprintf(stderr, "remote: deploy: no readable deploy spec on stdin (%v) — nothing was changed\n", err)
		return 1
	}
	e := &engine{dir: strings.TrimSuffix(dir, "/"), sp: sp, stderr: stderr, raw: raw, stdout: stdout,
		in: in, answerWait: answerWait, now: time.Now, sleep: time.Sleep}
	r, err := e.run()
	if e.broot != nil {
		defer e.broot.Close()
	}
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
	defer e.dropRestore()
	rep, err := e.locked(composeMissing)
	if err != nil && !e.retagged && e.failure == nil {
		err = e.unchanged(err)
	}
	return rep, err
}

// locked is the run under .deploy.lock.
func (e *engine) locked(composeMissing error) (*Report, error) {
	sp := e.sp
	e.clearRestores()
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
	// A failed run left its version live only past its post-hook; after a
	// failed revert, the snapshot is the version before it.
	e.outgoing = "unknown"
	if n := len(entries); n > 0 {
		v := prev
		if last := entries[n-1]; last.OK && (!last.IsFailed() || last.Reason == "post-hook") {
			v = last.Version
		}
		if safeName(v) {
			e.outgoing = v
		}
	}
	if err := e.preflight(); err != nil {
		return nil, err
	}
	if e.history {
		if err := checkBackups(e.dir); err != nil {
			return nil, err
		}
	}
	e.backupPath, e.digest = "no-backup", "-"
	// Any entry, a failed run's included, means an outgoing stack to act on.
	if e.history {
		if sp.Mode == "deploy" {
			if err := e.backupDir(); err != nil {
				if err = e.pastFailure("backup", err); err != nil {
					return nil, err
				}
			} else if err := e.hooks("backup", sp.Backup, func(err error) error { return e.pastFailure("backup hook", err) }); err != nil {
				return nil, err
			}
		}
	} else if skipped := e.firstSkips(); skipped != "" {
		if sp.Mode == "deploy" {
			e.note("first deploy — versions.log has no entry for this project, so %s will not run", skipped)
		} else {
			e.note("versions.log has no entry for this project, so %s will not run", skipped)
		}
	}
	rollback := sp.Mode == "rollback"
	if rollback && e.needsRestoreDir() {
		if err := e.extract(); err != nil {
			e.unpackFailed = true
			if err = e.pastFailure("backup extraction", err); err != nil {
				return nil, err
			}
		}
	}
	if sp.SkipHooks {
		e.note("%s hooks skipped (--skip-hooks)", e.preName)
	} else if e.history {
		if err := e.hooks(e.preName, sp.Pre, func(err error) error { return e.pastFailure(e.preName+" hook", err) }); err != nil {
			return nil, err
		}
	}
	// The data goes back while the outgoing containers still serve it.
	if rollback && sp.RestoreData && e.unpackFailed {
		e.note("data not restored: the backup could not be extracted")
	} else if rollback && sp.RestoreData {
		if err := e.hooks("restore", sp.Restore, func(err error) error { return e.pastFailure("restore hook", err) }); err != nil {
			return nil, err
		}
	}
	ids, err := e.currentIDs()
	if err != nil {
		return nil, err
	}
	// The ids the live stack started from: a kept snapshot's, from the run
	// that first took it.
	e.prevIDs = pinIDs(e.dir, sp.Snapshot, sp.Images, ids, e.stderr)
	e.liveBefore = e.liveContainers()
	e.liveSvc = map[string]string{}
	for _, c := range e.projectContainers() {
		e.liveSvc[c.name] = c.svc
	}
	e.retagged = true
	if err := e.retag(); err != nil {
		return nil, e.failed("up", err)
	}
	digest, err := e.digests()
	if err != nil {
		return nil, e.failed("up", err)
	}
	e.digest = digest
	if reason, err := e.upStack(); err != nil {
		return nil, e.failed(reason, err)
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
	} else if err := e.hooks(e.postName, sp.Post, nil); err != nil {
		return nil, e.postFailed(err)
	}

	e.keep()
	if err := e.record(sp.Mode); err != nil {
		e.failure = &Failure{Outcome: Unrecorded, Reason: "record", Prev: e.prev}
		return nil, failf("%v — %s %s is live: its containers are up and healthy and its hooks ran, and versions.log does not record it", err, e.project, sp.Version)
	}
	e.prune()
	return &Report{Version: sp.Version, PrevVersion: prev, DeployedBefore: before, Backup: e.backupPath, Digest: digest,
		ArchiveOnly: e.archiveOnly, FailedOnly: e.history && !before, Continued: e.continued}, nil
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
	e.restoreNotes(res)
	saved := e.saved(res)
	switch {
	case errors.Is(err, errForeign):
		e.note("%v", err)
		return failf("the %s of %s stopped before anything was started; its files are on the server beside the running stack%s", e.sp.Mode, e.sp.Version, e.leftDir())
	case err != nil:
		e.failure = &Failure{Outcome: Unrestored, Reason: "start", Prev: e.prev, Saved: res.Saved}
		return failf("the %s of %s stopped before anything was started, and putting back the files it had shipped failed: %v (%s%s) — %s/%s is kept, and the next run starts from it%s%s", e.sp.Mode, e.sp.Version, err, res.what(), e.mixed(res), e.dir, PrevDir, saved, e.leftDir())
	}
	dropSnapshot(e.dir)
	e.dropDir()
	e.failure = &Failure{Outcome: Restored, Reason: "start", Prev: e.prev, Saved: res.Saved}
	return failf("the %s of %s stopped before anything was started, and the files it had shipped were put back%s", e.sp.Mode, e.sp.Version, saved)
}

func (e *engine) restoreNotes(res *restored) {
	if res != nil {
		for _, n := range res.Notes {
			e.note("%s", n)
		}
	}
}

// mixed is the clause naming targets a restore left half done, "" for none.
func (e *engine) mixed(res *restored) string {
	if res == nil || len(res.Partial) == 0 {
		return ""
	}
	return "; " + res.mixed(e.prev, e.sp.Version)
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
		e.dropDir()
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
	return failf("the %s of %s failed (%s), and so did the revert to %s — %s. %s%s%s", e.sp.Mode, v, reason, e.was(), state, logged, saved, e.leftDir())
}

// revert returns what the restore did and, on failure, the state it left
// the server in.
func (e *engine) revert() (string, *restored, error) {
	v := e.sp.Version
	res, err := restore(e.dir, e.sp.Snapshot)
	e.restoreNotes(res)
	if err != nil {
		return res.what() + e.mixed(res) + " — the rest of the files, :current and whatever compose up left are " + v + "'s", res, err
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
	if err := e.healthWait(e.beforeTargets()); err != nil {
		return "the old stack is up again and not healthy", err
	}
	return "", nil
}

// beforeTargets is liveBefore now: a container a roll replaced stands for
// its service's running replicas.
func (e *engine) beforeTargets() []string {
	now := e.projectContainers()
	if len(now) == 0 {
		return e.liveBefore
	}
	var out []string
	for _, b := range e.liveBefore {
		if slices.ContainsFunc(now, func(c ctr) bool { return c.name == b }) {
			out = append(out, b)
			continue
		}
		for _, c := range now {
			if svc := e.liveSvc[b]; svc != "" && c.svc == svc && c.running && !slices.Contains(out, c.name) {
				out = append(out, c.name)
			}
		}
	}
	return out
}

// postFailed: the new version is live and its hook may have changed data, so
// nothing is reverted; deploy-failed records it.
func (e *engine) postFailed(cause error) error {
	e.note("%v", cause)
	e.keep()
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

// firstSkips names the outgoing steps a run with no history leaves out.
func (e *engine) firstSkips() string {
	var steps []string
	if e.sp.Mode == "deploy" && len(e.sp.Backup) > 0 {
		steps = append(steps, "the backup hooks")
	}
	if !e.sp.SkipHooks && len(e.sp.Pre) > 0 {
		steps = append(steps, "the "+e.preName+" hooks")
	}
	return strings.Join(steps, " and ")
}

// pastFailure is a failed backup or pre-hook's answer, from the Spec or else
// asked over the report channel: nil carries the run on as if it had passed.
// Nothing but the synced files has changed yet.
func (e *engine) pastFailure(step string, cause error) error {
	answer, how := e.sp.OnHookFailure, "--on-hook-failure=continue"
	if answer == "" {
		answer, how = e.ask(step, cause), "answered continue"
	}
	switch answer {
	case AnswerContinue:
		e.note("%v", cause)
		e.note("continuing past the failed %s (%s)", step, how)
		e.continued = append(e.continued, step)
		return nil
	case AnswerNoTTY:
		return failf("%v — there was no terminal to ask whether to %s anyway; pass --on-hook-failure=continue or --on-hook-failure=stop", cause, e.verb)
	case AnswerStop:
	default:
		e.note("the answer to whether to %s past the failed %s was %q, not continue or stop — stopping", e.verb, step, answer)
	}
	return cause
}

// ask writes the question and waits up to answerWait for one answer line; a
// dropped session (EOF) or no answer in time is stop.
func (e *engine) ask(step string, cause error) string {
	if e.stdout == nil || e.in == nil {
		return AnswerStop
	}
	b, _ := json.Marshal(Question{Step: step, Error: cause.Error()})
	fmt.Fprintf(e.stdout, "{\"%s\":1,%s\n", QuestionKey, b[1:])
	type reply struct {
		line string
		err  error
	}
	got := make(chan reply, 1)
	go func() {
		line, err := e.in.ReadString('\n')
		got <- reply{line, err}
	}()
	select {
	case r := <-got:
		if r.err != nil {
			e.note("no answer came back to whether to %s past the failed %s — stopping", e.verb, step)
			return AnswerStop
		}
		return strings.TrimSpace(r.line)
	case <-time.After(e.answerWait):
		e.note("no answer came back within %s to whether to %s past the failed %s — stopping", waitText(e.answerWait), e.verb, step)
		return AnswerStop
	}
}

func waitText(d time.Duration) string {
	if d >= time.Minute && d%time.Minute == 0 {
		return fmt.Sprintf("%d minutes", d/time.Minute)
	}
	return d.String()
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

// hooks run each entry as `sh -c` from the project directory, with no stdin
// (the engine's is the answer channel), COMPOSE_PROJECT_NAME set and
// KASBAH_BACKUP_DIR a deploy's backup directory, a rollback's extraction of
// its target's backup, or none.
// A failure goes to onFail, whose nil runs the next entry; none ends the list.
func (e *engine) hooks(what string, list []string, onFail func(error) error) error {
	for _, h := range list {
		e.note("%s hook: %s", what, h)
		c := e.sh(h)
		bdir := "none"
		switch {
		case e.sp.Mode == "rollback":
			if e.rdir != "" {
				bdir = e.rdir
			}
		case e.bdir != "":
			bdir = e.bdirPath()
		}
		c.Env = append(c.Env, "KASBAH_VERSION="+e.sp.Version, "KASBAH_PREV_VERSION="+e.prev, "KASBAH_PROJECT="+e.project,
			"KASBAH_BACKUP_DIR="+bdir, "COMPOSE_PROJECT_NAME="+e.project)
		if err := c.Run(); err != nil {
			err = failf("the %s hook failed (exit %d): %s", what, exitStatus(err), h)
			if onFail == nil {
				return err
			}
			if err = onFail(err); err != nil {
				return err
			}
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
		t, _ := e.target(container)
		return e.healthWait([]string{t})
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

// Converse reads the engine's stdout to its end, answering each question line
// through ask on w, which it closes once stdout ends. It returns all it read.
func Converse(r io.Reader, w io.WriteCloser, ask func(Question) string) string {
	defer w.Close()
	var all strings.Builder
	br := bufio.NewReader(r)
	for {
		line, err := br.ReadString('\n')
		all.WriteString(line)
		if l := strings.TrimRight(line, "\r\n"); strings.HasPrefix(l, "{\""+QuestionKey+"\":") && err == nil {
			var q Question
			answer := AnswerStop
			if json.Unmarshal([]byte(l), &q) == nil && ask != nil {
				answer = ask(q)
			}
			io.WriteString(w, answer+"\n")
		}
		if err != nil {
			return all.String()
		}
	}
}
