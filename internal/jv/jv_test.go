package jv

import (
	"strings"
	"testing"
)

// Spellings observed from jq 1.7 re-reading a literal it did not compute.
func TestCanonNumber(t *testing.T) {
	for in, want := range map[string]string{
		"1": "1", "-0": "-0", "1.0": "1.0", "1.50": "1.50", "1e2": "1E+2", "1e-07": "1E-7",
		"1.5e+300": "1.5E+300", "1e+16": "1E+16", "6.02e+23": "6.02E+23", "0.000001": "0.000001",
		"0.0001": "0.0001", "1e-05": "0.00001", "2000000000000000.0": "2000000000000000.0",
		"123456789012345678901234567890": "123456789012345678901234567890", "-0.0": "-0.0",
		"0.0": "0.0", "-0.0005": "-0.0005", "100000000000000000000.0": "100000000000000000000.0",
	} {
		if got := CanonNumber(in); got != want {
			t.Errorf("%s: %s, want %s", in, got, want)
		}
	}
}

func TestParseAndRender(t *testing.T) {
	vs, err := Parse([]byte(`{"b":1,"a":[true,null,"x\u0001\u007f\"\\é"],"b":2,"e":{},"f":[]} 3`))
	if err != nil || len(vs) != 2 {
		t.Fatalf("%v %v", vs, err)
	}
	if got := Compact(vs[0]); got != `{"b":2,"a":[true,null,"x\u0001\u007f\"\\é"],"e":{},"f":[]}` {
		t.Errorf("compact %s", got)
	}
	want := "{\n  \"b\": 2,\n  \"a\": [\n    true,\n    null,\n    \"x\\u0001\\u007f\\\"\\\\é\"\n  ],\n  \"e\": {},\n  \"f\": []\n}"
	if got := Pretty(vs[0]); got != want {
		t.Errorf("pretty\n%s\nwant\n%s", got, want)
	}
	if Raw("s\n") != "s\n" || Raw(Number("1.0")) != "1.0" || ToString(vs[0].(*Map)) != Compact(vs[0]) {
		t.Error("raw/tostring")
	}
	for _, bad := range []string{`{`, `[1,]`, `nope`, `{"a":1`} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("%q parses", bad)
		}
	}
	if vs, err := Parse(nil); err != nil || len(vs) != 0 {
		t.Error("an empty stream is no values")
	}
	if _, err := ParseOne([]byte("1 2")); err == nil {
		t.Error("ParseOne takes one value")
	}
}

func TestGet(t *testing.T) {
	v, _ := ParseOne([]byte(`{"a":{"b":[10,20]},"s":"x","z":null}`))
	cases := []struct {
		path []any
		want string
		ok   bool
	}{
		{[]any{"a", "b", 1}, "20", true},
		{[]any{"a", "b", -1}, "20", true},
		{[]any{"a", "b", 5}, "null", true},
		{[]any{"missing", "deeper"}, "null", true},
		{[]any{"z", 0}, "null", true},
		{[]any{"s", "k"}, "", false},
		{[]any{"a", 0}, "", false},
	}
	for _, c := range cases {
		got, ok := Get(v, c.path...)
		if ok != c.ok || (ok && Compact(got) != c.want) {
			t.Errorf("%v: %v %v", c.path, got, ok)
		}
	}
	if Type(v) != "object" || Type(Number("1")) != "number" || Type(nil) != "null" {
		t.Error("type")
	}
	if Truthy(false) || Truthy(nil) || !Truthy(Number("0")) || Alt(false, "d") != "d" {
		t.Error("truth")
	}
	m := v.(*Map)
	c := m.Clone()
	c.Delete("a")
	if !m.Has("a") || c.Has("a") || c.Len() != 2 {
		t.Error("clone/delete")
	}
	if i, ok := Number("42").Int64(); !ok || i != 42 || Number("1.5").Float64() != 1.5 {
		t.Error("number")
	}
	if _, ok := Number("1E+2").Big(); ok {
		t.Error("1E+2 is not an integer spelling")
	}
}

