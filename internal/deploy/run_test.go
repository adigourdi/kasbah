package deploy

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
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

	calls   []string
	client  string
	injects [][]string
	spec    *Spec
}

func (f *fake) log(c string) { f.calls = append(f.calls, c) }

func (f *fake) Marker() (*marker.Marker, error) {
	f.log("marker")
	return &marker.Marker{AppsPath: "/apps", DataPath: "/data", CPULimit: "1", MemLimit: "1g"}, nil
}
func (f *fake) HoldServer(string, string) (func(), error) { return func() {}, nil }
func (f *fake) Prepare(string) error                      { return nil }
func (f *fake) ShipTemplate(string, string) error         { return nil }
func (f *fake) Setup(string, bool) int                    { return 0 }
func (f *fake) Close()                                    {}
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
	return 0
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
func (f *fake) Run(dir string, sp Spec) (string, int) {
	f.log("run")
	f.spec = &sp
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
	cases := []struct {
		name string
		f    *fake
		want string
		frag bool
	}{
		{"engine fails", &fake{rc: 1}, "may already carry :current", false},
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

func TestRunSuccess(t *testing.T) {
	project(t, "client: acme\n")
	os.Remove(Fragment)
	gitc(t, "commit", "-qam", "no fragment")
	gitc(t, "tag", "-f", "v1.0.0")
	f := &fake{drift: "template_exists=no\nenv_exists=yes\nmissing=\nextra=\n"}
	err, out := deployWith(t, f, Options{Target: "d@h", SkipHooks: true, NoHealthWait: true, AllowStopped: true})
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
	if s := f.spec; !s.SkipHooks || !s.NoHealthWait || !s.AllowStopped || s.Mode != "deploy" || s.Kasbah != "0.1.0" {
		t.Errorf("spec %+v", s)
	}
	if v, _ := state.Get(state.File, "last_version"); v != "1.0.0" {
		t.Errorf("last_version %q", v)
	}
	want := []string{"marker", "prepare", "sync compose.prod.yml", "sync .env.prod.example", "drift", "inject", "run"}
	if strings.Join(f.calls, ",") != strings.Join(want, ",") {
		t.Errorf("calls %v", f.calls)
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
	want := []string{"marker", "mail", "prepare", "sync compose.prod.yml", "sync .env.prod.example", "drift", "inject", "run", "fragment /apps/traefik/dynamic/demo.yml"}
	if strings.Join(f.calls, ",") != strings.Join(want, ",") {
		t.Errorf("calls %v", f.calls)
	}
}

func TestProtocolParsers(t *testing.T) {
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
