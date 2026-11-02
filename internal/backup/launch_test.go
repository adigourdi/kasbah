package backup

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/dockerapi"
)

var (
	sockOnce sync.Once
	sockDir  string
	sockLn   net.Listener
)

// testSocket is a unix socket that exists, which the runner asks for before
// it talks to its (fake) daemon: made on first use, removed by TestMain.
func testSocket() string {
	sockOnce.Do(func() {
		sockDir, _ = os.MkdirTemp("", "kbsock")
		sockLn, _ = net.Listen("unix", sockDir+"/docker.sock")
	})
	return sockDir + "/docker.sock"
}

func TestMain(m *testing.M) {
	code := m.Run()
	if sockLn != nil {
		sockLn.Close()
	}
	if sockDir != "" {
		os.RemoveAll(sockDir)
	}
	os.Exit(code)
}

// fakeEngine is a daemon whose one container runs the job its fields say.
type fakeEngine struct {
	mu        sync.Mutex
	calls     []string
	created   []dockerapi.Config
	leftovers []dockerapi.Container
	createErr error
	stdout    string
	cut       bool
	stderr    string
	errCut    bool
	logsErr   error
	code      int
	// hang makes the wait last until its context ends.
	hang bool
}

func (f *fakeEngine) log(s string) { f.mu.Lock(); f.calls = append(f.calls, s); f.mu.Unlock() }

func (f *fakeEngine) Create(_ context.Context, name string, cfg dockerapi.Config) (string, error) {
	f.log("create " + name)
	if f.createErr != nil {
		return "", f.createErr
	}
	f.created = append(f.created, cfg)
	return "job1", nil
}
func (f *fakeEngine) Start(_ context.Context, id string) error { f.log("start " + id); return nil }
func (f *fakeEngine) Wait(ctx context.Context, id string) (int, error) {
	f.log("wait " + id)
	if f.hang {
		<-ctx.Done()
		return -1, ctx.Err()
	}
	return f.code, nil
}
func (f *fakeEngine) Stop(_ context.Context, id string, g time.Duration) error {
	f.log("stop " + id + " " + g.String())
	return nil
}
func (f *fakeEngine) Remove(_ context.Context, id string) error { f.log("remove " + id); return nil }
func (f *fakeEngine) List(_ context.Context, label string) ([]dockerapi.Container, error) {
	f.log("list " + label)
	l := f.leftovers
	f.leftovers = nil
	return l, nil
}
func (f *fakeEngine) Logs(_ context.Context, id string, outMax, errMax int) (dockerapi.Output, error) {
	f.log("logs " + id)
	if outMax != ReportMax || errMax != ErrMax {
		return dockerapi.Output{}, fmt.Errorf("read %d bytes of the report and %d of stderr", outMax, errMax)
	}
	return dockerapi.Output{Stdout: []byte(f.stdout), StdoutCut: f.cut, Stderr: []byte(f.stderr), StderrCut: f.errCut}, f.logsErr
}

// The launcher: the restic image, / at /host, the server's kasbah read-only at
// /kasbah as entrypoint, host network, an init, its own pid namespace, no
// privilege, a json-file log with the scheduler's limits.
func TestLauncherConfig(t *testing.T) {
	r, _, _, _ := runner("/srv/apps", "/srv/apps/data", time.Now())
	r.User, r.HookTimeout = "stevedore", 600
	got := r.launcherConfig()
	if got.Image != ResticImage || strings.Join(got.Entrypoint, " ") != "/kasbah" ||
		strings.Join(got.Cmd, " ") != "remote backup launch stevedore /srv/apps 600" || len(got.Env) != 0 ||
		len(got.Labels) != 1 || got.Labels[LauncherLabel] != "1" {
		t.Errorf("%+v", got)
	}
	h := got.HostConfig
	if strings.Join(h.Binds, ",") != "/:/host,/srv/apps/.kasbah/bin/kasbah:/kasbah:ro" || h.NetworkMode != "host" || !h.Init ||
		h.Privileged || h.PidMode != "" || h.AutoRemove {
		t.Errorf("%+v", h)
	}
	if l := h.LogConfig; l == nil || l.Type != "json-file" || len(l.Config) != 2 || l.Config["max-size"] != "10m" || l.Config["max-file"] != "3" {
		t.Errorf("log config %+v", l)
	}
}

