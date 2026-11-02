package backup

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/remote"
)

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// appsTree is an apps path with three projects (two sharing a client, one with
// a record that is no name), mail, and a password for acme.
func appsTree(t *testing.T) (apps, data string) {
	root := t.TempDir()
	apps, data = root+"/apps", root+"/apps/data"
	for _, d := range []string{"/.kasbah/backup/repos", "/.kasbah/backup/state", "/traefik", "/backups"} {
		os.MkdirAll(apps+d, 0o755)
	}
	write(t, apps+"/alpha/.kasbah-client", "acme\n")
	write(t, apps+"/alpha/.env", "A=1\n")
	write(t, apps+"/alpha/backups/dump.sql", "x")
	write(t, data+"/alpha/db", "x")
	write(t, apps+"/beta/.kasbah-client", "acme\n")
	write(t, apps+"/beta/.env", "B=1\n")
	write(t, apps+"/gamma/.kasbah-client", "Not A Name\n")
	write(t, apps+"/mail/.env", "M=1\n")
	write(t, data+"/mail/box", "x")
	write(t, apps+"/.kasbah/backup/repos/acme.pass", "pw\n")
	return apps, data
}

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

func runner(apps, data string, at time.Time) (*Runner, *bytes.Buffer, *bytes.Buffer, *clock) {
	var out, errb bytes.Buffer
	c := &clock{at}
	return &Runner{Apps: apps, Data: data, At: "02:00", Jitter: 0, Timeout: 900,
		Stdout: &out, Stderr: &errb, Environ: []string{"PATH=" + os.Getenv("PATH")}, Restic: "restic",
		Now: c.now, Sleep: func(time.Duration) {}, Pid: 4242}, &out, &errb, c
}

func TestPlan(t *testing.T) {
	apps, data := appsTree(t)
	r, out, errb, _ := runner(apps, data, time.Now())
	want := strings.Join([]string{
		"project alpha acme record", "project beta acme record", "project gamma gamma invalid",
		"repo mail no", "path " + data + "/mail", "path " + apps + "/mail/.env",
		"repo acme yes", "path " + apps + "/alpha/backups", "path " + apps + "/alpha/.env",
		"path " + apps + "/beta/.env",
		"repo gamma no", "path " + apps + "/gamma/.env",
	}, "\n") + "\n"
	write(t, apps+"/gamma/.env", "G=1\n")
	if rc := r.Run([]string{"plan"}); rc != 0 {
		t.Fatal(rc, errb)
	}
	if out.String() != want {
		t.Errorf("plan:\n%s\nwant\n%s", out, want)
	}
	if !strings.Contains(errb.String(), "is not a repository name — gamma is filed under 'gamma'") {
		t.Errorf("no warning: %s", errb)
	}
	r.Apps = ""
	if rc := r.Run([]string{"plan"}); rc != 1 {
		t.Error("plan with no apps path")
	}
}

func TestNext(t *testing.T) {
	loc := time.Local
	time.Local = time.UTC
	defer func() { time.Local = loc }()
	day := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	r, out, _, _ := runner("/apps", "/apps/data", day)
	for _, c := range []struct {
		at     string
		jitter int
		now    time.Time
		want   string
	}{
		{"02:00", 0, day.Add(-13600*time.Second + 2*time.Hour), "next run in 13600s (03:46:40 from now), slot 02:00 plus 0s jitter"},
		{"02:00", 137, day.Add(-13600*time.Second + 2*time.Hour), "next run in 13737s"},
		{"02:00", 0, day.Add(2*time.Hour - 2800*time.Second), "next run in 2800s"},
		{"02:00", 0, day.Add(2*time.Hour + 20*time.Second), "next run in 86380s"},
		{"02:00", 0, day.Add(2 * time.Hour), "next run in 86400s"},
	} {
		out.Reset()
		r.At, r.Jitter = c.at, c.jitter
		r.Run([]string{"next", strconv.FormatInt(c.now.Unix(), 10)})
		if !strings.HasPrefix(out.String(), c.want) {
			t.Errorf("%v: %q, want %q", c.now, out, c.want)
		}
	}
	if rc := r.Run([]string{"next", "01"}); rc != 1 {
		t.Error("a leading-zero epoch was read")
	}
	if rc := r.Run([]string{"bogus"}); rc != 1 {
		t.Error("an unknown mode ran")
	}
}

