package migrate

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// A fake file is `v<major>\n<text>`; a step bumps the stamp and appends its name.
func fakeMajor(b []byte) (int, error) {
	if len(b) < 2 || b[0] != 'v' {
		return 0, errors.New("no stamp")
	}
	return int(b[1] - '0'), nil
}

func step(from, to int, files ...string) Step {
	return Step{From: from, To: to, Desc: "fake",
		Files: func(string) ([]string, error) { return files, nil },
		Major: fakeMajor,
		Rewrite: func(b []byte) ([]byte, error) {
			return append([]byte{'v', byte('0' + to)}, append(b[2:], []byte("+"+string(rune('0'+from))+string(rune('0'+to))+"\n")...)...), nil
		}}
}

func write(t *testing.T, apps, rel, body string) {
	t.Helper()
	p := filepath.Join(apps, rel)
	os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func read(t *testing.T, apps, rel string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(apps, rel))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func newApps(t *testing.T, version string) string {
	apps := t.TempDir()
	write(t, apps, ".kasbah/server.json", `{"kasbah_version":"`+version+`","apps_path":"`+apps+`","data_path":"`+apps+`/data","cpu_limit":"1","mem_limit":"1g","future":{"k":[1]}}`+"\n")
	return apps
}

var now = time.Date(2026, 10, 21, 12, 0, 0, 0, time.UTC)

func TestPlan(t *testing.T) {
	steps := []Step{step(2, 3), step(0, 1), step(1, 2)}
	p, err := Plan(steps, 0, 3)
	if err != nil || len(p) != 3 || p[0].From != 0 || p[1].From != 1 || p[2].From != 2 {
		t.Fatalf("got %d steps, %v", len(p), err)
	}
	if p, err := Plan(steps, 1, 2); err != nil || len(p) != 1 || p[0].To != 2 {
		t.Errorf("1->2: %d %v", len(p), err)
	}
	if p, err := Plan(steps, 2, 2); err != nil || len(p) != 0 {
		t.Errorf("same: %d %v", len(p), err)
	}
	if _, err := Plan(steps, 0, 4); err == nil || !strings.Contains(err.Error(), "no migration step from major 3") {
		t.Errorf("gap: %v", err)
	}
	if _, err := Plan(steps, 3, 1); err == nil || !strings.Contains(err.Error(), "downwards") {
		t.Errorf("down: %v", err)
	}
	if p, err := Plan(Server, 0, 1); err != nil || len(p) != 1 {
		t.Errorf("the registry's 0->1: %d %v", len(p), err)
	}
	if _, err := Plan(Server, 1, 2); err == nil {
		t.Error("no 1->2 step exists")
	}
}

func tarNames(t *testing.T, path string) map[string]string {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	out := map[string]string{}
	tr := tar.NewReader(f)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(tr)
		out[h.Name] = string(b)
	}
}

