package deploy

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/release"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// fake is a server: what each call returns, and what reached it.
type fake struct {
	drift       string
	clientState string
	mail        *MailFacts
	mailErr     error
	out         *string
	rc          int
	fragErr     error
	record      *vlog.Record
	missing     []string
	// mtimes, when set, records each sync source's mtime (a symlink's own).
	mtimes map[string]time.Time

	calls            []string
	unlocked, closed int
	// marks, when set, receives "<unlocked>" and "<closed>" as they happen, so a
	// test can order them against the run's own output.
	marks   io.Writer
	client  string
	injects [][]string
	spec    *Spec
	token   string
	// limits is setup-env limits' answer, when set; limitsRC its exit.
	limits   string
	limitsRC int
	// question, when set, is asked through Run's ask; answer is the reply.
	question *Question
	answer   string
	// beforeAsk, when set, runs just before the question is asked.
	beforeAsk func()
	// backup is BackupProbe's answer (nil: no backup); envKeys and envAll
	// what RestoreEnv was asked for; envErr its failure.
	backup  *BackupFacts
	envKeys []string
	envAll  bool
	envErr  error
	// injectRC is Inject's exit; undoErr UndoEnv's failure, undoSaved its saved.
	injectRC  int
	undoErr   error
	undoSaved string
}

func (f *fake) log(c string) { f.calls = append(f.calls, c) }

func (f *fake) Marker() (*marker.Marker, error) {
	f.log("marker")
	return &marker.Marker{AppsPath: "/apps", DataPath: "/data", CPULimit: "1", MemLimit: "1g"}, nil
}
func (f *fake) HoldServer(string, string) (func(), error) {
	return func() { f.unlocked++; f.mark("<unlocked>") }, nil
}
func (f *fake) mark(s string) {
	if f.marks != nil {
		fmt.Fprint(f.marks, s)
	}
}
func (f *fake) Prepare(string) error                   { return nil }
func (f *fake) ShipTemplate(string, string) error      { return nil }
func (f *fake) StageSeed(string, string, []byte) error { f.log("seed"); return nil }
func (f *fake) Setup(_ string, fl env.SetupFlags) int {
	if fl.Seed != nil {
		f.log("setup --seed --headless")
	}
	return 0
}
func (f *fake) Close() { f.closed++; f.mark("<closed>") }
func (f *fake) Sync(e Entry, base string) error {
	f.log("sync " + e.Src)
	if fi, err := os.Lstat(e.Src); err == nil && f.mtimes != nil {
		f.mtimes[filepath.Base(e.Src)] = fi.ModTime()
	}
	return nil
}
func (f *fake) Fragment(local, dest string) error { f.log("fragment " + dest); return f.fragErr }
func (f *fake) Inject(dir string, pairs []string) int {
	f.log("inject")
	f.injects = append(f.injects, pairs)
	return f.injectRC
}
func (f *fake) Limits(cpus, memory string) (string, int) {
	f.log("limits " + cpus + " " + memory)
	if f.limitsRC != 0 {
		return "", f.limitsRC
	}
	if f.limits != "" {
		return f.limits, 0
	}
	return "host_cores=2\nhost_mem_kb=2097152\ncpu=0.5\nmem=512m\n", 0
}
func (f *fake) Drift(string) (string, int) {
	f.log("drift")
	if f.drift == "" {
		return "template_exists=yes\nenv_exists=yes\nmissing=\nextra=\n", 0
	}
	return f.drift, 0
}
func (f *fake) PrepareProject(apps, data, name, client string, parents []string) (string, error) {
	f.log("prepare")
	f.client = client
	if f.clientState == "" {
		return "written", nil
	}
	return f.clientState, nil
}
func (f *fake) Mail(string) (*MailFacts, error) { f.log("mail"); return f.mail, f.mailErr }
func (f *fake) Snapshot(dir, token string, targets []string) error {
	f.log("snapshot " + strings.Join(targets, ","))
	f.token = token
	return nil
}
func (f *fake) Run(dir string, sp Spec, ask func(Question) string) (string, int) {
	f.log("run")
	f.spec = &sp
	if f.question != nil {
		if f.beforeAsk != nil {
			f.beforeAsk()
		}
		f.answer = ask(*f.question)
	}
	if f.out != nil {
		return *f.out, f.rc
	}
	b, _ := json.Marshal(Report{Version: sp.Version, Backup: "no-backup", Digest: "-"})
	return "{\"" + ReportKey + "\":1," + string(b[1:]) + "\n", f.rc
}

func (f *fake) Images(version string, images []string) (int, []string, error) {
	f.log("images " + version + " " + strings.Join(images, ","))
	return len(images), f.missing, nil
}
func (f *fake) Record(apps, name string) (*vlog.Record, error) {
	f.log("record")
	if f.record == nil {
		return &vlog.Record{ActivePath: apps + "/" + name + "/versions.log", ArchivePath: apps + "/" + name + "/versions.log.gz", ActiveState: "missing", ArchiveState: "missing"}, nil
	}
	return f.record, nil
}

func (f *fake) BackupProbe(dir, version string) (*BackupFacts, error) {
	f.log("backup-probe " + version)
	if f.backup == nil {
		return &BackupFacts{Env: "no"}, nil
	}
	return f.backup, nil
}
func (f *fake) RestoreEnv(dir, backup string, keys []string) error {
	f.log("restore-env " + backup + " " + strings.Join(keys, ","))
	f.envKeys, f.envAll = keys, keys == nil
	return f.envErr
}

