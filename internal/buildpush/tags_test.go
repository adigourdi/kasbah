package buildpush

import (
	"bytes"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

func TestIdentify(t *testing.T) {
	a, b := digest([]byte("a")), digest([]byte("b"))
	// The same image as an overlay2 store and a containerd store, of two
	// docker versions, inspect it: other IDs, other empty fields.
	overlay := `{"Id":"` + a + `","Created":"2026-11-12T10:00:00.5Z","Architecture":"amd64","Os":"linux",` +
		`"Config":{"Hostname":"","Env":["A=1"],"Cmd":["sh"],"Entrypoint":null,"Labels":{"y":"2","x":"1"}},"RootFS":{"Type":"layers","Layers":["` + a + `"]}}`
	containerd := `{"Id":"` + b + `","Created":"2026-11-12T11:00:00.500+01:00","Architecture":"amd64","Os":"linux",` +
		`"Config":{"Env":["A=1"],"Cmd":["sh"],"Labels":{"x":"1","y":"2"}},"Descriptor":{},"RootFS":{"Layers":["` + a + `"]}}`
	x, err := identify([]byte(overlay))
	y, err2 := identify([]byte(containerd))
	if err != nil || err2 != nil || x.ID != a || y.ID != b || !x.same(y) || x.Created != "2026-11-12T10:00:00.5Z" {
		t.Fatalf("one image read as two: %+v %+v %v %v", x, y, err, err2)
	}
	// Docker 24 does not report a healthcheck's StartInterval: not compared.
	hc := `"Healthcheck":{"Test":["CMD","true"],"Interval":1000000000`
	z1, err := identify([]byte(strings.Replace(overlay, `"Env"`, hc+`,"StartInterval":2000000000},"Env"`, 1)))
	z2, err2 := identify([]byte(strings.Replace(containerd, `"Env"`, hc+`},"Env"`, 1)))
	if err != nil || err2 != nil || !z1.same(z2) || z1.Sum == x.Sum {
		t.Errorf("a StartInterval Docker 24 does not report told one build from itself: %+v %+v %v %v", z1, z2, err, err2)
	}
	for _, other := range []string{
		strings.Replace(containerd, `11:00:00.500`, `11:00:01.500`, 1),
		strings.Replace(containerd, `["sh"]`, `["bash"]`, 1),
		strings.Replace(containerd, `"Layers":["`+a, `"Layers":["`+b, 1),
		strings.Replace(containerd, `"amd64"`, `"arm64"`, 1),
	} {
		if z, err := identify([]byte(other)); err != nil || z.same(x) {
			t.Errorf("another build read as the same one (%v): %s", err, other)
		}
	}
	for _, bad := range []string{"", "{", `{"Id":"x"}`, `{"Id":"` + a + `","Created":"yesterday"}`} {
		if _, err := identify([]byte(bad)); err == nil {
			t.Errorf("identify(%q) was trusted", bad)
		}
	}
}

func TestParseTags(t *testing.T) {
	a, b := digest([]byte("a")), digest([]byte("b"))
	refs := []string{"w:1", "x:1"}
	got, err := parseTags([]byte("image=w:1 "+a+" "+b+" 2026-11-12T10:00:00Z\r\nimage=x:1 absent\nhave="+a+"\nimages=2\nlayers=1\n"), refs)
	if w, ok := got["w:1"]; err != nil || len(got) != 1 || !ok || w.Sum != a || w.ID != b || w.Created != "2026-11-12T10:00:00Z" {
		t.Fatalf("parseTags: %v %v", got, err)
	}
	for _, bad := range []string{
		"", "image=w:1 absent\nimages=1\n", "image=w:1 absent\nimage=x:1 absent\n",
		"image=w:1 absent\nimage=w:1 absent\nimages=2\n", "image=w:1 absent\nimage=y:1 absent\nimages=2\n",
		"image=w:1 absent\nimage=x:1 " + a + " nothex -\nimages=2\n", "image=w:1\nimage=x:1 absent\nimages=2\n",
	} {
		if _, err := parseTags([]byte(bad), refs); err == nil {
			t.Errorf("parseTags(%q) was trusted", bad)
		}
	}
}

func TestPlanTags(t *testing.T) {
	a, b, c := digest([]byte("a")), digest([]byte("b")), digest([]byte("c"))
	refs := []string{"new:1", "same:1", "other:1"}
	local := map[string]identity{"new:1": {ID: a, Sum: a}, "same:1": {ID: a, Sum: b}, "other:1": {ID: a, Sum: a, Created: "2026-11-12T10:00:00Z"}}
	there := map[string]identity{"same:1": {ID: c, Sum: b}, "other:1": {ID: c, Sum: c}}
	var errb bytes.Buffer
	out := &cli.Output{Stdout: io.Discard, Stderr: &errb}
	noTTY := &prompt.Prompter{In: strings.NewReader(""), Out: out}

	pl, err := planTags(out, noTTY, "u@h", refs, local, there, prompt.Yes, nil)
	if err != nil || strings.Join(pl.send, " ") != "new:1 other:1" || !pl.same["same:1"] || len(pl.same) != 1 || pl.replaced["other:1"].ID != c {
		t.Errorf("--replace-tag: %+v %v", pl, err)
	}
	_, err = planTags(out, noTTY, "u@h", refs, local, there, prompt.No, []string{"git tag -d v1"})
	if msg := errText(err); err == nil || !strings.Contains(msg, "nothing was sent") || !strings.Contains(msg, short(c)) ||
		!strings.Contains(msg, short(a)+" (created 2026-11-12T10:00:00Z)") || !strings.Contains(msg, "other:1") ||
		!strings.Contains(msg, "git tag -d v1") || !strings.Contains(msg, "--replace-tag") {
		t.Errorf("--no-replace-tag: %q", msg)
	}
	_, err = planTags(out, noTTY, "u@h", refs, local, there, prompt.Unset, nil)
	if msg := errText(err); err == nil || !strings.Contains(msg, "--replace-tag or --no-replace-tag") ||
		!strings.Contains(msg, "nothing was sent") || !strings.Contains(errb.String(), "u@h has "+short(c)) {
		t.Errorf("no terminal: %q, stderr %q", msg, errb.String())
	}
	// A no at the terminal: the differing images, shown with the question, are
	// not listed again in the failure.
	errb.Reset()
	no := &prompt.Prompter{In: strings.NewReader("n\n"), Out: out, TTY: true}
	_, err = planTags(out, no, "u@h", refs, local, there, prompt.Unset, nil)
	if msg := errText(err); err == nil || strings.Count(errb.String()+msg, "u@h has "+short(c)) != 1 {
		t.Errorf("answered no: %q, stderr %q", msg, errb.String())
	}
	yes := &prompt.Prompter{In: strings.NewReader("maybe\ny\n"), Out: out, TTY: true}
	if pl, err := planTags(out, yes, "u@h", refs, local, there, prompt.Unset, nil); err != nil || len(pl.send) != 2 {
		t.Errorf("answered yes: %+v %v", pl, err)
	}
	// Nothing the server holds differs: nothing is asked.
	delete(there, "other:1")
	if pl, err := planTags(out, noTTY, "u@h", refs, local, there, prompt.Unset, nil); err != nil || len(pl.send) != 2 || len(pl.replaced) != 0 {
		t.Errorf("no mismatch: %+v %v", pl, err)
	}
}

func TestLayersImages(t *testing.T) {
	a := digest([]byte("a"))
	dir := t.TempDir()
	obj := `{"Id":"` + a + `","Created":"2026-11-12T10:00:00Z","Config":{"Cmd":["sh"]},"RootFS":{"Layers":["` + a + `"]}}`
	os.WriteFile(filepath.Join(dir, "inspect-w:1"), []byte(obj+"\n"), 0o644)
	script := `#!/bin/sh
d=$(dirname "$0")
[ "$1 $2" = "image ls" ] && exit 0
[ "$1 $2 $3 $4" = "image inspect --format {{json .}}" ] || exit 9
[ "$5" = "broken:1" ] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
cat "$d/inspect-$5" 2>/dev/null || { echo "Error response from daemon: No such image: $5" >&2; exit 1; }
`
	os.WriteFile(filepath.Join(dir, "docker"), []byte(script), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	want, _ := identify([]byte(obj))
	var out, errb bytes.Buffer
	apps := t.TempDir()
	if rc := Layers([]string{apps, "--image=w:1", "--image=gone:1"}, &out, &errb); rc != 0 ||
		out.String() != "image=w:1 "+want.Sum+" "+a+" 2026-11-12T10:00:00Z\nimage=gone:1 absent\nimages=2\nlayers=0\n" {
		t.Errorf("rc %d stdout %q stderr %q", rc, out.String(), errb.String())
	}
	if got, err := parseTags(out.Bytes(), []string{"w:1", "gone:1"}); err != nil || !got["w:1"].same(want) {
		t.Errorf("its own answer did not read back: %v %v", got, err)
	}
	out.Reset()
	if rc := Layers([]string{apps, "--image=broken:1"}, &out, &errb); rc != 1 || strings.Contains(out.String(), "images=") {
		t.Errorf("a failed inspect answered %q (rc %d)", out.String(), rc)
	}
	if rc := Layers([]string{apps, "--image="}, &out, &errb); rc != 1 || !strings.Contains(errb.String(), "names no image") {
		t.Errorf("an empty --image=: rc %d", rc)
	}
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	msg := err.Error()
	if e := (*cli.Error)(nil); errors.As(err, &e) {
		msg += "\n" + strings.Join(e.NextLines(), "\n")
	}
	return msg
}

func TestRefsOf(t *testing.T) {
	// Two services building one image: asked about, and counted, once.
	images := []Image{{Service: "a", Ref: "x:1"}, {Service: "b", Ref: "y:1"}, {Service: "c", Ref: "x:1"}}
	if got := strings.Join(refsOf(images), " "); got != "x:1 y:1" {
		t.Errorf("refsOf: %q", got)
	}
}
