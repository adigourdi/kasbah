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
	l := Find([]byte(`{"letsencrypt":{"Certificates":[{"domain":{"main":"x"},"certificate":"`+b+`"}]}}`), "x", at.Add(time.Hour))
	if l.NotAfter != "Mar  1 12:00:00 2024 GMT" || !l.Expired || l.Days != 0 {
		t.Errorf("got %+v; an hour past notAfter is expired, 0 days ago, printed as openssl prints it", l)
	}
}

func TestFind(t *testing.T) {
	now := time.Unix(2000000000, 0)
	p := cert(t, pkix.RDNSequence{{atv(oCN, "demo.test")}}, now.Add(20*24*time.Hour+time.Minute))
	b := base64.StdEncoding.EncodeToString(p)
	store := `{"letsencrypt":{"Certificates":[{"domain":{"main":"a.test","sans":[5,"demo.test"]},"certificate":"` + b + `"}]}}`
	l := Find([]byte(store), "demo.test", now)
	if l.State != "found" || l.Main != "a.test" || l.Days != 20 || l.Count != 1 || l.Issuer != "CN = demo.test" {
		t.Errorf("got %+v", l)
	}
	expired := base64.StdEncoding.EncodeToString(cert(t, pkix.RDNSequence{{atv(oCN, "x")}}, now.Add(-36*time.Hour)))
	if l := Find([]byte(`{"letsencrypt":{"Certificates":[{"domain":{"main":"x"},"certificate":"`+expired+`"}]}}`), "x", now); !l.Expired || l.Days != 1 {
		t.Errorf("an expired certificate's days: %+v", l)
	}
	for body, want := range map[string]string{
		"":                                   "notjson",
		"{} {}":                              "notjson",
		"[1]":                                "notjson",
		`{"x":1}`:                            "noresolver",
		`{"letsencrypt":"x"}`:                "notjson",
		`{"letsencrypt":null}`:               "empty",
		`{"letsencrypt":{"Certificates":5}}`: "notarray",
		`{"letsencrypt":{"Certificates":[1,{"domain":{"main":"y"}}]}}`:                "nomatch",
		`{"letsencrypt":{"Certificates":[{"domain":{"main":"x"},"certificate":""}]}}`: "nocert",
	} {
		if l := Find([]byte(body), "x", now); l.State != want {
			t.Errorf("%s: %s, want %s", body, l.State, want)
		}
	}
}