func (f *fake) UndoEnv(dir, token string) (string, error) {
	f.log("undo-env " + token)
	return f.undoSaved, f.undoErr
}

func (f *fake) called(prefix string) bool {
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

// project is a checkout tagged v1.0.0 in a fresh directory, with no state.
func project(t *testing.T, extra string) {
	t.Helper()
	t.Chdir(t.TempDir())
	files := map[string]string{
		"kasbah.yml":          "schema: 1\nname: demo\nsync:\n  - compose.prod.yml -> compose.yml\n  - .env.prod.example\n" + extra,
		"compose.prod.yml":    "services:\n  web:\n    image: nginx\n",
		".env.prod.example":   "A=1\n",
		"traefik-dynamic.yml": "http: {}\n",
	}
	for n, b := range files {
		os.WriteFile(n, []byte(b), 0o644)
	}
	for _, a := range [][]string{{"init", "-q", "."}, {"add", "-A"}, {"commit", "-qm", "x"}, {"tag", "v1.0.0"}} {
		gitc(t, a...)
	}
}

func gitc(t *testing.T, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func deployWith(t *testing.T, f *fake, o Options) (error, string) {
	t.Helper()
	var errb bytes.Buffer
	out := &cli.Output{Stdout: &errb, Stderr: &errb}
	if f.marks != nil {
		f.marks = &errb
	}
	pwd, _ := os.Getwd()
	err := Run(Ctx{
		Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: out},
		PWD: pwd, Version: "0.1.0",
		Dial: func(string) (Server, error) { return f, nil },
		Now:  func() time.Time { return time.Unix(0, 0) },
	}, o)
	if err != nil {
		out.Report(err)
	}
	return err, errb.String()
}

func noState(t *testing.T, what string) {
	t.Helper()
	if _, err := os.Stat(state.File); err == nil {
		t.Errorf("%s: the state file was written", what)
	}
}

func TestRunFailuresLeaveNoState(t *testing.T) {
	other := "{\"" + ReportKey + "\":1,\"version\":\"9.9.9\",\"prev_version\":\"\",\"deployed_before\":false,\"backup\":\"no-backup\",\"digest\":\"-\"}\n"
	none := "hook chatter\n"
	failure := func(outcome string) string {
		return "chatter\n{\"" + FailureKey + "\":1,\"outcome\":\"" + outcome + "\",\"reason\":\"up\",\"prev\":\"0.9.0\"}\n"
	}
	reverted, first, post, revFailed := failure(Reverted), failure(FirstFailed), failure(PostHook), failure(RevertFailed)
	restored, unrestored, unrecorded := failure(Restored), failure(Unrestored), failure(Unrecorded)
	envKept := "{\"" + FailureKey + "\":1,\"outcome\":\"restored\",\"reason\":\"start\",\"prev\":\"0.9.0\",\"saved\":\"/apps/demo/.env.kasbah-replaced\"}\n"
	cases := []struct {
		name string
		f    *fake
		want string
		frag bool
	}{
		{"engine fails", &fake{rc: 1}, "nothing was started", false},
		{"engine reverted", &fake{rc: 1, out: &reverted}, "it was reverted: d@h runs what it ran before", false},
		{"first deploy failed", &fake{rc: 1, out: &first}, "a first deploy has nothing to revert to", false},
		{"post-hook failed", &fake{rc: 1, out: &post}, "The Traefik fragment was shipped, so the route names the live containers", true},
		{"revert failed", &fake{rc: 1, out: &revFailed}, "the revert to what ran before failed too", false},
		{"restored", &fake{rc: 1, out: &restored}, "the files it had shipped were put back", false},
		{"unrestored", &fake{rc: 1, out: &unrestored}, "putting back the files it had shipped failed", false},
		{"unrecorded", &fake{rc: 1, out: &unrecorded}, "versions.log could not record it", false},
		{"env kept", &fake{rc: 1, out: &envKept}, "/apps/demo/.env.kasbah-replaced — carry anything typed there back into .env", false},
		{"connection lost", &fake{rc: 255, out: &none}, "kasbah history", false},
		{"no report", &fake{out: &none}, "reported no report", false},
		{"another version", &fake{out: &other}, "reported version '9.9.9', not the 1.0.0", false},
		{"fragment fails", &fake{fragErr: errors.New("x")}, "the deploy itself succeeded", true},
	}
	for _, c := range cases {
		project(t, "")
		err, out := deployWith(t, c.f, Options{Target: "d@h"})
		if err == nil || !strings.Contains(out, c.want) {
			t.Errorf("%s: %v\n%s", c.name, err, out)
		}
		if c.f.called("fragment") != c.frag {
			t.Errorf("%s: fragment shipped = %v", c.name, !c.frag)
		}
		noState(t, c.name)
	}
}

func TestRunInterruptedLeavesTheServerToFinish(t *testing.T) {
	project(t, "")
	none := "hook chatter\n"
	f := &fake{rc: 255, out: &none}
	var errb bytes.Buffer
	out := &cli.Output{Stdout: &errb, Stderr: &errb}
	pwd, _ := os.Getwd()
	err := Run(Ctx{
		Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: out},
		PWD: pwd, Version: "0.1.0",
		Dial:        func(string) (Server, error) { return f, nil },
		Now:         func() time.Time { return time.Unix(0, 0) },
		Interrupted: func() int { return 130 },
	}, Options{Target: "d@h"})
	var ce *cli.Error
	if !errors.As(err, &ce) || ce.Code != 130 {
		t.Fatalf("not an interrupt: %#v", err)
	}
	out.Report(err)
	if s := errb.String(); !strings.Contains(s, "the server carries on") || !strings.Contains(s, "kasbah history d@h") {
		t.Errorf("%s", s)
	}
	if f.called("fragment") {
		t.Error("the fragment was shipped")
	}
	noState(t, "interrupted")
}