func onceTree(t *testing.T) (*Runner, *fakeEngine, string) {
	apps, data := appsTree(t)
	os.RemoveAll(apps + "/gamma")
	write(t, apps+"/.kasbah/backup/repos/mail.pass", "pw\n")
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=b/\n")
	r, _, _, _ := runner(apps, data, time.Unix(1700000000, 0))
	logf := t.TempDir() + "/log"
	r.Restic = stub(t, resticStub)
	r.Environ = append(r.Environ, "STUB_LOG="+logf)
	f := &fakeEngine{}
	r.Docker = f
	return r, f, logf
}

// Each project the job reports failed is in the record with its reason, the
// run is failed, the launcher's stderr tail is shown, and every repository is
// pushed all the same.
func TestOnceHostResults(t *testing.T) {
	r, f, logf := onceTree(t)
	f.code = 1
	f.stderr = "beta: backing up the live version\npg_dump: connection refused"
	f.stdout = "entering the host as deploy: uid 1001, gid 1001, groups 1001,997, resolved through the host's id\n" +
		"project alpha ok backups/1.0.0-20261102-020000.tar.gz 1.0.0\n" +
		"project beta failed the backup hook failed (exit 3): pg_dump\n" +
		"project web failed /apps/web/.kasbah-prev holds a deploy's snapshot taken no later than the last run; remove /apps/web/.kasbah-prev by hand, then back up\n" +
		"project stray skipped no live version\n"
	if rc := r.Run([]string{"once"}); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	out, errs := r.Stdout.(interface{ String() string }).String(), r.Stderr.(interface{ String() string }).String()
	for _, want := range []string{"launcher started: every project's backup hook, on the host as deploy, within 1800s",
		"launcher entering the host as deploy: uid 1001, gid 1001, groups 1001,997, resolved through the host's id",
		"alpha: backed up on the host: backups/1.0.0-", "stray: no backup taken: no live version", "run finished, repositories backed up: mail acme"} {
		if !strings.Contains(out, want) {
			t.Errorf("stdout lacks %q:\n%s", want, out)
		}
	}
	for _, want := range []string{"beta: backup FAILED: the backup hook failed (exit 3)",
		"kasbah-backup: the launcher's stderr tail:\nbeta: backing up the live version\npg_dump: connection refused\nkasbah-backup: end of the launcher's stderr tail\n",
		"backups that failed on the host, whose older backups were shipped instead: beta web"} {
		if !strings.Contains(errs, want) {
			t.Errorf("stderr lacks %q:\n%s", want, errs)
		}
	}
	if calls := read(t, logf); !strings.Contains(calls, "b/acme") || !strings.Contains(calls, "b/mail") {
		t.Errorf("the push did not run for everything:\n%s", calls)
	}
	if got := strings.Join(f.calls, ","); got != "list "+LauncherLabel+",create "+Launcher+",start job1,wait job1,logs job1,remove job1" {
		t.Errorf("api calls: %s", got)
	}
	rec := read(t, r.statefile())
	for _, want := range []string{"last_run_status=failed\n", "last_run_failed=beta the backup hook failed (exit 3): pg_dump\n",
		"last_run_failed=web /apps/web/.kasbah-prev holds"} {
		if !strings.Contains(rec, want) {
			t.Errorf("record lacks %q:\n%s", want, rec)
		}
	}
	got := backuprec.Read("dir", "file", rec, "1700000001")
	if got.Verdict != backuprec.Failed || len(got.Failed) != 2 || got.Failed[0].Project != "beta" || got.Launcher != "" {
		t.Errorf("%+v", got)
	}
	// The next run's record carries them until it replaces them.
	r.loadLastRun()
	if len(r.failed) != 2 || r.failed[1].Project != "web" {
		t.Errorf("carried %+v", r.failed)
	}
	f.code, f.stdout, f.stderr = 0, "project alpha ok x 1\n", "alpha: hook chatter\n"
	r.Stderr.(interface{ Reset() }).Reset()
	if rc := r.Run([]string{"once"}); rc != 0 || strings.Contains(read(t, r.statefile()), "last_run_failed") {
		t.Errorf("a clean run: rc %d\n%s", rc, read(t, r.statefile()))
	}
	if errs := r.Stderr.(interface{ String() string }).String(); strings.Contains(errs, "stderr tail") || strings.Contains(errs, "chatter") {
		t.Errorf("a clean run showed the stderr tail:\n%s", errs)
	}
}