func TestRunRewritesSnapshotsAndMarkerLast(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/compose.yml", "v0\nalpha\n")
	write(t, apps, "beta/compose.yml", "v1\nbeta\n")
	write(t, apps, "traefik/traefik.yml", "v0\ntraefik\n")
	steps := []Step{step(0, 1, "alpha/compose.yml", "beta/compose.yml", "gone/x.yml"), step(1, 2, "traefik/traefik.yml", "alpha/compose.yml")}
	before := read(t, apps, ".kasbah/server.json")

	r, err := Run(apps, "2.1.0", steps, now)
	if err != nil {
		t.Fatal(err)
	}
	if r.From != 0 || r.To != 2 || r.Nothing || r.Marker != "updated" || len(r.Steps) != 2 {
		t.Fatalf("report %+v", r)
	}
	if got := read(t, apps, "alpha/compose.yml"); got != "v2\nalpha\n+01\n+12\n" {
		t.Errorf("alpha through both steps: %q", got)
	}
	if got := read(t, apps, "beta/compose.yml"); got != "v1\nbeta\n" {
		t.Errorf("beta, already at 1, untouched: %q", got)
	}
	if got := read(t, apps, "traefik/traefik.yml"); got != "v2\ntraefik\n+12\n" {
		t.Errorf("traefik: %q", got)
	}
	want := []FileResult{{"alpha/compose.yml", "rewritten"}, {"beta/compose.yml", "skipped"}, {"gone/x.yml", "absent"}}
	for i, f := range r.Steps[0].Files {
		if f != want[i] {
			t.Errorf("step 0 file %d: %+v", i, f)
		}
	}
	mk := read(t, apps, ".kasbah/server.json")
	if !strings.Contains(mk, `"kasbah_version": "2.1.0"`) || !strings.Contains(mk, `"future": {`) || !strings.Contains(mk, `"cpu_limit": "1"`) {
		t.Errorf("marker merged: %s", mk)
	}
	if r.Snapshot != filepath.Join(apps, Dir, "0-to-2-20261021T120000Z.tar") {
		t.Errorf("snapshot %s", r.Snapshot)
	}
	names := tarNames(t, r.Snapshot)
	if names["alpha/compose.yml"] != "v0\nalpha\n" || names["beta/compose.yml"] != "v1\nbeta\n" || names["traefik/traefik.yml"] != "v0\ntraefik\n" || names[".kasbah/server.json"] != before || len(names) != 4 {
		t.Errorf("snapshot holds %v", names)
	}
	if fi, _ := os.Stat(r.Snapshot); fi.Mode().Perm() != 0o644 {
		t.Errorf("snapshot mode %v", fi.Mode())
	}

	r, err = Run(apps, "2.1.0", steps, now.Add(time.Second))
	if err != nil || !r.Nothing || r.Marker != "unchanged" || r.Snapshot != "" {
		t.Errorf("rerun: %+v %v", r, err)
	}
	if ents, _ := os.ReadDir(filepath.Join(apps, Dir)); len(ents) != 1 {
		t.Errorf("a rerun that does nothing writes no snapshot: %d", len(ents))
	}
}

