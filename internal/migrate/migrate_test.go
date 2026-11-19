package migrate

import (
	"archive/tar"
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// A fake file is `v<major>\n<text>`; a step bumps the stamp and appends its name.
func fakeMajor(_ string, b []byte) (int, error) {
	if len(b) < 2 || b[0] != 'v' {
		return 0, errors.New("no stamp")
	}
	return int(b[1] - '0'), nil
}

func step(from, to int, files ...string) Step {
	return Step{From: from, To: to, Desc: "fake",
		Files: func(string) ([]string, error) { return files, nil },
		Major: fakeMajor,
		Rewrite: func(_ string, b []byte) ([]byte, error) {
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
	if p, err := Plan(Server, 0, 2); err != nil || len(p) != 2 || p[1].From != 1 || p[1].Warn == nil || p[1].Act == nil {
		t.Errorf("the registry's 0->1->2: %d %v", len(p), err)
	}
	if _, err := Plan(Server, 2, 3); err == nil {
		t.Error("no 2->3 step exists")
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

	r0 := r
	r, err = Run(apps, "2.1.0", steps, now.Add(time.Second))
	if err != nil || !r.Nothing || r.Marker != "unchanged" || r.Snapshot != "" {
		t.Errorf("rerun: %+v %v", r, err)
	}
	if ents, _ := os.ReadDir(filepath.Join(apps, Dir)); len(ents) != 2 || ents[1].Name() != filepath.Base(r0.Snapshot)+Begun {
		t.Errorf("a rerun that does nothing writes no snapshot: %v", ents)
	}
}

func TestRunFailingStepLeavesMarkerAndFinishesOnRerun(t *testing.T) {
	apps := newApps(t, "0.1.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	write(t, apps, "beta/b.yml", "v0\nb\n")
	boom := true
	s := step(0, 1, "alpha/a.yml", "beta/b.yml")
	inner := s.Rewrite
	s.Rewrite = func(rel string, b []byte) ([]byte, error) {
		if boom && bytes.Contains(b, []byte("b\n")) {
			return nil, errors.New("boom")
		}
		return inner(rel, b)
	}
	// A file the step cannot rewrite refuses the run before its snapshot.
	_, err := Run(apps, "1.0.2-dev", []Step{s}, now)
	rf, next := refusal(err)
	if rf != (Refusal{Way: "fix", Major: 0}) || !strings.Contains(err.Error(), apps+"/beta/b.yml") || !strings.Contains(err.Error(), "boom") || !strings.Contains(err.Error(), "took no snapshot") {
		t.Fatalf("got %v %+v", err, rf)
	}
	if got := next; got != "Fix the file the cause above names, then re-run `kasbah migrate server d@h`." {
		t.Errorf("next: %s", got)
	}
	if got := read(t, apps, ".kasbah/server.json"); !strings.Contains(got, `"kasbah_version":"0.1.0"`) {
		t.Errorf("marker changed by a refused run: %s", got)
	}
	if read(t, apps, "alpha/a.yml") != "v0\na\n" || read(t, apps, "beta/b.yml") != "v0\nb\n" {
		t.Error("a refused run rewrites no file")
	}
	if _, err := os.Stat(filepath.Join(apps, Dir)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a refused run leaves no snapshot: %v", err)
	}
	// A run that dies once writing began: alpha is written, beta's write fails.
	boom = false
	tmp := filepath.Join(apps, "beta", "b.yml.tmp."+strconv.Itoa(os.Getpid()))
	os.Mkdir(tmp, 0o755)
	_, err = Run(apps, "1.0.2-dev", []Step{s}, now)
	if !errors.As(err, new(partway)) || !strings.Contains(err.Error(), "still says major 0") {
		t.Fatalf("got %v", err)
	}
	if read(t, apps, "alpha/a.yml") != "v1\na\n+01\n" || read(t, apps, "beta/b.yml") != "v0\nb\n" {
		t.Error("the run stopped after alpha")
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
	// A refused rerun names the stopped run's snapshot, not a clean tree.
	boom = true
	if _, err := Run(apps, "1.0.2-dev", []Step{s}, now.Add(30*time.Second)); err == nil || !strings.Contains(err.Error(), "an earlier one stopped partway and "+first+" holds the originals") {
		t.Errorf("refused rerun: %v", err)
	}
	boom = false
	r, err := Run(apps, "1.0.2-dev", []Step{s}, now.Add(time.Minute))
	if err != nil || r.Marker != "updated" {
		t.Fatalf("rerun: %+v %v", r, err)
	}
	if !r.SnapshotReused || r.Snapshot != first {
		t.Errorf("the rerun reuses the first run's snapshot: %+v", r)
	}
	if ents, _ := os.ReadDir(filepath.Join(apps, Dir)); len(ents) != 2 {
		t.Errorf("no second snapshot: %v", ents)
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
	u, err := Undo(apps, nil)
	if err != nil || u.Snapshot != first {
		t.Fatalf("undo: %+v %v", u, err)
	}
	if read(t, apps, "alpha/a.yml") != "v0\na\n" || read(t, apps, "beta/b.yml") != "v0\nb\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version":"0.1.0"`) {
		t.Error("undo restores every original, the one rewritten by the failed run included")
	}
}

// A snapshot whose run never began its steps is not reused: the rerun takes
// a fresh one of the files as they are now.
func TestRunSkipsSnapshotNeverBegun(t *testing.T) {
	apps := newApps(t, "0.1.0")
	write(t, apps, "a/x.yml", "v0\nrefused\n")
	stale, err := snapshot(apps, SnapshotName(0, 1, now), []string{"a/x.yml"})
	if err != nil {
		t.Fatal(err)
	}
	write(t, apps, "a/x.yml", "v0\nfixed\n")
	r, err := Run(apps, "1.0.0", []Step{step(0, 1, "a/x.yml")}, now.Add(time.Minute))
	if err != nil || r.SnapshotReused || r.Snapshot == stale || r.Snapshot != filepath.Join(apps, Dir, SnapshotName(0, 1, now.Add(time.Minute))) {
		t.Fatalf("%+v %v", r, err)
	}
	if got := tarNames(t, r.Snapshot)["a/x.yml"]; got != "v0\nfixed\n" {
		t.Errorf("fresh snapshot holds %q", got)
	}
	if _, err := Undo(apps, nil); err != nil || read(t, apps, "a/x.yml") != "v0\nfixed\n" {
		t.Errorf("undo puts back the fixed file: %v %q", err, read(t, apps, "a/x.yml"))
	}
}

func TestUndo(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	line, _ := vlog.Line(vlog.Stamp(now.Add(-time.Hour)), "deploy", "1.0.0", "-", "0.9.0", "-", "deploy")
	write(t, apps, "alpha/versions.log", line+"\n")
	write(t, apps, "beta/versions.log", "garbage\n")
	before := read(t, apps, ".kasbah/server.json")
	if _, err := Undo(apps, nil); err == nil || !strings.Contains(err.Error(), "nothing to undo") || errors.As(err, new(partway)) {
		t.Errorf("no snapshot: %v", err)
	}
	r, err := Run(apps, "1.0.2-dev", []Step{step(0, 1, "alpha/a.yml")}, now)
	if err != nil {
		t.Fatal(err)
	}
	if os.Geteuid() != 0 {
		os.Chmod(apps+"/alpha", 0o555)
		_, err := Undo(apps, nil)
		os.Chmod(apps+"/alpha", 0o755)
		if !errors.As(err, new(partway)) {
			t.Errorf("a restore that fails partway: %v", err)
		}
	}
	u, err := Undo(apps, nil)
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
	_, err = Undo(apps, nil)
	if rf, _ := refusal(err); err == nil || !strings.Contains(err.Error(), "alpha was deployed at "+vlog.Stamp(now.Add(2*time.Minute))) || !strings.Contains(err.Error(), r.Snapshot) || errors.As(err, new(partway)) ||
		rf != (Refusal{"stay", 1, r.Snapshot}) {
		t.Errorf("refusal: %v %+v", err, rf)
	}
	// Through the arm: the cause on stderr, no step, the refusal on stdout.
	var so, se bytes.Buffer
	if rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev", "--undo"}, &so, &se); rc != ExitRefused ||
		so.String() != `{"refused":"stay","major":1,"snapshot":"`+r.Snapshot+`"}`+"\n" ||
		!strings.Contains(se.String(), "alpha was deployed at") || strings.Contains(se.String(), "Leave") || strings.Count(se.String(), "\n") != 1 {
		t.Errorf("the arm's refusal: rc %d, %s %s", rc, so.String(), se.String())
	}
	if got := read(t, apps, ".kasbah/server.json"); !strings.Contains(got, "1.0.2-dev") {
		t.Error("a refused undo changes nothing")
	}
}

// Undo takes the snapshot whose move ended at the marker's major, not the
// newest file from another move, and refuses when none did.
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
	// A stray, newer file from a move that starts at major 0, where the
	// marker is not yet.
	write(t, apps, Dir+"/0-to-3-20261021T130000Z.tar", "not read")
	u, err := Undo(apps, nil)
	if err != nil || !strings.HasSuffix(u.Snapshot, "1-to-2-20261021T120100Z.tar") || u.From != 1 {
		t.Fatalf("%+v %v", u, err)
	}
	if read(t, apps, "a/x.yml") != "v1\nx\n+01\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version": "1.0.0"`) {
		t.Error("back at major 1")
	}
	u, err = Undo(apps, nil)
	if err != nil || !strings.HasSuffix(u.Snapshot, "0-to-1-20261021T120000Z.tar") {
		t.Fatalf("second undo: %+v %v", u, err)
	}
	// At major 0 the stray is the newest snapshot starting there, with no
	// note: read, and refused, naming the file to move aside.
	_, err = Undo(apps, nil)
	if rf, _ := refusal(err); err == nil || !strings.Contains(err.Error(), "0-to-3-20261021T130000Z.tar is not a tarball kasbah wrote") ||
		rf != (Refusal{"aside", 0, filepath.Join(apps, Dir, "0-to-3-20261021T130000Z.tar")}) || next(err) != nil {
		t.Errorf("the stray at major 0: %v %+v %q", err, rf, next(err))
	}
	os.Remove(filepath.Join(apps, Dir, "0-to-3-20261021T130000Z.tar"))
	if _, err := Undo(apps, nil); err == nil || !strings.Contains(err.Error(), "ending at major 0") {
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
	if rf, _ := refusal(err); err == nil || !strings.Contains(err.Error(), "running in alpha") || rf.Way != "busy" || next(err) != nil {
		t.Errorf("held deploy lock: %v %+v", err, rf)
	}
	if _, err := Undo(apps, nil); err == nil || !strings.Contains(err.Error(), "running in alpha") {
		t.Errorf("undo under a held deploy lock: %v", err)
	}
	hold(t, serverlock.Path(apps))
	_, err = Undo(apps, nil)
	if rf, _ := refusal(err); rf.Way != "busy" {
		t.Errorf("undo under a held server lock: %+v", rf)
	}
	if _, err := Run(apps, "1.0.0", Server, now); err == nil || !strings.Contains(err.Error(), "is running on this server — it holds "+serverlock.Path(apps)) ||
		strings.Contains(err.Error(), "re-run") {
		t.Errorf("held server lock: %v", err)
	}
	hold(t, filepath.Join(apps, Lock))
	if _, err := Run(apps, "1.0.0", Server, now); err == nil || !strings.Contains(err.Error(), "a migration is running") {
		t.Errorf("held migrate lock: %v", err)
	}
	// Through the arm: the cause alone, the refusal on stdout.
	var so, se bytes.Buffer
	if rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev", "--undo"}, &so, &se); rc != ExitRefused ||
		so.String() != `{"refused":"busy","major":0,"snapshot":""}`+"\n" || !strings.Contains(se.String(), "a migration is running") || strings.Contains(se.String(), "re-run") {
		t.Errorf("the arm under a held lock: rc %d, %s %s", rc, so.String(), se.String())
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
	if _, err := Run(apps, "3.0.0", Server, now); err == nil || !strings.Contains(err.Error(), "no migration step from major 2") {
		t.Errorf("3.0 without a step: %v", err)
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
	if os.Geteuid() != 0 {
		// The marker cannot be written: the run stopped partway, and its fresh
		// snapshot (the undone one moved a second back) is closed by --undo.
		ents, _ := os.ReadDir(filepath.Join(apps, Dir))
		for _, e := range ents {
			os.Rename(filepath.Join(apps, Dir, e.Name()), filepath.Join(apps, Dir, strings.Replace(e.Name(), "-2", "-1", 1)))
		}
		os.Chmod(apps+"/.kasbah", 0o555)
		var o2, e2 bytes.Buffer
		rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev"}, &o2, &e2)
		os.Chmod(apps+"/.kasbah", 0o755)
		if rc != ExitPartway {
			t.Errorf("partway: rc %d, %s", rc, e2.String())
		}
		e2.Reset()
		if rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev", "--undo"}, &o2, &e2); rc != 0 || !strings.Contains(o2.String(), `"marker":"unchanged","restored":[],"gone":[]`) {
			t.Errorf("closed: rc %d, %s %s", rc, o2.String(), e2.String())
		}
		e2.Reset()
		if rc := Remote([]string{"--apps=" + apps, "--version=1.0.2-dev", "--undo"}, &o2, &e2); rc != 1 || !strings.Contains(e2.String(), "nothing to undo") {
			t.Errorf("nothing to undo: rc %d, %s", rc, e2.String())
		}
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
	bump.Major = func(rel string, b []byte) (int, error) {
		if bytes.HasPrefix(b, []byte("schema: ")) {
			return int(b[len("schema: ")] - '0'), nil
		}
		return fakeMajor(rel, b)
	}
	inner := bump.Rewrite
	bump.Rewrite = func(rel string, b []byte) ([]byte, error) {
		if bytes.HasPrefix(b, []byte("schema: 0")) {
			return append([]byte("schema: 1"), b[len("schema: 0"):]...), nil
		}
		return inner(rel, b)
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
	probe     string
	probeRC   int
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

func (f *fakeSession) Probe(apps, ours string) ([]byte, int) {
	f.calls = append(f.calls, apps+" "+ours+" probe")
	return []byte(f.probe), f.probeRC
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
		f := &fakeSession{marker: mk, apps: "/apps", out: `{"undo":false,"from":0,"to":1,"nothing":false,"snapshot":"/apps/.kasbah/migrate/x.tar","snapshot_reused":false,"steps":[{"from":0,"to":1,"files":[]}],"marker":"updated","restored":[],"gone":[]}`}
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
		f := &fakeSession{marker: strings.Replace(mk, "0.9.0", "1.0.0", 1), apps: "/apps", out: `{"undo":true,"from":0,"to":1,"nothing":false,"snapshot":"/apps/.kasbah/migrate/x.tar","snapshot_reused":false,"steps":[],"marker":"restored","restored":["a"],"gone":[]}`}
		c, so, _ := ctx(f, false, "")
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true}); err != nil || f.calls[0] != "/apps 1.0.2-dev undo" || !strings.Contains(so.String(), "back at major 0") {
			t.Fatalf("%v %v %s", err, f.calls, so.String())
		}
		f.rc, f.out = 1, ""
		err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true})
		if err == nil || !strings.Contains(err.Error(), "exited 1") || next(err) != nil {
			t.Errorf("a failure before anything changed: %v %q", err, next(err))
		}
		// A refusal's step is spelled here, with the target the server lacks.
		for _, w := range []struct{ out, step string }{
			{`{"refused":"finish","major":2,"snapshot":"/apps/.kasbah/migrate/1-to-2-x.tar"}`,
				"Finish the run instead: re-run `kasbah migrate server d@h` with a kasbah of major 2 — it picks up where it stopped. Or restore by hand from /apps/.kasbah/migrate/1-to-2-x.tar."},
			{`{"refused":"stay","major":1,"snapshot":"/apps/.kasbah/migrate/0-to-1-x.tar"}`,
				"Leave d@h on major 1, or restore by hand from /apps/.kasbah/migrate/0-to-1-x.tar."},
			{`{"refused":"aside","major":1,"snapshot":"/apps/.kasbah/migrate/1-to-3-x.tar"}`,
				"Move /apps/.kasbah/migrate/1-to-3-x.tar aside, out of /apps/.kasbah/migrate, and re-run `kasbah migrate server d@h --undo`: it then looks past it."},
			{`{"refused":"busy","major":0,"snapshot":""}`, "Re-run `kasbah migrate server d@h --undo` once it has finished."},
			{`{"refused":"later","major":0,"snapshot":""}`,
				"This kasbah does not know the server's next step \"later\" — the server runs another build of kasbah than this workstation; the cause above is its own."},
		} {
			f.rc, f.out = ExitRefused, w.out
			err = RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true})
			if err == nil || !strings.Contains(err.Error(), "exited 5") || !slices.Equal(next(err), []string{w.step}) {
				t.Errorf("%v %q", err, next(err))
			}
		}
		f.out = `{"refused":"stay"}`
		err = RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true})
		if err == nil || !strings.HasPrefix(err.Error(), "the migration step on d@h exited 5 (see above): the migration step on d@h reported no major snapshot") ||
			!strings.Contains(err.Error(), "nothing was changed on d@h") || !slices.Equal(next(err), []string{"Re-run `kasbah migrate server d@h --undo` to see the refusal again."}) {
			t.Errorf("a truncated refusal: %v %q", err, next(err))
		}
		f.rc, f.out = ExitPartway, ""
		err = RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true})
		if !slices.Equal(next(err), []string{"Once the cause above is fixed, re-run `kasbah migrate server d@h --undo`: it picks the same snapshot again, which is noted undone only once every file is back."}) {
			t.Errorf("%v %q", err, next(err))
		}
		g := &fakeSession{marker: mk, apps: "/apps", rc: 1}
		c, _, _ = ctx(g, false, "")
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true}); next(err) != nil {
			t.Errorf("a failure before anything changed: %v %q", err, next(err))
		}
		// A run's refusals name the run.
		for _, w := range []struct{ out, step string }{
			{`{"refused":"busy","major":0,"snapshot":""}`, "Re-run `kasbah migrate server d@h` once it has finished."},
			{`{"refused":"second","major":0,"snapshot":"/apps/.kasbah/migrate/0-to-1-x.tar"}`, "Re-run `kasbah migrate server d@h` in a second."},
		} {
			g.rc, g.out = ExitRefused, w.out
			err = RunServer(c, Options{Server: true, Target: "d@h", Yes: true})
			if err == nil || !strings.Contains(err.Error(), "exited 5") || !slices.Equal(next(err), []string{w.step}) {
				t.Errorf("%v %q", err, next(err))
			}
		}
		g.out = "garbled"
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true}); !slices.Equal(next(err), []string{"Re-run `kasbah migrate server d@h` to see the refusal again."}) {
			t.Errorf("an unreadable refusal: %v %q", err, next(err))
		}
		g.out = ""
		g.rc = ExitPartway
		err = RunServer(c, Options{Server: true, Target: "d@h", Yes: true})
		if !slices.Equal(next(err), []string{"Once the cause above is fixed, re-run `kasbah migrate server d@h`: it picks up where it stopped, skipping every file already rewritten.",
			"Or go back: `kasbah migrate server d@h --undo` puts back from its snapshot any file it rewrote."}) {
			t.Errorf("%v %q", err, next(err))
		}
		p := &fakeSession{marker: mk, apps: "/apps", out: `{"undo":true,"from":0,"to":1,"nothing":false,"snapshot":"/apps/.kasbah/migrate/0-to-1-x.tar","snapshot_reused":false,"steps":[],"marker":"unchanged","restored":["a/x.yml"],"gone":["b/y.yml"]}`}
		c, so, _ = ctx(p, false, "")
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true}); err != nil {
			t.Fatal(err)
		}
		if want := "undone on d@h: the run from major 0 to 1 that stopped partway — 1 file(s) put back from /apps/.kasbah/migrate/0-to-1-x.tar; the marker is unchanged, still at major 0\n  restored a/x.yml\n  not restored b/y.yml: its directory is gone\n"; !strings.HasSuffix(so.String(), want) || strings.Contains(so.String(), "back at major") {
			t.Errorf("a partial undo's summary: %s", so.String())
		}
		p.out = `{"undo":true,"from":0,"to":1,"nothing":false,"snapshot":"/apps/.kasbah/migrate/0-to-1-x.tar","snapshot_reused":false,"steps":[],"marker":"unchanged","restored":[],"gone":[]}`
		if err := RunServer(c, Options{Server: true, Target: "d@h", Yes: true, Undo: true}); err != nil {
			t.Fatal(err)
		}
		if want := "undone on d@h: the run from major 0 to 1 had stopped; every file still there already matches what /apps/.kasbah/migrate/0-to-1-x.tar holds — closed, the marker unchanged at major 0\n"; !strings.HasSuffix(so.String(), want) {
			t.Errorf("a close's summary: %s", so.String())
		}
		c, _, _ = ctx(f, false, "")
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

