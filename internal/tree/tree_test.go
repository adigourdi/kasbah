package tree

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestParseKeepsOrderAndText(t *testing.T) {
	in := `{"z":1,"a":{"y":[],"b":{}},"z":2,"n":[123456789012345678901234567890,1.0,-0,1e3,1E-7],"s":"é"}`
	v, err := ParseOne([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	m := v.(*Map)
	if got := strings.Join(m.Keys(), ","); got != "z,a,n,s" {
		t.Errorf("keys %s", got)
	}
	if z, _ := m.Get("z"); z != Number("2") {
		t.Errorf("a repeated key keeps its last value: %v", z)
	}
	want := `{"z":2,"a":{"y":[],"b":{}},"n":[123456789012345678901234567890,1.0,-0,1e3,1E-7],"s":"é"}`
	if got := Compact(v); got != want {
		t.Errorf("compact\n%s\nwant\n%s", got, want)
	}
	if n, ok := Number("123456789012345678901234567890").Int64(); ok {
		t.Errorf("a big integer fits an int64: %d", n)
	}
	if n, ok := Number("42").Int64(); !ok || n != 42 || Number("1.5").Float64() != 1.5 {
		t.Error("Int64/Float64")
	}
}

func TestIndentMatchesEncodingJSON(t *testing.T) {
	in := `{"b":[true,null,{"c":"x"}],"e":{},"f":[],"g":"<a&b>\u2028\u2029\u0001\u007f\b\f\n\t\"\\/"}`
	v, err := ParseOne([]byte(in))
	if err != nil {
		t.Fatal(err)
	}
	var std any
	json.Unmarshal([]byte(in), &std)
	var b strings.Builder
	enc := json.NewEncoder(&b)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	enc.Encode(std) // keys in this input are already sorted
	if got, want := Indent(v)+"\n", b.String(); got != want {
		t.Errorf("indent\n%s\nwant\n%s", got, want)
	}
	g, _ := v.(*Map).Get("g")
	if got := Compact(g); got != `"<a&b>\u2028\u2029\u0001`+"\x7f"+`\b\f\n\t\"\\/"` {
		t.Errorf("escapes %s", got)
	}
	if Compact([]Value{}) != "[]" || Indent(NewMap()) != "{}" || Compact(nil) != "null" {
		t.Error("empties")
	}
}

func TestStreamAndRefusals(t *testing.T) {
	vs, err := Parse([]byte("{\"a\":1}\n{\"a\":2} 3 \"s\"\n"))
	if err != nil || len(vs) != 4 {
		t.Fatalf("%v %v", vs, err)
	}
	if vs, err := Parse(nil); err != nil || len(vs) != 0 {
		t.Error("an empty stream is no values")
	}
	if _, err := ParseOne([]byte("1 2")); err == nil {
		t.Error("ParseOne takes one value")
	}
	for _, bad := range []string{`{`, `[1,]`, `nope`, `{"a":1`, `{1:2}`, "\uFEFF{}", `NaN`, `[Infinity]`, `[01]`, `.5`, `+1`, "\"a\x01\"", `{"a" 1}`, `[1 2]`, `{} x`} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("%q parses", bad)
		}
	}
	if _, err := Parse([]byte(strings.Repeat("[", maxDepth+1) + strings.Repeat("]", maxDepth+1))); err == nil {
		t.Error("nesting past the limit parses")
	}
}

func TestAccessors(t *testing.T) {
	v, _ := ParseOne([]byte(`{"a":{"b":[10,"x",false]},"z":null}`))
	if x, ok := Lookup(v, "a", "b", 1); !ok || x != "x" {
		t.Errorf("lookup %v %v", x, ok)
	}
	for _, p := range [][]any{{"q"}, {"a", "b", 3}, {"a", "b", -1}, {"a", 0}, {"a", "b", "c"}, {"z", "y"}} {
		if _, ok := Lookup(v, p...); ok {
			t.Errorf("%v is found", p)
		}
	}
	if x, ok := Lookup(v, "z"); !ok || x != nil {
		t.Error("a null is found")
	}
	if f, _ := Lookup(v, "a", "b", 2); f != false {
		t.Error("false is a value like any other")
	}
	if TextAt(v, "a", "b", 2) != "false" || TextAt(v, "a", "b", 0) != "10" || TextAt(v, "z") != "" || TextAt(v, "q") != "" || TextAt(v, "a") != `{"b":[10,"x",false]}` {
		t.Error("TextAt")
	}
	if b, ok := Bool(false); !ok || b {
		t.Error("Bool")
	}
	if _, ok := String(Number("1")); ok {
		t.Error("a number is not a string")
	}
	if Kind(v) != "object" || Kind([]Value{}) != "array" || Kind(Number("1")) != "number" {
		t.Error("Kind")
	}
	l := NewMap()
	l.Set("a", Number("1"))
	l.Set("b", Number("2"))
	r := NewMap()
	r.Set("c", Number("3"))
	r.Set("a", Number("4"))
	m := Merge(l, r)
	if Compact(m) != `{"a":4,"b":2,"c":3}` || Compact(l) != `{"a":1,"b":2}` {
		t.Errorf("merge %s", Compact(m))
	}
	m.Delete("a")
	if strings.Join(m.Keys(), "") != "bc" || m.Has("a") || m.Len() != 2 {
		t.Error("delete")
	}
	m.Set("a", Number("5"))
	if Compact(m) != `{"b":2,"c":3,"a":5}` {
		t.Errorf("a key set again after Delete lands at the end: %s", Compact(m))
	}
	c := m.Clone()
	c.Set("b", "x")
	c.Delete("c")
	c.Set("d", nil)
	if Compact(m) != `{"b":2,"c":3,"a":5}` || Compact(c) != `{"b":"x","a":5,"d":null}` {
		t.Errorf("a clone is independent of its source: %s %s", Compact(m), Compact(c))
	}
}
