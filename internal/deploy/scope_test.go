package deploy

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const scopeModel = `{"networks":{"kasbah":{"name":"shop_kasbah"},"internal":{"name":"shop_internal"}},
"services":{
 "web":{"networks":{"kasbah":{"aliases":["www"]},"internal":null}},
 "api":{"container_name":"shop-api","networks":{"kasbah":null}},
 "db":{"container_name":"shop-db","networks":{"internal":null}}}}`

func shopScope(model string) scoping {
	return scoping{"shop", "prod", "deploy", func() (*composeModel, error) {
		return readModel("shop", func(...string) (string, error) { return model, nil })
	}}
}

func scopeOf(t *testing.T, text string) (string, error) {
	t.Helper()
	out, err := scopeFragment([]byte(text), []byte(text), shopScope(scopeModel))
	return string(out), err
}

// Every backend host gains the project network and every other byte stays.
func TestScopeFragmentQualifies(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: \"http://web:80\"\n",
			"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: \"http://web.shop_kasbah:80\"\n"},
		{"# http://web:80 in a comment\nhttp:\r\n  services:\r\n    s:\r\n      loadBalancer:\r\n        servers:\r\n          - url: 'https://www/a/b?c=1'  # web\r\n          - {url: http://shop-api}\r\n",
			"# http://web:80 in a comment\nhttp:\r\n  services:\r\n    s:\r\n      loadBalancer:\r\n        servers:\r\n          - url: 'https://www.shop_kasbah/a/b?c=1'  # web\r\n          - {url: http://shop-api.shop_kasbah}\r\n"},
		{"x: &u http://web:8080\nhttp:\n  services:\n    a:\n      loadBalancer:\n        servers: [{url: *u}]\n    b:\n      loadBalancer:\n        servers:\n          - url: |-\n              http://api:9000\n",
			"x: &u http://web.shop_kasbah:8080\nhttp:\n  services:\n    a:\n      loadBalancer:\n        servers: [{url: *u}]\n    b:\n      loadBalancer:\n        servers:\n          - url: |-\n              http://api.shop_kasbah:9000\n"},
		{"tcp:\n  services:\n    pg:\n      loadBalancer:\n        servers:\n          - address: \"web:5432\"\nudp:\n  services:\n    dns:\n      loadBalancer:\n        servers:\n          - address: api:53\n",
			"tcp:\n  services:\n    pg:\n      loadBalancer:\n        servers:\n          - address: \"web.shop_kasbah:5432\"\nudp:\n  services:\n    dns:\n      loadBalancer:\n        servers:\n          - address: api.shop_kasbah:53\n"},
		{"lb: &lb\n  servers:\n    - url: http://web\nhttp:\n  services:\n    s:\n      loadBalancer:\n        <<: *lb\n",
			"lb: &lb\n  servers:\n    - url: http://web.shop_kasbah\nhttp:\n  services:\n    s:\n      loadBalancer:\n        <<: *lb\n"},
		// Matched in any case, as DNS does, and spelled as written.
		{"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: http://WEB:80/\n          - url: http://Shop-Api\n",
			"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: http://WEB.shop_kasbah:80/\n          - url: http://Shop-Api.shop_kasbah\n"},
		// A byte-order mark before a one-line fragment.
		{"\uFEFFhttp: {services: {s: {loadBalancer: {servers: [{url: \"http://web:80\"}]}}}}\n",
			"\uFEFFhttp: {services: {s: {loadBalancer: {servers: [{url: \"http://web.shop_kasbah:80\"}]}}}}\n"},
		// A block scalar that strips its closing line break.
		{"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: >-\n              http://web\n",
			"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: >-\n              http://web.shop_kasbah\n"},
		{"tcp:\n  services:\n    t:\n      loadBalancer:\n        servers:\n          - address: web\n",
			"tcp:\n  services:\n    t:\n      loadBalancer:\n        servers:\n          - address: web.shop_kasbah\n"},
	} {
		if got, err := scopeOf(t, tc.in); err != nil || got != tc.want {
			t.Errorf("%q:\n got %q %v\nwant %q", tc.in, got, err, tc.want)
		}
	}
	// No backend reads no model.
	for _, in := range []string{"", "# empty\n", authFrag, "http:\n  services:\n    s:\n      loadBalancer:\n        servers: []\n"} {
		out, err := scopeFragment([]byte(in), []byte(in), scoping{"shop", "", "deploy", func() (*composeModel, error) { t.Fatal("read the model"); return nil, nil }})
		if err != nil || string(out) != in {
			t.Errorf("%q: %q %v", in, out, err)
		}
	}
}