// A launcher that cannot start fails the run with why, and the push still
// ships what backups/ holds.
func TestOnceLauncherFailures(t *testing.T) {
	for name, tc := range map[string]struct {
		set  func(r *Runner, f *fakeEngine)
		want string
	}{
		"no socket": {func(r *Runner, f *fakeEngine) { r.Socket = "/nonexistent/docker.sock" },
			"no Docker socket at /nonexistent/docker.sock in this container, so no project's backup hook ran — re-run kasbah server init --with-backup, which mounts it"},
		"no image": {func(r *Runner, f *fakeEngine) {
			f.createErr = &dockerapi.Error{Status: 404, Message: "No such image: restic/restic:0.18.0"}
		},
			"could not create the launcher container from " + ResticImage + ": No such image: restic/restic:0.18.0 (HTTP 404)"},
		"no user":       {func(r *Runner, f *fakeEngine) { r.User = "" }, "no backup user is configured"},
		"a silent exit": {func(r *Runner, f *fakeEngine) { f.code = 125 }, "the host job exited 125 without naming a project that failed"},
		"the launcher's own reason": {func(r *Runner, f *fakeEngine) {
			f.code, f.stdout = 125, "launcher the host has no user 'deploy' (looked up through the host's id) — re-run\n"
		}, "the host has no user 'deploy' (looked up through the host's id) — re-run"},
		"an unreadable log": {func(r *Runner, f *fakeEngine) {
			f.logsErr = errors.New("configured logging driver does not support reading")
		},
			"could not read the host job's report back from the launcher's json-file log: configured logging driver does not support reading"},
		"a live launcher": {func(r *Runner, f *fakeEngine) {
			f.leftovers = []dockerapi.Container{{Id: "other", Names: []string{"/" + Launcher}, State: "running", Created: 1700000000 - 100}}
		}, "a nightly job is already running (" + Launcher + ", created 100s ago), so this run took no new backups"},
	} {
		t.Run(name, func(t *testing.T) {
			r, f, logf := onceTree(t)
			tc.set(r, f)
			if rc := r.Run([]string{"once"}); rc != 1 {
				t.Fatalf("rc %d", rc)
			}
			if !strings.Contains(read(t, r.statefile()), "last_run_launcher="+tc.want) {
				t.Errorf("record:\n%s", read(t, r.statefile()))
			}
			if calls := read(t, logf); !strings.Contains(calls, "b/acme") {
				t.Errorf("no push:\n%s", calls)
			}
		})
	}
}

// A job past its deadline and LaunchGrace is stopped, then removed.
func TestOnceLauncherDeadline(t *testing.T) {
	defer func(g int) { LaunchGrace = g }(LaunchGrace)
	LaunchGrace = 0
	r, f, _ := onceTree(t)
	r.HookTimeout = 1
	f.hang = true
	start := time.Now()
	if rc := r.Run([]string{"once"}); rc != 1 || time.Since(start) > 10*time.Second {
		t.Fatalf("rc %d after %v", rc, time.Since(start))
	}
	if got := strings.Join(f.calls, ","); !strings.Contains(got, "wait job1,stop job1 10s,logs job1,remove job1") {
		t.Errorf("api calls: %s", got)
	}
	if !strings.Contains(read(t, r.statefile()), "last_run_launcher=the host job was still running 0s past its 1s deadline and was stopped") {
		t.Errorf("record:\n%s", read(t, r.statefile()))
	}
}

// `once --project` is the push alone: no launcher.
func TestOnceProjectRunsNoLauncher(t *testing.T) {
	r, f, _ := onceTree(t)
	r.Run([]string{"once", "--project", "alpha"})
	if len(f.calls) != 0 {
		t.Errorf("api calls: %v", f.calls)
	}
}

