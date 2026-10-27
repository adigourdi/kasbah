package yamlx

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/jv"
)

// The cache answers from the first read until told to forget.
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
	for _, doc := range []string{bomb, bomb + "z: 1\nz: 2\n", "z: 1\nz: 2\n" + bomb} {
		if _, err := Load([]byte(doc)); err == nil {
			t.Error("a billion-laughs document converts")
		} else if _, ok := err.(*Error); !ok {
			t.Errorf("a billion-laughs document is refused with %T", err)
		}
	}
}

// Each case is a stream and the compact JSON of each of its documents, or
// "error" when the stream is refused as a whole.
func TestLoad(t *testing.T) {
	for _, c := range []struct{ in, want string }{
		{"", ""},
		{"# only a comment\n", ""},
		{"z: 1\na: [x, {q: true, b: null}]\nm: \"s<>&\"\n", `{"z":1,"a":["x",{"q":true,"b":null}],"m":"s<>&"}`},
		{"a: 1\n---\n- 2\n---\nplain\n", `{"a":1}|[2]|"plain"`},
		{"---\n", `null`},
		{"a: 1\nb: 2\na: 3\n", `{"a":3,"b":2}`},
		{"a: &x {k: v}\nb: *x\n", `{"a":{"k":"v"},"b":{"k":"v"}}`},
		{"base: &b {x: 1, y: 2}\nm:\n  y: 9\n  <<: *b\n  z: 3\n", `{"base":{"x":1,"y":2},"m":{"y":9,"x":1,"z":3}}`},
		{"a: &a {k: 1, j: 1}\nb: &b {k: 2, i: 2}\nm: {<<: [*a, *b]}\n", `{"a":{"k":1,"j":1},"b":{"k":2,"i":2},"m":{"k":1,"j":1,"i":2}}`},
		{"m: {'<<': {k: 1}}\n", `{"m":{"<<":{"k":1}}}`},
		{"m: {<<: 1}\n", "error"},
		{"l: &l [{a: 1}]\nm: {<<: *l}\n", "error"},
		{"l: &l [{a: 1}]\nm: {<<: *l, x: 1, x: 2}\n", "error"},
		{"m: {<<: [{a: 1}, 2]}\n", "error"},
		{"m: {x: 0, <<: {a: 1, x: 1}, b: 2, <<: {a: 2, c: 2}}\n", `{"m":{"x":0,"a":2,"c":2,"b":2}}`},
		{"m: {<<: 1, <<: {a: 1}}\n", "error"},
		{"s: &s {a: 1, a: 2, b: 1}\nm: {<<: *s, b: 9}\n", `{"s":{"a":2,"b":1},"m":{"a":2,"b":9}}`},
		{"i: &i {a: 1, b: 1}\no: &o {<<: *i, b: 2}\nm: {<<: *o, c: 3}\n", `{"i":{"a":1,"b":1},"o":{"a":1,"b":2},"m":{"a":1,"b":2,"c":3}}`},
		{"a: &s 1\nb: *s\nc: &q [x, *s]\nd: *q\n", `{"a":1,"b":1,"c":["x",1],"d":["x",1]}`},
		{"a: &a {b: *a}\n", "error"},
		{"a: &a {b: *a, b: 1}\n", "error"},
		{"a: &a [{<<: *a}]\n", "error"},
		{"b: !!binary aGVsbG8=\n", `{"b":"hello"}`},
		{"2001-12-14: x\n", `{"2001-12-14":"x"}`},
		{"%YAML 1.2\n---\na: 1\n", "error"},
		{"a: .inf\na: 1\n", "error"},
		{"[yes, on, no, off, y, true, False, ~, null, '']\n", `["yes","on","no","off","y",true,false,null,null,""]`},
		{"[0755, 0o755, 0x1F, -12, +7, 1_000, 0b101]\n", `[493,493,31,-12,7,1000,5]`},
		{"[1.0, 0.5, -0.0, 1e16, 1e-5, .5, 1.5e300, 1e0, 10e-1, !!float 3]\n", `[1.0,0.5,-0.0,1e+16,1e-05,0.5,1.5e+300,1.0,1.0,3.0]`},
		{"[9223372036854775807, 18446744073709551615, 123456789012345678901234567890, -9223372036854775809, !local 123456789012345678901234567890]\n", `[9223372036854775807,18446744073709551615,123456789012345678901234567890,-9223372036854775809,123456789012345678901234567890]`},
		{"0xFFFFFFFFFFFFFFFFFFFF\n", `"0xFFFFFFFFFFFFFFFFFFFF"`},
		{"a: .inf\n", "error"},
		{"a: -.Inf\n", "error"},
		{"a: .nan\n", "error"},
		{"[2001-12-14, 2001-12-14t21:59:43.10-05:00, !!timestamp 2001-12-14, 1:30, 12:30:00]\n", `["2001-12-14","2001-12-14t21:59:43.10-05:00","2001-12-14","1:30","12:30:00"]`},
		{"[!!str 1, !!str true, !!int \"7\", !!float 1, '1', \"null\"]\n", `["1","true",7,1.0,"1","null"]`},
		{"a: !!int x\n", "error"},
		{"a: !reset null\nb: !override [x]\nc: !reset {}\nd: !local 5\ne: ! 5\n", `{"a":null,"b":["x"],"c":{},"d":5,"e":5}`},
		{"1: a\ntrue: b\n~: c\n0x10: d\n1.50: e\n", `{"1":"a","true":"b","null":"c","16":"d","1.5":"e"}`},
		{"? [a]\n: b\n", "error"},
		{"? {a: 1}\n: b\n", "error"},
		{"a: 1\r\nb: |\r\n  x\r\n  y\r\n", `{"a":1,"b":"x\ny\n"}`},
		{"\uFEFFa: 1\n", `{"a":1}`},
		{"a: 1\n---\nb:\n\tc: 2\n", "error"},
		{"a: [\n", "error"},
		{"a: &a [*a]\n", "error"},
		{"a: *nope\n", "error"},
		{"s: \"\\u00e9\\t\\u0001\"\n", `{"s":"é\t\u0001"}`},
	} {
		docs, err := Load([]byte(c.in))
		got := "error"
		if err == nil {
			parts := make([]string, len(docs))
			for i, d := range docs {
				parts[i] = jv.Compact(d)
			}
			got = strings.Join(parts, "|")
		} else if _, ok := err.(*Error); !ok {
			t.Errorf("%q: error %T, want *Error", c.in, err)
		}
		if got != c.want {
			t.Errorf("%q:\n got %s\nwant %s", c.in, got, c.want)
		}
	}
}