// A host that is not the project's own name on its kasbah network is refused,
// named, with the names it could have meant.
func TestScopeFragmentRefuses(t *testing.T) {
	frag := func(url string) string {
		return "http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: \"" + url + "\"\n"
	}
	for url, want := range map[string]string{
		"http://admin:80":            `url's host "admin" is not a name of this project on its kasbah network (shop_kasbah)`,
		"http://shop-db:5432":        `url's host "shop-db" is not a name of this project`,
		"http://10.0.0.5:80":         `url's host "10.0.0.5" is an IP address`,
		"http://[::1]:80":            `url's host "[::1]" is an IP address`,
		"https://example.com/":       `url's host "example.com" is a qualified name`,
		"http://web.other_kasbah:80": `url's host "web.other_kasbah" is a qualified name — name the service alone, and the deploy scopes it to shop_kasbah`,
		"http://web.shop_kasbah:80":  `url's host "web.shop_kasbah" is a qualified name`,
		"http://":                    `url's host "" names no host`,
		"http://w%65b:80":            "url is not a URL as Traefik reads it",
		"http://web!x:80":            `url's host "web!x" is not a host name`,
		"web:80":                     `url is not a URL as Traefik reads it`,
		"\\thttp://web:80":           `url holds a control character`,
		// Traefik dials what follows the @, never the name before it.
		"http://web:pw@10.0.0.5:80":       `url names a user or password before its host (…@), and Traefik dials what follows the @`,
		"http://web:80@evil.example.com/": `url names a user or password before its host`,
		"http://web@shop-api":             `url names a user or password before its host`,
	} {
		_, err := scopeOf(t, frag(url))
		if err == nil || !strings.Contains(err.Error(), "http.services.s.loadBalancer.servers[0]."+want) ||
			!strings.Contains(err.Error(), "one of this project's own names there: api, shop-api (api's container_name), web, www (a kasbah alias of web) (kasbah help T07)") {
			t.Errorf("%s: %v", url, err)
		}
		if err != nil && (strings.Contains(err.Error(), "pw") || strings.Contains(err.Error(), "evil")) {
			t.Errorf("%s: quotes the userinfo: %v", url, err)
		}
	}
	for addr, want := range map[string]string{"other:5432": `address's host "other" is not a name`, "::1": `address's host "::1" is an IP address`, "[::1]:53": `address's host "[::1]" is an IP address`, "web@x:53": `address's host "web@x" is not a host name`, "web:5:3": "address is not a host:port address"} {
		if _, err := scopeOf(t, "tcp:\n  services:\n    t:\n      loadBalancer:\n        servers:\n          - address: \""+addr+"\"\n"); err == nil ||
			!strings.Contains(err.Error(), "tcp.services.t.loadBalancer.servers[0]."+want) {
			t.Errorf("%s: %v", addr, err)
		}
	}
	// An anchor a backend shares with another field is not rewritten there.
	shared := "x: &u http://web:80\nhttp:\n  middlewares:\n    r:\n      redirectRegex:\n        regex: ^x\n        replacement: *u\n  services:\n    s:\n      loadBalancer:\n        servers: [{url: *u}]\n"
	if _, err := scopeOf(t, shared); err == nil || !strings.Contains(err.Error(), "servers[0].url is anchor &u, also used outside a backend") {
		t.Errorf("shared anchor: %v", err)
	}
	// A service name written as the url's alias is a use outside the backend.
	if _, err := scopeOf(t, "x: &u http://web:80\nhttp:\n  services:\n    *u :\n      loadBalancer:\n        servers: [{url: *u}]\n"); err == nil || !strings.Contains(err.Error(), "servers[0].url is anchor &u, also used outside a backend") {
		t.Errorf("service-name alias: %v", err)
	}
	// So is one inside an anchored mapping or sequence aliased outside a backend.
	for _, tc := range []struct{ name, in, anchor string }{
		{"&srv", "x: &srv {url: \"http://web:80\"}\nhttp:\n  middlewares:\n    p:\n      plugin:\n        p: *srv\n  services:\n    s:\n      loadBalancer:\n        servers: [*srv]\n", "&srv"},
		{"merge", "x: &srv {url: \"http://web:80\"}\nhttp:\n  middlewares:\n    p:\n      plugin:\n        p: {<<: *srv}\n  services:\n    s:\n      loadBalancer:\n        servers: [*srv]\n", "&srv"},
		{"&ss", "http:\n  services:\n    s:\n      loadBalancer:\n        servers: &ss [{url: \"http://web:80\"}]\n  middlewares:\n    p:\n      plugin:\n        p: *ss\n", "&ss"},
		// Or one holding an alias the backend is read through.
		{"&ss of *srv", "x: &srv {url: \"http://web:80\"}\nhttp: {services: {s: {loadBalancer: {servers: &ss [*srv]}}}, middlewares: {p: {plugin: {p: *ss}}}}\n", "&ss"},
		{"&ss of *u", "x: &u http://web:80\nhttp: {services: {s: {loadBalancer: {servers: &ss [{url: *u}]}}}, middlewares: {p: {plugin: {p: *ss}}}}\n", "&ss"},
		{"&lb of *srv", "x: &srv {url: \"http://web:80\"}\nlb: &lb {servers: [*srv]}\nhttp: {services: {s: {loadBalancer: *lb}}, middlewares: {p: {plugin: {p: *lb}}}}\n", "&lb"},
	} {
		if _, err := scopeOf(t, tc.in); err == nil || !strings.Contains(err.Error(), "servers[0].url is inside anchor "+tc.anchor+", also used outside a backend, which scoping it would change too — write the URL out") {
			t.Errorf("%s: %v", tc.name, err)
		}
	}
	// Every alias of it a backend: scoped once, in place.
	if got, err := scopeOf(t, "x: &srv {url: \"http://web:80\"}\nhttp:\n  services:\n    s:\n      loadBalancer:\n        servers: [*srv]\n    t:\n      loadBalancer:\n        servers: [{<<: *srv}]\n"); err != nil || !strings.HasPrefix(got, "x: &srv {url: \"http://web.shop_kasbah:80\"}\n") {
		t.Errorf("backend-only anchor: %q %v", got, err)
	}
	// A block scalar that keeps its closing line break hands Traefik a dead URL.
	for _, ind := range []string{"|", ">", "|+", ">+"} {
		if _, err := scopeOf(t, "http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: "+ind+"\n              http://web\n"); err == nil ||
			!strings.Contains(err.Error(), "servers[0].url is a block scalar (| or >) that keeps its closing line break, which Traefik reads as part of the url — strip it with |- or >-, or write it on one line") {
			t.Errorf("%s: %v", ind, err)
		}
	}
	if _, err := scopeOf(t, "tcp:\n  services:\n    t:\n      loadBalancer:\n        servers:\n          - address: other:5432\n"); err == nil ||
		!strings.Contains(err.Error(), `tcp.services.t.loadBalancer.servers[0].address's host "other"`) {
		t.Errorf("tcp: %v", err)
	}
	// Nothing joined to the kasbah network: nothing is the project's there.
	_, err := scopeFragment([]byte(frag("http://web")), []byte(frag("http://web")), shopScope(`{"services":{"web":{"networks":{"kasbah-net":null}}}}`))
	if err == nil || !strings.Contains(err.Error(), "(shop_kasbah)") || !strings.Contains(err.Error(), "no service of this project joins it") {
		t.Errorf("unjoined: %v", err)
	}
	// An unread model refuses with its cause: never installed unscoped.
	_, err = scopeFragment([]byte(frag("http://web")), []byte(frag("http://web")), scoping{"shop", "", "rollback", func() (*composeModel, error) { return nil, errors.New("exit status 15: bad interpolation") }})
	if err == nil || !strings.Contains(err.Error(), "could not be read to tell they are this project's (exit status 15: bad interpolation) — fix what compose reports, then re-run the rollback;") || !strings.Contains(err.Error(), "never installed unscoped") {
		t.Errorf("model: %v", err)
	}
}

