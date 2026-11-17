package acme

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/pem"
	"math/big"
	"os"
	"strings"
	"testing"
	"time"
)

func cert(t *testing.T, issuer pkix.RDNSequence, notAfter time.Time) []byte {
	t.Helper()
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	raw, _ := asn1.Marshal(issuer)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(7), RawSubject: raw, NotBefore: notAfter.Add(-time.Hour), NotAfter: notAfter}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func atv(oid []int, v string) pkix.AttributeTypeAndValue {
	return pkix.AttributeTypeAndValue{Type: asn1.ObjectIdentifier(oid), Value: v}
}

var (
	oC, oO, oCN, oOU = []int{2, 5, 4, 6}, []int{2, 5, 4, 10}, []int{2, 5, 4, 3}, []int{2, 5, 4, 11}
)

// The issuer as OpenSSL 3.0's `openssl x509 -issuer` prints it, which is what
// the Bash report showed on the workstation that ran it. OpenSSL 3.2+ prints
// `C=US, O=…` instead; the format is pinned here rather than inherited.
func TestIssuer(t *testing.T) {
	notAfter := time.Date(2027, 1, 2, 3, 4, 5, 0, time.UTC)
	for _, tc := range []struct {
		dn   pkix.RDNSequence
		want string
	}{
		{pkix.RDNSequence{{atv(oC, "US")}, {atv(oO, "Let's Encrypt")}, {atv(oCN, "R3")}}, "C = US, O = Let's Encrypt, CN = R3"},
		{pkix.RDNSequence{{atv(oO, "Foo, Inc.")}, {atv(oCN, "a+b")}}, `O = "Foo, Inc.", CN = "a+b"`},
		{pkix.RDNSequence{{atv(oCN, `x"y`)}, {atv(oOU, "a=b;c<d>")}}, `CN = x\"y, OU = "a=b;c<d>"`},
		{pkix.RDNSequence{{atv(oCN, "café")}}, `CN = caf\C3\A9`},
		{pkix.RDNSequence{{atv(oCN, "a"), atv(oO, "b")}}, "CN = a + O = b"},
		{pkix.RDNSequence{{atv(oCN, " lead")}, {atv(oO, "#hash")}}, `CN = " lead", O = "#hash"`},
	} {
		p := cert(t, tc.dn, notAfter)
		c := firstCert(p)
		if got := Issuer(c.RawIssuer); got != tc.want {
			t.Errorf("Issuer = %q, want %q", got, tc.want)
		}
	}
}

// Every attribute OpenSSL 3.0 names, in a certificate it issued; the expected
// line is that openssl's own `x509 -noout -issuer` (testdata/issuer.txt).
func TestIssuerNames(t *testing.T) {
	p, _ := os.ReadFile("testdata/issuer.pem")
	want, _ := os.ReadFile("testdata/issuer.txt")
	c := firstCert(p)
	if c == nil {
		t.Fatal("testdata/issuer.pem does not parse")
	}
	if got := Issuer(c.RawIssuer); got != strings.TrimSuffix(string(want), "\n") {
		t.Errorf("Issuer =\n%s\nopenssl says\n%s", got, want)
	}
}

func TestNotAfter(t *testing.T) {
	at := time.Date(2024, 3, 1, 12, 0, 0, 0, time.UTC)
	b := base64.StdEncoding.EncodeToString(cert(t, pkix.RDNSequence{{atv(oCN, "x")}}, at))
	l := Find([]byte(`{"http":{"Certificates":[{"domain":{"main":"x"},"certificate":"`+b+`"}]}}`), "x", at.Add(time.Hour))
	if l.NotAfter != "Mar  1 12:00:00 2024 GMT" || !l.Expired || l.Days != 0 {
		t.Errorf("got %+v; an hour past notAfter is expired, 0 days ago, printed as openssl prints it", l)
	}
}

func TestFind(t *testing.T) {
	now := time.Unix(2000000000, 0)
	p := cert(t, pkix.RDNSequence{{atv(oCN, "demo.test")}}, now.Add(20*24*time.Hour+time.Minute))
	b := base64.StdEncoding.EncodeToString(p)
	store := `{"http":{"Certificates":[{"domain":{"main":"a.test","sans":[5,"demo.test"]},"certificate":"` + b + `"}]}}`
	l := Find([]byte(store), "demo.test", now)
	if l.State != "found" || l.Main != "a.test" || l.Days != 20 || l.Count != 1 || l.Issuer != "CN = demo.test" {
		t.Errorf("got %+v", l)
	}
	expired := base64.StdEncoding.EncodeToString(cert(t, pkix.RDNSequence{{atv(oCN, "x")}}, now.Add(-36*time.Hour)))
	if l := Find([]byte(`{"http":{"Certificates":[{"domain":{"main":"x"},"certificate":"`+expired+`"}]}}`), "x", now); !l.Expired || l.Days != 1 {
		t.Errorf("an expired certificate's days: %+v", l)
	}
	for body, want := range map[string]string{
		"":                            "notjson",
		"{} {}":                       "notjson",
		"[1]":                         "notjson",
		`{"x":1}`:                     "noresolver",
		`{"letsencrypt":{}}`:          "noresolver",
		`{"http":"x"}`:                "notjson",
		`{"http":null}`:               "empty",
		`{"http":{"Certificates":5}}`: "notarray",
		`{"http":{"Certificates":[1,{"domain":{"main":"y"}}]}}`:                "nomatch",
		`{"http":{"Certificates":[{"domain":{"main":"x"},"certificate":""}]}}`: "nocert",
	} {
		if l := Find([]byte(body), "x", now); l.State != want {
			t.Errorf("%s: %s, want %s", body, l.State, want)
		}
	}
}