// At the scheduler's start every labelled launcher is stopped and removed;
// before a launch only the exited and those older than a whole job are, and
// a younger live one is named and left running.
func TestSweepLaunchers(t *testing.T) {
	r, f, _ := onceTree(t)
	now := r.Now().Unix()
	l := []dockerapi.Container{{Id: "run1", Names: []string{"/" + Launcher}, State: "running", Created: now - 30},
		{Id: "old2", Names: []string{"/x"}, State: "running", Created: now - int64(r.HookTimeout+LaunchGrace) - 1},
		{Id: "ex3", Names: []string{"/y"}, State: "exited", Created: now - 5}}
	f.leftovers = l
	if live, err := r.sweepLaunchers(true); err != nil || live != "" {
		t.Fatal(live, err)
	}
	if got := strings.Join(f.calls, ","); got != "list "+LauncherLabel+",stop run1 10s,remove run1,stop old2 10s,remove old2,remove ex3" {
		t.Errorf("all: api calls: %s", got)
	}
	if out := r.Stdout.(interface{ String() string }).String(); !strings.Contains(out, "removed a leftover launcher, "+Launcher+" (running, created 30s ago)") {
		t.Errorf("%s", out)
	}
	f.calls, f.leftovers = nil, l
	if live, err := r.sweepLaunchers(false); err != nil || live != Launcher+", created 30s ago" {
		t.Fatal(live, err)
	}
	if got := strings.Join(f.calls, ","); got != "list "+LauncherLabel+",stop old2 10s,remove old2,remove ex3" {
		t.Errorf("before a launch: api calls: %s", got)
	}
}

// A live launcher is left alone: no stop, no create, and the push still runs.
func TestOnceBesideALiveLauncher(t *testing.T) {
	r, f, logf := onceTree(t)
	f.leftovers = []dockerapi.Container{{Id: "other", Names: []string{"/" + Launcher}, State: "running", Created: r.Now().Unix()}}
	if rc := r.Run([]string{"once"}); rc != 1 {
		t.Fatalf("rc %d", rc)
	}
	if got := strings.Join(f.calls, ","); got != "list "+LauncherLabel {
		t.Errorf("api calls: %s", got)
	}
	if calls := read(t, logf); !strings.Contains(calls, "b/acme") {
		t.Errorf("no push:\n%s", calls)
	}
}

// A report past ReportMax, or stderr past ErrMax, is read from its tail: the
// fragment its first line may be is dropped, and the cut is said.
func TestOnceReportCut(t *testing.T) {
	r, f, _ := onceTree(t)
	f.code, f.cut, f.stdout = 1, true, "ject zeta failed half a line\nproject beta failed the hook failed\n"
	f.errCut, f.stderr = true, "agment\nbeta: pg_dump failed\n"
	r.Run([]string{"once"})
	errs := r.Stderr.(interface{ String() string }).String()
	if !strings.Contains(errs, "the host job's report ran past 4194304 bytes") || strings.Contains(errs, "zeta") ||
		!strings.Contains(errs, "kasbah-backup: the launcher's stderr tail, cut to its last 21 bytes:\nbeta: pg_dump failed\nkasbah-backup: end of") ||
		strings.Contains(errs, "agment") {
		t.Errorf("%s", errs)
	}
	if rec := read(t, r.statefile()); !strings.Contains(rec, "last_run_failed=beta the hook failed\n") || strings.Contains(rec, "last_run_launcher") {
		t.Errorf("record:\n%s", rec)
	}
}

func TestLookupUser(t *testing.T) {
	root := t.TempDir()
	write(t, root+"/etc/passwd", "root:x:0:0:root:/root:/bin/bash\nstevedore:x:1001:1001::/home/stevedore:/bin/bash\r\nloner:x:1002:1002::/home/loner:/bin/sh\n")
	write(t, root+"/etc/group", "root:x:0:\nstevedore:x:1001:\ndocker:x:998:stevedore,loner\nkasbah:x:997:other,stevedore\n")
	u, err := LookupUser(root, "stevedore")
	if err != nil || u == nil || u.Uid != 1001 || u.Gid != 1001 || u.Home != "/home/stevedore" || fmt.Sprint(u.Groups) != "[1001 998 997]" {
		t.Errorf("%+v %v", u, err)
	}
	if u, _ := LookupUser(root, "loner"); u == nil || fmt.Sprint(u.Groups) != "[1002 998]" {
		t.Errorf("loner: %+v", u)
	}
	if u, err := LookupUser(root, "ghost"); u != nil || err != nil {
		t.Errorf("ghost: %+v %v", u, err)
	}
	if _, err := LookupUser(t.TempDir(), "x"); err == nil {
		t.Error("no passwd read as no user")
	}
}