// A host a ${KEY} filled is refused naming the key and its line, never the
// value; a literal one is quoted.
func TestScopeFragmentNamesTheKey(t *testing.T) {
	frag := func(url string) string {
		return "http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: \"" + url + "\"\n"
	}
	for _, tc := range []struct{ tmpl, val, want, not string }{
		{"http://${BACKEND}:80", "http://admin:80", "url's host, filled from ${BACKEND} on line 6, is not a name of this project on its kasbah network (shop_kasbah)", `"admin"`},
		{"${UPSTREAM}", "https://token@host", "url, filled from ${UPSTREAM} on line 6, names a user or password before its host", "token"},
		{"http://web${SUFFIX}", "http://web.example.com:80", "url's host, filled from ${SUFFIX} on line 6, is a qualified name", "example"},
		{"http://admin:${PORT}", "http://admin:80", `url's host "admin" is not a name of this project`, "PORT"},
	} {
		_, err := scopeFragment([]byte(frag(tc.tmpl)), []byte(frag(tc.val)), shopScope(scopeModel))
		if err == nil || !strings.Contains(err.Error(), tc.want) || strings.Contains(err.Error(), tc.not) {
			t.Errorf("%s: %v", tc.tmpl, err)
		}
		if err != nil && tc.not != "PORT" && !strings.Contains(err.Error(), "`kasbah env set "+tc.tmpl[strings.Index(tc.tmpl, "${")+2:strings.Index(tc.tmpl, "}")]+" prod` sets another") {
			t.Errorf("%s: no next step: %v", tc.tmpl, err)
		}
	}
	// How the fragment is written is the fix, not another value.
	for _, tc := range []struct{ tmpl, val, want string }{
		{"http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: |\n              http://${BACKEND}\n", "http:\n  services:\n    s:\n      loadBalancer:\n        servers:\n          - url: |\n              http://admin\n",
			"url, filled from ${BACKEND} on line 6, is a block scalar (| or >) that keeps its closing line break"},
		{"x: &u http://${BACKEND}:80\nhttp: {services: {s: {loadBalancer: {servers: [{url: *u}]}}}, middlewares: {r: {redirectRegex: {regex: ^x, replacement: *u}}}}\n", "x: &u http://admin:80\nhttp: {services: {s: {loadBalancer: {servers: [{url: *u}]}}}, middlewares: {r: {redirectRegex: {regex: ^x, replacement: *u}}}}\n",
			"url, filled from ${BACKEND} on line 1, is anchor &u, also used outside a backend"},
	} {
		_, err := scopeFragment([]byte(tc.tmpl), []byte(tc.val), shopScope(scopeModel))
		if err == nil || !strings.Contains(err.Error(), tc.want) || strings.Contains(err.Error(), "admin") || strings.Contains(err.Error(), "kasbah env set") {
			t.Errorf("%s: %v", tc.want, err)
		}
	}
}