func exitOf(err error) int {
	var ce *cli.Error
	if errors.As(err, &ce) {
		return ce.Code
	}
	return -1
}

func TestRunResources(t *testing.T) {
	project(t, "resources:\n  cpus: 25%\n  memory: 512m\n")
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h", SkipHooks: true, NoHealthWait: true})
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if len(f.injects) != 1 || strings.Join(f.injects[0], " ") != "KASBAH_CPU_LIMIT=0.5 KASBAH_MEM_LIMIT=512m" ||
		!strings.Contains(out, "limits:  KASBAH_CPU_LIMIT=0.5 KASBAH_MEM_LIMIT=512m (from kasbah.yml resources)") {
		t.Errorf("resolved limits: %v\n%s", f.injects, out)
	}
	if f.calls[1] != "limits 25% 512m" {
		t.Errorf("resolved before the sync: %v", f.calls)
	}

	project(t, "resources:\n  memory: 2g\n")
	f = &fake{limits: "host_cores=2\nhost_mem_kb=2097152\nmem=2g\n"}
	err, out = deployWith(t, f, Options{Target: "d@h", SkipHooks: true, NoHealthWait: true})
	if exitOf(err) != 1 || !strings.Contains(out, "resources.memory '2g' comes to 2g on d@h") || !strings.Contains(out, "ceiling of 1g") ||
		f.called("sync") || f.called("inject") || f.called("run") {
		t.Errorf("above the ceiling: %v %v\n%s", err, f.calls, out)
	}
	noState(t, "above the ceiling")

	project(t, "resources:\n  memory: 512\n")
	f = &fake{}
	err, out = deployWith(t, f, Options{Target: "d@h"})
	if exitOf(err) != 1 || !strings.Contains(out, "has no unit") || f.called("marker") {
		t.Errorf("a bare memory is refused before dialing: %v %v\n%s", err, f.calls, out)
	}
}

func TestRunSuccess(t *testing.T) {
	project(t, "client: acme\n")
	os.Remove(Fragment)
	gitc(t, "commit", "-qam", "no fragment")
	gitc(t, "tag", "-f", "v1.0.0")
	f := &fake{drift: "template_exists=no\nenv_exists=yes\nmissing=\nextra=\n"}
	err, out := deployWith(t, f, Options{Target: "d@h", SkipHooks: true, NoHealthWait: true})
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if f.client != "acme" || !strings.Contains(out, "client:  acme (written") {
		t.Errorf("explicit client: %q\n%s", f.client, out)
	}
	if !strings.Contains(out, "has no /apps/demo/.env.prod.example") || len(f.injects) != 1 || f.injects[0][0] != "KASBAH_CPU_LIMIT=1" {
		t.Errorf("no template: warns and still injects (%v)\n%s", f.injects, out)
	}
	if f.called("fragment") || !strings.Contains(out, "no traefik-dynamic.yml") || strings.Contains(out, "routing:") {
		t.Errorf("no fragment: warns, ships nothing\n%s", out)
	}
	if s := f.spec; !s.SkipHooks || !s.NoHealthWait || s.OnHookFailure != "" || s.Mode != "deploy" || s.Kasbah != "0.1.0" {
		t.Errorf("spec %+v", s)
	}
	if v, _ := state.Get(state.File, "last_version"); v != "1.0.0" {
		t.Errorf("last_version %q", v)
	}
	want := []string{"marker", "snapshot .env,.env.prod.example,compose.yml", "prepare", "sync compose.prod.yml", "sync .env.prod.example", "drift", "inject", "run"}
	if strings.Join(f.calls, ",") != strings.Join(want, ",") {
		t.Errorf("calls %v", f.calls)
	}
	if len(f.token) != 24 || f.spec.Snapshot != f.token {
		t.Errorf("snapshot token %q, spec's %q", f.token, f.spec.Snapshot)
	}
}

func facts(reg string, dms string) *MailFacts {
	f := &MailFacts{Stack: true, Env: true, DMS: dms}
	if reg != "-" {
		f.HasRegistry, f.Registry = true, base64.StdEncoding.EncodeToString([]byte(reg))
	}
	return f
}

