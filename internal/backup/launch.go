package backup

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/dockerapi"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// hostMount is where the launcher container mounts the host's /, and Binary
// where it mounts the server's kasbah read-only: the daemon resolves a bind's
// source on the host, so a symlinked apps path reaches the right file.
const (
	hostMount = "/host"
	Binary    = "/kasbah"
)

// HostRoot is the host's / as Launch sees it. A seam for the tests.
var HostRoot = hostMount

// LaunchGrace is how long, in seconds, past the job's own deadline the
// scheduler waits before stopping the launcher: more than the job's
// SIGTERM-to-SIGKILL. A seam for the tests.
var LaunchGrace = 60

// StopGrace is the launcher's stop signal's grace before docker kills it.
const StopGrace = 10 * time.Second

// HostUser is a user as the host resolves it.
type HostUser struct {
	Name     string
	Uid, Gid uint32
	Home     string
	// Groups is every group the user is in, its primary one first.
	Groups []uint32
}

// HasGid is whether gid is one of the user's groups.
func (u *HostUser) HasGid(gid uint32) bool {
	for _, g := range u.Groups {
		if g == gid {
			return true
		}
	}
	return false
}

// How a user was resolved: the host's id and getent, through its NSS, or
// its /etc/passwd and /etc/group where it has no id.
const (
	ViaID    = "id"
	ViaFiles = "files"
)

// errNoTool is a host without the tool asked for.
var errNoTool = errors.New("not on the host")

// hostOutput is a host tool's stdout, run as /usr/bin/TOOL or /bin/TOOL
// chrooted into root ("" for none) with the C locale. A seam for the tests.
var hostOutput = func(root, tool string, args ...string) (string, error) {
	for _, dir := range []string{"/usr/bin/", "/bin/"} {
		c := exec.Command(dir+tool, args...)
		c.SysProcAttr = &syscall.SysProcAttr{Chroot: root}
		c.Dir, c.Env = "/", []string{"PATH=" + hostPath, "LC_ALL=C"}
		out, err := c.Output()
		if errors.Is(err, fs.ErrNotExist) {
			continue
		}
		return string(out), err
	}
	return "", errNoTool
}

// hostPath is the PATH host tools run with.
const hostPath = "/usr/local/bin:/usr/bin:/bin"

// ResolveUser is name as the host under root resolves it, and how: through
// its own id (NSS, so LDAP and sssd users too), its files only without id.
// nil for a user the host does not have.
func ResolveUser(root, name string) (*HostUser, string, error) {
	uid, err := hostOutput(root, "id", "-u", name)
	if errors.Is(err, errNoTool) {
		u, err := LookupUser(root, name)
		return u, ViaFiles, err
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return nil, ViaID, nil
	}
	if err != nil {
		return nil, ViaID, fmt.Errorf("could not run the host's id: %v", err)
	}
	// An id -G that exits 1 could not get the group list: what it printed is partial.
	var out [2]string
	for i, flag := range []string{"-g", "-G"} {
		out[i], err = hostOutput(root, "id", flag, name)
		if err != nil {
			return nil, ViaID, fmt.Errorf("the host's id %s %s failed: %v", flag, name, err)
		}
	}
	u, err := parseID(name, uid, out[0], out[1])
	if err != nil {
		return nil, ViaID, err
	}
	pw, err := hostOutput(root, "getent", "passwd", name)
	if errors.Is(err, errNoTool) {
		if f, _ := LookupUser(root, name); f != nil {
			u.Home = f.Home
		}
	} else if f := strings.Split(strings.TrimSpace(pw), ":"); err == nil && len(f) >= 7 {
		u.Home = f[5]
	}
	return u, ViaID, nil
}

// parseID is a user out of `id -u`, `id -g` and `id -G`: numbers only, as a
// group's name may hold spaces.
func parseID(name, uid, gid, groups string) (*HostUser, error) {
	num := func(s string) (uint32, error) {
		n, err := strconv.ParseUint(strings.TrimSpace(s), 10, 32)
		return uint32(n), err
	}
	u := &HostUser{Name: name}
	var e1, e2 error
	u.Uid, e1 = num(uid)
	u.Gid, e2 = num(gid)
	gs := strings.Fields(groups)
	if e1 != nil || e2 != nil || len(gs) == 0 {
		return nil, fmt.Errorf("the host's id gave no uid, gid and groups for %s (uid %q, gid %q, groups %q)",
			name, strings.TrimSpace(uid), strings.TrimSpace(gid), strings.TrimSpace(groups))
	}
	u.Groups = []uint32{u.Gid}
	for _, g := range gs {
		n, err := num(g)
		if err != nil {
			return nil, fmt.Errorf("the host's id gave %s a group that is not a number: %q", name, g)
		}
		if n != u.Gid {
			u.Groups = append(u.Groups, n)
		}
	}
	return u, nil
}

