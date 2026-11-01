package acme

import (
	"testing"

	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

func fragment(t *testing.T, y string) tree.Value {
	t.Helper()
	docs, err := yamlx.Load([]byte(y))
	if err != nil {
		t.Fatal(err)
	}
	return docs[0]
}

func plain(t *testing.T, y, host string) bool {
	t.Helper()
	return PlainHTTP([]byte(y), fragment(t, y), host)
}

func TestPlainHTTP(t *testing.T) {
	const web = "http:\n  routers:\n" +
		"    w: {rule: \"Host(`d.test`) && PathPrefix(`/x`)\", entryPoints: [web]}\n" +
		"    m: {rule: \"Host(`Mixed.Test`)\", entryPoints: [web]}\n"
	for host, want := range map[string]bool{"d.test": true, "mixed.test": true, "x.test": false, "d.test.": false} {
		if got := plain(t, web, host); got != want {
			t.Errorf("web only, %s: %v, want %v", host, got, want)
		}
	}
	// Any router that could serve HTTPS, whatever host it names, sends every
	// host of the fragment to the certificate lookup.
	for name, extra := range map[string]string{
		"websecure":      "    s: {rule: \"Host(`x.test`)\", entryPoints: [websecure]}\n",
		"websecure, web": "    s: {rule: \"Host(`x.test`)\", entryPoints: [web, websecure]}\n",
		"no entryPoints": "    s: {rule: \"Host(`x.test`)\"}\n",
		"empty list":     "    s: {rule: \"Host(`x.test`)\", entryPoints: []}\n",
		"not a list":     "    s: {rule: \"Host(`x.test`)\", entryPoints: web}\n",
		"tls on web":     "    s: {rule: \"Host(`x.test`)\", entryPoints: [web], tls: {}}\n",
		"bare tls key":   "    s: {rule: \"Host(`x.test`)\", entryPoints: [web], tls: }\n",
		"router scalar":  "    s: x\n",
		"router null":    "    s:\n",
		"tcp router":     "tcp:\n  routers:\n    t: {rule: \"HostSNI(`d.test`)\", entryPoints: [web], tls: {}}\n",
		"tcp not a map":  "tcp:\n  routers: [x]\n",
		// Traefik matches keys case-insensitively and renders the file as a
		// Go template first; either way kasbah may not read it as Traefik does.
		"TLS key":         "    s: {rule: \"Host(`x.test`)\", entryPoints: [web], TLS: {}}\n",
		"Tls key":         "    s: {rule: \"Host(`x.test`)\", entryPoints: [web], Tls: {certResolver: http}}\n",
		"long-s tls key":  "    s: {rule: \"Host(`x.test`)\", entryPoints: [web], tl\u017f: {}}\n",
		"EntryPoints key": "    s: {rule: \"Host(`x.test`)\", entryPoints: [web], EntryPoints: [websecure]}\n",
		"TCP top level":   "TCP:\n  routers:\n    t: {rule: \"HostSNI(`d.test`)\", entryPoints: [websecure], tls: {}}\n",
		"tcp Routers":     "tcp:\n  Routers:\n    t: {rule: \"HostSNI(`d.test`)\", entryPoints: [websecure], tls: {}}\n",
		"templated":       "# {{ print \"x\" }}\n",
		// Traefik trims entrypoint names and splits them on U+2551; only an
		// exact [web] is taken as plain.
		"padded websecure": "    s: {rule: \"Host(`x.test`)\", entryPoints: [web, \" websecure\"]}\n",
		"tab websecure":    "    s: {rule: \"Host(`x.test`)\", entryPoints: [\"websecure\\t\"]}\n",
		"joined":           "    s: {rule: \"Host(`x.test`)\", entryPoints: [\"web\u2551websecure\"]}\n",
		"padded web":       "    s: {rule: \"Host(`x.test`)\", entryPoints: [\" web\"]}\n",
		"non-string":       "    s: {rule: \"Host(`x.test`)\", entryPoints: [web, 1]}\n",
		// Anything beside http — tcp, udp, tls stores — is not read as plain.
		"empty tcp routers": "tcp:\n  routers: {}\n",
		"udp router":        "udp:\n  routers:\n    u: {entryPoints: [dns], service: s}\n",
		"duplicate router":  "    w: {rule: \"Host(`d.test`)\", entryPoints: [web]}\n",
		"generated cert":    "tls:\n  stores:\n    default:\n      defaultGeneratedCert: {resolver: http, domain: {main: d.test}}\n",
	} {
		if plain(t, web+extra, "d.test") {
			t.Errorf("%s: plain HTTP, but the fragment could serve HTTPS", name)
		}
	}
	for name, y := range map[string]string{
		"routers a list":  "http:\n  routers: [{rule: \"Host(`d.test`)\", entryPoints: [web]}]\n",
		"no routers":      "http:\n  services: {}\n",
		"no host matcher": "http:\n  routers:\n    w: {rule: \"PathPrefix(`/`)\", entryPoints: [web]}\n",
		"regexp only":     "http:\n  routers:\n    w: {rule: \"HostRegexp(`^d\\\\.test$`)\", entryPoints: [web]}\n",
		"negated":         "http:\n  routers:\n    w: {rule: \"!Host(`d.test`)\", entryPoints: [web]}\n",
	} {
		if plain(t, y, "d.test") {
			t.Errorf("%s: plain HTTP", name)
		}
	}
	if !plain(t, web+"  services: {s: {loadBalancer: {servers: [{url: \"http://a\"}]}}}\n", "d.test") {
		t.Errorf("services beside the routers: not plain HTTP")
	}
}

func TestRoutesHosts(t *testing.T) {
	r := Routes(fragment(t, "http:\n  routers:\n"+
		"    a: {rule: \"Host(`a.test`) || Host( \\\"b.test\\\" ) || !Host(`c.test`) || Host(``)\"}\n"+
		"    b: {rule: \"Host(`b.test`) && HostRegexp(`^r\\\\.test$`)\", entryPoints: [web]}\n"))
	if got := Hosts(r); len(got) != 2 || got[0] != "a.test" || got[1] != "b.test" {
		t.Errorf("hosts %q, want [a.test b.test]", got)
	}
	if r[0].Name != "a" || !r[0].Secure() || r[1].Secure() || !r[1].Names("B.TEST") {
		t.Errorf("routes %+v", r)
	}
}

func TestResolverFor(t *testing.T) {
	docs, err := yamlx.Load([]byte("http:\n  routers:\n    a: {rule: \"Host(`a.example.com`)\", tls: {certResolver: cloudflare}}\n" +
		"    b: {rule: \"Host(`b.example.com`)\", tls: {}}\n    c: {rule: \"Host(`a.example.com`)\", tls: {certResolver: http}}\n" +
		"tcp:\n  routers:\n    t: {tls: {certResolver: ovh}}\n"))
	if err != nil {
		t.Fatal(err)
	}
	routes := Routes(docs[0])
	for host, want := range map[string]string{"A.example.com": "cloudflare", "b.example.com": Resolver, "z.example.com": Resolver} {
		if got := ResolverFor(routes, host); got != want {
			t.Errorf("ResolverFor(%s) = %s, want %s", host, got, want)
		}
	}
}