func TestRunFailingStepLeavesMarkerAndFinishesOnRerun(t *testing.T) {
	apps := newApps(t, "0.1.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	write(t, apps, "beta/b.yml", "v0\nb\n")
	boom := true
	s := step(0, 1, "alpha/a.yml", "beta/b.yml")
	inner := s.Rewrite
	s.Rewrite = func(b []byte) ([]byte, error) {
		if boom && bytes.Contains(b, []byte("b\n")) {
			return nil, errors.New("boom")
		}
		return inner(b)
	}
	_, err := Run(apps, "1.0.2-dev", []Step{s}, now)
	if err == nil || !strings.Contains(err.Error(), "boom") || !strings.Contains(err.Error(), "still says major 0") {
		t.Fatalf("got %v", err)
	}
	if got := read(t, apps, ".kasbah/server.json"); !strings.Contains(got, `"kasbah_version":"0.1.0"`) {
		t.Errorf("marker changed by a failed run: %s", got)
	}
	if read(t, apps, "alpha/a.yml") != "v1\na\n+01\n" || read(t, apps, "beta/b.yml") != "v0\nb\n" {
		t.Error("the file before the failure is rewritten, the failing one is not")
	}
	for _, e := range func() []os.DirEntry { es, _ := os.ReadDir(apps + "/beta"); return es }() {
		if e.Name() != "b.yml" && e.Name() != ".deploy.lock" {
			t.Errorf("left behind: %s", e.Name())
		}
	}
	first, _, err := Find(apps, 0, 1)
	if err != nil || first == "" {
		t.Fatalf("the failed run left its snapshot: %q %v", first, err)
	}
	boom = false
	r, err := Run(apps, "1.0.2-dev", []Step{s}, now.Add(time.Minute))
	if err != nil || r.Marker != "updated" {
		t.Fatalf("rerun: %+v %v", r, err)
	}
	if !r.SnapshotReused || r.Snapshot != first {
		t.Errorf("the rerun reuses the first run's snapshot: %+v", r)
	}
	if ents, _ := os.ReadDir(filepath.Join(apps, Dir)); len(ents) != 1 {
		t.Errorf("no second snapshot: %d", len(ents))
	}
	if r.Steps[0].Files[0].Action != "skipped" || r.Steps[0].Files[1].Action != "rewritten" {
		t.Errorf("rerun picks up where it stopped: %+v", r.Steps[0].Files)
	}
	if read(t, apps, "alpha/a.yml") != "v1\na\n+01\n" {
		t.Error("a file at To is not rewritten twice")
	}
	if got := read(t, apps, ".kasbah/server.json"); !strings.Contains(got, `"kasbah_version": "1.0.2-dev"`) {
		t.Errorf("marker: %s", got)
	}
	u, err := Undo(apps)
	if err != nil || u.Snapshot != first {
		t.Fatalf("undo: %+v %v", u, err)
	}
	if read(t, apps, "alpha/a.yml") != "v0\na\n" || read(t, apps, "beta/b.yml") != "v0\nb\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version":"0.1.0"`) {
		t.Error("undo restores every original, the one rewritten by the failed run included")
	}
}

func TestUndo(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	line, _ := vlog.Line(vlog.Stamp(now.Add(-time.Hour)), "deploy", "1.0.0", "-", "0.9.0", "-", "deploy")
	write(t, apps, "alpha/versions.log", line+"\n")
	write(t, apps, "beta/versions.log", "garbage\n")
	before := read(t, apps, ".kasbah/server.json")
	if _, err := Undo(apps); err == nil || !strings.Contains(err.Error(), "nothing to undo") {
		t.Errorf("no snapshot: %v", err)
	}
	r, err := Run(apps, "1.0.2-dev", []Step{step(0, 1, "alpha/a.yml")}, now)
	if err != nil {
		t.Fatal(err)
	}
	u, err := Undo(apps)
	if err != nil || !u.Undo || u.Marker != "restored" || u.Snapshot != r.Snapshot || len(u.Restored) != 1 || u.Restored[0] != "alpha/a.yml" {
		t.Fatalf("undo: %+v %v", u, err)
	}
	if read(t, apps, "alpha/a.yml") != "v0\na\n" || read(t, apps, ".kasbah/server.json") != before {
		t.Error("files and marker are back")
	}

	// Migrate again, then a deploy after the snapshot: undo is refused.
	r, err = Run(apps, "1.0.2-dev", []Step{step(0, 1, "alpha/a.yml")}, now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	later, _ := vlog.Line(vlog.Stamp(now.Add(2*time.Minute)), "deploy", "1.0.1", "-", "1.0.2-dev", "-", "deploy")
	write(t, apps, "alpha/versions.log", line+"\n"+later+"\n")
	_, err = Undo(apps)
	if err == nil || !strings.Contains(err.Error(), "alpha was deployed at "+vlog.Stamp(now.Add(2*time.Minute))) || !strings.Contains(err.Error(), r.Snapshot) {
		t.Errorf("refusal: %v", err)
	}
	if got := read(t, apps, ".kasbah/server.json"); !strings.Contains(got, "1.0.2-dev") {
		t.Error("a refused undo changes nothing")
	}
}

// Undo takes the snapshot whose move ended at the marker's major, not the
// newest file, and refuses when none did.
func TestUndoPicksByMajor(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	steps := []Step{step(0, 1, "a/x.yml"), step(1, 2, "a/x.yml")}
	if _, err := Run(apps, "1.0.0", steps, now); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(apps, "2.0.0", steps, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	// A stray, newer file from a move that is not where the marker is.
	write(t, apps, Dir+"/0-to-3-20261021T130000Z.tar", "not read")
	u, err := Undo(apps)
	if err != nil || !strings.HasSuffix(u.Snapshot, "1-to-2-20261021T120100Z.tar") || u.From != 1 {
		t.Fatalf("%+v %v", u, err)
	}
	if read(t, apps, "a/x.yml") != "v1\nx\n+01\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version": "1.0.0"`) {
		t.Error("back at major 1")
	}
	u, err = Undo(apps)
	if err != nil || !strings.HasSuffix(u.Snapshot, "0-to-1-20261021T120000Z.tar") {
		t.Fatalf("second undo: %+v %v", u, err)
	}
	if _, err := Undo(apps); err == nil || !strings.Contains(err.Error(), "ending at major 0") {
		t.Errorf("no snapshot ends at 0: %v", err)
	}
}

func hold(t *testing.T, path string) {
	t.Helper()
	os.MkdirAll(filepath.Dir(path), 0o755)
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0o666)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { f.Close() })
}

