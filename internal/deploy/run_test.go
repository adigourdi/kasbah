package deploy

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/state"
)

// fake is a server: what each call returns, and what reached it.
type fake struct {
	drift       string
	clientState string
	mail        *MailFacts
	mailErr     error
	seedRes     string
	seedErr     error
	out         *string
	rc          int
	fragErr     error

	calls   []string
	client  string
	injects [][]string
	seeds   [][]byte
	spec    *Spec
}

func (f *fake) log(c string) { f.calls = append(f.calls, c) }

func (f *fake) Marker() (*marker.Marker, error) {
	f.log("marker")
	return &marker.Marker{AppsPath: "/apps", DataPath: "/data", CPULimit: "1", MemLimit: "1g"}, nil
}
func (f *fake) Prepare(string) error              { return nil }
func (f *fake) ShipTemplate(string, string) error { return nil }
func (f *fake) Setup(string, bool) int            { return 0 }
func (f *fake) Close()                            {}
func (f *fake) Sync(e Entry, base string) error   { f.log("sync " + e.Src); return nil }
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
func (f *fake) Seed(target string, data []byte) (string, error) {
	f.log("seed " + target)
	f.seeds = append(f.seeds, data)
	return f.seedRes, f.seedErr
}
func (f *fake) Run(dir string, sp Spec) (string, int) {
	f.log("run")
	f.spec = &sp
	if f.out != nil {
		return *f.out, f.rc
	}
	b, _ := json.Marshal(Report{Version: sp.Version, Backup: "no-backup", Digest: "-"})
	return "{\"" + ReportKey + "\":1," + string(b[1:]) + "\n", f.rc
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
		"seed.json":           "{\"seed\":1}\n",
	}
	for n, b := range files {
		os.WriteFile(n, []byte(b), 0o644)
	}
	for _, a := range [][]string{{"init", "-q", "."}, {"add", "-A"}, {"commit", "-qm", "x"}, {"tag", "v1.0.0"}} {
		cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, a...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v %s", a, err, out)
		}
	}
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

func TestRunSuccess(t *testing.T) {
	project(t, "client: acme\n")
	os.Remove(Fragment)
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
	f := &MailFacts{Stack: true, Env: true, DMS: dms, Snappymail: "running"}
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
		seeded   bool
		fails    bool
		prepared bool
	}{
		{"no stack", &fake{mail: &MailFacts{DMS: "running"}}, []string{"there is no mail stack at /apps/mail"}, false, false, true},
		{"no .env", &fake{mail: &MailFacts{Stack: true, DMS: "running"}}, []string{"/apps/mail on d@h has no .env"}, false, false, true},
		{"no registry", &fake{mail: facts("-", "running")}, []string{"/apps/mail/kasbah.yml on d@h is missing or unreadable"}, false, false, true},
		{"blank registry", &fake{mail: facts("\n \n", "running")}, []string{"is missing or unreadable"}, false, false, true},
		{"not YAML", &fake{mail: facts("a: [", "running")}, []string{"does not parse as YAML"}, false, false, true},
		{"no primary", &fake{mail: facts("domains: [demo.test]\n", "running")}, []string{"/apps/mail/kasbah.yml on d@h has no primary_domain:"}, false, true, false},
		{"dms absent", &fake{mail: facts(served, "absent"), seedRes: "copied"}, []string{"there is no mail-dms container", "seeded SnappyMail's demo.test.json"}, true, false, true},
		{"dms restarting", &fake{mail: facts(served, "restarting"), seedRes: "present"}, []string{"is 'restarting', not running", "left as it is"}, true, false, true},
		{"seed fails", &fake{mail: facts(served, "running"), seedErr: errors.New("x")}, []string{"is served by the stack", "could not seed SnappyMail's config"}, true, false, true},
		{"no snappymail", &fake{mail: facts(served, "running"), seedRes: "nocontainer"}, []string{"no mail-snappymail container"}, true, false, true},
		{"unmet", &fake{mail: facts("primary_domain: other.test\n", "running")}, []string{"lists: other.test", "it was NOT copied"}, false, false, true},
		{"probe fails", &fake{mailErr: cli.Fail("could not look for the mail stack")}, []string{"could not look for the mail stack"}, false, true, false},
	}
	for _, c := range cases {
		project(t, "mail:\n  domain: demo.test\n  snappymail_domain: seed.json\n")
		err, out := deployWith(t, c.f, Options{Target: "d@h"})
		if (err != nil) != c.fails {
			t.Errorf("%s: err %v\n%s", c.name, err, out)
		}
		for _, w := range c.want {
			if !strings.Contains(out, w) {
				t.Errorf("%s: no %q in\n%s", c.name, w, out)
			}
		}
		if c.f.called("seed") != c.seeded {
			t.Errorf("%s: seed ran = %v", c.name, !c.seeded)
		}
		if c.seeded && (string(c.f.seeds[0]) != "{\"seed\":1}\n" || !c.f.called("seed /var/lib/snappymail/_data_/_default_/domains/demo.test.json")) {
			t.Errorf("%s: seeded %q (%v)", c.name, c.f.seeds, c.f.calls)
		}
		if c.f.called("prepare") != c.prepared {
			t.Errorf("%s: prepared = %v", c.name, !c.prepared)
		}
	}
	project(t, "mail:\n  domain: demo.test\n  snappymail_domain: nope.json\n")
	f := &fake{mail: facts(served, "running")}
	if err, out := deployWith(t, f, Options{Target: "d@h"}); err != nil || f.called("seed") || !strings.Contains(out, "no such file in this checkout") {
		t.Errorf("a seed file the checkout lacks: %v %v\n%s", err, f.calls, out)
	}
}

func TestProtocolParsers(t *testing.T) {
	if c, err := parsePrepare([]byte("client=written\r\nprepared=yes\n"), "d@h"); err != nil || c != "written" {
		t.Errorf("parsePrepare = %q %v", c, err)
	}
	if _, err := parsePrepare([]byte("prepared=yes\n"), "d@h"); err == nil || !strings.Contains(err.Error(), "reported no prepared or client") {
		t.Errorf("no client=: %v", err)
	}
	good := `{"stack":true,"env":false,"registry_b64":"","dms":"absent","snappymail":"absent","registry":false}`
	if f, err := parseMailFacts([]byte(good+"\n"), "d@h"); err != nil || !f.Stack || f.DMS != "absent" {
		t.Errorf("parseMailFacts = %+v %v", f, err)
	}
	for _, bad := range []string{"", "mail_stack=yes", `{"stack":true,"dms":"running"}`, `{"stack":"yes","env":false,"registry_b64":"","dms":"x","snappymail":"x","registry":false}`} {
		if _, err := parseMailFacts([]byte(bad), "d@h"); err == nil || !strings.Contains(err.Error(), "reported no mail facts") {
			t.Errorf("parseMailFacts(%q) = %v", bad, err)
		}
	}
	if r, missing, _ := ParseReport(`{"kasbah_deploy_report":1,"version":1,"prev_version":"","deployed_before":false,"backup":"x","digest":"-"}`); r != nil || strings.Join(missing, "") != "readable values" {
		t.Errorf("a mistyped value: %v %v", r, missing)
	}
}