// refusal is a run's or an undo's refusal and the step it names on d@h.
func refusal(err error) (Refusal, string) {
	var rf refused
	if !errors.As(err, &rf) {
		return Refusal{}, ""
	}
	return rf.Refusal, rf.Step("d@h", false)
}

// next is a failure's next step.
func next(err error) []string {
	var e *cli.Error
	if !errors.As(err, &e) {
		return nil
	}
	return e.NextLines()
}

// A snapshot that fails to read back names what it restored before it failed.
func TestUndoNamesWhatItRestored(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	r, err := Run(apps, "1.0.2-dev", []Step{step(0, 1, "alpha/a.yml")}, now)
	if err != nil {
		t.Fatal(err)
	}
	snap := r.Snapshot
	if !filepath.IsAbs(snap) {
		snap = filepath.Join(apps, Dir, snap)
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	tw.WriteHeader(&tar.Header{Name: "alpha/a.yml", Mode: 0o644, Size: 5, Typeflag: tar.TypeReg})
	tw.Write([]byte("v0\na\n"))
	tw.Close()
	if err := os.WriteFile(snap, buf.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
	_, err = Undo(apps, nil)
	if err == nil || !strings.Contains(err.Error(), "carries no marker, which an undo restores last — already restored: alpha/a.yml; the marker was not") {
		t.Errorf("a snapshot with no marker: %v", err)
	}
}

// A run in the second of a snapshot an undo has finished with is refused,
// nothing changed: the fresh one would take its name.
func TestSnapshotOfThisSecond(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	r, err := Run(apps, "1.0.0", []Step{step(0, 1, "a/x.yml")}, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Undo(apps, nil); err != nil {
		t.Fatal(err)
	}
	_, err = Run(apps, "1.0.0", []Step{step(0, 1, "a/x.yml")}, now)
	if rf, _ := refusal(err); rf != (Refusal{"second", 0, r.Snapshot}) || !strings.Contains(err.Error(), r.Snapshot+" already exists") || strings.Contains(err.Error(), "re-run") {
		t.Errorf("%v %+v", err, rf)
	}
	if read(t, apps, "a/x.yml") != "v0\nx\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), "0.9.0") {
		t.Error("a refused run changes nothing")
	}
}

// A finished undo writes its note before the marker: one whose marker write
// fails is picked again by a re-run, which then moves the marker.
func TestUndoNoteBeforeMarker(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only directory")
	}
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	before := read(t, apps, ".kasbah/server.json")
	r, err := Run(apps, "1.0.0", []Step{step(0, 1, "a/x.yml")}, now)
	if err != nil {
		t.Fatal(err)
	}
	os.Chmod(apps+"/.kasbah", 0o555)
	_, err = Undo(apps, nil)
	os.Chmod(apps+"/.kasbah", 0o755)
	if !errors.As(err, new(partway)) || read(t, apps, "a/x.yml") != "v0\nx\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version": "1.0.0"`) {
		t.Fatalf("the marker write fails: %v", err)
	}
	if _, err := os.Stat(r.Snapshot + Undone); err != nil {
		t.Errorf("the note is written before the marker: %v", err)
	}
	u, err := Undo(apps, nil)
	if err != nil || u.Snapshot != r.Snapshot || u.Marker != "restored" || read(t, apps, ".kasbah/server.json") != before {
		t.Errorf("the re-run: %+v %v", u, err)
	}
}

// A run that stopped partway is undone from its snapshot: the files it
// rewrote go back, the marker, already at the old major, stays, and the
// snapshot is noted undone.
func TestUndoPartial(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only directory")
	}
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	write(t, apps, "beta/b.yml", "v0\nb\n")
	write(t, apps, "beta/.deploy.lock", "")
	before := read(t, apps, ".kasbah/server.json")
	steps := []Step{step(0, 1, "alpha/a.yml", "beta/b.yml")}
	os.Chmod(apps+"/beta", 0o555)
	_, err := Run(apps, "1.0.0", steps, now)
	os.Chmod(apps+"/beta", 0o755)
	if !errors.As(err, new(partway)) || read(t, apps, "alpha/a.yml") != "v1\na\n+01\n" {
		t.Fatalf("partway: %v", err)
	}
	snap, _, _ := Find(apps, 0, 1)

	// A deploy since the snapshot refuses the partial undo too, naming the
	// way forward.
	later, _ := vlog.Line(vlog.Stamp(now.Add(time.Minute)), "deploy", "1.0.1", "-", "0.9.0", "-", "deploy")
	write(t, apps, "alpha/versions.log", later+"\n")
	_, err = Undo(apps, nil)
	if rf, _ := refusal(err); err == nil || !strings.Contains(err.Error(), "alpha was deployed at") || !strings.Contains(err.Error(), snap) || errors.As(err, new(partway)) ||
		rf != (Refusal{"finish", 1, snap}) || next(err) != nil {
		t.Errorf("refusal: %v %+v %q", err, rf, next(err))
	}
	if read(t, apps, "alpha/a.yml") != "v1\na\n+01\n" {
		t.Error("a refused undo changes nothing")
	}
	os.Remove(apps + "/alpha/versions.log")

	u, err := Undo(apps, nil)
	if err != nil || !u.Undo || u.Snapshot != snap || u.From != 0 || u.To != 1 || u.Marker != "unchanged" || !slices.Equal(u.Restored, []string{"alpha/a.yml"}) {
		t.Fatalf("undo: %+v %v", u, err)
	}
	if read(t, apps, "alpha/a.yml") != "v0\na\n" || read(t, apps, "beta/b.yml") != "v0\nb\n" || read(t, apps, ".kasbah/server.json") != before {
		t.Error("the rewritten file is back, the marker untouched")
	}
	if fi, err := os.Stat(snap + Undone); err != nil || fi.Size() != 0 || fi.Mode().Perm() != 0o644 {
		t.Errorf("the note: %v %v", fi, err)
	}
	// A file changed since is not taken for a stopped run's.
	write(t, apps, "beta/b.yml", "v0\nchanged\n")
	if _, err := Undo(apps, nil); err == nil || !strings.Contains(err.Error(), "nothing to undo") || !strings.Contains(err.Error(), snap+", the newest starting there, was already undone") {
		t.Errorf("second undo: %v", err)
	}
	if read(t, apps, "beta/b.yml") != "v0\nchanged\n" {
		t.Error("the second undo changed nothing")
	}
	// A run after the undo takes a fresh snapshot of the tree as it now is.
	r, err := Run(apps, "1.0.0", steps, now.Add(time.Hour))
	if err != nil || r.SnapshotReused || r.Snapshot == snap || tarNames(t, r.Snapshot)["beta/b.yml"] != "v0\nchanged\n" {
		t.Errorf("rerun after the undo: %+v %v", r, err)
	}
}

// A finished undo is not taken for a stopped run: a file of the undone move
// changed since stays, and an undo that died partway resumes on its snapshot.
func TestUndoAfterFinishedUndo(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only directory")
	}
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	write(t, apps, "b/y.yml", "v1\ny\n")
	write(t, apps, "c/z.yml", "v0\nz\n")
	steps := []Step{step(0, 1, "a/x.yml", "c/z.yml"), step(1, 2, "a/x.yml", "b/y.yml")}
	if _, err := Run(apps, "1.0.0", steps, now); err != nil {
		t.Fatal(err)
	}
	if _, err := Run(apps, "2.0.0", steps, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	if u, err := Undo(apps, nil); err != nil || !strings.HasSuffix(u.Snapshot, "1-to-2-20261021T120100Z.tar") || u.Marker != "restored" {
		t.Fatalf("undo 1->2: %+v %v", u, err)
	}
	// Something else (an upgrade-traefik) changes a file only 1->2 held.
	write(t, apps, "b/y.yml", "v1\nupgraded\n")

	// The undo of 0->1 dies after its first file, then resumes.
	os.Chmod(apps+"/c", 0o555)
	_, err := Undo(apps, nil)
	os.Chmod(apps+"/c", 0o755)
	if !errors.As(err, new(partway)) || read(t, apps, "a/x.yml") != "v0\nx\n" {
		t.Fatalf("partway undo: %v", err)
	}
	u, err := Undo(apps, nil)
	if err != nil || !strings.HasSuffix(u.Snapshot, "0-to-1-20261021T120000Z.tar") || u.Marker != "restored" || u.From != 0 {
		t.Fatalf("resumed undo: %+v %v", u, err)
	}
	if read(t, apps, "a/x.yml") != "v0\nx\n" || read(t, apps, "c/z.yml") != "v0\nz\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version":"0.9.0"`) {
		t.Error("back at major 0")
	}
	if read(t, apps, "b/y.yml") != "v1\nupgraded\n" {
		t.Error("the change since 1->2 was undone is kept")
	}
}