// LookupUser reads name out of root's /etc/passwd and /etc/group, the
// fallback on a host without id; nil without such a user.
func LookupUser(root, name string) (*HostUser, error) {
	pw, err := os.ReadFile(root + "/etc/passwd")
	if err != nil {
		return nil, fmt.Errorf("could not read %s/etc/passwd: %v", root, err)
	}
	var u *HostUser
	for _, l := range strings.Split(string(pw), "\n") {
		f := strings.Split(strings.TrimSuffix(l, "\r"), ":")
		if len(f) < 7 || f[0] != name {
			continue
		}
		uid, e1 := strconv.ParseUint(f[2], 10, 32)
		gid, e2 := strconv.ParseUint(f[3], 10, 32)
		if e1 != nil || e2 != nil {
			return nil, fmt.Errorf("%s/etc/passwd's line for %s has no numeric uid and gid", root, name)
		}
		u = &HostUser{Name: name, Uid: uint32(uid), Gid: uint32(gid), Home: f[5], Groups: []uint32{uint32(gid)}}
		break
	}
	if u == nil {
		return nil, nil
	}
	gr, err := os.ReadFile(root + "/etc/group")
	if err != nil {
		return nil, fmt.Errorf("could not read %s/etc/group: %v", root, err)
	}
	for _, l := range strings.Split(string(gr), "\n") {
		f := strings.Split(strings.TrimSuffix(l, "\r"), ":")
		if len(f) < 4 {
			continue
		}
		gid, err := strconv.ParseUint(f[2], 10, 32)
		if err != nil {
			continue
		}
		if uint32(gid) == u.Gid {
			continue
		}
		for _, m := range strings.Split(f[3], ",") {
			if m == name {
				u.Groups = append(u.Groups, uint32(gid))
				break
			}
		}
	}
	return u, nil
}

// groupGid is the gid of the group named g as the host under root resolves
// it, through its getent, its /etc/group without getent; false for none.
func groupGid(root, g string) (uint32, bool, error) {
	line, err := hostOutput(root, "getent", "group", g)
	var ee *exec.ExitError
	switch {
	case errors.Is(err, errNoTool):
		b, err := os.ReadFile(root + "/etc/group")
		if err != nil {
			return 0, false, fmt.Errorf("could not read %s/etc/group: %v", root, err)
		}
		line = ""
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(strings.TrimSuffix(l, "\r"), g+":") {
				line = l
				break
			}
		}
	case errors.As(err, &ee):
		return 0, false, nil
	case err != nil:
		return 0, false, fmt.Errorf("could not run the host's getent group %s: %v", g, err)
	}
	f := strings.Split(strings.TrimSpace(line), ":")
	if len(f) < 3 || f[0] != g {
		return 0, false, nil
	}
	n, err := strconv.ParseUint(f[2], 10, 32)
	if err != nil {
		return 0, false, fmt.Errorf("the host's group %s has no numeric gid: %q", g, f[2])
	}
	return uint32(n), true, nil
}

// inGroup is whether u is in the group named g: its gid among u's groups.
func inGroup(root string, u *HostUser, g string) (bool, error) {
	gid, ok, err := groupGid(root, g)
	return ok && u.HasGid(gid), err
}

// UserCheck is `kasbah remote backup-init user NAME APPS`: the nightly job's
// user as this host resolves it — backup_user=ok, absent or root, how it was
// looked up, and whether it is in kasbah and docker and owns APPS.
func UserCheck(name, apps string, stdout io.Writer) error {
	u, via, err := ResolveUser("", name)
	if err != nil {
		return err
	}
	yn := func(b bool) string {
		if b {
			return "yes"
		}
		return "no"
	}
	switch {
	case u == nil:
		fmt.Fprintf(stdout, "backup_user=absent\nbackup_user_via=%s\n", via)
	case u.Uid == 0:
		fmt.Fprintf(stdout, "backup_user=root\nbackup_user_via=%s\n", via)
	default:
		kasbah, err := inGroup("", u, serverlock.Group)
		if err != nil {
			return err
		}
		docker, err := inGroup("", u, "docker")
		if err != nil {
			return err
		}
		owner := false
		if fi, err := os.Stat(apps); err == nil {
			if st, ok := fi.Sys().(*syscall.Stat_t); ok {
				owner = st.Uid == u.Uid
			}
		}
		fmt.Fprintf(stdout, "backup_user=ok\nbackup_user_via=%s\nbackup_user_kasbah=%s\nbackup_user_docker=%s\nbackup_user_owner=%s\n",
			via, yn(kasbah), yn(docker), yn(owner))
	}
	return nil
}