func TestMailClaim(t *testing.T) {
	served := "primary_domain: demo.test\n"
	cases := []struct {
		name     string
		f        *fake
		want     []string
		fails    bool
		prepared bool
	}{
		{"no stack", &fake{mail: &MailFacts{DMS: "running"}}, []string{"there is no mail stack at /apps/mail"}, false, true},
		{"no .env", &fake{mail: &MailFacts{Stack: true, DMS: "running"}}, []string{"/apps/mail on d@h has no .env"}, false, true},
		{"no registry", &fake{mail: facts("-", "running")}, []string{"/apps/mail/kasbah.yml on d@h is missing or unreadable"}, false, true},
		{"blank registry", &fake{mail: facts("\n \n", "running")}, []string{"is missing or unreadable"}, false, true},
		{"not YAML", &fake{mail: facts("a: [", "running")}, []string{"does not parse as YAML"}, false, true},
		{"no primary", &fake{mail: facts("domains: [demo.test]\n", "running")}, []string{"/apps/mail/kasbah.yml on d@h has no primary_domain:"}, true, false},
		{"met", &fake{mail: facts(served, "running")}, []string{"mail: demo.test is served by the stack at /apps/mail (dms running)"}, false, true},
		{"dms absent", &fake{mail: facts(served, "absent")}, []string{"is served by the stack", "there is no mail-dms container"}, false, true},
		{"dms restarting", &fake{mail: facts(served, "restarting")}, []string{"is 'restarting', not running"}, false, true},
		{"unmet", &fake{mail: facts("primary_domain: other.test\n", "running")}, []string{"lists: other.test", "mail for demo.test is not accepted until then"}, false, true},
		{"probe fails", &fake{mailErr: cli.Fail("could not look for the mail stack")}, []string{"could not look for the mail stack"}, true, false},
	}
	for _, c := range cases {
		project(t, "mail:\n  domain: demo.test\n")
		err, out := deployWith(t, c.f, Options{Target: "d@h"})
		if (err != nil) != c.fails {
			t.Errorf("%s: err %v\n%s", c.name, err, out)
		}
		for _, w := range c.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: no %q in\n%s", c.name, w, out)
			}
		}
		if c.f.called("prepare") != c.prepared {
			t.Errorf("%s: prepared = %v", c.name, !c.prepared)
		}
	}
}

// A mail: key kasbah does not know, naming a file that is not there, is not
// read: a met claim deploys with no warning at all.
func TestMailUnknownKeyIgnored(t *testing.T) {
	project(t, "mail:\n  domain: demo.test\n  snappymail_domain: ./x.json\n")
	f := &fake{mail: facts("primary_domain: demo.test\n", "running")}
	err, out := deployWith(t, f, Options{Target: "d@h"})
	if err != nil || !strings.Contains(out, "is served by the stack") || strings.Contains(out, "warning:") || strings.Contains(out, "x.json") {
		t.Errorf("%v\n%s", err, out)
	}
	want := []string{"marker", "mail", "snapshot .env,.env.prod.example,compose.yml", "prepare", "sync compose.prod.yml", "sync .env.prod.example", "drift", "inject", "run", "fragment /apps/traefik/dynamic/demo.yml"}
	if strings.Join(f.calls, ",") != strings.Join(want, ",") {
		t.Errorf("calls %v", f.calls)
	}
}

func TestProtocolParsers(t *testing.T) {
	for in, ok := range map[string]bool{"snapshot=written\n": true, "snapshot=none\r\n": true, "": false, "snapshot=\n": false} {
		if err := parseSnapshot([]byte(in), "d@h"); (err == nil) != ok {
			t.Errorf("parseSnapshot(%q) = %v", in, err)
		}
	}
	if ParseFailure("{\""+FailureKey+"\":1,\"outcome\":\"\"}\n") != nil || ParseFailure("x\n") != nil {
		t.Error("ParseFailure took a line with no outcome")
	}
	if c, err := parsePrepare([]byte("client=written\r\nprepared=yes\n"), "d@h"); err != nil || c != "written" {
		t.Errorf("parsePrepare = %q %v", c, err)
	}
	if _, err := parsePrepare([]byte("prepared=yes\n"), "d@h"); err == nil || !strings.Contains(err.Error(), "reported no prepared or client") {
		t.Errorf("no client=: %v", err)
	}
	good := `{"stack":true,"env":false,"registry_b64":"","dms":"absent","registry":false}`
	if f, err := parseMailFacts([]byte(good+"\n"), "d@h"); err != nil || !f.Stack || f.DMS != "absent" {
		t.Errorf("parseMailFacts = %+v %v", f, err)
	}
	for _, bad := range []string{"", "mail_stack=yes", `{"stack":true,"dms":"running"}`, `{"stack":"yes","env":false,"registry_b64":"","dms":"x","registry":false}`} {
		if _, err := parseMailFacts([]byte(bad), "d@h"); err == nil || !strings.Contains(err.Error(), "the mail claim step on d@h reported no ") {
			t.Errorf("parseMailFacts(%q) = %v", bad, err)
		}
	}
	if r, missing, _ := ParseReport(`{"kasbah_deploy_report":1,"version":1,"prev_version":"","deployed_before":false,"backup":"x","digest":"-"}`); r != nil || strings.Join(missing, "") != "readable values" {
		t.Errorf("a mistyped value: %v %v", r, missing)
	}
}

// deployWith's clock is the epoch.
const epochLabel = "1.0.0-dirty.19700101000000"