func TestHealth(t *testing.T) {
	apps, data := appsTree(t)
	r, out, errb, _ := runner(apps, data, time.Unix(1700000000, 0))
	if rc := r.Run([]string{"health"}); rc != 1 || !strings.Contains(errb.String(), "has not reported in") {
		t.Errorf("no record: %d %s", rc, errb)
	}
	rec := apps + "/.kasbah/backup/state/status"
	for _, tc := range []struct {
		body string
		rc   int
		said string
	}{
		{"state=sleeping\ndeadline=1700000100\n", 0, "sleeping, 100s of its budget left"},
		{"state=running\ndeadline=1699999000\n", 1, "outlived its deadline by 1000s"},
		{"state=sleeping\n", 1, "carries no deadline"},
		{"state=sleeping\ndeadline=01700000100\n", 1, "not a unix time"},
		{"state=sleeping\ndeadline=1700000100\r\n", 1, "not a unix time"},
		{"state=sleeping\ndeadline=999999999999999999\n", 0, "of its budget left"},
		{"state=sleeping\ndeadline=9999999999999999999\n", 1, "not a unix time"},
	} {
		out.Reset()
		errb.Reset()
		write(t, rec, tc.body)
		if rc := r.Run([]string{"health"}); rc != tc.rc || !strings.Contains(out.String()+errb.String(), tc.said) {
			t.Errorf("%q: %d %s%s", tc.body, rc, out, errb)
		}
	}
}

// stub is a restic that logs each call and fails `cat config` until the
// repository was initialised.
func stub(t *testing.T, body string) string {
	dir := t.TempDir()
	p := dir + "/restic"
	write(t, p, "#!/bin/sh\n"+body)
	os.Chmod(p, 0o755)
	return p
}

const resticStub = `log="$STUB_LOG"
printf '%s %s %s\n' "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD_FILE" "$*" >> "$log"
[ -z "$RESTIC_PASSWORD" ] || echo "LEAKED RESTIC_PASSWORD" >> "$log"
case $1 in
  cat) [ -e "$log.init.${RESTIC_REPOSITORY##*/}" ] ;;
  init) : > "$log.init.${RESTIC_REPOSITORY##*/}" ;;
  *) exit 0 ;;
esac
`