// A dotted name on the kasbah network is refused, whosever it is.
func TestComposeModelDotted(t *testing.T) {
	m, _ := readModel("shop", func(...string) (string, error) {
		return `{"services":{"web":{"container_name":"web.shop","networks":{"kasbah":{"aliases":["www","web.other_kasbah"]}}},"api.v2":{"networks":{"kasbah":null}},"db.x":{"networks":{"internal":null}}}}`, nil
	})
	err := m.dotted("shop")
	if err == nil || err.Error() != "compose puts a name with a dot on this project's kasbah network (shop_kasbah) or kasbah-net: api.v2 (a service), web.other_kasbah (a kasbah alias of web), web.shop (web's container_name) — Docker answers a dotted name on every network Traefik is on, so it could answer for another project's backend; rename it without a dot, and the fragment's backend with it (kasbah help C16)" {
		t.Errorf("%v", err)
	}
	// Traefik is on kasbah-net too, joined by key or as a default network of that name.
	for model, want := range map[string]string{
		`{"services":{"web":{"networks":{"kasbah-net":{"aliases":["web.victim_kasbah"]}}}}}`:                                                                "kasbah-net: web.victim_kasbah (a kasbah-net alias of web) —",
		`{"networks":{"default":{"name":"kasbah-net"}},"services":{"web.victim_kasbah":{"networks":{"default":null}}}}`:                                     "kasbah-net: web.victim_kasbah (a service) —",
		`{"networks":{"shared":{"name":"kasbah-net"}},"services":{"web":{"container_name":"a.b","networks":{"shared":{"aliases":["web.victim_kasbah"]}}}}}`: "kasbah-net: web.victim_kasbah (a kasbah-net alias of web), a.b (web's container_name) —",
	} {
		m, _ := readModel("shop", func(...string) (string, error) { return model, nil })
		if err := m.dotted("shop"); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%s: %v", model, err)
		}
	}
	m, _ = readModel("shop", func(...string) (string, error) {
		return `{"networks":{"internal":{"name":"shop_internal"}},"services":{"db":{"container_name":"db.x","networks":{"internal":{"aliases":["a.b"]}}}}}`, nil
	})
	if err := m.dotted("shop"); err != nil {
		t.Errorf("off Traefik's networks: %v", err)
	}
	m, _ = readModel("shop", func(...string) (string, error) { return scopeModel, nil })
	if err := m.dotted("shop"); err != nil {
		t.Errorf("%v", err)
	}
}

