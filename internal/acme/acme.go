// Package acme reads Traefik's certificate store, acme.json, for the one
// thing kasbah reports out of it: which certificate covers a hostname, its
// issuer and its expiry — and, from a fragment's routers, whether a hostname
// is expected to have one. It never returns a key, and reports no age —
// Let's Encrypt backdates notBefore by about an hour.
package acme

import (
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/asn1"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/tree"
)

// Resolver is the certresolver kasbah configures, a frozen contract.
const Resolver = "http"

// Lookup is what the store says about one hostname. State is one of notjson,
// noresolver, empty, notarray (Kind is the type found), nomatch, nocert,
// notbase64, nopem or found.
type Lookup struct {
	State, Kind string
	// Count is the certificates in the store, whatever the verdict.
	Count            int
	Main             string
	Issuer, NotAfter string
	// Expired is notAfter in the past; Days is whole days since it then,
	// whole days until it otherwise.
	Expired bool
	Days    int64
}

// Find looks domain up in the store's content, judging expiry against now.
// An entry matches on its main domain or any of its SANs.
func Find(content []byte, domain string, now time.Time) Lookup {
	var l Lookup
	vals, err := tree.Parse(content)
	if err != nil || len(vals) != 1 {
		l.State = "notjson"
		return l
	}
	top, ok := vals[0].(*tree.Map)
	if !ok {
		l.State = "notjson"
		return l
	}
	if !top.Has(Resolver) {
		l.State = "noresolver"
		return l
	}
	var certs tree.Value
	switch r, _ := top.Get(Resolver); r := r.(type) {
	case nil:
	case *tree.Map:
		certs, _ = r.Get("Certificates")
	default:
		l.State = "notjson"
		return l
	}
	list, isList := certs.([]tree.Value)
	switch {
	case certs == nil:
		l.State = "empty"
		return l
	case !isList:
		l.State, l.Kind = "notarray", tree.Kind(certs)
		return l
	}
	l.Count = len(list)
	if l.Count == 0 {
		l.State = "empty"
		return l
	}
	found := -1
	for i, c := range list {
		mv, _ := tree.Lookup(c, "domain", "main")
		main, _ := tree.String(mv)
		main = strings.TrimSuffix(main, "\r")
		if main == domain || sansMatch(c, domain) {
			found, l.Main = i, main
			break
		}
	}
	if found < 0 {
		l.State = "nomatch"
		return l
	}
	cv, _ := tree.Lookup(list[found], "certificate")
	b64, _ := tree.String(cv)
	b64 = strings.TrimSuffix(b64, "\r")
	if b64 == "" {
		l.State = "nocert"
		return l
	}
	pemBytes, err := base64.StdEncoding.DecodeString(strings.Join(strings.Fields(b64), ""))
	if err != nil || len(pemBytes) == 0 {
		l.State = "notbase64"
		return l
	}
	cert := firstCert(pemBytes)
	if cert == nil {
		l.State = "nopem"
		return l
	}
	l.State = "found"
	l.Issuer = Issuer(cert.RawIssuer)
	l.NotAfter = cert.NotAfter.UTC().Format("Jan _2 15:04:05 2006 GMT")
	l.Expired = cert.NotAfter.Before(now)
	if l.Expired {
		l.Days = (now.Unix() - cert.NotAfter.Unix()) / 86400
	} else {
		l.Days = (cert.NotAfter.Unix() - now.Unix()) / 86400
	}
	return l
}

func sansMatch(c tree.Value, domain string) bool {
	sv, _ := tree.Lookup(c, "domain", "sans")
	sans, _ := sv.([]tree.Value)
	for _, s := range sans {
		if s, ok := s.(string); ok && strings.TrimSuffix(s, "\r") == domain {
			return true
		}
	}
	return false
}