func TestParseDirty(t *testing.T) {
	for _, tt := range []struct {
		cmd  string
		args []string
		want string
	}{
		{"deploy", []string{"d@h", "--dirty"}, ""},
		{"deploy", []string{"--dirty=1"}, "--dirty takes no value"},
		{"deploy", []string{"--dirty", "1.2.0"}, "pass one or the other"},
		{"deploy", []string{"1.2.0-dirty.20261028080507"}, "no tag holds its files"},
		{"rollback", []string{"--dirty"}, "not a rollback flag"},
		{"rollback", []string{"d@h", "1.2.0-dirty.20261028080507"}, "never a rollback target"},
		{"rollback", []string{"1.2.0-rc.1"}, ""},
	} {
		o, err := parse(tt.cmd, tt.args)
		switch {
		case tt.want == "" && err != nil:
			t.Errorf("%s %q: %v", tt.cmd, tt.args, err)
		case tt.want == "" && tt.cmd == "deploy" && !o.Dirty:
			t.Errorf("%s %q: Dirty not set", tt.cmd, tt.args)
		case tt.want != "" && (err == nil || !strings.Contains(err.Error(), tt.want)):
			t.Errorf("%s %q = %v, want %q", tt.cmd, tt.args, err, tt.want)
		}
	}
}

func TestDirtyTreeRefused(t *testing.T) {
	project(t, "")
	os.WriteFile("scratch.txt", []byte("x"), 0o644)
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h"})
	if err == nil || !strings.Contains(out, "?? scratch.txt") || !strings.Contains(out, "kasbah deploy --dirty") {
		t.Fatalf("a dirty tree deployed: %v\n%s", err, out)
	}
	if len(f.calls) != 0 {
		t.Errorf("the server was reached: %v", f.calls)
	}
	noState(t, "dirty tree")
}

// A project that builds nothing labels its own --dirty run.
func TestDirtyStockOnly(t *testing.T) {
	project(t, "")
	os.WriteFile(".env.prod.example", []byte("A=2\n"), 0o644)
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h", Dirty: true})
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if f.spec.Version != epochLabel || !strings.Contains(out, "Deployed demo "+epochLabel) || !strings.Contains(out, "never a rollback target") {
		t.Errorf("spec %q\n%s", f.spec.Version, out)
	}
	if v, _ := state.Get(state.File, "last_version"); v != epochLabel {
		t.Errorf("last_version %q", v)
	}
}

func builtProject(t *testing.T) {
	project(t, "")
	os.WriteFile("compose.prod.yml", []byte("services:\n  web:\n    build: .\n    image: demo-web:current\n"), 0o644)
	gitc(t, "commit", "-qam", "build")
	gitc(t, "tag", "-f", "v1.0.0")
	os.WriteFile(".env.prod.example", []byte("A=2\n"), 0o644)
}

func TestDirtyBuiltNeedsItsBuild(t *testing.T) {
	builtProject(t)
	tree, err := release.Fingerprint("deploy")
	if err != nil {
		t.Fatal(err)
	}
	const label = "1.0.0-dirty.20261028080507"
	record := func(server, tree string) {
		os.Remove(state.File)
		if server == "" {
			return
		}
		state.Record(state.File, "0.1.0", buildpush.DirtyBuild, label, buildpush.DirtyServer, server, buildpush.DirtyTree, tree)
	}
	for _, c := range []struct {
		name, server, tree, want string
	}{
		{"never built", "", "", "records no `kasbah build-push --dirty`"},
		{"another server", "x@other", tree, "was shipped to x@other — not d@h"},
		{"tree moved on", "d@h", "0000", "the working tree has changed since"},
	} {
		record(c.server, c.tree)
		f := &fake{}
		err, out := deployWith(t, f, Options{Target: "d@h", Dirty: true})
		if err == nil || !strings.Contains(out, c.want) || !strings.Contains(out, "kasbah build-push d@h --dirty") {
			t.Errorf("%s: %v\n%s", c.name, err, out)
		}
		if len(f.calls) != 0 {
			t.Errorf("%s: the server was reached: %v", c.name, f.calls)
		}
	}

	record("d@h", tree)
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h", Dirty: true})
	if err != nil || f.spec.Version != label || strings.Join(f.spec.Images, ",") != "demo-web" {
		t.Fatalf("the recorded build: %v %+v\n%s", err, f.spec, out)
	}
}

func TestChangelogDirtyEndpoints(t *testing.T) {
	project(t, "")
	for _, c := range []struct{ prev, want, not string }{
		{"1.0.0-dirty.20261028080507", "compared as its base tag v1.0.0", "git fetch"},
		{"0.0.0-dirty.20261028080507", "no tagged base", "git fetch"},
		{"3.0.0-dirty.20261028080507", "based on 3.0.0, and v3.0.0 is no tag in this checkout", "git fetch"},
	} {
		var b strings.Builder
		r := &run{c: Ctx{Out: &cli.Output{Stdout: &b, Stderr: &b}}, version: "1.0.0", target: "d@h", mode: "deploy"}
		r.changelog(&Report{PrevVersion: c.prev})
		if !strings.Contains(b.String(), c.want) || strings.Contains(b.String(), c.not) {
			t.Errorf("prev %s:\n%s", c.prev, b.String())
		}
	}
}

