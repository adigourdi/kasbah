package drop

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/templates"
)

func TestParse(t *testing.T) {
	o, err := Parse([]string{"deploy@vps\r", "--prune", "--yes"})
	if err != nil || o.Target != "deploy@vps" || !o.Prune || !o.Yes {
		t.Fatalf("got %+v %v", o, err)
	}
	for args, want := range map[string]string{
		"--prune=yes":   "--prune takes no value",
		"--yes=1":       "--yes takes no value",
		"--force":       "unknown flag '--force'",
		"vps":           "'vps' is not a USER@HOST",
		"a@b c@d":       "two servers given",
		"--colour=auto": "unknown flag '--colour'",
	} {
		if _, err := Parse(strings.Fields(args)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: got %v, want %q", args, err, want)
		}
	}
	if _, err := Parse([]string{"--help"}); err != ErrHelp {
		t.Errorf("--help: %v", err)
	}
	if o, _ := Parse(nil); o.Prune || o.Yes || o.Target != "" {
		t.Errorf("no flags: %+v", o)
	}
}

var tplFS, bashRegistry = func() (fs.FS, string) {
	b, _ := os.ReadFile("testdata/registry-bash.yml")
	return templates.FS, string(b)
}()

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

const builtCompose = "services:\n  web:\n    build: .\n    image: built-app-web:${V}\n  worker:\n    build: .\n    image: built-app-worker:1\n  cache:\n    image: redis:7-alpine\n"

// fixture is two projects: built-app builds two images, demo builds none.
func fixture() *Scan {
	return &Scan{HaveDocker: true, AppsState: "dir", ProjectState: "dir", DataState: "dir", BackupsState: "dir",
		FragmentState: "ok", LockState: "free", MailDir: "absent", RegistryState: "missing",
		Containers: []Container{{"built-app-web", "running"}},
		Images: []Image{
			{"sha256:w", []string{"built-app-web:3.4.0", "built-app-web:current"}},
			{"sha256:k", []string{"built-app-worker:3.4.0", "built-app-worker:current", "other:keep"}},
			{"sha256:n", []string{"nginx:alpine"}},
			{"sha256:o", []string{"ghost:1", "ghost:current"}},
		},
		Projects: []Project{
			{"built-app", "dir", "ok", b64(builtCompose)},
			{"data", "dir", "missing", ""},
			{"demo", "dir", "ok", b64("services:\n  web:\n    image: nginx:alpine\n")},
		}, Count: 3}
}

func plan(s *Scan, prune bool) *Plan {
	return &Plan{Name: "built-app", Target: "deploy@vps", Apps: "/apps", Data: "/apps/data", Prune: prune, Scan: s}
}

func TestDecideRemovesEveryTagOfOwnRepos(t *testing.T) {
	p := plan(fixture(), false)
	if err := Decide(p, tplFS); err != nil {
		t.Fatal(err)
	}
	want := "built-app-web:3.4.0 built-app-web:current built-app-worker:3.4.0 built-app-worker:current"
	if got := strings.Join(p.Remove, " "); got != want {
		t.Fatalf("remove: %s", got)
	}
	if len(p.Unknown) != 0 {
		t.Fatalf("the data path is not a project: unknown=%v", p.Unknown)
	}
	var buf bytes.Buffer
	p.Report(&buf)
	out := buf.String()
	for _, w := range []string{
		"kasbah drop — built-app on deploy@vps (/apps)\n",
		"  route       /apps/traefik/dynamic/built-app.yml\n",
		"  containers  built-app-web(running)\n",
		"    built-app-web:3.4.0       built by built-app, claimed by no other project\n",
		"    built-app-worker:3.4.0    untags only, the image also carries other:keep\n",
		"\nto keep\n  config      /apps/built-app/ (dir)\n",
		"a later `kasbah deploy` resurrects",
	} {
		if !strings.Contains(out, w) {
			t.Errorf("report lacks %q:\n%s", w, out)
		}
	}
	if strings.Contains(out, "nginx") || strings.Contains(out, "redis") {
		t.Errorf("a stock image is in nobody's build: and never a candidate:\n%s", out)
	}
	if strings.Join(p.Orphans, " ") != "ghost:1 ghost:current" {
		t.Errorf("orphans: %v", p.Orphans)
	}
}

