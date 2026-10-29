package buildpush

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func digest(b []byte) string {
	h := sha256.Sum256(b)
	return "sha256:" + hex.EncodeToString(h[:])
}

type entry struct {
	name, link string
	body       []byte
	dir        bool
}

func mktar(t *testing.T, ents []entry, trailer int) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range ents {
		h := &tar.Header{Name: e.name, Mode: 0o644, Size: int64(len(e.body)), Typeflag: tar.TypeReg}
		switch {
		case e.dir:
			h.Typeflag, h.Size, h.Mode = tar.TypeDir, 0, 0o755
		case e.link != "":
			h.Typeflag, h.Linkname, h.Size = tar.TypeSymlink, e.link, 0
		}
		if err := tw.WriteHeader(h); err != nil {
			t.Fatal(err)
		}
		tw.Write(e.body)
	}
	tw.Close()
	buf.Write(make([]byte, trailer))
	return buf.Bytes()
}

// untar is every entry of b: names in order, and bodies or link targets.
func untar(t *testing.T, b []byte) ([]string, map[string]string) {
	t.Helper()
	tr := tar.NewReader(bytes.NewReader(b))
	var names []string
	got := map[string]string{}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return names, got
		}
		if err != nil {
			t.Fatalf("output is not a tar: %v", err)
		}
		body, _ := io.ReadAll(tr)
		names = append(names, h.Name)
		got[h.Name] = string(body) + h.Linkname
	}
}

func run(t *testing.T, in []byte, skip map[string]bool) ([]byte, *filter, error) {
	t.Helper()
	var out bytes.Buffer
	f := newFilter(&out, skip, skip)
	src := bytes.NewReader(in)
	err := f.run(src)
	if err == nil {
		if src.Len() != 0 {
			t.Errorf("%d bytes of the input were left unread", src.Len())
		}
		f.close()
	}
	return out.Bytes(), f, err
}

func TestFilterOCI(t *testing.T) {
	base, app := bytes.Repeat([]byte("base-layer "), 3000), []byte("app-layer")
	b, a := digest(base), digest(app)
	hb, ha := strings.TrimPrefix(b, "sha256:"), strings.TrimPrefix(a, "sha256:")
	cfg := []byte(`{"rootfs":{"diff_ids":["` + b + `","` + a + `"]}}`)
	hc := strings.TrimPrefix(digest(cfg), "sha256:")
	manifest := `[{"Config":"blobs/sha256/` + hc + `","Layers":["blobs/sha256/` + hb + `","blobs/sha256/` + ha + `"]}]`
	in := mktar(t, []entry{
		{name: "blobs/", dir: true}, {name: "blobs/sha256/", dir: true},
		{name: "blobs/sha256/" + ha, body: app},
		{name: "blobs/sha256/" + hb, body: base},
		{name: "blobs/sha256/" + hc, body: cfg},
		// docker 25 kept the legacy paths as links to the blobs.
		{name: "0123/layer.tar", link: "../blobs/sha256/" + hb},
		{name: "4567/layer.tar", link: "../blobs/sha256/" + ha},
		{name: "index.json", body: []byte(`{"schemaVersion":2}`)},
		{name: "manifest.json", body: []byte(manifest)},
		{name: "oci-layout", body: []byte(`{"imageLayoutVersion":"1.0.0"}`)},
		{name: "repositories", body: []byte(`{}`)},
	}, 8192)

	out, f, err := run(t, in, map[string]bool{b: true})
	if err != nil {
		t.Fatal(err)
	}
	names, got := untar(t, out)
	want := []string{"blobs/", "blobs/sha256/", "blobs/sha256/" + ha, "blobs/sha256/" + hc,
		"4567/layer.tar", "index.json", "manifest.json", "oci-layout", "repositories"}
	if !reflect.DeepEqual(names, want) {
		t.Errorf("entries %q\nwant    %q", names, want)
	}
	if got["blobs/sha256/"+ha] != string(app) || got["manifest.json"] != manifest || got["blobs/sha256/"+hc] != string(cfg) {
		t.Errorf("a kept entry changed on the way through: %q", got)
	}
	if f.skipped != 1 || f.skippedBytes != int64(len(base)) {
		t.Errorf("skipped %d (%d bytes), want 1 (%d)", f.skipped, f.skippedBytes, len(base))
	}

	// Nothing to skip: the same entries come out.
	out, f, _ = run(t, in, map[string]bool{})
	if names, _ := untar(t, out); len(names) != 11 || f.skipped != 0 {
		t.Errorf("an empty skip set dropped entries: %q", names)
	}
}