func TestChangelogFirstDeployWording(t *testing.T) {
	for _, c := range []struct {
		rep  Report
		want string
	}{
		{Report{}, "first deploy to d@h"},
		{Report{FailedOnly: true}, "no earlier deploy to d@h succeeded"},
	} {
		var b strings.Builder
		r := &run{c: Ctx{Out: &cli.Output{Stdout: &b, Stderr: &b}}, version: "1.0.0", target: "d@h", mode: "deploy"}
		r.changelog(&c.rep)
		if !strings.Contains(b.String(), c.want) {
			t.Errorf("%+v:\n%s", c.rep, b.String())
		}
	}
}

func TestParseBump(t *testing.T) {
	for in, want := range map[string]string{
		"--bump=major d@h":     "bump=major",
		"--bump=x":             "error: deploy: --bump=x is not a bump",
		"--bump":               "error: deploy: --bump takes its value with '='",
		"--no-git-push":        "error: deploy: unknown flag '--no-git-push'",
		"--bump=patch --dirty": "error: deploy: --dirty ships under no tag",
		"--bump=patch 1.0.0":   "error: deploy: 1.0.0 names a tag that exists",
	} {
		o, err := Parse(strings.Split(in, " "))
		got := "bump=" + o.Bump
		if err != nil {
			got = "error: " + err.Error()
		}
		if !strings.HasPrefix(got, want) {
			t.Errorf("Parse(%q) = %q, want %q", in, got, want)
		}
	}
	if _, err := ParseRollback([]string{"--bump=patch"}); err == nil || !strings.Contains(err.Error(), "unknown flag") {
		t.Errorf("rollback --bump=patch: %v", err)
	}
}

// untagged is project with HEAD one commit past v1.0.0, and a bare origin.
func untagged(t *testing.T) string {
	t.Helper()
	project(t, "")
	gitc(t, "commit", "-q", "--allow-empty", "-m", "fix")
	origin := t.TempDir()
	gitc(t, "init", "-q", "--bare", origin)
	gitc(t, "remote", "add", "origin", origin)
	return origin
}

func TestRunUntaggedBumps(t *testing.T) {
	origin := untagged(t)
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h"})
	if err == nil || !strings.Contains(out, "--bump=patch|minor|major") || len(f.calls) != 0 || gitc(t, "tag", "--points-at", "HEAD") != "" {
		t.Fatalf("no terminal, no --bump: %v %v\n%s", err, f.calls, out)
	}
	noState(t, "unanswered")

	err, out = deployWith(t, f, Options{Target: "d@h", Bump: "patch"})
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if f.spec.Version != "1.0.1" || gitc(t, "tag", "--points-at", "HEAD") != "v1.0.1" {
		t.Errorf("spec %q, HEAD %q", f.spec.Version, gitc(t, "tag", "--points-at", "HEAD"))
	}
	if got := gitc(t, "--git-dir="+origin, "tag"); got != "" {
		t.Errorf("origin's tags %q", got)
	}
	tagged, told := strings.Index(out, "Tagged HEAD v1.0.1"), strings.Index(out, "git:     v1.0.1 is not on origin")
	if tagged < 0 || told < tagged || !strings.Contains(out, "the tag stays") || !strings.Contains(out, "git push origin v1.0.1") {
		t.Errorf("output\n%s", out)
	}
}

// A run that fails after the tag leaves it here for the next run.
func TestRunUntaggedFailureKeepsTag(t *testing.T) {
	origin := untagged(t)
	f := &fake{rc: 1}
	if err, out := deployWith(t, f, Options{Target: "d@h", Bump: "minor"}); err == nil {
		t.Fatalf("deployed\n%s", out)
	}
	if gitc(t, "tag", "--points-at", "HEAD") != "v1.1.0" || gitc(t, "--git-dir="+origin, "tag") != "" {
		t.Errorf("HEAD %q, origin %q", gitc(t, "tag", "--points-at", "HEAD"), gitc(t, "--git-dir="+origin, "tag"))
	}
	noState(t, "failed")
	f = &fake{}
	if err, out := deployWith(t, f, Options{Target: "d@h"}); err != nil || f.spec.Version != "1.1.0" || !strings.Contains(out, "v1.1.0 is not on origin") {
		t.Errorf("the rerun: %v\n%s", err, out)
	}
}

func TestRunUntaggedDirtyRefused(t *testing.T) {
	untagged(t)
	os.WriteFile("scratch.txt", []byte("x"), 0o644)
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h", Bump: "patch"})
	if err == nil || !strings.Contains(out, "commit first") || !strings.Contains(out, "kasbah deploy --dirty") || len(f.calls) != 0 {
		t.Fatalf("%v %v\n%s", err, f.calls, out)
	}
	if gitc(t, "tag", "--points-at", "HEAD") != "" {
		t.Error("HEAD was tagged")
	}
}

func TestRunUntaggedBuiltRefused(t *testing.T) {
	builtProject(t)
	gitc(t, "commit", "-qam", "fix")
	for _, bump := range []string{"", "patch"} {
		f := &fake{}
		err, out := deployWith(t, f, Options{Target: "d@h", Bump: bump})
		if err == nil || !strings.Contains(out, "demo builds images") || !strings.Contains(out, "kasbah build-push d@h") || strings.Contains(out, "--bump=patch|minor|major") || len(f.calls) != 0 {
			t.Errorf("bump %q: %v %v\n%s", bump, err, f.calls, out)
		}
		if gitc(t, "tag", "--points-at", "HEAD") != "" {
			t.Errorf("bump %q: HEAD was tagged", bump)
		}
	}
}