func TestFindIn(t *testing.T) {
	store := []byte(`{"http":{"Certificates":[{"domain":{"main":"a.example.com"}}]},"cloudflare":{"Certificates":[{"domain":{"main":"b.example.com"}},{"domain":{"main":"c.example.com"}}]}}`)
	now := time.Now()
	if l := FindIn(store, "cloudflare", "b.example.com", now); l.State != "nocert" || l.Count != 2 {
		t.Errorf("cloudflare: %+v", l)
	}
	if l := FindIn(store, "cloudflare", "a.example.com", now); l.State != "nomatch" {
		t.Errorf("another resolver's certificate matched: %+v", l)
	}
	if l := FindIn(store, "ovh", "a.example.com", now); l.State != "noresolver" {
		t.Errorf("ovh: %+v", l)
	}
	if l := FindIn(store, "", "", now); l.Count != 3 {
		t.Errorf("every store: %+v", l)
	}
	if l := FindIn([]byte(`{}`), "", "", now); l.State != "noresolver" {
		t.Errorf("no store at all: %+v", l)
	}
}

// A *. name covers one label; an exact name anywhere wins over a wildcard.
func TestWildcard(t *testing.T) {
	entry := func(main string, sans ...string) string {
		b := `{"domain":{"main":"` + main + `","sans":[`
		for i, s := range sans {
			if i > 0 {
				b += ","
			}
			b += `"` + s + `"`
		}
		return b + `]}}`
	}
	store := func(entries ...string) []byte {
		return []byte(`{"http":{"Certificates":[` + strings.Join(entries, ",") + `]}}`)
	}
	wildMain := entry("*.example.com")
	wildSAN := entry("tenants.example.com", "*.tenants.example.com")
	for _, tc := range []struct {
		name  string
		store []byte
		host  string
		main  string
		match string
		wild  bool
		via   string
	}{
		{"exact main", store(entry("a.example.com")), "a.example.com", "a.example.com", "a.example.com", false, ""},
		{"exact SAN", store(entry("x.test", "a.example.com")), "a.example.com", "x.test", "a.example.com", false, " (as a SAN of x.test)"},
		{"wildcard main", store(wildMain), "a.example.com", "*.example.com", "*.example.com", true, " (by the wildcard *.example.com)"},
		{"wildcard SAN", store(wildSAN), "acme.tenants.example.com", "tenants.example.com", "*.tenants.example.com", true, " (by the wildcard *.tenants.example.com, a SAN of tenants.example.com)"},
		{"the wildcard entry's own main", store(wildSAN), "tenants.example.com", "tenants.example.com", "tenants.example.com", false, ""},
		{"deeper label", store(wildMain), "a.b.example.com", "", "", false, ""},
		{"apex", store(wildMain), "example.com", "", "", false, ""},
		{"empty label", store(wildMain), ".example.com", "", "", false, ""},
		{"suffix not on a label boundary", store(wildMain), "aexample.com", "", "", false, ""},
		{"a bare *.", store(entry("*.")), "a.", "", "", false, ""},
		{"mixed case exact", store(entry("A.Example.COM")), "a.example.com", "A.Example.COM", "A.Example.COM", false, ""},
		{"mixed case wildcard", store(entry("*.Example.com")), "App.EXAMPLE.com", "*.Example.com", "*.Example.com", true, " (by the wildcard *.Example.com)"},
		{"CR stripped", store(entry(`*.example.com\r`)), "a.example.com", "*.example.com", "*.example.com", true, " (by the wildcard *.example.com)"},
		{"exact preferred over an earlier wildcard", store(wildMain, entry("x.test", "a.example.com")), "a.example.com", "x.test", "a.example.com", false, " (as a SAN of x.test)"},
		{"a * inside the first label", store(entry("*foo.example.com")), "afoo.example.com", "", "", false, ""},
		{"a * in a later label", store(entry("a.*.example.com")), "a.b.example.com", "", "", false, ""},
		{"a bare *", store(entry("*")), "a", "", "", false, ""},
		{"a wildcard host matches its own name exactly", store(wildMain), "*.example.com", "*.example.com", "*.example.com", false, ""},
		{"a trailing dot is not stripped", store(wildMain, entry("a.example.com")), "a.example.com.", "", "", false, ""},
		{"exact SAN preferred over a wildcard main", store(entry("*.example.com", "a.example.com")), "a.example.com", "*.example.com", "a.example.com", false, " (as a SAN of *.example.com)"},
		{"first wildcard entry wins", store(entry("one.test", "*.example.com"), wildMain), "a.example.com", "one.test", "*.example.com", true, " (by the wildcard *.example.com, a SAN of one.test)"},
	} {
		l := Find(tc.store, tc.host, time.Now())
		want := "nocert"
		if tc.main == "" {
			want = "nomatch"
		}
		if l.State != want || l.Main != tc.main || l.Name != tc.match || l.Wildcard != tc.wild || l.Via() != tc.via {
			t.Errorf("%s: %+v via %q, want %s main %q name %q wildcard %v via %q", tc.name, l, l.Via(), want, tc.main, tc.match, tc.wild, tc.via)
		}
	}
}
