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
	"syscall"
	"time"
	"unicode"

	"github.com/adigourdi/kasbah/internal/atexit"
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
	// lockFile holds the flock until the run returns; any exit releases it.
	lockFile *os.File
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
	if err != nil {
		fmt.Fprintf(stderr, "remote: %v\n", err)
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
	if fi, err := os.Stat(filepath.Join(e.dir, "compose.yml")); err != nil || fi.IsDir() {
		return nil, failf("%s/compose.yml is missing — the project's sync: list must map its compose file to compose.yml", e.dir)
	}
	if _, err := os.Stat(filepath.Join(e.dir, ".env")); err != nil {
		return nil, failf("%s/.env is missing — compose reads the project's values from it", e.dir)
	}

	if err := e.lock(); err != nil {
		return nil, err
	}
	if err := e.preflight(); err != nil {
		return nil, err
	}
	last, err := vlog.LastLine(e.dir)
	if err != nil {
		return nil, failf("could not read %s/%s", e.dir, vlog.Log)
	}
	prev := ""
	if en := vlog.Parse(last); last != "" && en.OK {
		prev = en.Version
	}
	// An absent active log is not a first deploy while the archive holds
	// entries: rotation never empties the log, so it was lost or replaced.
	if last == "" {
		if fi, err := os.Stat(filepath.Join(e.dir, vlog.Archive)); err == nil && fi.Size() > 0 {
			e.archiveOnly = true
		}
	}
	before := last != "" || e.archiveOnly
	if err := e.outgoing(prev, before); err != nil {
		return nil, err
	}

	backup := "no-backup"
	if sp.Mode == "deploy" {
		if backup, err = e.backup(); err != nil {
			return nil, err
		}
	}
	if sp.SkipHooks {
		e.note("%s hooks skipped (--skip-hooks)", e.preName)
	} else if err := e.hooks(e.preName, true, prev, backup, sp.Pre); err != nil {
		return nil, err
	}
	if err := e.retag(); err != nil {
		return nil, err
	}
	digest, err := e.digests()
	if err != nil {
		return nil, err
	}
	if e.docker("compose", "-p", e.project, "up", "-d", "--remove-orphans").Run() != nil {
		return nil, failf("docker compose -p %s up -d --remove-orphans failed in %s", e.project, e.dir)
	}
	if sp.NoHealthWait {
		e.note("health wait skipped (--no-health-wait)")
	} else if err := e.healthWait(); err != nil {
		return nil, err
	}
	if sp.SkipHooks {
		e.note("%s hooks skipped (--skip-hooks)", e.postName)
	} else if err := e.hooks(e.postName, false, prev, backup, sp.Post); err != nil {
		return nil, err
	}

	kv := sp.Kasbah
	if kv == "" {
		kv = "unknown"
	}
	line, err := vlog.Line(vlog.Stamp(e.now()), sp.Mode, sp.Version, backup, kv, digest)
	if err != nil {
		return nil, fatal{err.Error()}
	}
	repaired, err := vlog.Append(e.dir, line)
	if repaired {
		e.note("the last line of versions.log had no newline on it — an append that was interrupted. Terminated it rather than writing into it; it is left exactly as it stands.")
	}
	if err != nil {
		return nil, fatal{err.Error()}
	}
	// Never the run's status: a failed compaction must not cost the route.
	moved, cut, rerr := vlog.Rotate(e.dir, e.now())
	switch {
	case rerr != nil:
		e.note("%v", rerr)
	case moved > 0:
		e.note("versions.log: %d entries older than %s moved to versions.log.gz", moved, vlog.MonthName(cut))
	}
	return &Report{Version: sp.Version, PrevVersion: prev, DeployedBefore: before, Backup: backup, Digest: digest, ArchiveOnly: e.archiveOnly}, nil
}

// lock is flock(2) on .deploy.lock, held until the process exits — the lock
// util-linux's flock takes, so `drop` sees the same one.
func (e *engine) lock() error {
	path := filepath.Join(e.dir, ".deploy.lock")
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
	if err != nil {
		return failf("could not open the lock file %s", path)
	}
	rc, err := f.SyscallConn()
	if err != nil {
		return failf("could not open the lock file %s", path)
	}
	var lerr error
	rc.Control(func(fd uintptr) { lerr = syscall.Flock(int(fd), syscall.LOCK_EX|syscall.LOCK_NB) })
	if lerr != nil {
		f.Close()
		return failf("another deploy or rollback is already running in %s — it holds the lock on %s", e.dir, path)
	}
	e.lockFile = f
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
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o666)
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

// healthWait polls under one deadline, health.timeout, for the whole wait. A
// container with no healthcheck passes at once.
func (e *engine) healthWait() error {
	var targets []string
	if c := e.sp.Health.Container; c != "" {
		targets = []string{c}
	} else {
		out, err := e.query("compose", "-p", e.project, "ps", "-q")
		if err != nil {
			return failf("could not list the containers of compose project %s", e.project)
		}
		for _, t := range strings.Split(out, "\n") {
			if t = strings.TrimSpace(t); t != "" {
				targets = append(targets, t)
			}
		}
	}
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