// What jq 1.7 accepts and refuses on reading, observed on the host.
func TestParseLikeJq(t *testing.T) {
	for in, want := range map[string]string{
		"\ufeff{\"a\":1}":      `{"a":1}`,
		`{"a":NaN,"b":-nan}`:   `{"a":null,"b":null}`,
		`[Infinity,-infinity]`: `[1.7976931348623157e+308,-1.7976931348623157e+308]`,
		`[01,1.,.5,+1,1e5]`:    `[1,1,0.5,1,1E+5]`,
		`"\udc00x"`:            "\"�x\"",
		`"𐀀"`:                  "\"\U00010000\"",
		"\"a\xffb\"":           "\"a�b\"",
		`"\/"`:                 `"/"`,
	} {
		v, err := ParseOne([]byte(in))
		if err != nil || Compact(v) != want {
			t.Errorf("%q: %v %v, want %s", in, Compact(v), err, want)
		}
	}
	for _, bad := range []string{`"\ud800"`, `"\ud800x"`, `"\ud800A"`, "{\"a\":1}\ufeff{}", `[1,]`, `{'a':1}`, `[1 2]`, `"\q"`, `{"a" 1}`, `1e`} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("%q parses; jq refuses it", bad)
		}
	}
	// jq's depth boundaries, each measured on the host: an object counts twice.
	wrap := func(open, close string, n int, inner string) string {
		return strings.Repeat(open, n) + inner + strings.Repeat(close, n)
	}
	for in, ok := range map[string]bool{
		wrap("[", "]", 256, ""):        true,
		wrap("[", "]", 257, ""):        false,
		wrap(`{"a":`, "}", 128, "1"):   true,
		wrap(`{"a":`, "}", 129, "1"):   false,
		wrap(`{"a":`, "}", 127, "[]"):  true,
		wrap(`{"a":`, "}", 128, "[]"):  false,
		wrap("[", "]", 255, `{"a":1}`): true,
		wrap("[", "]", 256, `{"a":1}`): false,
		wrap("[", "]", 256, "{}"):      false,
	} {
		if _, err := Parse([]byte(in)); (err == nil) != ok {
			t.Errorf("%.40s… (%d bytes): accepted=%v, jq accepted=%v", in, len(in), err == nil, ok)
		}
	}
	// Raw C0 controls inside a string are jq's parse error; DEL is not.
	for _, bad := range []string{"\"a\tb\"", "\"a\x01b\"", "\"a\nb\""} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("%q parses; jq refuses a raw control character", bad)
		}
	}
	if v, err := ParseOne([]byte("\"a\x7fb\"")); err != nil || Compact(v) != `"a\u007fb"` {
		t.Errorf("DEL: %v %v", v, err)
	}
}

// Invalid UTF-8 is repaired as jq repairs it, read or written: one U+FFFD per
// bad lead byte, truncated sequence (which takes the string's rest) or bad
// complete sequence — each case measured on the host jq.
func TestInvalidUTF8(t *testing.T) {
	const r = "\ufffd"
	for in, want := range map[string]string{
		"a\xed\xa0\x80b":     "a" + r + "b",
		"a\xff\xfeb":         "a" + r + r + "b",
		"a\xe2\x82b":         "a" + r + "b",
		"a\xf0\x9f\x98b":     "a" + r + "b",
		"a\xc0\x80b":         "a" + r + r + "b",
		"a\xf5\x80\x80\x80b": "a" + r + r + r + r + "b",
		"a\xed\xbf\xbfb":     "a" + r + "b",
		"a\xf4\x90\x80\x80b": "a" + r + "b",
		"a\x80\x80b":         "a" + r + r + "b",
		"a\xe2b":             "a" + r,
		"a\xe2bcdef":         "a" + r + "bcdef",
	} {
		if got := FixUTF8(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
		if got := Compact(in); got != `"`+want+`"` {
			t.Errorf("write %q: %q", in, got)
		}
		if v, err := ParseOne([]byte(`"` + in + `"`)); err != nil || v != want {
			t.Errorf("read %q: %q %v", in, v, err)
		}
	}
	if got := Compact("é😀"); got != `"é😀"` {
		t.Errorf("%q", got)
	}
}