// A run that fails before its first rewrite is closed by --undo, which
// leaves the migration before it alone.
func TestUndoRunFailedBeforeRewrite(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only directory")
	}
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	steps := []Step{step(0, 1, "a/x.yml"), step(1, 2, "a/x.yml")}
	if _, err := Run(apps, "1.0.0", steps, now); err != nil {
		t.Fatal(err)
	}
	at1 := read(t, apps, ".kasbah/server.json")
	os.Chmod(apps+"/a", 0o555)
	_, err := Run(apps, "2.0.0", steps, now.Add(time.Minute))
	os.Chmod(apps+"/a", 0o755)
	if !errors.As(err, new(partway)) || read(t, apps, "a/x.yml") != "v1\nx\n+01\n" {
		t.Fatalf("failed run: %v", err)
	}
	u, err := Undo(apps, nil)
	if err != nil || !strings.HasSuffix(u.Snapshot, "1-to-2-20261021T120100Z.tar") || u.Marker != "unchanged" || len(u.Restored) != 0 || u.From != 1 || u.To != 2 {
		t.Fatalf("close: %+v %v", u, err)
	}
	if read(t, apps, "a/x.yml") != "v1\nx\n+01\n" || read(t, apps, ".kasbah/server.json") != at1 {
		t.Error("the finished 0->1 is untouched")
	}
	if u, err := Undo(apps, nil); err != nil || !strings.HasSuffix(u.Snapshot, "0-to-1-20261021T120000Z.tar") || u.Marker != "restored" {
		t.Errorf("then 0->1: %+v %v", u, err)
	}
}