// launchCmd is the host job, entered from the launcher container: chrooted
// into the host's /, as u with its groups, in an environment of its own.
func launchCmd(u *HostUser, apps, secs string) *exec.Cmd {
	c := exec.Command(apps+"/.kasbah/bin/kasbah", "remote", "backup", "host", apps, secs)
	c.SysProcAttr = &syscall.SysProcAttr{Chroot: HostRoot,
		Credential: &syscall.Credential{Uid: u.Uid, Gid: u.Gid, Groups: u.Groups}}
	c.Dir = "/"
	c.Env = []string{"PATH=" + hostPath, "LC_ALL=C", "HOME=" + u.Home, "USER=" + u.Name, "LOGNAME=" + u.Name}
	return c
}

// startJob starts the host job. A seam for the tests, which cannot setuid.
var startJob = func(c *exec.Cmd) error { return c.Start() }

// The first words of the launcher's own result lines: who it enters the
// host as, or why the job did not start.
const (
	LaunchEntered = "entering"
	LaunchFailed  = "launcher"
)

// Launch is `kasbah remote backup launch USER APPS SECONDS`, the launcher's
// entrypoint, as root: resolves the user through the host's tools, becomes the
// host job, passes its exit status and stop signal through; 125 if not started.
func Launch(args []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		msg := fmt.Sprintf(format, a...)
		fmt.Fprintf(stdout, "%s %s\n", LaunchFailed, oneLine(msg))
		fmt.Fprintf(stderr, "kasbah-backup launcher: %s\n", msg)
		return 125
	}
	if len(args) != 3 {
		return fail("usage: launch USER APPS SECONDS")
	}
	name, apps, secs := args[0], args[1], args[2]
	if !reUser.MatchString(name) {
		return fail("'%s' is not a user name", name)
	}
	if !filepath.IsAbs(apps) || filepath.Clean(apps) != apps {
		return fail("the apps path '%s' is not a clean absolute path", apps)
	}
	if n, err := strconv.Atoi(secs); !reDigits.MatchString(secs) || err != nil || n <= 0 {
		return fail("the deadline '%s' is not a positive whole number of seconds", secs)
	}
	remedy := " — re-run kasbah server init --with-backup --backup-user=NAME"
	u, via, err := ResolveUser(HostRoot, name)
	if err != nil {
		return fail("could not resolve the user %s on the host (through %s): %v", name, viaName(via), err)
	}
	if u == nil {
		return fail("the host has no user '%s' (looked up through %s)%s", name, viaName(via), remedy)
	}
	if u.Uid == 0 {
		return fail("the backup user %s is root on the host, and the nightly job never runs as root%s", name, remedy)
	}
	syscall.Umask(0o002)
	c := launchCmd(u, apps, secs)
	c.Stdout, c.Stderr = stdout, stderr
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(sig)
	fmt.Fprintf(stdout, "%s the host as %s: uid %d, gid %d, groups %s, resolved through %s\n", LaunchEntered, name, u.Uid, u.Gid, joinIDs(u.Groups), viaName(via))
	if err := startJob(c); err != nil {
		return fail("could not enter the host as %s (uid %d, gid %d, groups %s, resolved through %s): %v", name, u.Uid, u.Gid, joinIDs(u.Groups), viaName(via), err)
	}
	go func() {
		for s := range sig {
			c.Process.Signal(s)
		}
	}()
	return ssh.ExitCode(c.Wait())
}

func joinIDs(ids []uint32) string {
	l := make([]string, len(ids))
	for i, n := range ids {
		l[i] = strconv.FormatUint(uint64(n), 10)
	}
	return strings.Join(l, ",")
}

// viaName is how a user was resolved, in words.
func viaName(via string) string {
	if via == ViaFiles {
		return "the host's /etc/passwd and /etc/group, as it has no id"
	}
	return "the host's id"
}

