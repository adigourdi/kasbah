package prune

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/vlog"
)

func b64(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func gz(s string) string {
	var b bytes.Buffer
	w := gzip.NewWriter(&b)
	w.Write([]byte(s))
	w.Close()
	return base64.StdEncoding.EncodeToString(b.Bytes())
}

func TestParse(t *testing.T) {
	o, err := Parse([]string{"deploy@vps"})
	if err != nil || o.Target != "deploy@vps" || o.Yes {
		t.Fatalf("got %+v %v", o, err)
	}
	if o, _ = Parse([]string{"deploy@vps", "--yes"}); !o.Yes {
		t.Fatal("--yes is the scriptable answer")
	}
	for _, args := range [][]string{{"deploy@vps", "--apps-path=/srv"}, {"deploy@vps", "--force"}} {
		if _, err := Parse(args); err == nil || !strings.Contains(err.Error(), "unknown flag") {
			t.Errorf("%v: %v", args, err)
		}
	}
	if _, err := Parse(nil); err == nil || !strings.Contains(err.Error(), "USER@HOST is required") {
		t.Errorf("no target: %v", err)
	}
}

func TestRepos(t *testing.T) {
	cases := []struct {
		compose string
		want    string
		ok      bool
	}{
		{"services:\n  web:\n    build: .\n    image: alpha-web:current\n  api:\n    build:\n      context: ./api\n    image: alpha-api:current\n  cache:\n    image: redis:7-alpine\n", "alpha-web alpha-api", true},
		{"services:\n  web:\n    build: .\n    image: reg.example:5000/team/web:current\n", "reg.example:5000/team/web", true},
		{"services: [not: a mapping", "", false},
		{"services:\n  web:\n    image: nginx:alpine\n", "", true},
		{"x: 1\n", "", true},
		{"services: 5\n", "", false},
	}
	for _, c := range cases {
		got, ok := Repos(c.compose)
		if ok != c.ok || strings.Join(got, " ") != c.want {
			t.Errorf("%q: got %v %v, want %q %v", c.compose, got, ok, c.want, c.ok)
		}
	}
}

func record(t *testing.T, archive, active string) *vlog.Record {
	t.Helper()
	p := vlog.Probe{ActiveState: "missing", ArchiveState: "missing"}
	if active != "" {
		p.ActiveState, p.ActiveB64 = "ok", b64(active)
	}
	if archive != "" {
		p.ArchiveState, p.ArchiveB64 = "ok", gz(archive)
	}
	raw, _ := json.Marshal(p)
	r, err := vlog.ReadProbe(raw, "t@h", "/apps/x/versions.log")
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func TestKeep(t *testing.T) {
	log5 := ""
	for i := 1; i <= 5; i++ {
		log5 += fmt.Sprintf("2026-0%d-01T10:00:00+00:00 deploy 1.%d.0 no-backup kasbah=0.1.0 digest=-\n", i, i)
	}
	cases := []struct {
		name, archive, active, want string
	}{
		{"three newest", "", log5, "1.5.0 1.4.0 1.3.0"},
		{"rollback target first", "", log5 + "2026-05-02T10:00:00+00:00 rollback 1.2.0 no-backup kasbah=0.1.0 digest=-\n", "1.2.0 1.5.0 1.4.0"},
		{"redeploy spends no slot", "", log5 + "2026-05-03T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-\n", "1.5.0 1.4.0 1.3.0"},
		{"one deploy", "", "2026-05-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-\n", "1.5.0"},
		{"empty", "", "", "refused"},
		{"damaged in span", "", log5 + "this line was written by a truncated append\n", "refused"},
		{"damaged beyond span", "", "a truncated line, older than everything\n" + log5, "1.5.0 1.4.0 1.3.0"},
		{"archive counts", "2025-01-01T10:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n", "2026-05-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-\n", "1.5.0 0.9.0"},
	}
	for _, c := range cases {
		k, ok := Keep(record(t, c.archive, c.active))
		got := strings.Join(k, " ")
		if !ok {
			got = "refused"
		}
		if got != c.want {
			t.Errorf("%s: got %q, want %q", c.name, got, c.want)
		}
	}
}

// The retention window is rotation's window: April is out from August, May is in.
func TestWindowIsRotations(t *testing.T) {
	aug, _ := vlog.MonthIndex("2026-08-01")
	may, _ := vlog.MonthIndex("2026-05-31")
	apr, _ := vlog.MonthIndex("2026-04-01")
	if aug-3 != may || apr >= aug-3 {
		t.Fatalf("aug=%d may=%d apr=%d", aug, may, apr)
	}
}

type imgs struct{ s []Image }

func (i *imgs) add(id, created string, tags ...string) {
	i.s = append(i.s, Image{ID: id, Created: created, Tags: tags})
}

func proj(name, cstate, compose, astate, active, gstate, archiveB64 string) Project {
	p := Project{Name: name, ComposeState: cstate}
	if compose != "" {
		p.ComposeB64 = b64(compose)
	}
	p.ActiveState, p.ArchiveState, p.ArchiveB64 = astate, gstate, archiveB64
	if active != "" {
		p.ActiveB64 = b64(active)
	}
	return p
}

func otherCompose(n string) string {
	return fmt.Sprintf("services:\n  web:\n    build: .\n    image: %s-web:current\n", n)
}

// fixture is one server, every edge of the policy as a pair: two tags of the
// same age in one repository, differing only in the fact under test.
func fixture(month string) *Scan {
	var i imgs
	i.add("sha256:a15", "2026-08-01T00:00:00Z", "alpha-web:current", "alpha-web:1.5.0")
	i.add("sha256:a14", "2026-07-01T00:00:00Z", "alpha-web:1.4.0")
	i.add("sha256:a13", "2026-01-01T00:00:00Z", "alpha-web:1.3.0")
	i.add("sha256:a12", "2026-01-01T00:00:00Z", "alpha-web:1.2.0")
	i.add("sha256:a11", "2025-12-01T00:00:00Z", "alpha-web:1.1.0")
	i.add("sha256:a10", "2025-12-01T00:00:00Z", "alpha-web:1.0.0")
	i.add("sha256:a09", "2026-05-31T00:00:00Z", "alpha-web:0.9.0")
	i.add("sha256:a08", "2026-04-01T00:00:00Z", "alpha-web:0.8.0")
	i.add("sha256:b05", "2025-10-01T00:00:00Z", "alpha-api:current", "alpha-api:0.5.0")
	i.add("sha256:b04", "2025-10-01T00:00:00Z", "alpha-api:0.4.0", "spare/base:latest")
	i.add("sha256:r00", "2024-01-01T00:00:00Z", "redis:7-alpine")
	i.add("sha256:n00", "2024-01-01T00:00:00Z", "nginx:alpine")
	i.add("sha256:c01", "2024-01-01T00:00:00Z", "common-web:0.1.0")
	i.add("sha256:g22", "2026-08-02T00:00:00Z", "gamma-web:current", "gamma-web:2.2.0")
	i.add("sha256:g20", "2025-09-02T00:00:00Z", "gamma-web:2.0.0")
	i.add("sha256:g10", "2025-09-01T00:00:00Z", "gamma-web:1.0.0")
	for _, p := range []string{"beta", "delta", "epsilon", "zeta", "eta"} {
		i.add("sha256:"+p+"0", "2025-09-01T00:00:00Z", p+"-web:current", p+"-web:2.0.0")
		i.add("sha256:"+p+"1", "2025-09-01T00:00:00Z", p+"-web:1.0.0")
	}
	alpha := "services:\n  web:\n    build: .\n    image: alpha-web:current\n  api:\n    build: ./api\n    image: alpha-api:current\n  shared:\n    build: ./shared\n    image: common-web:current\n  cache:\n    image: redis:7-alpine\n"
	gamma := "services:\n  web:\n    build: .\n    image: gamma-web:current\n  shared:\n    build: ./shared\n    image: common-web:current\n"
	alphaLog := "2026-01-01T10:00:00+00:00 deploy 1.2.0 no-backup kasbah=0.1.0 digest=-\n2026-01-02T10:00:00+00:00 deploy 1.3.0 no-backup kasbah=0.1.0 digest=-\n2026-07-01T10:00:00+00:00 deploy 1.4.0 no-backup kasbah=0.1.0 digest=-\n2026-08-01T10:00:00+00:00 deploy 1.5.0 no-backup kasbah=0.1.0 digest=-\n"
	other := "2026-08-01T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n"
	s := &Scan{NowMonth: month, Images: i.s,
		Containers: []Container{{"sha256:a10", "running", "alpha-web"}, {"sha256:a15", "exited", "alpha-web-old"}},
		Projects: []Project{
			proj("alpha", "ok", alpha, "ok", alphaLog, "missing", ""),
			proj("beta", "ok", otherCompose("beta"), "unreadable", "", "missing", ""),
			proj("gamma", "ok", gamma, "ok", "2026-08-01T10:00:00+00:00 deploy 2.1.0 no-backup kasbah=0.1.0 digest=-\n2026-08-02T10:00:00+00:00 deploy 2.2.0 no-backup kasbah=0.1.0 digest=-\n", "ok", gz("2025-09-02T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n")),
			proj("delta", "ok", otherCompose("delta"), "ok", other, "ok", b64("this is not gzip")),
			proj("zeta", "ok", otherCompose("zeta"), "notfile", "", "ok", gz(other)),
			proj("eta", "ok", otherCompose("eta"), "ok", other+"2026-08-02T10:00:00+00:00 deploy", "missing", ""),
			proj("store", "missing", "", "missing", "", "missing", ""),
		}}
	s.Count = len(s.Projects)
	return s
}

func report(pl *Plan) string {
	var b bytes.Buffer
	pl.Report(&b, "deploy@vps", "/apps")
	return b.String()
}

func TestDecide(t *testing.T) {
	pl, err := Decide(fixture("2026-08"), "deploy@vps", "/apps", "store")
	if err != nil {
		t.Fatal(err)
	}
	out := report(pl)
	got := append([]string{}, pl.Remove...)
	sort.Strings(got)
	if want := "alpha-api:0.4.0 alpha-web:0.8.0 alpha-web:1.1.0 alpha-web:1.2.0 gamma-web:1.0.0"; strings.Join(got, " ") != want {
		t.Fatalf("removal set\n want %s\n got  %s\n%s", want, strings.Join(got, " "), out)
	}
	for _, re := range []string{
		`remove +alpha-web:0\.8\.0`, `keep +alpha-web:0\.9\.0 .*inside the 3-month window`,
		`keep +alpha-web:1\.3\.0 .*among the last 3 deployed`, `remove +alpha-web:1\.2\.0 .*older than 3 months`,
		`keep +alpha-api:0\.5\.0 .*:current points at this image`, `remove +alpha-api:0\.4\.0 .*untags only.*spare/base:latest`,
		`keep +common-web:0\.1\.0 .*claimed by more than one project \(alpha gamma\)`,
		`keep +alpha-web:1\.0\.0 .*held by container alpha-web\(running\)`, `remove +alpha-web:1\.1\.0`,
		`keep +gamma-web:2\.0\.0 .*among the last 3 deployed`, `remove +gamma-web:1\.0\.0`,
		`(?m)^  beta: .*versions.log cannot be read.*unreadable`, `(?m)^  delta: .*not gzip`,
		`(?m)^  zeta: .*versions.log cannot be read.*notfile`, `(?m)^  eta: .*does not yield`,
		`kasbah server prune — deploy@vps \(/apps\)`, `5 tag\(s\) to remove on deploy@vps\.`,
	} {
		if !regexp.MustCompile(re).MatchString(out) {
			t.Errorf("no match for %s in\n%s", re, out)
		}
	}
	for _, re := range []string{`(remove|keep) +[a-z-]+:current`, `(remove|keep) +(redis|nginx|epsilon-web|store)`,
		`(remove|keep) +(beta|delta|zeta|eta)-web:`, `(?m)^  store: `} {
		if regexp.MustCompile(re).MatchString(out) {
			t.Errorf("unexpected match for %s in\n%s", re, out)
		}
	}
	if len(pl.Skips) != 4 {
		t.Errorf("skips: %+v", pl.Skips)
	}
	// Sorted by project then tag, columns padded to the widest tag.
	if !strings.Contains(out, "\nalpha\n  remove alpha-api:0.4.0   built") || !strings.Contains(out, "\n  keep   alpha-api:0.5.0   :current points") {
		t.Errorf("layout:\n%s", out)
	}

	// The data path is dropped only when it is the data path.
	pl, _ = Decide(fixture("2026-08"), "deploy@vps", "/apps", "")
	if len(pl.Skips) != 5 || len(pl.Unknown) != 1 || pl.Unknown[0] != "store" || len(pl.Remove) != 0 {
		t.Errorf("an unreadable store row is unknown ownership: %+v %+v", pl.Skips, pl.Unknown)
	}

	pl, _ = Decide(fixture("2025-10"), "deploy@vps", "/apps", "store")
	if len(pl.Remove) != 0 || !strings.Contains(report(pl), "nothing to remove") {
		t.Errorf("all inside the window: %v", pl.Remove)
	}
	if _, err := Decide(fixture("2026"), "t", "/apps", ""); err == nil {
		t.Error("a now_month that is not YYYY-MM is refused")
	}
}

func TestUnknownOwnership(t *testing.T) {
	var i imgs
	i.add("sha256:t30", "2026-08-02T00:00:00Z", "shared-web:current", "shared-web:3.0.0")
	i.add("sha256:t10", "2025-09-01T00:00:00Z", "shared-web:1.0.0")
	i.add("sha256:t20", "2026-08-02T00:00:00Z", "theta-web:current", "theta-web:2.0.0")
	i.add("sha256:t11", "2025-09-01T00:00:00Z", "theta-web:1.0.0")
	theta := "services:\n  web:\n    build: .\n    image: theta-web:current\n  shared:\n    build: ./shared\n    image: shared-web:current\n"
	log := "2026-08-02T10:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n"
	all := []Project{
		proj("theta", "ok", theta, "ok", log, "missing", ""),
		proj("omega", "ok", "services: [not: a mapping", "ok", log, "missing", ""),
		proj("kappa", "unreadable", "", "ok", log, "missing", ""),
	}
	s := &Scan{NowMonth: "2026-08", Images: i.s, Projects: all, Count: 3}
	pl, _ := Decide(s, "deploy@vps", "/apps", "data")
	out := report(pl)
	if len(pl.Remove) != 0 {
		t.Fatalf("nothing is removed while ownership is unknown: %v", pl.Remove)
	}
	for _, re := range []string{`(?m)^  omega: .*compose.yml does not parse`, `(?m)^  kappa: .*compose.yml cannot be read`,
		`keep +shared-web:1\.0\.0 .*ownership cannot be established.*omega kappa`, `keep +theta-web:1\.0\.0 .*ownership cannot be established`,
		`no repository on deploy@vps is provably single-owner`} {
		if !regexp.MustCompile(re).MatchString(out) {
			t.Errorf("no match for %s in\n%s", re, out)
		}
	}
	s.Projects, s.Count = all[:1], 1
	pl, _ = Decide(s, "deploy@vps", "/apps", "data")
	if strings.Join(pl.Remove, " ") != "shared-web:1.0.0 theta-web:1.0.0" || len(pl.Skips) != 0 {
		t.Fatalf("without them both go: %v %v", pl.Remove, pl.Skips)
	}
}

type fake struct {
	scan    []byte
	scanRC  int
	removed [][]string
	failTag string
	steps   int
}

func (f *fake) Ensure() (string, string, error) { return "/apps", "store", nil }
func (f *fake) Scan(string) ([]byte, int)       { f.steps++; return f.scan, f.scanRC }
func (f *fake) Remove(apps string, tags []string) ([]byte, int) {
	f.steps++
	f.removed = append(f.removed, tags)
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	for _, t := range tags {
		if t == f.failTag {
			enc.Encode(Removal{Failed: t, Reason: "Error response from daemon: conflict: unable to delete"})
		} else {
			enc.Encode(Removal{Removed: t})
		}
	}
	return b.Bytes(), 0
}
func (f *fake) Close() {}

func runFake(t *testing.T, f *fake, o Options, tty bool, answer string) (string, string, int) {
	t.Helper()
	var so, se bytes.Buffer
	out := &cli.Output{Stdout: &so, Stderr: &se}
	p := &prompt.Prompter{Out: out, In: strings.NewReader(answer), TTY: tty}
	code := out.Report(Run(Ctx{Out: out, Prompter: p, Dial: func(string) (Session, error) { return f, nil }}, o))
	return so.String(), se.String(), code
}

func TestRun(t *testing.T) {
	raw, _ := json.Marshal(fixture("2026-08"))
	f := &fake{scan: raw}
	so, se, code := runFake(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 0 || len(f.removed) != 1 || len(f.removed[0]) != 5 || f.steps != 2 {
		t.Fatalf("code=%d removed=%v steps=%d\n%s%s", code, f.removed, f.steps, so, se)
	}
	if !strings.Contains(se, "4 project(s) were skipped whole") || !strings.Contains(se, "removed 5 of 5 tag(s) on deploy@vps") {
		t.Errorf("stderr: %s", se)
	}

	f = &fake{scan: raw}
	so, se, code = runFake(t, f, Options{Target: "deploy@vps"}, false, "")
	if code != 1 || len(f.removed) != 0 || !strings.Contains(se, "--yes") || !strings.Contains(so, "remove alpha-web:1.2.0") {
		t.Errorf("no tty, no --yes: code=%d removed=%v\n%s%s", code, f.removed, so, se)
	}

	f = &fake{scan: raw}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps"}, true, "n\n")
	if code != 1 || len(f.removed) != 0 || !strings.Contains(se, "not confirmed — nothing was removed") {
		t.Errorf("declined: code=%d\n%s", code, se)
	}
	f = &fake{scan: raw}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps"}, true, "y\n")
	if code != 0 || len(f.removed) != 1 || strings.Contains(se, "not confirmed") {
		t.Errorf("confirmed: code=%d\n%s", code, se)
	}

	f = &fake{scan: raw, failTag: "alpha-web:1.2.0"}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "could not remove alpha-web:1.2.0") || !strings.Contains(se, "unable to delete") || !strings.Contains(se, "removed 4 of 5") {
		t.Errorf("a refused removal: code=%d\n%s", code, se)
	}

	early, _ := json.Marshal(fixture("2025-10"))
	f = &fake{scan: early}
	so, _, code = runFake(t, f, Options{Target: "deploy@vps"}, false, "")
	if code != 0 || f.steps != 1 || !strings.Contains(so, "nothing to remove") {
		t.Errorf("nothing to remove needs no answer: code=%d steps=%d", code, f.steps)
	}

	f = &fake{scan: []byte(`{"now_month":"2026-08"}`)}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "reported no") || len(f.removed) != 0 {
		t.Errorf("a truncated scan: code=%d\n%s", code, se)
	}
	var cut Scan
	json.Unmarshal(raw, &cut)
	cut.Count++
	short, _ := json.Marshal(cut)
	f = &fake{scan: short}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "counted 8 projects and described 7") {
		t.Errorf("a short table: code=%d\n%s", code, se)
	}
	docker, _ := json.Marshal(Scan{NowMonth: "2026-08", DockerError: "Cannot connect to the Docker daemon", Images: []Image{}, Containers: []Container{}, Projects: []Project{}})
	f = &fake{scan: docker}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 1 || !strings.Contains(se, "docker did not answer") {
		t.Errorf("docker down: code=%d\n%s", code, se)
	}
}