// A snapshot with no note that an undo already put back (a kasbah that wrote
// none) is closed with nothing to put back.
func TestUndoOldSnapshot(t *testing.T) {
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	r, err := Run(apps, "1.0.0", []Step{step(0, 1, "a/x.yml")}, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := Undo(apps, nil); err != nil {
		t.Fatal(err)
	}
	os.Remove(r.Snapshot + Undone)
	u, err := Undo(apps, nil)
	if err != nil || u.Snapshot != r.Snapshot || u.Marker != "unchanged" || len(u.Restored) != 0 {
		t.Fatalf("closed: %+v %v", u, err)
	}
	if _, err := os.Stat(r.Snapshot + Undone); err != nil {
		t.Errorf("noted: %v", err)
	}
	if _, err := Undo(apps, nil); err == nil || !strings.Contains(err.Error(), "nothing to undo") {
		t.Errorf("then: %v", err)
	}
}

// A file whose directory is gone (a dropped project) is reported, not
// restored, on either path.
func TestUndoDroppedProject(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only directory")
	}
	apps := newApps(t, "0.9.0")
	write(t, apps, "alpha/a.yml", "v0\na\n")
	write(t, apps, "beta/b.yml", "v0\nb\n")
	write(t, apps, "beta/.deploy.lock", "")
	steps := []Step{step(0, 1, "alpha/a.yml", "beta/b.yml")}
	os.Chmod(apps+"/beta", 0o555)
	_, err := Run(apps, "1.0.0", steps, now)
	os.Chmod(apps+"/beta", 0o755)
	if !errors.As(err, new(partway)) {
		t.Fatalf("partway: %v", err)
	}
	os.RemoveAll(apps + "/alpha")
	u, err := Undo(apps, nil)
	if err != nil || len(u.Restored) != 0 || !slices.Equal(u.Gone, []string{"alpha/a.yml"}) {
		t.Fatalf("partial: %+v %v", u, err)
	}

	write(t, apps, "alpha/a.yml", "v0\na\n")
	if _, err := Run(apps, "1.0.0", steps, now.Add(time.Minute)); err != nil {
		t.Fatal(err)
	}
	os.RemoveAll(apps + "/alpha")
	u, err = Undo(apps, nil)
	if err != nil || u.Marker != "restored" || !slices.Equal(u.Restored, []string{"beta/b.yml"}) || !slices.Equal(u.Gone, []string{"alpha/a.yml"}) {
		t.Fatalf("finished: %+v %v", u, err)
	}
	if _, err := os.Stat(apps + "/alpha"); !errors.Is(err, os.ErrNotExist) {
		t.Error("the dropped project is not recreated")
	}
}

