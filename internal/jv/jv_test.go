package jv

import "testing"

func TestJqHelpers(t *testing.T) {
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
	if Raw("s\n") != "s\n" || Raw(Number("1.0")) != "1.0" || ToString(v) != Compact(v) {
		t.Error("raw/tostring")
	}
	a, _ := Get(v, "a")
	if Raw(a) != "{\n  \"b\": [\n    10,\n    20\n  ]\n}" {
		t.Errorf("raw %q", Raw(a))
	}
}