// releasedFirst is whether the server's lock and session were both let go
// before origin was asked about the tag.
func releasedFirst(out string) bool {
	ask := strings.Index(out, "asking origin whether")
	u, c := strings.Index(out, "<unlocked>"), strings.Index(out, "<closed>")
	return ask > 0 && u >= 0 && c >= 0 && u < ask && c < ask
}

// Origin lacking the tag is one summary line, and the tag stays off it; origin
// having it, or there being none, is silence. The server is let go of before
// origin is asked.
func TestRunUnpublishedTag(t *testing.T) {
	project(t, "")
	origin := t.TempDir()
	gitc(t, "init", "-q", "--bare", origin)
	gitc(t, "remote", "add", "origin", origin)
	f := &fake{marks: io.Discard}
	err, out := deployWith(t, f, Options{Target: "d@h"})
	want := "git:     v1.0.0 is not on origin — the server runs a version origin cannot fetch; publish it:  git push origin v1.0.0"
	if err != nil || strings.Count(out, "git:") != 1 || !strings.Contains(out, want) || gitc(t, "--git-dir="+origin, "tag") != "" {
		t.Fatalf("%v\n%s", err, out)
	}
	if f.unlocked != 1 || f.closed != 1 || !releasedFirst(out) {
		t.Errorf("unlocked %d, closed %d, released before asking origin %v\n%s", f.unlocked, f.closed, releasedFirst(out), out)
	}
	gitc(t, "push", "-q", "origin", "v1.0.0")
	if err, out := deployWith(t, &fake{}, Options{Target: "d@h"}); err != nil || strings.Contains(out, "git:") {
		t.Errorf("on origin: %v\n%s", err, out)
	}
}

func TestRunOriginUnreachable(t *testing.T) {
	project(t, "")
	gitc(t, "remote", "add", "origin", filepath.Join(t.TempDir(), "gone.git"))
	err, out := deployWith(t, &fake{}, Options{Target: "d@h"})
	if err != nil || strings.Count(out, "git:") != 1 || !strings.Contains(out, "git:     could not ask origin whether it has v1.0.0, so that went unchecked") || strings.Contains(out, "warning:") {
		t.Errorf("%v\n%s", err, out)
	}
	if v, _ := state.Get(state.File, "last_version"); v != "1.0.0" {
		t.Errorf("last_version %q", v)
	}
}

func TestRunNoOriginSilent(t *testing.T) {
	project(t, "")
	err, out := deployWith(t, &fake{}, Options{Target: "d@h"})
	if err != nil || strings.Contains(out, "git:") || strings.Contains(out, "origin") || strings.Contains(out, "warning:") {
		t.Errorf("%v\n%s", err, out)
	}
}

// The engine is told which hosts the shipped fragment routes to.
func TestRunSendsRoutedHosts(t *testing.T) {
	project(t, "")
	os.WriteFile(Fragment, []byte("http:\n  services:\n    demo:\n      loadBalancer:\n        servers:\n          - url: \"http://demo-web:80\"\n          - url: http://demo-alt/x\n"), 0o644)
	gitc(t, "commit", "-qam", "route")
	gitc(t, "tag", "-f", "v1.0.0")
	f := &fake{drift: "template_exists=yes\nenv_exists=yes\nmissing=\nextra=\n"}
	if err, out := deployWith(t, f, Options{Target: "d@h", SkipHooks: true, NoHealthWait: true}); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if got := strings.Join(f.spec.Routed, ","); got != "demo-web,demo-alt" {
		t.Errorf("routed %q", got)
	}
}

func TestEnvSeedFlag(t *testing.T) {
	for _, parse := range []func([]string) (Options, error){Parse, ParseRollback} {
		o, err := parse([]string{"d@h", "--env-seed=/tmp/seed", "--on-drift=continue"})
		if err != nil || o.EnvSeed != "/tmp/seed" || o.OnDrift != "continue" {
			t.Errorf("--env-seed=: %+v %v", o, err)
		}
		if _, err := parse([]string{"--env-seed"}); err == nil || !strings.Contains(err.Error(), "--env-seed=FILE") {
			t.Errorf("bare --env-seed: %v", err)
		}
	}
	if !strings.Contains(Usage(), "--env-seed=FILE") || !strings.Contains(RollbackUsage(), "--env-seed=FILE") {
		t.Error("--env-seed is missing from a usage")
	}

	project(t, "")
	f := &fake{}
	err, out := deployWith(t, f, Options{Target: "d@h", EnvSeed: t.TempDir() + "/nope"})
	if err == nil || !strings.Contains(out, "deploy: --env-seed=") || len(f.calls) != 0 {
		t.Errorf("a missing seed is refused before anything connects: %v %q %v", err, out, f.calls)
	}

	seed := t.TempDir() + "/seed"
	os.WriteFile(seed, []byte("B=s3cret\n"), 0o600)
	f = &fake{drift: "template_exists=yes\nenv_exists=yes\nmissing=B\nextra=\n"}
	err, out = deployWith(t, f, Options{Target: "d@h", EnvSeed: seed})
	if err != nil || !f.called("setup --seed --headless") || f.called("seed") || strings.Contains(out, "s3cret") || strings.Contains(out, "setup/continue/abort") {
		t.Errorf("a seeded drift without a terminal: %v %q %v", err, out, f.calls)
	}
}