func TestOnce(t *testing.T) {
	apps, data := appsTree(t)
	os.Remove(apps + "/gamma/.kasbah-client")
	write(t, apps+"/.kasbah/backup/repos/mail.pass", "pw\n")
	write(t, apps+"/.kasbah/backup/env", "# c\nKASBAH_BACKUP_REPO_BASE=rest:http://u:p@h/b/\nRESTIC_PASSWORD=nope\nAWS_KEY=k\n")
	r, out, errb, _ := runner(apps, data, time.Unix(1700000000, 0))
	logf := t.TempDir() + "/log"
	r.Restic = stub(t, resticStub)
	r.Environ = append(r.Environ, "STUB_LOG="+logf)
	if rc := r.Run([]string{"once"}); rc != 1 {
		t.Fatalf("gamma has no password, so the run fails: %d\n%s%s", rc, out, errb)
	}
	o := out.String()
	for _, want := range []string{"mail: initialising the repository", "mail: backing up " + data + "/mail " + apps + "/mail/.env",
		"acme: backing up " + apps + "/alpha/backups " + apps + "/alpha/.env " + apps + "/beta/.env\n", "no .kasbah-client record, filed under their own name: gamma",
		"run finished, repositories backed up: mail acme"} {
		if !strings.Contains(o, want) {
			t.Errorf("missing %q in\n%s", want, o)
		}
	}
	for _, want := range []string{"ignoring RESTIC_PASSWORD= — kasbah sets it per repository", "NOT backed up: gamma", "kasbah server init USER@HOST --with-backup"} {
		if !strings.Contains(errb.String(), want) {
			t.Errorf("missing %q in\n%s", want, errb)
		}
	}
	calls := read(t, logf)
	if strings.Contains(calls, "LEAKED") || !strings.Contains(calls, "rest:http://u:p@h/b/acme "+apps+"/.kasbah/backup/repos/acme.pass backup --tag kasbah") {
		t.Errorf("calls:\n%s", calls)
	}
	rec := read(t, apps+"/.kasbah/backup/state/status")
	lines := strings.Split(strings.TrimSuffix(rec, "\n"), "\n")
	keys := []string{}
	for _, l := range lines {
		keys = append(keys, strings.SplitN(l, "=", 2)[0])
	}
	if strings.Join(keys, " ") != "state since deadline next_run last_run_started last_run_finished last_run_status last_run_repos timeout at jitter" {
		t.Errorf("record keys: %v", keys)
	}
	for _, want := range []string{"state=sleeping", "last_run_status=failed", "last_run_repos= mail acme", "last_run_started=1700000000", "timeout=900", "at=02:00", "jitter=0"} {
		if !strings.Contains(rec, want+"\n") {
			t.Errorf("record lacks %q:\n%s", want, rec)
		}
	}
	// The workstation reader agrees with what was written.
	if v := backuprec.Read("dir", "file", rec, "1700000001"); v.Verdict != backuprec.Failed {
		t.Errorf("verdict %s", v.Verdict)
	}
	if _, err := os.Stat(apps + "/.kasbah/backup/state/status.tmp.4242"); err == nil {
		t.Error("temp record left")
	}

	write(t, apps+"/.kasbah/backup/env", "# no base\n")
	out.Reset()
	errb.Reset()
	if rc := r.Run([]string{"once"}); rc != 1 || !strings.Contains(errb.String(), "sets no KASBAH_BACKUP_REPO_BASE") {
		t.Errorf("%d %s", rc, errb)
	}
	os.Remove(apps + "/.kasbah/backup/env")
	if rc := r.Run([]string{"once"}); rc != 1 || !strings.Contains(errb.String(), "nothing says where the repository is") {
		t.Errorf("%d %s", rc, errb)
	}
	if rec := read(t, apps+"/.kasbah/backup/state/status"); !strings.Contains(rec, "last_run_status=failed\nlast_run_repos=-\n") {
		t.Errorf("record:\n%s", rec)
	}
}

func TestOnceBounded(t *testing.T) {
	apps, data := appsTree(t)
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=b/\n")
	os.RemoveAll(apps + "/mail")
	os.RemoveAll(apps + "/gamma")
	os.RemoveAll(apps + "/beta")
	r, out, errb, _ := runner(apps, data, time.Now())
	r.Timeout = 1
	r.Restic = stub(t, "exec sleep 60\n")
	start := time.Now()
	if rc := r.Run([]string{"once"}); rc != 1 {
		t.Fatalf("%d %s %s", rc, out, errb)
	}
	if el := time.Since(start); el > 20*time.Second {
		t.Errorf("took %v", el)
	}
	if !strings.Contains(errb.String(), "acme: could not initialise the repository") {
		t.Errorf("%s", errb)
	}
}