func TestLocks(t *testing.T) {
	apps := newApps(t, "0.9.0")
	os.MkdirAll(apps+"/alpha", 0o755)
	hold(t, filepath.Join(apps, "alpha", ".deploy.lock"))
	_, err := Run(apps, "1.0.0", Server, now)
	if err == nil || !strings.Contains(err.Error(), "running in alpha") {
		t.Errorf("held deploy lock: %v", err)
	}
	if _, err := Undo(apps); err == nil || !strings.Contains(err.Error(), "running in alpha") {
		t.Errorf("undo under a held deploy lock: %v", err)
	}
	hold(t, filepath.Join(apps, Lock))
	if _, err := Run(apps, "1.0.0", Server, now); err == nil || !strings.Contains(err.Error(), "a migration is running") {
		t.Errorf("held migrate lock: %v", err)
	}
	if got := read(t, apps, ".kasbah/server.json"); !strings.Contains(got, "0.9.0") {
		t.Error("nothing changed")
	}
}

func TestRegistryStep(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/compose.yml", "services: {}\n")
	r, err := Run(apps, "1.0.2-dev", Server, now)
	if err != nil || r.From != 0 || r.To != 1 || len(r.Steps) != 1 || len(r.Steps[0].Files) != 0 || r.Marker != "updated" {
		t.Fatalf("%+v %v", r, err)
	}
	if names := tarNames(t, r.Snapshot); len(names) != 1 || !strings.Contains(names[".kasbah/server.json"], "0.9.0") {
		t.Errorf("snapshot: %v", names)
	}
	if read(t, apps, "alpha/compose.yml") != "services: {}\n" {
		t.Error("0->1 rewrites nothing")
	}
	if _, err := Run(apps, "2.0.0", Server, now); err == nil || !strings.Contains(err.Error(), "no migration step from major 1") {
		t.Errorf("2.0 without a step: %v", err)
	}
	if _, err := Run(apps, "0.5.0", Server, now); err == nil || !strings.Contains(err.Error(), "downwards") {
		t.Errorf("down: %v", err)
	}
}

func TestRemote(t *testing.T) {
	apps := newApps(t, "0.9.0")
	var so, se bytes.Buffer
	if rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev"}, &so, &se); rc != 0 || !strings.Contains(so.String(), `"marker":"updated"`) {
		t.Fatalf("rc %d, %s %s", rc, so.String(), se.String())
	}
	so.Reset()
	if rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev", "--undo"}, &so, &se); rc != 0 || !strings.Contains(so.String(), `"marker":"restored"`) {
		t.Fatalf("undo rc %d, %s %s", rc, so.String(), se.String())
	}
	if rc := Remote([]string{"--apps=relative", "--version=1"}, &so, &se); rc != 1 || !strings.Contains(se.String(), "usage") {
		t.Errorf("usage: %d %s", rc, se.String())
	}
	for _, k := range Keys {
		if !strings.Contains(so.String(), `"`+k+`":`) {
			t.Errorf("report lacks %s: %s", k, so.String())
		}
	}
}