func TestDecideSharedAndUnknownOwners(t *testing.T) {
	s := fixture()
	s.Projects = append(s.Projects, Project{"twin", "dir", "ok", b64("services:\n  w:\n    build: x\n    image: built-app-web\n")})
	s.Count++
	p := plan(s, false)
	Decide(p, nil)
	if strings.Join(p.Remove, " ") != "built-app-worker:3.4.0 built-app-worker:current" {
		t.Fatalf("a repository two projects declare is kept: %v", p.Remove)
	}
	for _, l := range p.Lines {
		if l.Tag == "built-app-web:current" && !strings.Contains(l.Why, "claimed by more than one project (built-app twin)") {
			t.Errorf("why: %q", l.Why)
		}
	}

	s = fixture()
	s.Projects[2].ComposeState = "unreadable"
	p = plan(s, false)
	Decide(p, nil)
	if len(p.Remove) != 0 || strings.Join(p.UnknownOthers, " ") != "demo" {
		t.Fatalf("one unreadable compose anywhere removes nothing: %v %v", p.Remove, p.UnknownOthers)
	}
	var buf bytes.Buffer
	p.Report(&buf)
	if !strings.Contains(buf.String(), "images      none — every tag of this project is left alone, below") ||
		!strings.Contains(buf.String(), "\nleft alone\n  images\n") {
		t.Errorf("report:\n%s", buf.String())
	}
	if err := p.pruneCliff(&cli.Output{Stdout: &buf, Stderr: &buf}); err == nil ||
		!strings.Contains(err.Error(), "--prune is refused: demo declare(s) images kasbah could not read") {
		t.Errorf("a neighbour's unknown declarations refuse --prune: %v", err)
	}
}

func TestPruneCliffOwnCompose(t *testing.T) {
	for st, refused := range map[string]bool{"unreadable": true, "ok": true, "missing": false} {
		s := fixture()
		s.Projects[0].ComposeState = st
		if st == "ok" {
			s.Projects[0].ComposeB64 = b64("services: [\n")
		} else {
			s.Projects[0].ComposeB64 = ""
		}
		p := plan(s, true)
		Decide(p, nil)
		var buf bytes.Buffer
		err := p.pruneCliff(&cli.Output{Stdout: &buf, Stderr: &buf})
		if refused != (err != nil) {
			t.Errorf("%s: refused=%v err=%v", st, refused, err)
		}
		if st == "ok" && !strings.Contains(err.Error(), "compose.yml is not YAML kasbah can parse") {
			t.Errorf("unparseable: %v", err)
		}
		if st == "missing" && !strings.Contains(buf.String(), "    ghost:current") {
			t.Errorf("no compose at all goes ahead and names the orphans:\n%s", buf.String())
		}
	}
}

func registryScan(reg string) *Scan {
	s := fixture()
	s.MailDir, s.RegistryState, s.RegistryB64 = "dir", "ok", b64(reg)
	return s
}

func TestMailRelease(t *testing.T) {
	want := []byte(bashRegistry)
	reg := strings.Replace(string(want), "  - other.example.org\n", "  - other.example.org\n  - built-app.test\n", 1)
	p := plan(registryScan(reg), true)
	p.MailDomain = "built-app.test"
	if err := Decide(p, tplFS); err != nil {
		t.Fatal(err)
	}
	if p.MailRendered != string(want) {
		t.Fatalf("the re-render is not byte-identical to the Bash renderer's:\n%s", p.MailRendered)
	}
	if p.MailPrev != Sum([]byte(reg)) || !strings.HasPrefix(p.MailVerdict, "released: built-app.test") {
		t.Errorf("prev/verdict: %s %s", p.MailPrev, p.MailVerdict)
	}

	for _, c := range []struct{ reg, domain, verdict string }{
		{reg, "mail.example.com", "NOT released: mail.example.com is the stack's primary_domain"},
		{reg, "nowhere.test", "nothing to release: /apps/mail/kasbah.yml does not list nowhere.test"},
		{"domains: [a.test]\n", "a.test", "NOT released: /apps/mail/kasbah.yml on deploy@vps has no primary_domain:"},
		{"[\n", "a.test", "NOT released: /apps/mail/kasbah.yml on deploy@vps could not be read as YAML"},
	} {
		p := plan(registryScan(c.reg), true)
		p.MailDomain = c.domain
		if err := Decide(p, tplFS); err != nil || !strings.HasPrefix(p.MailVerdict, c.verdict) || p.MailRendered != "" {
			t.Errorf("%s: %q %v", c.domain, p.MailVerdict, err)
		}
	}
	p = plan(registryScan(reg), false)
	p.MailDomain = "built-app.test"
	Decide(p, tplFS)
	if !strings.HasPrefix(p.MailVerdict, "kept: plain drop leaves the claim") || p.MailRendered != "" {
		t.Errorf("plain drop keeps the claim: %q", p.MailVerdict)
	}
}