func TestLastRunCarried(t *testing.T) {
	apps, data := appsTree(t)
	rec := apps + "/.kasbah/backup/state/status"
	r, _, _, _ := runner(apps, data, time.Unix(1700001000, 0))
	for _, tc := range []struct{ body, want string }{
		{"state=sleeping\nsince=1700000000\ndeadline=1700000900\nnext_run=1700086400\nlast_run_started=1700000000\nlast_run_finished=1700000123\nlast_run_status=ok\nlast_run_repos= acme mail\n",
			"last_run_started=1700000000\nlast_run_finished=1700000123\nlast_run_status=ok\nlast_run_repos= acme mail\n"},
		{"last_run_started=1700000000\nlast_run_finished=1700000123\nlast_run_status=ok\n",
			"last_run_started=0\nlast_run_finished=0\nlast_run_status=-\nlast_run_repos=-\n"},
		{"last_run_started=1700000000\r\nlast_run_finished=1700000123\r\nlast_run_status=ok\r\nlast_run_repos= a\r\n",
			"last_run_started=0\nlast_run_finished=0\nlast_run_status=-\nlast_run_repos=-\n"},
		{"last_run_started=01700000000\nlast_run_finished=1700000123\nlast_run_status=ok\nlast_run_repos= a\n",
			"last_run_status=-\n"},
		{"last_run_started=1700000000\nlast_run_finished=1700000123\nlast_run_status=failed\nlast_run_repos=-\n",
			"last_run_status=failed\nlast_run_repos=-\n"},
	} {
		write(t, rec, tc.body)
		r.loadLastRun()
		r.writeStatus("starting", 1700001300, 0)
		got := read(t, rec)
		if !strings.Contains(got, tc.want) || !strings.Contains(got, "state=starting\nsince=1700001000\ndeadline=1700001300\nnext_run=0\n") {
			t.Errorf("from %q:\n%s", tc.body, got)
		}
		if v := backuprec.Read("dir", "file", got, "1700001001"); v.Verdict == backuprec.Unparsed {
			t.Errorf("unparsed: %s", got)
		}
	}
}

func TestRead(t *testing.T) {
	apps, data := appsTree(t)
	write(t, apps+"/.kasbah/backup/env", "AWS_ACCESS_KEY_ID=secret-value\nRESTIC_REPOSITORY=x\n")
	write(t, apps+"/.kasbah/backup/compose.yml", "name: kasbah-backup\n")
	os.MkdirAll(data+"/vol", 0o755)
	r := Read(apps, data)
	b, _ := json.Marshal(r)
	if strings.Contains(string(b), "secret-value") {
		t.Errorf("the env file's content left the server: %s", b)
	}
	if r.Dir != "dir" || r.Env != "present" || r.EnvOwned != "RESTIC_REPOSITORY" || !r.Mail || strings.Join(r.HasPass, " ") != "acme" {
		t.Errorf("%+v", r)
	}
	if c, _ := base64.StdEncoding.DecodeString(r.Compose); string(c) != "name: kasbah-backup\n" {
		t.Errorf("%q", c)
	}
	var names []string
	for _, p := range r.Projects {
		names = append(names, p.Name+"="+p.Client)
	}
	if strings.Join(names, " ") != "alpha=acme beta=acme gamma=?" {
		t.Errorf("%v", names)
	}
	// The data path is skipped by path, whatever it is called.
	os.MkdirAll(apps+"/vol", 0o755)
	if ps := Read(apps, apps+"/vol").Projects; len(ps) != 3 || ps[2].Name != "gamma" {
		t.Errorf("%+v", ps)
	}
	if Read(t.TempDir()+"/none", "/x").Dir != "absent" {
		t.Error("absent")
	}
}

func layout(t *testing.T, apps string, body LayoutBody) (string, error) {
	raw, _ := json.Marshal(body)
	size, sum := remote.Digest(raw)
	var out bytes.Buffer
	err := remoteLayout(apps, size, sum, bytes.NewReader(raw), &out)
	return out.String(), err
}

