package mailreg

import (
	"errors"
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	r, err := Parse([]byte("name: mail\nprimary_domain: a.test\ndomains:\n  - b.test\n  - a.test\n  -\n"), "f")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(r.Domains, " ") != "a.test b.test" || !r.Serves("a.test") || r.Serves("c.test") {
		t.Fatalf("got %+v", r)
	}
	if r, err := Parse([]byte("primary_domain: a.test\r\n"), "f"); err != nil || !r.Serves("a.test") {
		t.Fatalf("CRLF, no domains: %+v %v", r, err)
	}
}

func TestRefusals(t *testing.T) {
	cases := map[string]string{
		"name: mail\ndomains:\n  - a.test\n":          "has no primary_domain:",
		"primary_domain: \"\"\n":                      "has no primary_domain:",
		"primary_domain: localhost\n":                 "which is not a domain name",
		"primary_domain: a.test\ndomains: [bad_name]": "lists 'bad_name'",
		"primary_domain: a.test\ndomains: a.test\n":   "not a list",
		"   \n": "missing or empty",
	}
	for in, want := range cases {
		_, err := Parse([]byte(in), "/apps/mail/kasbah.yml on d@h")
		if err == nil || !strings.Contains(err.Error(), want) || !strings.Contains(err.Error(), "/apps/mail/kasbah.yml on d@h") {
			t.Errorf("Parse(%q) = %v; want it naming the file and %q", in, err, want)
		}
		if errors.Is(err, ErrUnparseable) {
			t.Errorf("Parse(%q) read as unparseable", in)
		}
	}
	for _, in := range []string{"a: [", "- a\n- b\n", "a: 1\n---\nb: 2\n"} {
		if _, err := Parse([]byte(in), "f"); !errors.Is(err, ErrUnparseable) {
			t.Errorf("Parse(%q) = %v; want ErrUnparseable", in, err)
		}
	}
}