func TestRunProject(t *testing.T) {
	root := t.TempDir()
	write(t, root, "kasbah.yml", "schema: 0\r\nkasbah_version: 0.1.0\r\nname: demo\r\n")
	write(t, root, "compose.prod.yml", "v0\nservices: {}\n")
	bump := step(0, 1, "compose.prod.yml")
	bump.Files = func(string) ([]string, error) { return []string{"compose.prod.yml", "kasbah.yml"}, nil }
	bump.Major = func(b []byte) (int, error) {
		if bytes.HasPrefix(b, []byte("schema: ")) {
			return int(b[len("schema: ")] - '0'), nil
		}
		return fakeMajor(b)
	}
	inner := bump.Rewrite
	bump.Rewrite = func(b []byte) ([]byte, error) {
		if bytes.HasPrefix(b, []byte("schema: 0")) {
			return append([]byte("schema: 1"), b[len("schema: 0"):]...), nil
		}
		return inner(b)
	}
	var out bytes.Buffer
	if err := RunProject(&out, root, "1.0.2-dev", []Step{bump}); err != nil {
		t.Fatal(err)
	}
	if got := read(t, root, "kasbah.yml"); got != "schema: 1\r\nkasbah_version: 1.0.2-dev\r\nname: demo\r\n" {
		t.Errorf("manifest: %q", got)
	}
	if got := read(t, root, "compose.prod.yml"); got != "v1\nservices: {}\n+01\n" {
		t.Errorf("tree file: %q", got)
	}
	if got := read(t, root, ".kasbah/state.json"); !strings.Contains(got, "\"schema_migrations_applied\": [\n    \"0->1\"\n  ]") {
		t.Errorf("state: %s", got)
	}
	if !strings.Contains(out.String(), "migrated kasbah.yml from schema 0 to 1") {
		t.Errorf("said: %s", out.String())
	}
	// Insert branch: no kasbah_version line, CRLF kept, no stray LF line.
	write(t, root, "kasbah.yml", "schema: 0\r\nname: demo\r\n")
	os.WriteFile(filepath.Join(root, ".kasbah/state.json"), []byte(`{"schema_migrations_applied":["0->1"]}`), 0o644)
	write(t, root, "compose.prod.yml", "v0\nservices: {}\n")
	if err := RunProject(&out, root, "1.0.2-dev", []Step{bump}); err != nil {
		t.Fatal(err)
	}
	if got := read(t, root, "kasbah.yml"); got != "schema: 1\r\nkasbah_version: 1.0.2-dev\r\nname: demo\r\n" {
		t.Errorf("inserted line: %q", got)
	}
	if got := read(t, root, ".kasbah/state.json"); strings.Count(got, `"0->1"`) != 1 {
		t.Errorf("a step already recorded is not recorded twice: %s", got)
	}
	out.Reset()
	if err := RunProject(&out, root, "1.0.2-dev", []Step{bump}); err != nil || !strings.Contains(out.String(), "nothing to migrate") {
		t.Errorf("at schema 1: %v %s", err, out.String())
	}
	write(t, root, "kasbah.yml", "schema: 2\nkasbah_version: 2.0.0\nname: demo\n")
	if err := RunProject(&out, root, "1.0.2-dev", Project); err == nil || !strings.Contains(err.Error(), "newer than this kasbah") {
		t.Errorf("newer schema: %v", err)
	}
	if err := RunProject(&out, t.TempDir(), "1.0.2-dev", Project); err == nil {
		t.Error("no project")
	} else if e, ok := err.(*cli.Error); !ok || e.Code != cli.ExitNoProject {
		t.Errorf("no project: %v", err)
	}
}

type fakeSession struct {
	marker    string
	apps      string
	calls     []string
	out       string
	rc        int
	markerErr error
}

func (f *fakeSession) Marker() (*marker.Marker, string, error) {
	if f.markerErr != nil {
		return nil, "", f.markerErr
	}
	mk, err := marker.Validate([]byte(f.marker), marker.Path(f.apps), "d@h", "init")
	return mk, f.apps, err
}

func (f *fakeSession) Migrate(apps, ours string, undo bool) ([]byte, int) {
	f.calls = append(f.calls, apps+" "+ours+" "+map[bool]string{true: "undo", false: "run"}[undo])
	return []byte(f.out), f.rc
}

func (f *fakeSession) Close() {}

func TestParse(t *testing.T) {
	for _, c := range []struct {
		args []string
		want Options
		err  string
	}{
		{nil, Options{}, ""},
		{[]string{"server", "d@h", "--yes"}, Options{Server: true, Target: "d@h", Yes: true}, ""},
		{[]string{"server", "--undo", "d@h\r"}, Options{Server: true, Target: "d@h", Undo: true}, ""},
		{[]string{"server"}, Options{}, "no server given"},
		{[]string{"d@h"}, Options{}, "unexpected argument 'd@h'"},
		{[]string{"--yes"}, Options{}, "belong to"},
		{[]string{"server", "a", "b"}, Options{}, "two servers"},
		{[]string{"server", "d@h", "--yes=1"}, Options{}, "takes no value"},
		{[]string{"server", "d@h", "--force"}, Options{}, "unknown flag '--force'"},
	} {
		o, err := Parse(c.args)
		if c.err == "" && (err != nil || o != c.want) {
			t.Errorf("%q: %+v %v", c.args, o, err)
		}
		if c.err != "" && (err == nil || !strings.Contains(err.Error(), c.err)) {
			t.Errorf("%q: %v; want %s", c.args, err, c.err)
		}
	}
	if _, err := Parse([]string{"--help"}); err != ErrHelp {
		t.Error("help")
	}
}