// fake is a Session over a canned scan and act.
type fake struct {
	scan    *Scan
	actOut  string
	actRC   int
	acted   [][]string
	stdin   []byte
	scanned int
}

func (f *fake) Marker() (*marker.Marker, error) {
	return &marker.Marker{AppsPath: "/apps", DataPath: "/apps/data"}, nil
}
func (f *fake) Scan(apps, data, name string) ([]byte, int) {
	f.scanned++
	b, _ := json.Marshal(f.scan)
	return b, 0
}
func (f *fake) Act(stdin []byte, args []string) ([]byte, int) {
	f.acted = append(f.acted, args)
	f.stdin = stdin
	return []byte(f.actOut), f.actRC
}
func (f *fake) Close() {}

func project(t *testing.T, extra string) string {
	t.Helper()
	d := t.TempDir()
	t.Chdir(d)
	os.WriteFile("kasbah.yml", []byte("schema: 1\nkasbah_version: 0.1.0\nname: built-app\ndomain: built-app.test\n"+extra), 0o644)
	return d
}

func run(t *testing.T, f *fake, o Options, tty bool, answers string) (stdout, stderr string, code int) {
	t.Helper()
	var so, se bytes.Buffer
	out := &cli.Output{Stdout: &so, Stderr: &se}
	p := &prompt.Prompter{In: strings.NewReader(answers), Out: out, TTY: tty}
	code = out.Report(Run(Ctx{Out: out, Prompter: p, Version: "0.1.0", Templates: tplFS,
		Dial: func(string) (Session, error) { return f, nil }}, o))
	return so.String(), se.String(), code
}

func lastServer(t *testing.T) string {
	v, _ := state.Get(state.File, "last_server")
	return v
}

const okAct = `started=yes
{"fragment":"removed","down":"ok","down_detail":"","down_left":"","removed":["built-app-web:3.4.0","built-app-web:current","built-app-worker:3.4.0","built-app-worker:current"],"failed":[]}
`

func TestRunNoTTYNeverAssumes(t *testing.T) {
	project(t, "")
	f := &fake{scan: fixture()}
	so, se, code := run(t, f, Options{Target: "deploy@vps"}, false, "")
	if code != 1 || !strings.Contains(se, "--yes") || len(f.acted) != 0 {
		t.Fatalf("code %d acted %v stderr %s", code, f.acted, se)
	}
	if !strings.Contains(so, "built by built-app") {
		t.Errorf("the plan comes first:\n%s", so)
	}
	if lastServer(t) != "" {
		t.Errorf("a run that declined recorded last_server")
	}
}

func TestRunConfirmations(t *testing.T) {
	project(t, "")
	f := &fake{scan: fixture(), actOut: okAct}
	if _, se, code := run(t, f, Options{Target: "deploy@vps"}, true, "y\nbuilt-ap\n"); code != 1 ||
		!strings.Contains(se, "that is not built-app — nothing was changed") || len(f.acted) != 0 {
		t.Fatalf("a mistyped name: %d %s", code, se)
	}
	if _, se, code := run(t, f, Options{Target: "deploy@vps"}, true, "n\n"); code != 1 ||
		!strings.Contains(se, "not confirmed") || len(f.acted) != 0 {
		t.Fatalf("a no: %d %s", code, se)
	}
	so, se, code := run(t, f, Options{Target: "deploy@vps"}, true, "y\nbuilt-app\n")
	if code != 0 || len(f.acted) != 1 {
		t.Fatalf("typed back: %d %s", code, se)
	}
	if !strings.Contains(so, "  removed 4 of 4 image tag(s)\n") || !strings.Contains(so, "  kasbah deploy deploy@vps\n") {
		t.Errorf("outcome:\n%s", so)
	}
	if lastServer(t) != "deploy@vps" {
		t.Errorf("last_server not recorded")
	}
	want := "/apps /apps/data built-app no 0 - - -- built-app-web:3.4.0 built-app-web:current built-app-worker:3.4.0 built-app-worker:current"
	if got := strings.Join(f.acted[0], " "); got != want {
		t.Errorf("act argv: %s", got)
	}
}