// fakeHost answers hostOutput from a table keyed by the command line; a
// value led by ! is printed by a tool that then exits 1, a key missing is one
// that prints nothing and exits 1, a nil table a host without id.
func fakeHost(t *testing.T, root string, table map[string]string) *[]string {
	t.Helper()
	old := hostOutput
	t.Cleanup(func() { hostOutput = old })
	var seen []string
	hostOutput = func(r, tool string, args ...string) (string, error) {
		line := strings.Join(append([]string{tool}, args...), " ")
		seen = append(seen, r+":"+line)
		if r != root {
			t.Errorf("%s run in %q, not %q", line, r, root)
		}
		if table == nil {
			return "", errNoTool
		}
		if out, ok := table[line]; ok {
			if rest, failed := strings.CutPrefix(out, "!"); failed {
				return rest, exec.Command("false").Run()
			}
			return out, nil
		}
		return "", exec.Command("false").Run()
	}
	return &seen
}

var ldapUser = map[string]string{
	"id -u ldapu": "5001\n", "id -g ldapu": "5000\n", "id -G ldapu": "5000 998 997 27\n",
	"getent passwd ldapu": "ldapu:*:5001:5000:L:/home/ldapu:/bin/bash\n",
}

// The user is the host's id's, through its NSS: uid, primary gid first, every
// supplementary group by number (a name may hold spaces), the home getent
// gives; id refusing it is no user; a host without id is read from its files.
func TestResolveUser(t *testing.T) {
	seen := fakeHost(t, "/host", ldapUser)
	u, via, err := ResolveUser("/host", "ldapu")
	if err != nil || via != ViaID || u == nil || u.Uid != 5001 || u.Gid != 5000 || u.Home != "/home/ldapu" ||
		fmt.Sprint(u.Groups) != "[5000 998 997 27]" {
		t.Errorf("%+v %s %v", u, via, err)
	}
	if strings.Join(*seen, ",") != "/host:id -u ldapu,/host:id -g ldapu,/host:id -G ldapu,/host:getent passwd ldapu" {
		t.Errorf("%v", *seen)
	}
	if u, via, err := ResolveUser("/host", "ghost"); u != nil || via != ViaID || err != nil {
		t.Errorf("ghost: %+v %s %v", u, via, err)
	}
	// sssd's names hold spaces, and a group may have no name: only numbers are read.
	fakeHost(t, "/host", map[string]string{"id -u n": "7", "id -g n": "7", "id -G n": "7 4242 998",
		"id -nG n": "domain users@corp.example 4242 docker\n"})
	if u, _, err := ResolveUser("/host", "n"); err != nil || fmt.Sprint(u.Groups) != "[7 4242 998]" {
		t.Errorf("spaced and unnamed groups: %+v %v", u, err)
	}
	// An id -G that exits 1 printed only part of the list: refused, not run short.
	fakeHost(t, "/host", map[string]string{"id -u n": "7", "id -g n": "7", "id -G n": "!7"})
	if _, _, err := ResolveUser("/host", "n"); err == nil || !strings.Contains(err.Error(), "the host's id -G n failed") {
		t.Errorf("a partial id -G: %v", err)
	}
	fakeHost(t, "/host", map[string]string{"id -u n": "7", "id -g n": "!"})
	if _, _, err := ResolveUser("/host", "n"); err == nil || !strings.Contains(err.Error(), "the host's id -g n failed") {
		t.Errorf("a failing id -g: %v", err)
	}

	root := t.TempDir()
	write(t, root+"/etc/passwd", "stevedore:x:1001:1001::/home/stevedore:/bin/sh\n")
	write(t, root+"/etc/group", "stevedore:x:1001:\nkasbah:x:997:stevedore\n")
	fakeHost(t, root, nil)
	if u, via, err := ResolveUser(root, "stevedore"); err != nil || via != ViaFiles || u == nil || u.Uid != 1001 || !u.HasGid(997) {
		t.Errorf("files: %+v %s %v", u, via, err)
	}
}

func TestParseID(t *testing.T) {
	u, err := parseID("a", "1001\n", "1001", "998 1001 997\n")
	if err != nil || fmt.Sprint(u.Groups) != "[1001 998 997]" {
		t.Errorf("primary not first: %+v %v", u, err)
	}
	for _, bad := range [][3]string{{"x", "1", "1"}, {"1", "", "1"}, {"1", "1", ""}, {"1", "1", "1 z"}, {"1", "1", "domain users@corp.example"}} {
		if _, err := parseID("a", bad[0], bad[1], bad[2]); err == nil {
			t.Errorf("%q read", bad)
		}
	}
}

