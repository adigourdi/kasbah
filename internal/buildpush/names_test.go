package buildpush

import (
	"bytes"
	"encoding/json"
	"maps"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"syscall"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

func hexOf(id string) string { return strings.TrimPrefix(id, "sha256:") }

// csave is a containerd-store save of one image: each layer blob named by
// the digest of its stored bytes, the config pairing them with diffIDs.
func csave(t *testing.T, layers [][]byte, diffIDs []string) []byte {
	t.Helper()
	cfg, _ := json.Marshal(map[string]any{"rootfs": map[string]any{"type": "layers", "diff_ids": diffIDs}})
	ents := []entry{{name: "blobs/sha256/" + hexOf(digest(cfg)), body: cfg}}
	var paths []string
	for _, l := range layers {
		p := "blobs/sha256/" + hexOf(digest(l))
		paths = append(paths, p)
		ents = append(ents, entry{name: p, body: l})
	}
	man, _ := json.Marshal([]map[string]any{{"Config": "blobs/sha256/" + hexOf(digest(cfg)), "RepoTags": []string{"a:1"}, "Layers": paths}})
	ents = append(ents, entry{name: "index.json", body: []byte("{}")}, entry{name: "manifest.json", body: man})
	return mktar(t, ents, 1024)
}

func TestMapFormat(t *testing.T) {
	a, b, c := digest([]byte("a")), digest([]byte("b")), digest([]byte("c"))
	n := parseMap([]byte(b + " " + a + "\r\n" + c + " " + a + "\n"))
	if !reflect.DeepEqual(n, names{b: a, c: a}) {
		t.Fatalf("parseMap = %v", n)
	}
	// A save that named a layer by its diffID: an identity pair.
	if n := parseMap([]byte(a + " " + a + "\n")); !reflect.DeepEqual(n, names{a: a}) {
		t.Fatalf("parseMap = %v", n)
	}
	if got := string(n.encode()); got != b+" "+a+"\n"+c+" "+a+"\n" && got != c+" "+a+"\n"+b+" "+a+"\n" {
		t.Errorf("encode = %q", got)
	}
	if got := n.byDiff()[a]; !slices.IsSorted(got) || len(got) != 2 {
		t.Errorf("byDiff = %v", got)
	}
	for _, bad := range []string{b + " " + a + "\nnot a line\n", b + " sha256:x\n", b + " " + a + " " + c + "\n"} {
		if n := parseMap([]byte(bad)); len(n) != 0 {
			t.Errorf("parseMap(%q) = %v, want empty", bad, n)
		}
	}
}

func TestLearn(t *testing.T) {
	gzLayer := []byte("\x1f\x8b compressed layer one")
	zstdLayer := []byte("\x28\xb5\x2f\xfd compressed layer two")
	plain := []byte("an uncompressed layer named by its diffID")
	d1, d2 := digest([]byte("tar one")), digest([]byte("tar two"))
	in := csave(t, [][]byte{gzLayer, zstdLayer, plain}, []string{d1, d2, digest(plain)})
	r := bytes.NewReader(in)
	n, err := learn(r)
	if err != nil || !reflect.DeepEqual(n, names{digest(gzLayer): d1, digest(zstdLayer): d2, digest(plain): digest(plain)}) {
		t.Errorf("learn = %v, %v", n, err)
	}
	if r.Len() != 0 {
		t.Errorf("%d bytes left unread", r.Len())
	}
	if _, err := learn(bytes.NewReader(mktar(t, []entry{{name: "blobs/sha256/" + hexOf(d1), body: gzLayer}}, 0))); err == nil {
		t.Error("an export with no manifest.json taught something")
	}
	if _, err := learn(bytes.NewReader(in[:700])); err == nil {
		t.Error("a cut export was read as whole")
	}
}

func kasbahDir(t *testing.T) string {
	apps := t.TempDir()
	if err := os.MkdirAll(filepath.Join(apps, ".kasbah"), 0o775); err != nil {
		t.Fatal(err)
	}
	return apps
}

func mapMode(t *testing.T, apps string) os.FileMode {
	fi, err := os.Stat(mapPath(apps))
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

func TestLoadRecordsNames(t *testing.T) {
	layer := []byte("\x1f\x8b layer")
	d := digest([]byte("its tar"))
	in := gz(t, csave(t, [][]byte{layer}, []string{d}))
	apps := kasbahDir(t)
	// An unreadable map is started over, never fatal.
	os.WriteFile(mapPath(apps), []byte("garbage\n"), 0o600)
	fakeDocker(t)
	var out, errb bytes.Buffer
	if rc := Load([]string{apps, "a:1"}, bytes.NewReader(in), &out, &errb); rc != 0 || out.String() != "loaded=1\n" {
		t.Fatalf("rc %d stdout %q stderr %q", rc, out.String(), errb.String())
	}
	got, _ := os.ReadFile(mapPath(apps))
	if string(got) != digest(layer)+" "+d+"\n" || mapMode(t, apps) != MapMode {
		t.Errorf("map %q mode %o", got, mapMode(t, apps))
	}
	if left, _ := filepath.Glob(filepath.Join(apps, ".kasbah", ".layers.map.*")); len(left) != 0 {
		t.Errorf("temp files left: %v", left)
	}

	// A failed load records nothing.
	other := []byte("\x1f\x8b another")
	t.Setenv("FAKE_LOAD_RC", "1")
	Load([]string{apps, "a:1"}, bytes.NewReader(gz(t, csave(t, [][]byte{other}, []string{d}))), &out, &errb)
	if again, _ := os.ReadFile(mapPath(apps)); !bytes.Equal(again, got) {
		t.Errorf("a failed load changed the map to %q", again)
	}
}

func TestLayersNamesAndPrune(t *testing.T) {
	a, b, x := digest([]byte("a")), digest([]byte("b")), digest([]byte("x"))
	pa, pa2, pb, px := digest([]byte("pa")), digest([]byte("pa2")), digest([]byte("pb")), digest([]byte("px"))
	ab := chainIDs([]string{a, b})
	fakeStore(t, map[string][]string{"i1": {a, b}})
	apps := kasbahDir(t)
	os.WriteFile(mapPath(apps), names{pa: a, pa2: a, pb: b, px: x}.encode(), 0o664)
	var out, errb bytes.Buffer
	if rc := Layers([]string{apps, ab[0], ab[1]}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d stderr %q", rc, errb.String())
	}
	want := []string{"have=" + ab[0], "have=" + ab[1]}
	for _, d := range slices.Sorted(slices.Values([]string{a, b})) {
		bs := map[string][]string{a: {pa, pa2}, b: {pb}}[d]
		slices.Sort(bs)
		for _, bl := range bs {
			want = append(want, "name="+d+" "+bl)
		}
	}
	if got := strings.Split(strings.TrimSuffix(out.String(), "\n"), "\n"); !reflect.DeepEqual(got, append(want, "layers=2")) {
		t.Errorf("stdout %q, want %q", got, want)
	}
	if m := readMap(apps); !reflect.DeepEqual(m, names{pa: a, pa2: a, pb: b}) || mapMode(t, apps) != MapMode {
		t.Errorf("pruned map %v mode %o", m, mapMode(t, apps))
	}

	// Nothing to prune: the map is left as it is, not rewritten.
	ino := func() uint64 {
		fi, _ := os.Stat(mapPath(apps))
		return fi.Sys().(*syscall.Stat_t).Ino
	}
	before := ino()
	out.Reset()
	if rc := Layers([]string{apps}, &out, &errb); rc != 0 || out.String() != "layers=0\n" || ino() != before {
		t.Errorf("rc %d stdout %q, rewritten %v", rc, out.String(), ino() != before)
	}
}

// fakeEngine is a docker whose info prints $FAKE_INFO and whose save prints
// $FAKE_SAVE, or fails with FAKE_SAVE_RC.
func fakeEngine(t *testing.T, info string, save []byte) string {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "save.tar"), save, 0o644)
	t.Setenv("FAKE_INFO", info)
	script := `#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/calls"
case "$1" in
info) printf '%s\n' "$FAKE_INFO"; exit 0 ;;
save) [ -n "${FAKE_SAVE_RC:-}" ] && { echo "no such image" >&2; exit "$FAKE_SAVE_RC"; }; cat "$d/save.tar"; exit 0 ;;
esac
exit 9
`
	os.WriteFile(filepath.Join(dir, "docker"), []byte(script), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return dir
}

const (
	containerdInfo = `[["driver-type","io.containerd.snapshotter.v1"]]`
	overlayInfo    = `[["Backing Filesystem","extfs"],["Supports d_type","true"]]`
)

func TestDropSet(t *testing.T) {
	lb, la := []byte("\x1f\x8b base"), []byte("\x1f\x8b app")
	db, da := digest([]byte("base tar")), digest([]byte("app tar"))
	save := csave(t, [][]byte{lb, la}, []string{db, da})
	diffs := map[string]bool{db: true, da: true}
	unnamed := serverHeld{ids: map[string]bool{db: true}}
	saves := func(dir string) int {
		calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
		return strings.Count(string(calls), "save ")
	}
	for _, tt := range []struct {
		name   string
		info   string
		held   serverHeld
		rc     string
		drop   []string
		saves  int
		stderr string
	}{
		{"named by its diffID", containerdInfo, serverHeld{ids: unnamed.ids, names: map[string][]string{db: {db}}}, "", []string{db}, 0, ""},
		{"named by the server", containerdInfo, serverHeld{ids: unnamed.ids, names: map[string][]string{db: {digest(lb)}}}, "", []string{db, digest(lb)}, 0, ""},
		{"containerd learns", containerdInfo, unnamed, "", []string{db, digest(lb)}, 1, "learning this workstation's layer names: one extra local export, nothing sent"},
		{"overlay2 never learns", overlayInfo, unnamed, "", []string{db}, 0, ""},
		{"no answer from info", "", unnamed, "", []string{db}, 0, ""},
		{"learning fails", containerdInfo, unnamed, "1", []string{db}, 1, "could not learn this workstation's layer names (docker save exited 1: no such image)"},
	} {
		t.Run(tt.name, func(t *testing.T) {
			dir := fakeEngine(t, tt.info, save)
			if tt.rc != "" {
				t.Setenv("FAKE_SAVE_RC", tt.rc)
			}
			var errb bytes.Buffer
			drop, known := dropSet(&cli.Output{Stdout: &errb, Stderr: &errb}, []string{"a:1"}, tt.held, diffs)
			got := slices.Sorted(maps.Keys(drop))
			slices.Sort(tt.drop)
			calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
			if len(tt.held.names) > 0 && strings.Contains(string(calls), "info") {
				t.Errorf("every skippable layer had a name, and the store was still asked: %q", calls)
			}
			if !reflect.DeepEqual(got, tt.drop) || saves(dir) != tt.saves || !strings.Contains(errb.String(), tt.stderr) {
				t.Errorf("drop %v saves %d said %q; want %v %d %q", got, saves(dir), errb.String(), tt.drop, tt.saves, tt.stderr)
			}
			if !known[db] || !known[da] {
				t.Errorf("known %v lacks a diffID", known)
			}
			if tt.saves == 1 && tt.rc == "" && !known[digest(la)] {
				t.Errorf("known %v lacks a learned name", known)
			}
		})
	}
	if drop, _ := dropSet(&cli.Output{Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}}, nil, serverHeld{}, diffs); drop != nil {
		t.Errorf("nothing held, drop %v", drop)
	}
}