func TestRunAllowStoppedFromManifest(t *testing.T) {
	project(t, "backup:\n  container: db\n")
	f := &fake{scan: fixture(), actOut: okAct}
	so, _, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 0 || !strings.Contains(so, "kasbah deploy deploy@vps --allow-stopped") {
		t.Fatalf("%d\n%s", code, so)
	}
	m := map[string]bool{"": false, "hooks:\n  pre-deploy: []\n": false, "hooks:\n  pre-deploy: [\"db pg_dump\"]\n": true,
		"hooks:\n  post-deploy: [\"x\"]\n": false, "backup:\n  container: \"\"\n": false}
	for extra, want := range m {
		project(t, extra)
		f := &fake{scan: fixture(), actOut: okAct}
		so, _, _ := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
		if got := strings.Contains(so, "--allow-stopped"); got != want {
			t.Errorf("%q: allow-stopped=%v", extra, got)
		}
	}
}

func TestRunNothingToDropNeverAsks(t *testing.T) {
	project(t, "")
	s := fixture()
	s.Images, s.Containers, s.FragmentState = nil, nil, "missing"
	s.ProjectState, s.DataState = "absent", "absent"
	s.Projects = s.Projects[1:]
	s.Count = 2
	for _, o := range []Options{{Target: "deploy@vps", Prune: true}, {Target: "deploy@vps"}} {
		f := &fake{scan: s}
		so, se, code := run(t, f, o, false, "")
		if code != 0 || !strings.Contains(so, "built-app is not on deploy@vps — nothing to drop") || len(f.acted) != 0 {
			t.Fatalf("%+v: %d %s %s", o, code, so, se)
		}
		if lastServer(t) != "deploy@vps" {
			t.Errorf("the nothing-to-do path records last_server")
		}
	}
}

func TestRunActOutcomes(t *testing.T) {
	project(t, "")
	// Refused by the act's own guards (a deploy took the lock meanwhile):
	// nothing changed, nothing recorded (docs/cli.md).
	f := &fake{scan: fixture(), actRC: 1}
	_, se, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "it refused before changing anything") || lastServer(t) != "" {
		t.Fatalf("refused: %d %q %s", code, lastServer(t), se)
	}
	// Past the guards and cut short.
	f = &fake{scan: fixture(), actOut: "started=yes\n", actRC: 255}
	_, se, code = run(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "some of it may have run — `kasbah drop deploy@vps` again") || lastServer(t) != "deploy@vps" {
		t.Fatalf("half-done: %d %s", code, se)
	}
	// A tag docker would not remove, and a container down left behind.
	f = &fake{scan: fixture(), actOut: `started=yes
{"fragment":"removed","down":"ok","down_detail":"","down_left":"built-app-run-1","removed":["built-app-web:3.4.0","built-app-web:current","built-app-worker:3.4.0"],"failed":[{"ref":"built-app-worker:current","reason":"conflict"}]}
`}
	so, se, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(so, "FAILED to remove image built-app-worker:current") ||
		!strings.Contains(se, "could not remove built-app-worker:current on deploy@vps: conflict") ||
		!strings.Contains(so, "down returned 0, and built-app-run-1 is still there") ||
		strings.Contains(so, "everything a redeploy needs") {
		t.Fatalf("partial: %d\n%s\n%s", code, so, se)
	}
	// A report that does not account for every tag.
	f = &fake{scan: fixture(), actOut: `started=yes
{"fragment":"removed","down":"ok","down_detail":"","down_left":"","removed":[],"failed":[]}
`}
	if _, se, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, ""); code != 1 || !strings.Contains(se, "accounted for 0 of 4") {
		t.Fatalf("truncated: %s", se)
	}
}

func TestRunPruneShipsRegistry(t *testing.T) {
	project(t, "mail:\n  domain: built-app.test\n")
	want := []byte(bashRegistry)
	reg := strings.Replace(string(want), "  - other.example.org\n", "  - other.example.org\n  - built-app.test\n", 1)
	f := &fake{scan: registryScan(reg), actOut: `started=yes
{"fragment":"removed","down":"ok","down_detail":"","down_left":"","removed":["built-app-web:3.4.0","built-app-web:current","built-app-worker:3.4.0","built-app-worker:current"],"failed":[],"mail":"written","data":"removed","config":"removed"}
`}
	so, se, code := run(t, f, Options{Target: "deploy@vps", Prune: true, Yes: true}, false, "")
	if code != 0 || string(f.stdin) != string(want) {
		t.Fatalf("%d %s\n%s", code, se, f.stdin)
	}
	a := f.acted[0]
	if size, sum := remote.Digest(want); a[3] != "yes" || a[4] != size || a[5] != sum || a[6] != Sum([]byte(reg)) {
		t.Errorf("argv %v", a)
	}
	for _, w := range []string{"deleted /apps/data/built-app\n", "deleted /apps/built-app (the on-VPS backups with it)", "released built-app.test"} {
		if !strings.Contains(so, w) {
			t.Errorf("lacks %q:\n%s", w, so)
		}
	}
	if !strings.Contains(se, "setup alias del postmaster@built-app.test postmaster@mail.example.com") ||
		!strings.Contains(se, "kasbah server add-mail-domain deploy@vps built-app.test") {
		t.Errorf("stderr:\n%s", se)
	}
}