// firstCert is the first certificate block `openssl x509` would read.
func firstCert(data []byte) *x509.Certificate {
	for {
		var b *pem.Block
		b, data = pem.Decode(data)
		if b == nil {
			return nil
		}
		switch b.Type {
		case "CERTIFICATE", "X509 CERTIFICATE", "TRUSTED CERTIFICATE":
			c, err := x509.ParseCertificate(b.Bytes)
			if err != nil {
				return nil
			}
			return c
		}
	}
}

// shortNames is OpenSSL's short name for each attribute a DN carries; an OID
// it has none for prints dotted.
var shortNames = map[string]string{
	"2.5.4.3": "CN", "2.5.4.4": "SN", "2.5.4.5": "serialNumber", "2.5.4.6": "C",
	"2.5.4.7": "L", "2.5.4.8": "ST", "2.5.4.9": "street", "2.5.4.10": "O",
	"2.5.4.11": "OU", "2.5.4.12": "title", "2.5.4.13": "description",
	"2.5.4.14": "searchGuide", "2.5.4.15": "businessCategory", "2.5.4.16": "postalAddress",
	"2.5.4.17": "postalCode", "2.5.4.18": "postOfficeBox", "2.5.4.19": "physicalDeliveryOfficeName",
	"2.5.4.20": "telephoneNumber", "2.5.4.41": "name", "2.5.4.42": "GN",
	"2.5.4.43": "initials", "2.5.4.44": "generationQualifier", "2.5.4.45": "x500UniqueIdentifier",
	"2.5.4.46": "dnQualifier", "2.5.4.51": "houseIdentifier", "2.5.4.65": "pseudonym",
	"2.5.4.72": "role", "2.5.4.97": "organizationIdentifier",
	"1.2.840.113549.1.9.1": "emailAddress", "1.2.840.113549.1.9.2": "unstructuredName",
	"1.2.840.113549.1.9.8":      "unstructuredAddress",
	"0.9.2342.19200300.100.1.1": "UID", "0.9.2342.19200300.100.1.25": "DC",
	"1.3.6.1.4.1.311.60.2.1.1": "jurisdictionL", "1.3.6.1.4.1.311.60.2.1.2": "jurisdictionST",
	"1.3.6.1.4.1.311.60.2.1.3": "jurisdictionC",
}

// Issuer is a DN as OpenSSL 3.0's `openssl x509 -issuer` prints it:
// `C = US, O = Let's Encrypt, CN = R3`.
func Issuer(raw []byte) string {
	var seq pkix.RDNSequence
	if rest, err := asn1.Unmarshal(raw, &seq); err != nil || len(rest) != 0 {
		return ""
	}
	var rdns []string
	for _, rdn := range seq {
		var avas []string
		for _, ava := range rdn {
			name, ok := shortNames[ava.Type.String()]
			if !ok {
				name = ava.Type.String()
			}
			avas = append(avas, name+" = "+escape(fmt.Sprint(ava.Value)))
		}
		rdns = append(rdns, strings.Join(avas, " + "))
	}
	return strings.Join(rdns, ", ")
}

// escape is RFC 2253 escaping with quoting (ESC_QUOTE): `"` and `\` take a
// backslash, the other specials quote the whole value, and control or
// non-ASCII bytes are \XX.
func escape(v string) string {
	var b strings.Builder
	quote := false
	for i := 0; i < len(v); i++ {
		c := v[i]
		switch {
		case c == '"' || c == '\\':
			b.WriteByte('\\')
			b.WriteByte(c)
		case strings.IndexByte(",+<>;", c) >= 0,
			i == 0 && (c == '#' || c == ' '),
			i == len(v)-1 && c == ' ':
			quote = true
			b.WriteByte(c)
		case c < 0x20 || c >= 0x7f:
			fmt.Fprintf(&b, "\\%02X", c)
		default:
			b.WriteByte(c)
		}
	}
	if quote {
		return `"` + b.String() + `"`
	}
	return b.String()
}