func TestCauseLine(t *testing.T) {
	for in, want := range map[string]string{
		"time=\"x\" level=warning msg=\"a\"\r\nerror while interpolating: bad\nmore\n": "error while interpolating: bad",
		"level=warning msg=a\nlevel=warning msg=b\n":                                   "level=warning msg=b",
		"": "",
	} {
		if got := causeLine(in); got != want {
			t.Errorf("%q: %q", in, got)
		}
	}
}

func TestLiveHosts(t *testing.T) {
	got := liveHosts([]string{"web", "web.demo_kasbah", "www.demo_kasbah", "web.other_kasbah", "10.0.0.1", "example.com"}, "demo_kasbah")
	if strings.Join(got, " ") != "web web www" {
		t.Errorf("%q", got)
	}
}

const shopFrag = "http:\n  services:\n    demo:\n      loadBalancer:\n        servers:\n          - url: \"http://${BACKEND}:80\"\n"

// The arm installs the scoped fragment, ${KEY}s filled first; a foreign
// backend or an unread compose model leaves the live file as it was.
func TestFragmentArmScopes(t *testing.T) {
	apps, dir := renderDir(t, "BACKEND=\n", "BACKEND=web\n")
	bin := filepath.Join(t.TempDir(), "bin")
	os.MkdirAll(bin, 0o755)
	os.WriteFile(filepath.Join(bin, "docker"), []byte(dockerStub), 0o755)
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"networks":{"kasbah":{"name":"demo_kasbah"}},"services":{"web":{"networks":{"kasbah":null}}}}`), 0o644)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("LOG", filepath.Join(t.TempDir(), "log"))
	t.Setenv("CONFIG", cfg)
	dest := filepath.Join(apps, "traefik", "dynamic", "demo.yml")
	want := strings.Replace(shopFrag, "${BACKEND}", "web.demo_kasbah", 1)
	if rc, out, errs := fragmentArm(t, apps, []byte(shopFrag), false); rc != 0 || out != "fragment=written\n" {
		t.Fatalf("rc %d %q %q", rc, out, errs)
	}
	if b, _ := os.ReadFile(dest); string(b) != want {
		t.Fatalf("installed %q", b)
	}
	if rc, out, _ := fragmentArm(t, apps, []byte(shopFrag), false); rc != 0 || out != "fragment=unchanged\n" {
		t.Errorf("second run: rc %d %q", rc, out)
	}
	os.WriteFile(filepath.Join(dir, ".env"), []byte("BACKEND=admin\n"), 0o600)
	rc, out, errs := fragmentArm(t, apps, []byte(shopFrag), true)
	if b, _ := os.ReadFile(dest); rc != 1 || out != "" || string(b) != want || !strings.Contains(errs, "host, filled from ${BACKEND} on line 6, is not a name of this project") || strings.Contains(errs, "admin") ||
		!strings.Contains(errs, "one of this project's own names there: web (kasbah help T07)") || !strings.Contains(errs, dest+" was left as it was") {
		t.Errorf("foreign: rc %d %q %q, live %q", rc, out, errs, b)
	}
	os.WriteFile(filepath.Join(dir, ".env"), []byte("BACKEND=web\n"), 0o600)
	os.WriteFile(cfg, []byte("not json"), 0o644)
	rc, _, errs = fragmentArm(t, apps, []byte(strings.Replace(shopFrag, ":80", ":81", 1)), false)
	if b, _ := os.ReadFile(dest); rc != 1 || string(b) != want || !strings.Contains(errs, "`docker compose -p demo config` could not be read") || !strings.Contains(errs, "does not read as JSON") {
		t.Errorf("model: rc %d %q, live %q", rc, errs, b)
	}
	if log, _ := os.ReadFile(os.Getenv("LOG")); !bytes.Contains(log, []byte("compose -p demo config --format json")) {
		t.Errorf("docker calls: %s", log)
	}
	os.WriteFile(cfg, []byte(`{"services":{"web":{"networks":{"kasbah":{"aliases":["web.other_kasbah"]}}}}}`), 0o644)
	rc, _, errs = fragmentArm(t, apps, []byte(strings.Replace(shopFrag, ":80", ":81", 1)), false)
	if b, _ := os.ReadFile(dest); rc != 1 || string(b) != want || !strings.Contains(errs, "web.other_kasbah (a kasbah alias of web)") || !strings.Contains(errs, "(kasbah help C16)") {
		t.Errorf("dotted: rc %d %q, live %q", rc, errs, b)
	}
}

// The pre-flight refuses a foreign backend before anything starts, in a
// deploy and a rollback alike.
func TestEnginePreflightScopesTheFragment(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line), 0o640)
	r.running("demo-web=running")
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"services":{"web":{"networks":{"kasbah":null}}}}`), 0o644)
	t.Setenv("CONFIG", cfg)
	frag := "http:\n  services:\n    demo:\n      loadBalancer:\n        servers:\n          - url: http://%s:80\n"
	for _, mode := range []string{"deploy", "rollback"} {
		sp := r.spec()
		sp.Mode, sp.Tagged, sp.NoHealthWait = mode, mode == "rollback", true
		sp.Fragment = strings.Replace(frag, "%s", "other-web", 1)
		os.Remove(r.log)
		rc, out, errs := r.run(sp)
		if rc != 1 || strings.Contains(out, ReportKey) || !strings.Contains(errs, `host "other-web" is not a name of this project on its kasbah network (demo_kasbah)`) ||
			!strings.Contains(errs, "one of this project's own names there: web (kasbah help T07)") {
			t.Errorf("%s: rc %d %q", mode, rc, errs)
		}
		for _, c := range r.calls() {
			if strings.HasPrefix(c, "hook") || strings.Contains(c, " up ") || strings.HasPrefix(c, "tag ") {
				t.Errorf("%s: ran %q before the preflight refused", mode, c)
			}
		}
		sp.Fragment = strings.Replace(frag, "%s", "web", 1)
		if rc, out, errs := r.run(sp); rc != 0 || !strings.Contains(out, ReportKey) {
			t.Errorf("%s, own: rc %d %q", mode, rc, errs)
		}
	}
	os.WriteFile(cfg, []byte("not json"), 0o644)
	sp := r.spec()
	sp.Fragment = strings.Replace(frag, "%s", "web", 1)
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "could not be read to tell they are this project's") || !strings.Contains(errs, "then re-run the deploy;") {
		t.Errorf("model: rc %d %q", rc, errs)
	}
	// A dotted name refuses the deploy, routed or not.
	os.WriteFile(cfg, []byte(`{"services":{"web":{"networks":{"kasbah":{"aliases":["web.other_kasbah"]}}}}}`), 0o644)
	os.Remove(r.log)
	sp.Fragment = ""
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "compose puts a name with a dot on this project's kasbah network (demo_kasbah) or kasbah-net: web.other_kasbah") {
		t.Errorf("dotted: rc %d %q", rc, errs)
	}
	for _, c := range r.calls() {
		if strings.HasPrefix(c, "hook") || strings.Contains(c, " up ") || strings.HasPrefix(c, "tag ") {
			t.Errorf("dotted: ran %q before the preflight refused", c)
		}
	}
}