func TestLayout(t *testing.T) {
	apps := t.TempDir() + "/apps"
	os.MkdirAll(apps, 0o755)
	def := "# kasbah\nKASBAH_BACKUP_REPO_BASE=b/\n# yours\n"
	out, err := layout(t, apps, LayoutBody{Default: def, RepoBase: "b/", Env: []string{"AWS=k"},
		Passwords: []Password{{"acme", "pw-for-acme"}}})
	if err != nil || !strings.Contains(out, "env_state=written") {
		t.Fatal(out, err)
	}
	dir := apps + "/.kasbah/backup"
	for path, mode := range map[string]os.FileMode{dir: 0o700, dir + "/repos": 0o700, dir + "/state": 0o700, dir + "/env": 0o600, dir + "/repos/acme.pass": 0o600} {
		if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != mode {
			t.Errorf("%s: %v %v", path, fi.Mode(), err)
		}
	}
	if read(t, dir+"/env") != def+"AWS=k\n" || read(t, dir+"/repos/acme.pass") != "pw-for-acme\n" {
		t.Error("contents")
	}
	// Re-run: unchanged, the mode enforced anyway, a password never rewritten.
	os.Chmod(dir+"/env", 0o644)
	os.Chmod(dir, 0o755)
	out, err = layout(t, apps, LayoutBody{Default: def, RepoBase: "b/", Env: []string{"AWS=k"},
		Passwords: []Password{{"acme", "other"}}})
	if err != nil || !strings.Contains(out, "env_state=unchanged") || !strings.Contains(out, "pass_kept=acme") {
		t.Fatal(out, err)
	}
	if fi, _ := os.Stat(dir + "/env"); fi.Mode().Perm() != 0o600 {
		t.Error("env mode not enforced")
	}
	if fi, _ := os.Stat(dir); fi.Mode().Perm() != 0o700 {
		t.Error("dir mode not enforced")
	}
	if read(t, dir+"/repos/acme.pass") != "pw-for-acme\n" {
		t.Error("a password was rewritten")
	}
	// The operator's half survives; an owned key is refused, server side too.
	write(t, dir+"/env", read(t, dir+"/env")+"MINE=1\n")
	if _, err := layout(t, apps, LayoutBody{Default: def, RepoBase: "c/"}); err != nil || !strings.Contains(read(t, dir+"/env"), "MINE=1\n") || !strings.Contains(read(t, dir+"/env"), "KASBAH_BACKUP_REPO_BASE=c/\n") {
		t.Error(err, read(t, dir+"/env"))
	}
	write(t, dir+"/env", "RESTIC_REPOSITORY=x\n")
	if _, err := layout(t, apps, LayoutBody{Default: def, RepoBase: "c/"}); err == nil || !strings.Contains(err.Error(), "which kasbah sets itself") {
		t.Error(err)
	}
	for _, bad := range []LayoutBody{
		{RepoBase: ""}, {RepoBase: "b/", Env: []string{"RESTIC_PASSWORD=x"}},
		{RepoBase: "b/", Passwords: []Password{{"../x", "p"}}},
	} {
		if _, err := layout(t, apps, bad); err == nil {
			t.Errorf("accepted %+v", bad)
		}
	}
	// A cut payload installs nothing.
	raw, _ := json.Marshal(LayoutBody{Default: def, RepoBase: "z/"})
	size, sum := remote.Digest(raw)
	if err := remoteLayout(apps, size, sum, bytes.NewReader(raw[:10]), &bytes.Buffer{}); err == nil {
		t.Error("a truncated payload was accepted")
	}
}

func TestRepos(t *testing.T) {
	apps, _ := appsTree(t)
	write(t, apps+"/.kasbah/backup/repos/.hidden.pass", "x")
	r := Repos(apps)
	if strings.Join(r.Repos, " ") != "acme" || r.Pass["acme"] != base64.StdEncoding.EncodeToString([]byte("pw\n")) {
		t.Errorf("%+v", r)
	}
}

const lastRun = "state=sleeping\nsince=1700000000\ndeadline=1700000900\nnext_run=1700086400\nlast_run_started=1700000000\nlast_run_finished=1700000123\nlast_run_status=ok\nlast_run_repos= zeta\n"