func TestFilterLegacy(t *testing.T) {
	layer := bytes.Repeat([]byte("legacy "), 1000)
	d := digest(layer)
	in := mktar(t, []entry{
		{name: "0123/", dir: true},
		{name: "0123/VERSION", body: []byte("1.0")},
		{name: "0123/json", body: []byte(`{"id":"0123"}`)},
		{name: "0123/layer.tar", body: layer},
		{name: "89ab.json", body: []byte(`{}`)},
		{name: "manifest.json", body: []byte(`[{"Layers":["0123/layer.tar"]}]`)},
		{name: "repositories", body: []byte(`{}`)},
	}, 0)
	// The legacy names carry no diffID: nothing can be told apart, nothing goes.
	out, f, err := run(t, in, map[string]bool{d: true})
	if err != nil {
		t.Fatal(err)
	}
	names, got := untar(t, out)
	if len(names) != 7 || got["0123/layer.tar"] != string(layer) || f.skipped != 0 {
		t.Errorf("a legacy save changed: %q, skipped %d", names, f.skipped)
	}
}

func TestFilterCut(t *testing.T) {
	base := bytes.Repeat([]byte("x"), 5000)
	hb := strings.TrimPrefix(digest(base), "sha256:")
	in := mktar(t, []entry{{name: "blobs/sha256/" + hb, body: base}, {name: "index.json", body: []byte("{}")}}, 0)
	if _, _, err := run(t, in[:2000], nil); err == nil {
		t.Error("a stream cut inside an entry was accepted")
	}
	// Cut at an entry boundary: no error, and no end marker until close.
	var out bytes.Buffer
	f := newFilter(&out, nil, nil)
	if err := f.run(bytes.NewReader(in[:512+5120])); err != nil {
		t.Fatal(err)
	}
	if n := out.Len(); n != 512+5120 {
		t.Errorf("before close the output is %d bytes, want the one entry (%d) and no end marker", n, 512+5120)
	}
}

func TestChainIDs(t *testing.T) {
	a, b := digest([]byte("a")), digest([]byte("b"))
	c := chainIDs([]string{a, b})
	if c[0] != a || c[1] != digest([]byte(a+" "+b)) {
		t.Errorf("chainIDs = %q", c)
	}
}

func TestSkippable(t *testing.T) {
	a, b, x := digest([]byte("a")), digest([]byte("b")), digest([]byte("x"))
	have := map[string]bool{}
	for _, c := range chainIDs([]string{a, b}) {
		have[c] = true
	}
	// b also sits on x in the second image, a chain the server lacks: it ships.
	got := skippable([][]string{{a, b}, {x, b}}, have)
	if !reflect.DeepEqual(got, map[string]bool{a: true}) {
		t.Errorf("skippable = %v, want only %s", got, a)
	}
	if got := skippable([][]string{{a, b, x}}, have); !reflect.DeepEqual(got, map[string]bool{a: true, b: true}) {
		t.Errorf("skippable = %v, want a and b", got)
	}
}

func TestParseHave(t *testing.T) {
	a, b := digest([]byte("a")), digest([]byte("b"))
	if h, err := parseHave([]byte("have="+a+"\r\nlayers=1\n"), []string{a, b}); err != nil || !h[a] || h[b] {
		t.Errorf("parseHave: %v %v", h, err)
	}
	for _, bad := range []string{"", "have=" + a + "\n", "have=" + a + "\nlayers=2\n", "have=" + digest([]byte("z")) + "\nlayers=1\n"} {
		if _, err := parseHave([]byte(bad), []string{a, b}); err == nil {
			t.Errorf("parseHave(%q) was trusted", bad)
		}
	}
}

