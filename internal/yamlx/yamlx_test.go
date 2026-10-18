package yamlx

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/adigourdi/kasbah/internal/jv"
)

// The cache answers from the first read until told to forget (yaml_test.sh).
func TestCache(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.yml")
	os.WriteFile(p, []byte("name: first\n"), 0o644)
	var c Cache
	name := func() jv.Value { v, _ := jv.Get(c.Get(p).Docs[0], "name"); return v }
	if name() != "first" {
		t.Fatal("first read")
	}
	os.WriteFile(p, []byte("name: second\n"), 0o644)
	if name() != "first" {
		t.Error("a cached file is not re-read")
	}
	c.Forget(p)
	if name() != "second" {
		t.Error("Forget makes the next Get read again")
	}
	c.Forget("never-loaded")

	os.WriteFile(p, []byte("a: [\n"), 0o644)
	c.Forget(p)
	if f := c.Get(p); f.Err == nil || f.Docs != nil {
		t.Error("a file that does not parse yields no documents")
	}
	if f := c.Get(filepath.Join(t.TempDir(), "absent.yml")); f.Err == nil {
		t.Error("a missing file is an error")
	}
}

// An alias bomb is refused without being expanded.
func TestExpansion(t *testing.T) {
	bomb := "a: &a [x,x,x,x,x,x,x,x,x,x]\n"
	prev := "a"
	for _, n := range []string{"b", "c", "d", "e", "f", "g", "h", "i"} {
		bomb += n + ": &" + n + " [*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + ",*" + prev + "]\n"
		prev = n
	}
	if _, err := Load([]byte(bomb)); err == nil {
		t.Error("a billion-laughs document converts")
	}
}

func TestPyRepr(t *testing.T) {
	for f, want := range map[float64]string{1: "1.0", 0.1: "0.1", 1e16: "1e+16", 2e15: "2000000000000000.0", 1e-5: "1e-05",
		0.0001: "0.0001", 1.5e300: "1.5e+300", 123456789.123456789: "123456789.12345679", -0.5: "-0.5"} {
		if got := pyRepr(f); got != want {
			t.Errorf("%v: %s, want %s", f, got, want)
		}
	}
}