// A scheduler brought up by a restart carries the stack's history (12e543a).
func TestScheduleCarriesLastRun(t *testing.T) {
	apps, data := appsTree(t)
	rec := apps + "/.kasbah/backup/state/status"
	write(t, rec, lastRun)
	r, _, _, _ := runner(apps, data, time.Unix(1700001000, 0))
	var seen string
	r.Sleep = func(time.Duration) { seen = read(t, rec); panic("slept") }
	func() {
		defer func() {
			if recover() == nil {
				t.Fatal("the scheduler never slept")
			}
		}()
		r.Run(nil)
	}()
	for _, want := range []string{"state=sleeping\n", "last_run_started=1700000000\n", "last_run_finished=1700000123\n",
		"last_run_status=ok\n", "last_run_repos= zeta\n"} {
		if !strings.Contains(seen, want) {
			t.Errorf("the first sleeping record lacks %q:\n%s", want, seen)
		}
	}
}

// A hand-run `once` beside a scheduler carries the record's last run into its
// running record, with its own start, under a deadline sized to the plan.
func TestOnceRunningRecord(t *testing.T) {
	apps, data := appsTree(t)
	rec := apps + "/.kasbah/backup/state/status"
	write(t, rec, lastRun)
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=b/\n")
	r, _, _, _ := runner(apps, data, time.Unix(1700005000, 0))
	snap := t.TempDir() + "/mid"
	r.Restic = stub(t, `[ -e "$SNAP" ] || cp "$REC" "$SNAP"`+"\n")
	r.Environ = append(r.Environ, "SNAP="+snap, "REC="+rec)
	r.Run([]string{"once"})
	mid := read(t, snap)
	// mail, acme and gamma: three repositories.
	want := "state=running\nsince=1700005000\ndeadline=" + strconv.Itoa(1700005000+900*(2*3+1)+Grace) + "\nnext_run=0\n" +
		"last_run_started=1700005000\nlast_run_finished=1700000123\nlast_run_status=ok\nlast_run_repos= zeta\n"
	if !strings.HasPrefix(mid, want) {
		t.Errorf("the running record:\n%s\nwant it to begin\n%s", mid, want)
	}
}

// A project's backups/ ships as what it resolves to — restic stores a link as
// the link — and one resolving outside the container's mounts is named, never
// dropped in silence. The data path itself is no project's scope.
func TestPlanResolvesBackups(t *testing.T) {
	apps, data := appsTree(t)
	outside := t.TempDir()
	os.MkdirAll(data+"/alpha-backups", 0o755)
	os.RemoveAll(apps + "/alpha/backups")
	os.Symlink(data+"/alpha-backups", apps+"/alpha/backups")
	os.MkdirAll(apps+"/beta", 0o755)
	os.Symlink(outside, apps+"/beta/backups")
	os.MkdirAll(apps+"/gamma", 0o755)
	os.Symlink("/nowhere/in/here", apps+"/gamma/backups")
	r, out, errb, _ := runner(apps, data, time.Now())
	if rc := r.Run([]string{"plan"}); rc != 0 {
		t.Fatal(rc, errb)
	}
	o := out.String()
	for _, want := range []string{
		"repo acme yes\npath " + data + "/alpha-backups\npath " + apps + "/alpha/.env\npath " + apps + "/beta/.env\nunshipped " + apps + "/beta/backups -> " + outside + "\n",
		"repo gamma no\nunshipped " + apps + "/gamma/backups -> /nowhere/in/here\n",
	} {
		if !strings.Contains(o, want) {
			t.Errorf("plan lacks %q:\n%s", want, o)
		}
	}
	if strings.Contains(o, "path "+data+"/alpha\n") {
		t.Errorf("the data path is in the plan:\n%s", o)
	}

	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=b/\n")
	write(t, apps+"/.kasbah/backup/repos/mail.pass", "pw\n")
	os.RemoveAll(apps + "/gamma")
	logf := t.TempDir() + "/log"
	r.Restic = stub(t, resticStub)
	r.Environ = append(r.Environ, "STUB_LOG="+logf)
	out.Reset()
	if rc := r.Run([]string{"once"}); rc != 1 {
		t.Fatalf("a backups/ not shipped fails the run: %d\n%s%s", rc, out, errb)
	}
	if want := "acme: " + apps + "/beta/backups -> " + outside + " resolves outside this container's mounts (" + apps + ", " + data + ") — NOT shipped off-box"; !strings.Contains(errb.String(), want) {
		t.Errorf("missing %q in\n%s", want, errb)
	}
	if calls := read(t, logf); !strings.Contains(calls, "backup --tag kasbah "+data+"/alpha-backups "+apps+"/alpha/.env "+apps+"/beta/.env\n") {
		t.Errorf("the rest still ships:\n%s", calls)
	}
	if rec := read(t, apps+"/.kasbah/backup/state/status"); !strings.Contains(rec, "last_run_status=failed\n") {
		t.Errorf("record:\n%s", rec)
	}
}