// The real id, for the user running the tests.
func TestResolveUserRealID(t *testing.T) {
	name, err := exec.Command("id", "-un").Output()
	if err != nil {
		t.Skip("no id")
	}
	u, via, err := ResolveUser("", strings.TrimSpace(string(name)))
	if err != nil || u == nil || via != ViaID || int(u.Uid) != os.Getuid() || int(u.Gid) != os.Getgid() {
		t.Errorf("%+v %s %v", u, via, err)
	}
}

// UserCheck names the verdict, how the user was looked up, and the groups
// and ownership init warns about: a group's gid, as getent gives it, among
// the user's numeric groups.
func TestUserCheck(t *testing.T) {
	apps := t.TempDir()
	me := fmt.Sprint(os.Getuid())
	host := map[string]string{
		"getent group kasbah": "kasbah:x:997:ldapu\n", "getent group docker": "docker:x:998:\n",
		"id -u ldapu": "5001", "id -g ldapu": "5000", "id -G ldapu": "5000 998 997",
		"id -nG ldapu": "domain users@corp.example docker kasbah",
		"id -u owner":  me, "id -g owner": "5000", "id -G owner": "5000",
		"id -u root": "0", "id -g root": "0", "id -G root": "0",
		"id -u half": "5002", "id -g half": "997", "id -G half": "997",
	}
	seen := fakeHost(t, "", host)
	for name, want := range map[string]string{
		"ldapu": "backup_user=ok\nbackup_user_via=id\nbackup_user_kasbah=yes\nbackup_user_docker=yes\nbackup_user_owner=no\n",
		"half":  "backup_user=ok\nbackup_user_via=id\nbackup_user_kasbah=yes\nbackup_user_docker=no\nbackup_user_owner=no\n",
		"owner": "backup_user=ok\nbackup_user_via=id\nbackup_user_kasbah=no\nbackup_user_docker=no\nbackup_user_owner=yes\n",
		"root":  "backup_user=root\nbackup_user_via=id\n",
		"ghost": "backup_user=absent\nbackup_user_via=id\n",
	} {
		var b strings.Builder
		if err := UserCheck(name, apps, &b); err != nil || b.String() != want {
			t.Errorf("%s: %q %v", name, b.String(), err)
		}
	}
	if strings.Contains(strings.Join(*seen, ","), "-nG") {
		t.Errorf("group names read: %v", *seen)
	}
	// No such group on the host is not membership; getent's absence reads /etc/group.
	delete(host, "getent group docker")
	var b strings.Builder
	if err := UserCheck("ldapu", apps, &b); err != nil || !strings.Contains(b.String(), "backup_user_docker=no\n") {
		t.Errorf("no docker group: %q %v", b.String(), err)
	}
	root := t.TempDir()
	write(t, root+"/etc/group", "docker:x:998:\r\nkasbahx:x:5:\nkasbah:x:997:\n")
	fakeHost(t, root, nil)
	u := &HostUser{Groups: []uint32{5000, 997}}
	for g, want := range map[string]bool{"kasbah": true, "docker": false, "kasbahx": false, "nope": false} {
		if in, err := inGroup(root, u, g); err != nil || in != want {
			t.Errorf("files: %s: %v %v", g, in, err)
		}
	}
}

