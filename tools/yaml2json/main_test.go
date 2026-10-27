package main

import (
	"bytes"
	"strings"
	"testing"
)

func run(t *testing.T, src string) (string, error) {
	t.Helper()
	var out bytes.Buffer
	err := convert(strings.NewReader(src), &out)
	return out.String(), err
}

func TestKeyOrderKept(t *testing.T) {
	got, err := run(t, "z: 1\na: [x, {q: true, b: null}]\nm: \"s<>\"\n")
	if err != nil {
		t.Fatal(err)
	}
	want := `{"z":1,"a":["x",{"q":true,"b":null}],"m":"s<>"}` + "\n"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestMultiDoc(t *testing.T) {
	got, err := run(t, "a: 1\n---\n- 2\n---\nplain\n")
	if err != nil {
		t.Fatal(err)
	}
	if want := "{\"a\":1}\n[2]\n\"plain\"\n"; got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestAnchorsAndEmpty(t *testing.T) {
	got, err := run(t, "a: &x {k: v}\nb: *x\n---\n")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(got, `{"a":{"k":"v"},"b":{"k":"v"}}`+"\n") {
		t.Fatalf("got %q", got)
	}
}

func TestParseErrorKeepsEarlierDocs(t *testing.T) {
	got, err := run(t, "a: 1\n---\nb:\n\tc: 2\n")
	if err == nil {
		t.Fatal("want an error")
	}
	if got != "{\"a\":1}\n" {
		t.Fatalf("got %q", got)
	}
}