// fakeStore is a docker whose `image ls` lists $FAKE_IDS and whose inspect
// prints $dir/rootfs-<id> per argument; FAKE_INSPECT_RC fails it.
func fakeStore(t *testing.T, images map[string][]string) string {
	dir := t.TempDir()
	var ids []string
	for id, layers := range images {
		ids = append(ids, id)
		os.WriteFile(filepath.Join(dir, "rootfs-"+id), []byte(`["`+strings.Join(layers, `","`)+`"]`+"\n"), 0o644)
	}
	t.Setenv("FAKE_IDS", strings.Join(append(ids, ids...), " "))
	script := `#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/calls"
[ "$1 $2" = "image ls" ] && { for i in $FAKE_IDS; do echo "$i"; done; exit 0; }
[ "$1 $2" = "image inspect" ] || exit 9
shift 4
for i; do cat "$d/rootfs-$i" || exit 1; done
exit "${FAKE_INSPECT_RC:-0}"
`
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return dir
}

func TestLayers(t *testing.T) {
	a, b, x := digest([]byte("a")), digest([]byte("b")), digest([]byte("x"))
	ab := chainIDs([]string{a, b})
	dir := fakeStore(t, map[string][]string{"i1": {a, b}, "i2": {a}})
	var out, errb bytes.Buffer
	if rc := Layers([]string{ab[0], ab[1], x}, &out, &errb); rc != 0 || out.String() != "have="+a+"\nhave="+ab[1]+"\nlayers=2\n" {
		t.Errorf("rc %d stdout %q stderr %q", rc, out.String(), errb.String())
	}
	// Each image inspected once, though image ls named it twice.
	calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
	if strings.Count(string(calls), "i1") != 1 || strings.Count(string(calls), "\n") != 2 {
		t.Errorf("docker calls: %q", calls)
	}

	t.Setenv("FAKE_INSPECT_RC", "1")
	out.Reset()
	if rc := Layers([]string{a}, &out, &errb); rc != 1 || strings.Contains(out.String(), "layers=") {
		t.Errorf("a failed inspect answered %q (rc %d)", out.String(), rc)
	}
	out.Reset()
	if rc := Layers([]string{"sha256:nothex"}, &out, &errb); rc != 1 || !strings.Contains(errb.String(), "not a sha256") || out.Len() != 0 {
		t.Errorf("a malformed id: rc %d stdout %q", rc, out.String())
	}
}

func TestLoadUnpackFailure(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
cat > /dev/null
echo "Loaded image: a:1"
echo "Error unpacking image b:1: apply layer error: content digest sha256:00: not found"
exit 0
`
	os.WriteFile(filepath.Join(dir, "docker"), []byte(script), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	var out, errb bytes.Buffer
	rc := Load([]string{"a:1", "b:1"}, bytes.NewReader(gz(t, []byte("tar"))), &out, &errb)
	if rc != 1 || out.String() != "incomplete=b:1\n" || !strings.Contains(errb.String(), "left b:1 unusable") ||
		!strings.Contains(errb.String(), "Loaded image: a:1") {
		t.Errorf("rc %d stdout %q stderr %q", rc, out.String(), errb.String())
	}
}

func TestMB(t *testing.T) {
	for n, want := range map[int64]string{0: "0 B", 999: "999 B", 3170: "3.2 kB", 71_400_000: "71.4 MB"} {
		if got := mb(n); got != want {
			t.Errorf("mb(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestFilterCompressed(t *testing.T) {
	// A containerd-store save: the layer blob is named by its compressed digest.
	layer := []byte("gzipped layer bytes")
	diffID := digest([]byte("the uncompressed tar"))
	in := mktar(t, []entry{{name: "blobs/sha256/" + strings.TrimPrefix(digest(layer), "sha256:"), body: layer}}, 0)
	_, f, err := run(t, in, map[string]bool{diffID: true})
	if err != nil || f.matched != 0 || f.skipped != 0 {
		t.Errorf("matched %d skipped %d err %v; want nothing matched", f.matched, f.skipped, err)
	}
}
