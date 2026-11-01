package acme

import (
	"bytes"
	"regexp"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// Route is one http router of a fragment as certificates concern it: the
// hosts its rule names in a plain Host(), whether its entrypoints are exactly
// [web], and whether it carries a tls key.
type Route struct {
	Name    string
	Hosts   []string
	WebOnly bool
	TLS     bool
}

// One Host() with a backtick or double-quoted literal; a match carrying a
// leading ! is a negation, which names nothing.
var reHost = regexp.MustCompile("(!\\s*)?\\bHost\\s*\\(\\s*(?:`([^`]*)`|\"([^\"\\\\]*)\")\\s*\\)")

// Routes is every router under the tree's http.routers, in file order; none
// when that is not a mapping.
func Routes(root tree.Value) []Route {
	rv, _ := tree.Lookup(root, "http", "routers")
	m, _ := rv.(*tree.Map)
	if m == nil {
		return nil
	}
	var out []Route
	for _, k := range m.Keys() {
		v, _ := m.Get(k)
		r := Route{Name: k}
		rule, _ := tree.Lookup(v, "rule")
		s, _ := rule.(string)
		for _, sm := range reHost.FindAllStringSubmatch(s, -1) {
			if sm[1] == "" && sm[2]+sm[3] != "" {
				r.Hosts = append(r.Hosts, sm[2]+sm[3])
			}
		}
		eps, _ := tree.Lookup(v, "entryPoints")
		l, _ := eps.([]tree.Value)
		r.WebOnly = len(l) > 0
		for _, e := range l {
			s, _ := e.(string)
			r.WebOnly = r.WebOnly && s == "web"
		}
		_, r.TLS = tree.Lookup(v, "tls")
		out = append(out, r)
	}
	return out
}

// Hosts is every host the routes name, each once, in router order.
func Hosts(routes []Route) []string {
	var out []string
	for _, r := range routes {
		for _, h := range r.Hosts {
			if !slices.Contains(out, h) {
				out = append(out, h)
			}
		}
	}
	return out
}

// Names is whether the route's rule names host, compared case-insensitively.
func (r Route) Names(host string) bool {
	return slices.ContainsFunc(r.Hosts, func(h string) bool { return strings.EqualFold(h, host) })
}

// Secure is whether the route could serve HTTPS: anything but entrypoints of
// exactly [web] (the one entrypoint without TLS) and no tls key.
func (r Route) Secure() bool {
	return r.TLS || !r.WebOnly
}

// HTTPS is whether something in the fragment could serve HTTPS or issue a
// certificate: a top-level key other than http, or a Secure http router.
func HTTPS(root tree.Value) bool {
	if m, ok := root.(*tree.Map); ok && slices.ContainsFunc(m.Keys(), func(k string) bool { return k != "http" }) {
		return true
	}
	return slices.ContainsFunc(Routes(root), Route.Secure)
}

// PlainHTTP is whether Traefik serves host over plain HTTP only, and so never
// issues it a certificate: the fragment reads as Traefik reads it, no router
// in it could serve HTTPS, and an http router names host.
func PlainHTTP(raw []byte, root tree.Value, host string) bool {
	return !uncertain(raw, root) && !HTTPS(root) &&
		slices.ContainsFunc(Routes(root), func(r Route) bool { return r.Names(host) })
}

// The keys a router's HTTPS turns on; Traefik matches them case-insensitively.
var tlsKeys = []string{"routers", "entryPoints", "tls"}

// uncertain is whether Traefik may read the fragment otherwise than kasbah: it
// renders a file as a Go template first, refuses a duplicate key (keeping its
// last good configuration live), and matches keys case-insensitively.
func uncertain(raw []byte, root tree.Value) bool {
	return bytes.Contains(raw, []byte("{{")) || !yamlx.Strict(raw) || foldedKey(root)
}

func foldedKey(v tree.Value) bool {
	switch x := v.(type) {
	case *tree.Map:
		for _, k := range x.Keys() {
			if slices.ContainsFunc(tlsKeys, func(c string) bool { return k != c && strings.EqualFold(k, c) }) {
				return true
			}
			if c, _ := x.Get(k); foldedKey(c) {
				return true
			}
		}
	case []tree.Value:
		return slices.ContainsFunc(x, foldedKey)
	}
	return false
}