// A symlinked .env ships as what it resolves to, as backups/ does, and one
// resolving outside the mounts is named.
func TestPlanResolvesEnv(t *testing.T) {
	apps, data := appsTree(t)
	outside := t.TempDir()
	write(t, data+"/alpha-env", "A=1\n")
	write(t, outside+"/beta-env", "B=1\n")
	os.Remove(apps + "/alpha/.env")
	os.Symlink(data+"/alpha-env", apps+"/alpha/.env")
	os.Remove(apps + "/beta/.env")
	os.Symlink(outside+"/beta-env", apps+"/beta/.env")
	r, out, errb, _ := runner(apps, data, time.Now())
	if rc := r.Run([]string{"plan"}); rc != 0 {
		t.Fatal(rc, errb)
	}
	want := "repo acme yes\npath " + apps + "/alpha/backups\npath " + data + "/alpha-env\nunshipped " + apps + "/beta/.env -> " + outside + "/beta-env\n"
	if !strings.Contains(out.String(), want) {
		t.Errorf("plan lacks %q:\n%s", want, out)
	}
}

// With --project, only that project's unshipped path fails the run; a
// sibling's in the same repository is named and the run goes on.
func TestOnceProjectSiblingUnshipped(t *testing.T) {
	apps, data := appsTree(t)
	outside := t.TempDir()
	os.Symlink(outside, apps+"/beta/backups")
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=b/\n")
	r, out, errb, _ := runner(apps, data, time.Unix(1700000000, 0))
	r.Restic = stub(t, resticStub)
	r.Environ = append(r.Environ, "STUB_LOG="+t.TempDir()+"/log")
	notShipped := "acme: " + apps + "/beta/backups -> " + outside + " resolves outside this container's mounts (" + apps + ", " + data + ") — NOT shipped off-box"
	if rc := r.Run([]string{"once", "--project", "alpha"}); rc != 0 ||
		!strings.Contains(errb.String(), notShipped+" (beta's, not alpha's: this run does not fail on it)") ||
		!strings.Contains(out.String(), "repositories backed up: acme\n") {
		t.Errorf("alpha's push: %d\n%s%s", rc, out, errb)
	}
	errb.Reset()
	if rc := r.Run([]string{"once", "--project", "beta"}); rc != 1 || !strings.Contains(errb.String(), notShipped+"\n") {
		t.Errorf("beta's push: %d\n%s", rc, errb)
	}
}