// Engine is the Docker Engine API as the scheduler uses it.
type Engine interface {
	Create(ctx context.Context, name string, cfg dockerapi.Config) (string, error)
	Start(ctx context.Context, id string) error
	Wait(ctx context.Context, id string) (int, error)
	Stop(ctx context.Context, id string, grace time.Duration) error
	Remove(ctx context.Context, id string) error
	List(ctx context.Context, label string) ([]dockerapi.Container, error)
	Logs(ctx context.Context, id string, outMax, errMax int) (dockerapi.Output, error)
}

// Failure is a project the nightly job did not back up, and why.
type Failure struct{ Project, Reason string }

// apiBound is the bound on any one API call but the wait.
const apiBound = time.Minute

// ReportMax is how much of the job's report, its stdout, the scheduler
// reads: the tail, where the result lines are. ErrMax is how much of its
// stderr, the hooks' output, it reads and shows after a failed run.
const (
	ReportMax = 4 << 20
	ErrMax    = 64 << 10
)

func (r *Runner) api() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), apiBound)
}

// launcherConfig is the launcher: the restic image, the host's / read-write,
// the server's kasbah as entrypoint, host network, its own pid namespace, an
// init, no privilege, and a json-file log the scheduler can read back.
func (r *Runner) launcherConfig() dockerapi.Config {
	return dockerapi.Config{
		Image:      r.Image,
		Entrypoint: []string{Binary},
		Cmd:        []string{"remote", "backup", "launch", r.User, r.Apps, strconv.Itoa(r.HookTimeout)},
		Env:        []string{},
		Labels:     map[string]string{LauncherLabel: "1"},
		HostConfig: dockerapi.HostConfig{
			Binds:       []string{"/:" + hostMount, r.Apps + "/.kasbah/bin/kasbah:" + Binary + ":ro"},
			NetworkMode: "host", Init: true,
			LogConfig: &dockerapi.LogConfig{Type: "json-file", Config: map[string]string{"max-size": "10m", "max-file": "3"}},
		},
	}
}

// sweepLaunchers removes labelled launchers: every one when all (at the
// scheduler's start, when none can be another run's), else only the exited
// and those older than a whole job. A live one it leaves is named.
func (r *Runner) sweepLaunchers(all bool) (live string, err error) {
	ctx, cancel := r.api()
	defer cancel()
	l, err := r.Docker.List(ctx, LauncherLabel)
	if err != nil {
		return "", err
	}
	for _, c := range l {
		name := strings.TrimPrefix(strings.Join(c.Names, ","), "/")
		age := r.Now().Unix() - c.Created
		done := c.State == "exited" || c.State == "dead"
		if !all && !done && age <= int64(r.HookTimeout+LaunchGrace) {
			live = fmt.Sprintf("%s, created %ds ago", name, age)
			continue
		}
		if c.State == "running" {
			r.Docker.Stop(ctx, c.Id, StopGrace)
		}
		if err := r.Docker.Remove(ctx, c.Id); err != nil {
			return "", fmt.Errorf("could not remove the leftover launcher %s: %v", name, err)
		}
		r.say("removed a leftover launcher, %s (%s, created %ds ago)", name, c.State, age)
	}
	return live, nil
}