// A finished 0->1 then a partial 1->2: the partial one is undone first, then
// the finished one.
func TestUndoPartialBeforeFinished(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root writes through a read-only directory")
	}
	apps := newApps(t, "0.9.0")
	write(t, apps, "a/x.yml", "v0\nx\n")
	write(t, apps, "b/y.yml", "v1\ny\n")
	steps := []Step{step(0, 1, "a/x.yml"), step(1, 2, "a/x.yml", "b/y.yml")}
	if _, err := Run(apps, "1.0.0", steps, now); err != nil {
		t.Fatal(err)
	}
	at1 := read(t, apps, ".kasbah/server.json")
	os.Chmod(apps+"/b", 0o555)
	_, err := Run(apps, "2.0.0", steps, now.Add(time.Minute))
	os.Chmod(apps+"/b", 0o755)
	if !errors.As(err, new(partway)) || read(t, apps, "a/x.yml") != "v2\nx\n+01\n+12\n" {
		t.Fatalf("partway: %v", err)
	}
	u, err := Undo(apps, nil)
	if err != nil || !strings.HasSuffix(u.Snapshot, "1-to-2-20261021T120100Z.tar") || u.Marker != "unchanged" || u.From != 1 || u.To != 2 {
		t.Fatalf("first undo: %+v %v", u, err)
	}
	if read(t, apps, "a/x.yml") != "v1\nx\n+01\n" || read(t, apps, ".kasbah/server.json") != at1 {
		t.Error("back at the finished 0->1")
	}
	u, err = Undo(apps, nil)
	if err != nil || !strings.HasSuffix(u.Snapshot, "0-to-1-20261021T120000Z.tar") || u.Marker != "restored" || u.From != 0 || u.To != 1 {
		t.Fatalf("second undo: %+v %v", u, err)
	}
	if read(t, apps, "a/x.yml") != "v0\nx\n" || !strings.Contains(read(t, apps, ".kasbah/server.json"), `"kasbah_version":"0.9.0"`) {
		t.Error("back at major 0")
	}
	if _, err := Undo(apps, nil); err == nil || !strings.Contains(err.Error(), "nothing to undo") {
		t.Errorf("third undo: %v", err)
	}
}