// The engine's question after a failed pre-step: a terminal answers it; with
// none the answer is no-tty and the failure names the flag.
func TestRunAnswersTheEnginesQuestion(t *testing.T) {
	q := &Question{Step: "pre-deploy hook", Error: "the pre-deploy hook failed (exit 1): false"}
	restored := "{\"" + FailureKey + "\":1,\"outcome\":\"restored\",\"reason\":\"start\",\"prev\":\"0.9.0\"}\n"
	for _, tc := range []struct {
		name, typed, want string
		tty               bool
	}{
		{"continue", "continue\n", AnswerContinue, true},
		{"by number", "1\n", AnswerContinue, true},
		{"stop", "stop\n", AnswerStop, true},
		{"q", "q\n", AnswerStop, true},
		{"no terminal", "", AnswerNoTTY, false},
	} {
		project(t, "")
		f := &fake{question: q, rc: 1, out: &restored}
		var errb bytes.Buffer
		out := &cli.Output{Stdout: &errb, Stderr: &errb}
		pwd, _ := os.Getwd()
		err := Run(Ctx{
			Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(tc.typed), Out: out, TTY: tc.tty},
			PWD: pwd, Version: "0.1.0",
			Dial: func(string) (Server, error) { return f, nil },
			Now:  func() time.Time { return time.Unix(0, 0) },
		}, Options{Target: "d@h"})
		if err != nil {
			out.Report(err)
		}
		if f.answer != tc.want {
			t.Errorf("%s: answered %q, want %q\n%s", tc.name, f.answer, tc.want, errb.String())
		}
		names := strings.Contains(errb.String(), "pass --on-hook-failure=continue or --on-hook-failure=stop")
		if names != !tc.tty {
			t.Errorf("%s: the flag named = %v\n%s", tc.name, names, errb.String())
		}
		if tc.tty && !strings.Contains(errb.String(), "the pre-deploy hook failed — carry on with the deploy of 1.0.0 anyway?") {
			t.Errorf("%s: no question\n%s", tc.name, errb.String())
		}
	}
}

// signalIn is a terminal that delivers a signal on its first read, then never
// types anything.
type signalIn struct{ sig func() }

func (s signalIn) Read([]byte) (int, error) { s.sig(); select {} }

// A signal, before the question or while it is on screen, answers stop: no
// prompt after it, and the message says the files are put back.
func TestRunSignalAtTheQuestionStops(t *testing.T) {
	q := &Question{Step: "pre-deploy hook", Error: "the pre-deploy hook failed (exit 1): false"}
	restored := "{\"" + FailureKey + "\":1,\"outcome\":\"restored\",\"reason\":\"start\",\"prev\":\"0.9.0\"}\n"
	for _, during := range []bool{false, true} {
		project(t, "")
		var held func(os.Signal)
		signal := func() { held(os.Interrupt) }
		f := &fake{question: q, rc: 1, out: &restored}
		var in io.Reader = strings.NewReader("continue\n")
		if during {
			in = signalIn{signal}
		} else {
			f.beforeAsk = signal
		}
		var errb bytes.Buffer
		out := &cli.Output{Stdout: &errb, Stderr: &errb}
		pwd, _ := os.Getwd()
		err := Run(Ctx{
			Out: out, Prompter: &prompt.Prompter{In: in, Out: out, TTY: true},
			PWD: pwd, Version: "0.1.0",
			Dial:        func(string) (Server, error) { return f, nil },
			Now:         func() time.Time { return time.Unix(0, 0) },
			Interrupted: func() int { return 130 },
			Hold:        func(fn func(os.Signal)) func() { held = fn; return func() {} },
		}, Options{Target: "d@h"})
		if exitOf(err) != 130 {
			t.Fatalf("during=%v: not an interrupt: %v", during, err)
		}
		out.Report(err)
		s := errb.String()
		if f.answer != AnswerStop || !strings.Contains(s, "the interrupt answered stop") || !strings.Contains(s, "puts back the files this run shipped") || strings.Contains(s, "carries on without this end") {
			t.Errorf("during=%v: answered %q\n%s", during, f.answer, s)
		}
		if prompted := strings.Contains(s, "carry on with the deploy of 1.0.0 anyway?"); prompted != during {
			t.Errorf("during=%v: prompted=%v\n%s", during, prompted, s)
		}
		if f.called("fragment") {
			t.Errorf("during=%v: the fragment was shipped", during)
		}
	}
}

func TestRunSaysItContinued(t *testing.T) {
	project(t, "")
	b, _ := json.Marshal(Report{Version: "1.0.0", Backup: "no-backup", Digest: "-", Continued: []string{"backup"}})
	rep := "{\"" + ReportKey + "\":1," + string(b[1:]) + "\n"
	f := &fake{out: &rep}
	err, out := deployWith(t, f, Options{Target: "d@h", OnHookFailure: "continue"})
	if err != nil || !strings.Contains(out, "the deploy 1.0.0 carried on past a failed backup") || f.spec.OnHookFailure != "continue" {
		t.Fatalf("%v\n%s", err, out)
	}
}