// Launch refuses what it was not handed whole before anything runs, a user
// the host has not or root, all with 125 and a result line naming why; a
// job it starts passes its exit status through.
func TestLaunch(t *testing.T) {
	defer func(r string) { HostRoot = r }(HostRoot)
	HostRoot = ""
	apps := t.TempDir()
	write(t, apps+"/.kasbah/bin/kasbah", "#!/bin/sh\necho \"project a ok $*\"\necho \"to stderr\" >&2\nexit 3\n")
	os.Chmod(apps+"/.kasbah/bin/kasbah", 0o755)
	fakeHost(t, "", map[string]string{"id -u ldapu": "5001", "id -g ldapu": "5000", "id -G ldapu": "5000",
		"getent passwd ldapu": "ldapu:*:5001:5000::/home/ldapu:/bin/sh",
		"id -u root":          "0", "id -g root": "0", "id -G root": "0"})
	var cred *syscall.Credential
	defer func(s func(*exec.Cmd) error) { startJob = s }(startJob)
	startJob = func(c *exec.Cmd) error {
		cred, c.SysProcAttr.Credential = c.SysProcAttr.Credential, nil
		return c.Start()
	}
	for _, tc := range []struct {
		args []string
		code int
		out  string
	}{
		{[]string{"ldapu", apps}, 125, "launcher usage: launch USER APPS SECONDS\n"},
		{[]string{"ldapu", apps, "60", "x"}, 125, "launcher usage: launch USER APPS SECONDS\n"},
		{[]string{"Bad;", apps, "60"}, 125, "launcher 'Bad;' is not a user name\n"},
		{[]string{"ldapu", "srv/apps", "60"}, 125, "launcher the apps path 'srv/apps' is not a clean absolute path\n"},
		{[]string{"ldapu", apps + "/", "60"}, 125, "launcher the apps path '" + apps + "/' is not a clean absolute path\n"},
		{[]string{"ldapu", apps, "0"}, 125, "launcher the deadline '0' is not a positive whole number of seconds\n"},
		{[]string{"ldapu", apps, "1e3"}, 125, "launcher the deadline '1e3' is not a positive whole number of seconds\n"},
		{[]string{"ghost", apps, "60"}, 125, "launcher the host has no user 'ghost' (looked up through the host's id) — re-run kasbah server init --with-backup --backup-user=NAME\n"},
		{[]string{"root", apps, "60"}, 125, "launcher the backup user root is root on the host, and the nightly job never runs as root — re-run kasbah server init --with-backup --backup-user=NAME\n"},
		{[]string{"ldapu", apps, "60"}, 3, "entering the host as ldapu: uid 5001, gid 5000, groups 5000, resolved through the host's id\n" +
			"project a ok remote backup host " + apps + " 60\n"},
	} {
		var out, errb strings.Builder
		if code := Launch(tc.args, &out, &errb); code != tc.code || out.String() != tc.out {
			t.Errorf("%v: %d %q %q", tc.args, code, out.String(), errb.String())
		}
	}
	if cred == nil || cred.Uid != 5001 || cred.Gid != 5000 || fmt.Sprint(cred.Groups) != "[5000]" {
		t.Errorf("credential %+v", cred)
	}
	startJob = func(c *exec.Cmd) error { return errors.New("operation not permitted") }
	var out, errb strings.Builder
	if code := Launch([]string{"ldapu", apps, "60"}, &out, &errb); code != 125 ||
		!strings.HasSuffix(out.String(), "\nlauncher could not enter the host as ldapu (uid 5001, gid 5000, groups 5000, resolved through the host's id): operation not permitted\n") {
		t.Errorf("%d %q", code, out.String())
	}
}

// The job is entered chrooted into /host as the user with its groups, in
// an environment of its own: nothing of the launcher's.
func TestLaunchCmd(t *testing.T) {
	u := &HostUser{Name: "stevedore", Uid: 1001, Gid: 1001, Home: "/home/stevedore", Groups: []uint32{1001, 997}}
	c := launchCmd(u, "/apps", "1800")
	if c.Path != "/apps/.kasbah/bin/kasbah" || strings.Join(c.Args[1:], " ") != "remote backup host /apps 1800" || c.Dir != "/" {
		t.Errorf("%s %v %s", c.Path, c.Args, c.Dir)
	}
	a := c.SysProcAttr
	if a == nil || a.Chroot != "/host" || a.Credential == nil || a.Credential.Uid != 1001 || a.Credential.Gid != 1001 ||
		len(a.Credential.Groups) != 2 || a.Credential.Groups[1] != 997 || a.Credential.NoSetGroups {
		t.Errorf("%+v", a)
	}
	if got := strings.Join(c.Env, " "); got != "PATH=/usr/local/bin:/usr/bin:/bin LC_ALL=C HOME=/home/stevedore USER=stevedore LOGNAME=stevedore" {
		t.Errorf("env: %s", got)
	}
}

func TestFlags(t *testing.T) {
	for _, v := range []string{"deploy", "_svc", "a.b-c_1"} {
		if CheckUser("server init", v) != nil {
			t.Errorf("%s refused", v)
		}
	}
	for _, v := range []string{"", "Deploy", "1x", "a b", "a;rm"} {
		if err := CheckUser("server init", v); err == nil || !strings.Contains(err.Error(), "--backup-user=") {
			t.Errorf("%q: %v", v, err)
		}
	}
	for v, ok := range map[string]bool{"30": true, "1800": true, "86400": true, "29": false, "86401": false, "1e3": false, "": false} {
		if _, err := CheckHookTimeout("server init", v); (err == nil) != ok || err != nil && !strings.Contains(err.Error(), "--backup-hook-timeout=") {
			t.Errorf("%q: %v", v, err)
		}
	}
}