func TestDataDir(t *testing.T) {
	for _, c := range []struct{ marker, want string }{
		{`{"data_path":"/apps/store"}`, "store"},
		{`{"data_path":"/apps/data"}`, "data"},
		{`{"data_path":"/srv/data"}`, ""},
		{`{"data_path":"/apps/a/b"}`, ""},
		{`{}`, ""},
	} {
		if got, err := dataDir([]byte(c.marker), "/apps", "m", "t"); err != nil || got != c.want {
			t.Errorf("%s: %q %v", c.marker, got, err)
		}
	}
	if _, err := dataDir([]byte("[1]"), "/apps", "m", "t"); err == nil {
		t.Error("a marker that is not an object is refused")
	}
}

func TestScan(t *testing.T) {
	apps := t.TempDir()
	for _, d := range []string{".kasbah", "demo", "traefik", "mail", "locked", "data", "backups"} {
		os.MkdirAll(filepath.Join(apps, d), 0o755)
	}
	os.WriteFile(filepath.Join(apps, "demo/compose.yml"), []byte("services: {}\n"), 0o644)
	os.WriteFile(filepath.Join(apps, "demo/versions.log"), []byte("2026-08-01T10:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n"), 0o644)
	os.WriteFile(filepath.Join(apps, "notaproject"), nil, 0o644)
	os.WriteFile(filepath.Join(apps, "locked/compose.yml"), nil, 0o000)

	var calls []string
	orig := runDocker
	defer func() { runDocker = orig }()
	runDocker = func(args ...string) (string, error) {
		calls = append(calls, args[0]+" "+args[1])
		switch args[0] + " " + args[1] {
		case "version --format":
			return "27.3.1\n", nil
		case "images -q":
			return "sha256:aaa\nsha256:bbb\nsha256:aaa\n", nil
		case "image inspect":
			return "sha256:aaa 2026-08-01T00:00:00Z demo-web:current demo-web:1.0.0\nsha256:bbb 2025-01-01T00:00:00Z\n", nil
		case "ps -a":
			return "c1\n", nil
		case "inspect --format":
			return "sha256:aaa running /demo-web\n", nil
		}
		return "", fmt.Errorf("unexpected")
	}
	s := scan(apps, time.Date(2026, 8, 3, 0, 0, 0, 0, time.UTC))
	if s.NowMonth != "2026-08" || s.DockerError != "" || s.Count != 3 {
		t.Fatalf("%+v", s)
	}
	if len(s.Images) != 2 || strings.Join(s.Images[0].Tags, " ") != "demo-web:current demo-web:1.0.0" || len(s.Images[1].Tags) != 0 {
		t.Errorf("images: %+v", s.Images)
	}
	if len(s.Containers) != 1 || s.Containers[0] != (Container{"sha256:aaa", "running", "demo-web"}) {
		t.Errorf("containers: %+v", s.Containers)
	}
	states := map[string]string{}
	for _, p := range s.Projects {
		states[p.Name] = p.ComposeState + " " + p.ActiveState + " " + p.ArchiveState
	}
	want := map[string]string{"demo": "ok ok missing", "notaproject": "notdir notdir notdir"}
	if os.Geteuid() != 0 {
		want["locked"] = "unreadable missing missing"
	}
	for k, v := range want {
		if states[k] != v {
			t.Errorf("%s: %q, want %q", k, states[k], v)
		}
	}
	for _, c := range calls {
		if !regexp.MustCompile(`^(version --format|images -q|image inspect|ps -a|inspect --format)$`).MatchString(c) {
			t.Errorf("a docker verb that is not a read: %s", c)
		}
	}
}
