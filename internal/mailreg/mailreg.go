// Package mailreg is the one reader of <apps>/mail/kasbah.yml (docs/mail.md):
// a registry with no primary_domain is refused, naming file and key (D4).
package mailreg

import (
	"errors"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// Path is the registry under an apps path.
func Path(apps string) string { return apps + "/mail/kasbah.yml" }

// Registry is what the file says. Domains leads with the primary, which the
// stack serves whether or not anyone listed it.
type Registry struct {
	Primary string
	Domains []string
}

// Serves is whether the stack accepts mail for d.
func (r *Registry) Serves(d string) bool {
	for _, x := range r.Domains {
		if x == d {
			return true
		}
	}
	return false
}

// ErrUnparseable marks a file that is not YAML at all, as distinct from one
// that parses and says something kasbah refuses.
var ErrUnparseable = errors.New("not YAML")

type unparseable struct{ e *cli.Error }

func (u unparseable) Error() string   { return u.e.Error() }
func (u unparseable) Unwrap() []error { return []error{u.e, ErrUnparseable} }

// Parse reads the registry's bytes; where names the file in messages (e.g.
// "/apps/mail/kasbah.yml on deploy@vps").
func Parse(data []byte, where string) (*Registry, error) {
	if len(strings.TrimSpace(string(data))) == 0 {
		return nil, cli.Fail("%s is missing or empty", where).Cont(
			"that file is the mail stack's registry — the one thing that says which",
			"domains this server's mail handles")
	}
	docs, err := yamlx.Load(data)
	if err != nil || len(docs) > 1 {
		return nil, unparseable{cli.Fail("%s could not be read as YAML", where)}
	}
	var doc tree.Value
	if len(docs) == 1 {
		doc = docs[0]
	}
	if _, ok := doc.(*tree.Map); !ok {
		return nil, unparseable{cli.Fail("%s could not be read as YAML", where)}
	}
	str := func(v tree.Value) string {
		if v == nil {
			return ""
		}
		return strings.TrimSuffix(tree.Text(v), "\r")
	}
	pv, _ := tree.Lookup(doc, "primary_domain")
	r := &Registry{Primary: str(pv)}
	if r.Primary == "" {
		return nil, cli.Fail("%s has no primary_domain: — it is the MX target and the name both certificates are issued for, and nothing here can invent it", where).Cont(
			"add it to that file:  primary_domain: <domain>")
	}
	if !initproject.IsFQDN(r.Primary) {
		return nil, cli.Fail("%s has primary_domain: '%s', which is not a domain name", where, r.Primary)
	}
	r.Domains = []string{r.Primary}
	dv, _ := tree.Lookup(doc, "domains")
	switch l := dv.(type) {
	case nil:
	case []tree.Value:
		for _, v := range l {
			d := str(v)
			if d == "" {
				continue
			}
			if !initproject.IsFQDN(d) {
				return nil, cli.Fail("%s lists '%s' under domains:, which is not a domain name", where, d)
			}
			if d != r.Primary {
				r.Domains = append(r.Domains, d)
			}
		}
	default:
		return nil, cli.Fail("%s has a domains: that is not a list", where)
	}
	return r, nil
}