// A live fragment scoped to the project network rolls as its bare form did;
// one scoped to another network reaches nothing of the project.
func TestEngineRollReadsAScopedLiveFragment(t *testing.T) {
	for host, rolls := range map[string]bool{"demo-web": true, "demo-web.demo_kasbah": true, "demo-web.other_kasbah": false} {
		r := newRollRig(t, rollModel)
		r.live(host)
		t.Setenv("RECREATE", map[bool]string{false: "demo-web"}[rolls])
		rc, _, errs := r.run(r.spec())
		scaled := index(r.calls(), "compose -p demo up -d --no-deps --no-recreate --remove-orphans --scale demo-web=2 demo-web") >= 0
		if rc != 0 || scaled != rolls {
			t.Errorf("%s: rc %d, rolled %v\n%s", host, rc, scaled, errs)
		}
		if !rolls && !strings.Contains(errs, "as the live route does not reach its running container on demo_kasbah") {
			t.Errorf("%s: %s", host, errs)
		}
	}
}

// A fragment that does not parse is not installed unscoped.
func TestScopeFragmentUnparsed(t *testing.T) {
	if _, err := scopeOf(t, "http: [\n"); err == nil || !strings.Contains(err.Error(), "does not parse as YAML") {
		t.Errorf("%v", err)
	}
}