func TestFilterDropsNames(t *testing.T) {
	// The drop set a learned name makes: the compressed blob stays home.
	layer := []byte("\x1f\x8b base")
	in := csave(t, [][]byte{layer}, []string{digest([]byte("tar"))})
	set := map[string]bool{digest(layer): true}
	out, f, err := run(t, in, set)
	names, _ := untar(t, out)
	if err != nil || f.skipped != 1 || f.matched != 1 || slices.Contains(names, "blobs/sha256/"+hexOf(digest(layer))) {
		t.Errorf("skipped %d matched %d err %v names %v", f.skipped, f.matched, err, names)
	}
}

func TestLoadBusyLock(t *testing.T) {
	apps := kasbahDir(t)
	held, err := serverlock.Take(apps, serverlock.Exclusive, "server prune")
	if err != nil || held == nil {
		t.Fatal(err)
	}
	defer held.Close()
	fakeDocker(t)
	var out, errb bytes.Buffer
	in := gz(t, csave(t, [][]byte{[]byte("\x1f\x8b layer")}, []string{digest([]byte("tar"))}))
	if rc := Load([]string{apps, "a:1"}, bytes.NewReader(in), &out, &errb); rc != 0 || out.String() != "loaded=1\n" ||
		!strings.Contains(errb.String(), "the images loaded; their layer names were not recorded: ") ||
		!strings.Contains(errb.String(), "holds the server lock") || strings.Contains(errb.String(), "Nothing was changed") {
		t.Errorf("rc %d stdout %q stderr %q", rc, out.String(), errb.String())
	}
	if _, err := os.Stat(mapPath(apps)); err == nil {
		t.Error("a map was written past a held lock")
	}
}