func TestRunServer(t *testing.T) {
	const mk = `{"kasbah_version":"0.9.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1","mem_limit":"1g"}`
	ctx := func(f *fakeSession, tty bool, answer string) (Ctx, *bytes.Buffer, *bytes.Buffer) {
		var so, se bytes.Buffer
		out := &cli.Output{Stdout: &so, Stderr: &se}
		return Ctx{Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(answer), Out: out, TTY: tty}, Version: "1.0.2-dev",
			Dial: func(string) (Session, error) { return f, nil }, Now: func() time.Time { return now }}, &so, &se
	}
	t.Run("no tty, no --yes: nothing runs", func(t *testing.T) {
		f := &fakeSession{marker: mk, apps: "/apps"}
		c, so, _ := ctx(f, false, "")
		err := RunServer(c, Options{Server: true, Target: "d@h"})
		if err == nil || !strings.Contains(err.Error(), "--yes") || len(f.calls) != 0 {
			t.Fatalf("%v, calls %v", err, f.calls)
		}
		for _, want := range []string{"from major 0 (kasbah 0.9.0) to 1 (kasbah 1.0.2-dev)", "step 0->1: rewrites no file", "/apps/.kasbah/migrate/0-to-1-20261021T120000Z.tar", "/apps/.kasbah/migrate.lock"} {
			if !strings.Contains(so.String(), want) {
				t.Errorf("plan lacks %q: %s", want, so.String())
			}
		}
	})
	t.Run("declined", func(t *testing.T) {
		f := &fakeSession{marker: mk, apps: "/apps"}
		c, _, _ := ctx(f, true, "n\n")
		if err := RunServer(c, Options{Server: true, Target: "d@h"}); err == nil || !strings.Contains(err.Error(), "not confirmed") || len(f.calls) != 0 {
			t.Fatalf("%v %v", err, f.calls)
		}
	})
	t.Run("--yes runs and prints the report", func(t *testing.T) {
		f := &fakeSession{marker: mk, apps: "/apps", out: `{"undo":false,"from":0,"to":1,"nothing":false,"snapshot":"/apps/.kasbah/migrate/x.tar","snapshot_reused":false,"steps":[{"from":0,"to":1,"files":[]}],"marker":"updated","restored":[]}`}
		c, so, _ := ctx(f, false, "")
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true}); err != nil || len(f.calls) != 1 || f.calls[0] != "/apps 1.0.2-dev run" {
			t.Fatalf("%v %v", err, f.calls)
		}
		if !strings.Contains(so.String(), "migrated d@h from major 0 to 1; snapshot /apps/.kasbah/migrate/x.tar") || !strings.Contains(so.String(), "marker updated") {
			t.Errorf("%s", so.String())
		}
	})
	t.Run("already at our major", func(t *testing.T) {
		f := &fakeSession{marker: strings.Replace(mk, "0.9.0", "1.0.0", 1), apps: "/apps"}
		c, so, _ := ctx(f, false, "")
		if err := RunServer(c, Options{Server: true, Target: "d@h"}); err != nil || len(f.calls) != 0 || !strings.Contains(so.String(), "nothing to migrate") {
			t.Fatalf("%v %v %s", err, f.calls, so.String())
		}
	})
	t.Run("undo", func(t *testing.T) {
		f := &fakeSession{marker: strings.Replace(mk, "0.9.0", "1.0.0", 1), apps: "/apps", out: `{"undo":true,"from":0,"to":1,"nothing":false,"snapshot":"/apps/.kasbah/migrate/x.tar","snapshot_reused":false,"steps":[],"marker":"restored","restored":["a"]}`}
		c, so, _ := ctx(f, false, "")
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true}); err != nil || f.calls[0] != "/apps 1.0.2-dev undo" || !strings.Contains(so.String(), "back at major 0") {
			t.Fatalf("%v %v %s", err, f.calls, so.String())
		}
		f.rc, f.out = 1, ""
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true}); err == nil || !strings.Contains(err.Error(), "exited 1") {
			t.Errorf("%v", err)
		}
		f.rc, f.out = 0, `{"from":0}`
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true}); err == nil || !strings.Contains(err.Error(), "reported no") {
			t.Errorf("%v", err)
		}
	})
	t.Run("marker refusals pass through", func(t *testing.T) {
		f := &fakeSession{markerErr: cli.Failf(cli.ExitNoRemoteState, "no marker")}
		c, _, _ := ctx(f, false, "")
		err := RunServer(c, Options{Server: true, Target: "d@h"})
		var e *cli.Error
		if !errors.As(err, &e) || e.Code != cli.ExitNoRemoteState {
			t.Errorf("%v", err)
		}
	})
}