// hostRun is the nightly job: the launcher started, waited on to the job's
// deadline and LaunchGrace, then stopped; removed whatever happened. The
// projects that failed, and why the launcher did, "" when it ran.
func (r *Runner) hostRun() ([]Failure, string) {
	if r.User == "" {
		return nil, "no backup user is configured (KASBAH_BACKUP_USER), so no project's backup hook ran — re-run kasbah server init --with-backup"
	}
	if fi, err := os.Stat(r.Socket); err != nil || fi.Mode()&os.ModeSocket == 0 {
		return nil, fmt.Sprintf("no Docker socket at %s in this container, so no project's backup hook ran — re-run kasbah server init --with-backup, which mounts it", r.Socket)
	}
	live, err := r.sweepLaunchers(false)
	if err != nil {
		return nil, "could not clear the launchers left over: " + err.Error()
	}
	if live != "" {
		return nil, "a nightly job is already running (" + live + "), so this run took no new backups and pushed what backups/ already holds"
	}
	ctx, cancel := r.api()
	id, err := r.Docker.Create(ctx, Launcher, r.launcherConfig())
	cancel()
	if err != nil {
		return nil, fmt.Sprintf("could not create the launcher container from %s: %v", r.Image, err)
	}
	defer func() {
		ctx, cancel := r.api()
		defer cancel()
		if err := r.Docker.Remove(ctx, id); err != nil {
			r.warn("could not remove the launcher %s: %v — the next run removes it", Launcher, err)
		}
	}()
	ctx, cancel = r.api()
	err = r.Docker.Start(ctx, id)
	cancel()
	if err != nil {
		return nil, "could not start the launcher container: " + err.Error()
	}
	r.say("launcher started: every project's backup hook, on the host as %s, within %ds", r.User, r.HookTimeout)
	why := ""
	wctx, wcancel := context.WithTimeout(context.Background(), time.Duration(r.HookTimeout+LaunchGrace)*time.Second)
	code, err := r.Docker.Wait(wctx, id)
	timedOut := err != nil && wctx.Err() != nil
	wcancel()
	switch {
	case timedOut:
		ctx, cancel := r.api()
		r.Docker.Stop(ctx, id, StopGrace)
		cancel()
		why = fmt.Sprintf("the host job was still running %ds past its %ds deadline and was stopped", LaunchGrace, r.HookTimeout)
	case err != nil:
		why = "could not wait on the launcher container: " + err.Error()
	}
	ctx, cancel = r.api()
	logs, err := r.Docker.Logs(ctx, id, ReportMax, ErrMax)
	cancel()
	if err != nil && why == "" {
		why = "could not read the host job's report back from the launcher's json-file log: " + err.Error()
	}
	out := logs.Stdout
	if logs.StdoutCut {
		out = dropFragment(out)
		r.warn("the host job's report ran past %d bytes; only its last %d were read", ReportMax, len(out))
	}
	fails, launcher, err := r.hostReport(out)
	if err != nil && why == "" {
		why = "could not read the host job's report: " + err.Error()
	}
	if why == "" {
		why = launcher
	}
	if why == "" && code != 0 && len(fails) == 0 {
		why = fmt.Sprintf("the host job exited %d without naming a project that failed", code)
	}
	if len(fails) > 0 || why != "" {
		r.stderrTail(logs.Stderr, logs.StderrCut)
	}
	return fails, why
}

// dropFragment is a cut tail without its first line, which may be partial.
func dropFragment(b []byte) []byte {
	if i := bytes.IndexByte(b, '\n'); i >= 0 {
		return b[i+1:]
	}
	return b
}

// stderrTail writes what was read of the launcher's stderr into the
// scheduler's own log, between two labelled lines, cut-marked when cut.
func (r *Runner) stderrTail(b []byte, cut bool) {
	if cut {
		b = dropFragment(b)
	}
	if len(bytes.TrimSpace(b)) == 0 {
		return
	}
	if cut {
		r.warn("the launcher's stderr tail, cut to its last %d bytes:", len(b))
	} else {
		r.warn("the launcher's stderr tail:")
	}
	r.Stderr.Write(b)
	if b[len(b)-1] != '\n' {
		io.WriteString(r.Stderr, "\n")
	}
	r.warn("end of the launcher's stderr tail")
}

// hostReport reads the job's result lines, saying each: the projects that
// failed, and the launcher's own reason when the job did not start.
func (r *Runner) hostReport(out []byte) ([]Failure, string, error) {
	var fails []Failure
	launcher := ""
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 64<<10), 1<<20)
	for sc.Scan() {
		line := strings.TrimSuffix(sc.Text(), "\r")
		if rest, ok := strings.CutPrefix(line, LaunchFailed+" "); ok {
			launcher = rest
			continue
		}
		if strings.HasPrefix(line, LaunchEntered+" ") {
			r.say("launcher %s", line)
			continue
		}
		f := strings.SplitN(line, " ", 4)
		if len(f) < 3 || f[0] != "project" {
			r.warn("host job: %s", line)
			continue
		}
		detail := ""
		if len(f) == 4 {
			detail = f[3]
		}
		switch f[2] {
		case "ok":
			r.say("%s: backed up on the host: %s", f[1], detail)
		case "skipped":
			r.say("%s: no backup taken: %s", f[1], detail)
		default:
			r.warn("%s: backup FAILED: %s", f[1], detail)
			fails = append(fails, Failure{f[1], detail})
		}
	}
	return fails, launcher, sc.Err()
}