// once --project backs up the one repository the project files into, its
// sibling projects with it, and leaves the scheduler's record alone.
func TestOnceProject(t *testing.T) {
	apps, data := appsTree(t)
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=b/\n")
	r, out, errb, _ := runner(apps, data, time.Unix(1700000000, 0))
	logf := t.TempDir() + "/log"
	r.Restic = stub(t, resticStub)
	r.Environ = append(r.Environ, "STUB_LOG="+logf)
	rec := apps + "/.kasbah/backup/state/status"
	write(t, rec, "state=sleeping\n")
	if rc := r.Run([]string{"once", "--project", "beta"}); rc != 0 {
		t.Fatalf("%d\n%s%s", rc, out, errb)
	}
	calls := read(t, logf)
	if strings.Contains(calls, "b/mail") || strings.Contains(calls, "b/gamma") ||
		!strings.Contains(calls, "b/acme "+apps+"/.kasbah/backup/repos/acme.pass backup --tag kasbah "+apps+"/alpha/backups "+apps+"/alpha/.env "+apps+"/beta/.env\n") {
		t.Errorf("calls:\n%s", calls)
	}
	if !strings.Contains(out.String(), "run finished, repositories backed up: acme\n") {
		t.Errorf("out:\n%s", out)
	}
	if got := read(t, rec); got != "state=sleeping\n" {
		t.Errorf("the record was written:\n%s", got)
	}
	errb.Reset()
	if rc := r.Run([]string{"once", "--project", "nosuch"}); rc != 1 || !strings.Contains(errb.String(), "no project 'nosuch' under "+apps) {
		t.Errorf("%d %s", rc, errb)
	}
	for _, args := range [][]string{{"once", "--project"}, {"once", "beta"}, {"push", "/apps"}} {
		if rc := r.Run(args); rc != 1 {
			t.Errorf("%v ran", args)
		}
	}
}

// push runs once --project in the scheduler container, and reports a
// container that is not running rather than pushing nothing quietly.
func TestPush(t *testing.T) {
	bin := t.TempDir()
	logf := bin + "/log"
	write(t, bin+"/docker", `#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
case "$1" in
inspect) [ -n "$STATE" ] || exit 1; echo "$STATE healthy 0 kasbah-backup" ;;
version) echo 27 ;;
exec) echo pushing; echo restic-said >&2; exit "${EXEC_RC:-0}" ;;
esac
`)
	os.Chmod(bin+"/docker", 0o755)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("LOG", logf)
	for _, tc := range []struct{ state, rc, want string }{
		{"running", "0", "push=ok\n"},
		{"running", "3", "push=failed\nrc=3\n"},
		{"exited", "0", "push=no-container\nstate=exited\n"},
		{"", "0", "push=no-container\nstate=absent\n"},
	} {
		t.Setenv("STATE", tc.state)
		t.Setenv("EXEC_RC", tc.rc)
		os.Remove(logf)
		var out, errb bytes.Buffer
		if rc := Push("/apps", "demo", &out, &errb); rc != 0 || out.String() != tc.want {
			t.Errorf("%s/%s: %d %q %q", tc.state, tc.rc, rc, out.String(), errb.String())
		}
		ran := strings.Contains(read(t, logf), "exec kasbah-backup /apps/.kasbah/bin/kasbah remote backup once --project demo\n")
		if ran != (tc.state == "running") {
			t.Errorf("%s: exec ran %v:\n%s", tc.state, ran, read(t, logf))
		}
		if ran && errb.String() != "pushing\nrestic-said\n" {
			t.Errorf("the run's output is not on stderr: %q", errb.String())
		}
	}
	os.Remove(logf)
	for _, a := range [][2]string{{"/apps", "-x"}, {"/apps", "a/b"}, {"/apps", "../x"}, {"/apps", "de\x00mo"}, {"/apps", ""}, {"/apps", "Demo"},
		{"apps", "demo"}, {"", "demo"}, {"/ap\x00ps", "demo"}} {
		var out, errb bytes.Buffer
		if rc := Push(a[0], a[1], &out, &errb); rc != 1 || out.Len() != 0 || !strings.Contains(errb.String(), "usage: kasbah remote backup push APPS NAME") {
			t.Errorf("%q ran: %d %q %q", a, rc, out.String(), errb.String())
		}
	}
	if _, err := os.Stat(logf); err == nil {
		t.Errorf("docker ran on a refused argument:\n%s", read(t, logf))
	}
}