func TestRunRefusals(t *testing.T) {
	project(t, "")
	for _, c := range []struct {
		mut  func(*Scan)
		code int
		want string
	}{
		{func(s *Scan) { s.LockState = "held" }, 1, "a deploy or rollback of built-app is running"},
		{func(s *Scan) { s.DockerError = "Cannot connect" }, 1, "docker did not answer"},
		{func(s *Scan) { s.AppsState = "absent" }, 4, "/apps on deploy@vps is not there"},
		{func(s *Scan) { s.Count = 9 }, 1, "counted 9 projects and described 3"},
	} {
		s := fixture()
		c.mut(s)
		f := &fake{scan: s}
		_, se, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
		if code != c.code || !strings.Contains(se, c.want) || len(f.acted) != 0 || lastServer(t) != "" {
			t.Errorf("%s: %d %s", c.want, code, se)
		}
	}
	os.WriteFile(filepath.Join(".kasbah", "x"), nil, 0o644)
	f := &fake{scan: fixture()}
	if _, se, code := run(t, f, Options{}, false, ""); code != 1 || !strings.Contains(se, "has never deployed to one") {
		t.Errorf("no target: %d %s", code, se)
	}
}

func TestMailReleaseLastDomain(t *testing.T) {
	want, err := os.ReadFile("testdata/registry-bash-primary-only.yml")
	if err != nil {
		t.Fatal(err)
	}
	reg := strings.Replace(string(want), "  - mail.example.com\n", "  - mail.example.com\n  - built-app.test\n", 1)
	p := plan(registryScan(reg), true)
	p.MailDomain = "built-app.test"
	if err := Decide(p, tplFS); err != nil {
		t.Fatal(err)
	}
	if p.MailRendered != string(want) {
		t.Fatalf("not byte-identical to the Bash render:\n%s", p.MailRendered)
	}
}

func TestRunTruncatedProbe(t *testing.T) {
	project(t, "")
	f := &fake{scan: fixture()}
	var so, se bytes.Buffer
	out := &cli.Output{Stdout: &so, Stderr: &se}
	s := &truncated{f}
	code := out.Report(Run(Ctx{Out: out, Prompter: &prompt.Prompter{Out: out}, Version: "0.1.0", Templates: tplFS,
		Dial: func(string) (Session, error) { return s, nil }}, Options{Target: "deploy@vps", Yes: true}))
	if code != 1 || !strings.Contains(se.String(), "the drop probe on deploy@vps reported no") || len(f.acted) != 0 || so.Len() != 0 {
		t.Fatalf("%d %s", code, se.String())
	}
}

// truncated cuts the scan's JSON short.
type truncated struct{ *fake }

func (t *truncated) Scan(a, d, n string) ([]byte, int) {
	b, _ := t.fake.Scan(a, d, n)
	return b[:len(b)/2], 0
}

func TestRunRefusedPruneNeverActs(t *testing.T) {
	project(t, "")
	s := fixture()
	s.Projects[2].ComposeState = "unreadable"
	f := &fake{scan: s, actOut: okAct}
	_, se, code := run(t, f, Options{Target: "deploy@vps", Prune: true, Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "--prune is refused: demo") || len(f.acted) != 0 || lastServer(t) != "" {
		t.Fatalf("%d %v %s", code, f.acted, se)
	}
}

func TestRunFailedImageRecordsLastServer(t *testing.T) {
	project(t, "")
	f := &fake{scan: fixture(), actOut: `started=yes
{"fragment":"removed","down":"ok","down_detail":"","down_left":"","removed":["built-app-web:3.4.0","built-app-web:current","built-app-worker:3.4.0"],"failed":[{"ref":"built-app-worker:current","reason":"in use"}]}
`}
	if _, _, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, ""); code != 1 || lastServer(t) != "deploy@vps" {
		t.Fatalf("%d %q", code, lastServer(t))
	}
}

func TestRunUnknownLockProceeds(t *testing.T) {
	project(t, "")
	s := fixture()
	s.LockState = "unknown"
	f := &fake{scan: s, actOut: okAct}
	if _, se, code := run(t, f, Options{Target: "deploy@vps", Yes: true}, false, ""); code != 0 || len(f.acted) != 1 {
		t.Fatalf("%d %s", code, se)
	}
}
