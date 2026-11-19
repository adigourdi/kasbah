package migrate

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

// fakeDocker is a docker with kasbah-net (nil: gone) and the networks
// Traefik is on (nil: no traefik); calls records every command that changes
// something.
type fakeDocker struct {
	shared  []string
	traefik []string
	ps      string
	inspect string
	err     error
	calls   []string
}

func (f *fakeDocker) run(args ...string) (string, error) {
	j := strings.Join(args, " ")
	if f.err != nil {
		return "", f.err
	}
	switch {
	case strings.HasPrefix(j, "network inspect"):
		if f.shared == nil {
			return "", errors.New("Error response from daemon: network kasbah-net not found")
		}
		return "kasbah-net\n", nil
	case strings.HasPrefix(j, "inspect -f {{range $k"):
		if f.traefik == nil {
			return "", errors.New("Error: No such object: traefik")
		}
		return strings.Join(f.traefik, "\n") + "\n", nil
	case strings.HasPrefix(j, "network disconnect kasbah-net traefik"):
		f.calls = append(f.calls, j)
		f.shared = slices.DeleteFunc(f.shared, func(n string) bool { return n == "traefik" })
		f.traefik = slices.DeleteFunc(f.traefik, func(n string) bool { return n == "kasbah-net" })
		return "", nil
	case j == "network rm kasbah-net":
		f.calls = append(f.calls, j)
		f.shared = nil
		return "", nil
	case j == "ps -q":
		return f.ps, nil
	case strings.HasPrefix(j, "inspect -f {{.Name}}"):
		return f.inspect, nil
	}
	return "", errors.New("unexpected docker " + j)
}

// composeConfig is a compose model per project directory's base name; one
// absent fails as compose would.
func composeConfig(models map[string]string) func(string) func(...string) (string, error) {
	return func(dir string) func(...string) (string, error) {
		return func(...string) (string, error) {
			if m, ok := models[filepath.Base(dir)]; ok {
				return m, nil
			}
			return "", errors.New("exit status 1: no configuration file provided: not found")
		}
	}
}

const alphaModel = `{"services":{"web":{"networks":{"kasbah":{"aliases":["www"]},"default":null}},"db":{"networks":{"default":null}}},"networks":{"kasbah":{"name":"alpha_kasbah"},"default":{"name":"alpha_default"}}}`

func TestScopedFiles(t *testing.T) {
	s := scoped((&fakeDocker{}).run, composeConfig(nil))
	apps := t.TempDir()
	write(t, apps, "traefik/dynamic/alpha.yml", "x")
	write(t, apps, "traefik/dynamic/_shared.yml", "x")
	write(t, apps, "traefik/dynamic/notes.txt", "x")
	write(t, apps, "traefik/dynamic/Bad_Name.yml", "x")
	write(t, apps, "traefik/dynamic/mail.yml", "x")
	write(t, apps, "traefik/dynamic/beta.yml", "x")
	write(t, apps, "traefik/dynamic/ops.yml", "x")
	write(t, apps, "gamma", "a file, not a project")
	write(t, apps, "traefik/dynamic/gamma.yml", "x")
	os.MkdirAll(filepath.Join(apps, "alpha"), 0o755)
	os.MkdirAll(filepath.Join(apps, "beta"), 0o755)
	got, err := s.Files(apps)
	want := []string{"traefik/dynamic/alpha.yml", "traefik/dynamic/beta.yml", "traefik/dynamic/_mail.yml", "traefik/compose.yml"}
	if err != nil || !slices.Equal(got, want) {
		t.Errorf("%q %v", got, err)
	}
	if got, err := s.Files(t.TempDir()); err != nil || !slices.Equal(got, want[2:]) {
		t.Errorf("no dynamic/: %q %v", got, err)
	}
}

func TestScopedFragments(t *testing.T) {
	s := scoped((&fakeDocker{}).run, composeConfig(nil))
	const rel = "traefik/dynamic/alpha.yml"
	for _, c := range []struct{ name, in, out, err string }{
		{"http and tcp", "http:\n  services:\n    web:\n      loadBalancer:\n        servers:\n          - url: \"http://web:80\"\n          - url: http://api:8080/x\ntcp:\n  services:\n    pg:\n      loadBalancer:\n        servers:\n          - address: db:5432\n",
			"http:\n  services:\n    web:\n      loadBalancer:\n        servers:\n          - url: \"http://web.alpha_kasbah:80\"\n          - url: http://api.alpha_kasbah:8080/x\ntcp:\n  services:\n    pg:\n      loadBalancer:\n        servers:\n          - address: db.alpha_kasbah:5432\n", ""},
		{"CRLF", "http:\r\n  services:\r\n    web:\r\n      loadBalancer:\r\n        servers:\r\n          - url: 'http://web:80' # the site\r\n",
			"http:\r\n  services:\r\n    web:\r\n      loadBalancer:\r\n        servers:\r\n          - url: 'http://web.alpha_kasbah:80' # the site\r\n", ""},
		{"an anchor read only as a backend", "x-u: &u http://web:80\nhttp:\n  services:\n    a:\n      loadBalancer:\n        servers:\n          - url: *u\n    b:\n      loadBalancer:\n        servers:\n          - url: *u\n",
			"x-u: &u http://web.alpha_kasbah:80\nhttp:\n  services:\n    a:\n      loadBalancer:\n        servers:\n          - url: *u\n    b:\n      loadBalancer:\n        servers:\n          - url: *u\n", ""},
		{"an IP and a dotted host stay", "http:\n  services:\n    a:\n      loadBalancer:\n        servers:\n          - url: http://10.0.0.5:80\n          - url: http://web.example.com\n", "", ""},
		{"no backend", "http:\n  routers:\n    r:\n      rule: Host(`a.test`)\n      service: noop@internal\n", "", ""},
		{"an anchor also read elsewhere", "http:\n  services:\n    a:\n      loadBalancer:\n        servers:\n          - url: &u http://web:80\n  routers:\n    r:\n      rule: *u\n", "", "is anchor &u, also used outside a backend"},
		{"unparsable", "http: [\n", "", "does not parse as YAML"},
	} {
		at, err := s.Major(rel, []byte(c.in))
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("%s: %d %v", c.name, at, err)
			}
			continue
		}
		if c.out == "" {
			if err != nil || at != 2 {
				t.Errorf("%s: at %d %v, want 2", c.name, at, err)
			}
			continue
		}
		if err != nil || at != 1 {
			t.Errorf("%s: at %d %v, want 1", c.name, at, err)
		}
		out, err := s.Rewrite(rel, []byte(c.in))
		if err != nil || string(out) != c.out {
			t.Errorf("%s: %v\n%s", c.name, err, out)
		}
		if at, err := s.Major(rel, out); err != nil || at != 2 {
			t.Errorf("%s rewritten: at %d %v", c.name, at, err)
		}
	}
	mail, _ := os.ReadFile("../../templates/mail/_mail.yml")
	if at, err := s.Major(mailFragment, mail); err != nil || at != 2 {
		t.Errorf("2.x _mail.yml: %d %v", at, err)
	}
	old := bytes.Replace(mail, []byte("mail-cypht.mail_kasbah:80"), []byte("mail-cypht:80"), 1)
	if out, err := s.Rewrite(mailFragment, old); err != nil || !bytes.Equal(out, mail) {
		t.Errorf("1.x _mail.yml: %v", err)
	}
}

func TestScopedTraefikCompose(t *testing.T) {
	s := scoped((&fakeDocker{}).run, composeConfig(nil))
	v1, err := os.ReadFile("testdata/traefik-compose-1.yml")
	if err != nil {
		t.Fatal(err)
	}
	if at, err := s.Major(traefikFile, v1); err != nil || at != 1 {
		t.Fatalf("1.x: %d %v", at, err)
	}
	out, err := s.Rewrite(traefikFile, v1)
	if err != nil {
		t.Fatal(err)
	}
	// Only kasbah-net's lines go: the service's networks: entry, the
	// top-level networks: with its comment, and the blank line before it.
	want := strings.Replace(string(v1), "    networks:\n      - kasbah-net\n", "", 1)
	want = want[:strings.Index(want, "\n# Kasbah's own shared network")]
	if string(out) != want {
		t.Errorf("got\n%s", out)
	}
	if at, err := s.Major(traefikFile, out); err != nil || at != 2 {
		t.Errorf("rewritten: %d %v", at, err)
	}
	v2, _ := os.ReadFile("../../templates/traefik/compose.yml")
	v2 = bytes.Replace(v2, []byte("__ACME_DNS_ENV_FILES__\n"), nil, 1)
	if at, err := s.Major(traefikFile, v2); err != nil || at != 2 {
		t.Errorf("2.x template: %d %v", at, err)
	}
	crlf := bytes.ReplaceAll(v1, []byte("\n"), []byte("\r\n"))
	if out, err := s.Rewrite(traefikFile, crlf); err != nil || string(out) != strings.ReplaceAll(want, "\n", "\r\n") {
		t.Errorf("CRLF: %v\n%q", err, out)
	}
	for _, c := range []struct{ name, in, out, err string }{
		{"other networks stay", "services:\n  traefik:\n    image: t\n    networks:\n      - edge\n      - kasbah-net\nnetworks:\n  edge: {}\n  # shared\n  kasbah-net:\n    name: kasbah-net\n",
			"services:\n  traefik:\n    image: t\n    networks:\n      - edge\nnetworks:\n  edge: {}\n", ""},
		{"a mapping, by name", "services:\n  traefik:\n    networks:\n      shared:\n        aliases: [t]\n    image: t\nnetworks:\n  shared:\n    name: kasbah-net\n",
			"services:\n  traefik:\n    image: t\n", ""},
		{"flow style", "services:\n  traefik:\n    networks: [kasbah-net]\nnetworks:\n  kasbah-net: {}\n", "", "line 3 in a shape kasbah cannot edit"},
		{"no traefik", "services:\n  web: {}\n", "", "has no services.traefik"},
		{"networks through a merge", "x-t: &t\n  networks:\n    - kasbah-net\nservices:\n  traefik:\n    <<: *t\n    image: t\nnetworks:\n  kasbah-net: {}\n", "", "its networks: through the merge on line 6"},
		{"the service an alias", "x-t: &t\n  networks:\n    - kasbah-net\nservices:\n  traefik: *t\nnetworks:\n  kasbah-net: {}\n", "", "services.traefik on line 5 as an alias"},
		{"an alias as a flow item", "x-n: &s kasbah-net\nservices:\n  traefik:\n    networks: [edge, *s]\nnetworks:\n  edge: {}\n  kasbah-net: {}\n", "", "line 4 in a shape kasbah cannot edit"},
		{"an alias as a list item", "x-n: &s kasbah-net\nservices:\n  traefik:\n    networks:\n      - edge\n      - *s\nnetworks:\n  edge: {}\n  kasbah-net: {}\n", "", "an alias or a merge on line 6 in services.traefik's networks:"},
		{"an alias as a block item", "x-n: &s kasbah-net\nservices:\n  traefik:\n    networks:\n    - *s\nnetworks:\n  kasbah-net: {}\n", "", "an alias or a merge on line 5 in services.traefik's networks:"},
		{"a merge in the networks mapping", "x-n: &n\n  kasbah-net: {}\nservices:\n  traefik:\n    networks:\n      edge: {}\n      <<: *n\nnetworks:\n  edge: {}\n  kasbah-net: {}\n", "", "an alias or a merge on line 7 in services.traefik's networks:"},
		{"an alias deep in an entry", "x-a: &a [t]\nservices:\n  traefik:\n    networks:\n      kasbah-net:\n        aliases: *a\nnetworks:\n  kasbah-net: {}\n", "", "an alias or a merge on line 6"},
		{"a merge among the top-level networks", "x-n: &n\n  kasbah-net: {}\nservices:\n  traefik:\n    networks:\n      - kasbah-net\nnetworks:\n  <<: *n\n", "", "an alias or a merge on line 8 as a key of the top-level networks:"},
		{"a value alias among the top-level networks", "x-d: &d {driver: bridge}\nservices:\n  traefik:\n    image: t\n    networks:\n      - edge\n      - kasbah-net\nnetworks:\n  edge: *d\n  kasbah-net: {}\n",
			"x-d: &d {driver: bridge}\nservices:\n  traefik:\n    image: t\n    networks:\n      - edge\nnetworks:\n  edge: *d\n", ""},
		{"a name through an alias", "x-n: &s kasbah-net\nservices:\n  traefik:\n    image: t\n    networks:\n      - edge\n      - shared\nnetworks:\n  edge: {}\n  shared:\n    name: *s\n",
			"x-n: &s kasbah-net\nservices:\n  traefik:\n    image: t\n    networks:\n      - edge\nnetworks:\n  edge: {}\n", ""},
		{"a merge that gives no networks", "x-t: &t\n  image: t\nservices:\n  traefik:\n    <<: *t\n    networks:\n      - kasbah-net\nnetworks:\n  kasbah-net: {}\n",
			"x-t: &t\n  image: t\nservices:\n  traefik:\n    <<: *t\n", ""},
		{"a block scalar goes whole", "services:\n  traefik:\n    image: t\n    networks:\n      - edge\n      - kasbah-net\nnetworks:\n  edge: {}\n  kasbah-net:\n    name: kasbah-net\n    labels:\n      note: |\n        line one\n\n        line two\n  other: {}\n",
			"services:\n  traefik:\n    image: t\n    networks:\n      - edge\nnetworks:\n  edge: {}\n  other: {}\n", ""},
		{"a list at its key's indent", "services:\n  traefik:\n    image: t\n    networks:\n    - edge\n    - kasbah-net\n", "services:\n  traefik:\n    image: t\n    networks:\n    - edge\n", ""},
		{"flow style without kasbah-net is at 2", "services:\n  traefik:\n    networks: [edge]\nnetworks: {edge: {}}\n", "", ""},
	} {
		out, err := s.Rewrite(traefikFile, []byte(c.in))
		if c.err == "" && c.out == "" {
			if at, err := s.Major(traefikFile, []byte(c.in)); err != nil || at != 2 {
				t.Errorf("%s: %d %v", c.name, at, err)
			}
			continue
		}
		if c.err != "" {
			if _, merr := s.Major(traefikFile, []byte(c.in)); err == nil || merr == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("%s: %v %v", c.name, err, merr)
			}
			continue
		}
		if err != nil || string(out) != c.out {
			t.Errorf("%s: %v\n%s", c.name, err, out)
		}
	}
}

func TestDetach(t *testing.T) {
	const kept = "traefik disconnected from kasbah-net, which is kept: traefik was created on it and needs it to start — " + recreate
	for _, c := range []struct {
		name       string
		f          fakeDocker
		did, calls []string
	}{
		{"on it and another", fakeDocker{shared: []string{"traefik"}, traefik: []string{"alpha_kasbah", "kasbah-net"}},
			[]string{kept}, []string{"network disconnect kasbah-net traefik"}},
		{"already off it", fakeDocker{shared: []string{}, traefik: []string{"alpha_kasbah"}},
			[]string{"traefik is not on kasbah-net: nothing was disconnected"}, nil},
		{"kasbah-net gone", fakeDocker{traefik: []string{"traefik_default"}},
			[]string{"traefik is not on kasbah-net: nothing was disconnected"}, nil},
		{"no traefik", fakeDocker{shared: []string{}},
			[]string{"there is no traefik container: nothing was disconnected from kasbah-net"}, nil},
		{"on it alone", fakeDocker{shared: []string{"traefik"}, traefik: []string{"kasbah-net"}},
			[]string{"traefik is on no network but kasbah-net, so it stays on it — " + recreate}, nil},
	} {
		f := c.f
		did, err := detach(f.run)
		if err != nil || !slices.Equal(did, c.did) || !slices.Equal(f.calls, c.calls) {
			t.Errorf("%s: %q %v, calls %q", c.name, did, err, f.calls)
		}
		// The network is never removed; a rerun changes nothing more.
		if _, err := detach(f.run); err != nil || !slices.Equal(f.calls, c.calls) || slices.Contains(f.calls, "network rm kasbah-net") {
			t.Errorf("%s rerun: %v %q", c.name, err, f.calls)
		}
	}
	// A docker that does not run is not a Traefik that is gone.
	f := fakeDocker{err: errors.New(`exec: "docker": executable file not found in $PATH`)}
	if did, err := detach(f.run); err == nil {
		t.Errorf("no docker: %q", did)
	}
}

func TestReattach(t *testing.T) {
	for _, c := range []struct {
		name string
		f    fakeDocker
		want string
	}{
		{"still on it", fakeDocker{shared: []string{"traefik"}, traefik: []string{"kasbah-net", "a_kasbah"}}, ""},
		{"off it", fakeDocker{shared: []string{}, traefik: []string{"a_kasbah"}}, "`docker network connect kasbah-net traefik` on the server puts it back"},
		{"gone", fakeDocker{traefik: []string{"a_kasbah"}}, "traefik is off kasbah-net, which is gone"},
		{"no traefik", fakeDocker{}, ""},
		{"no docker", fakeDocker{err: errors.New("Cannot connect to the Docker daemon")}, "is unjudged: "},
	} {
		got := reattach(c.f.run)
		if c.want == "" && got != nil || c.want != "" && (len(got) != 1 || !strings.Contains(got[0], c.want)) {
			t.Errorf("%s: %q", c.name, got)
		}
	}
}

// v1Apps is a 1.x server: alpha routed by a bare web, a bare admin that is
// not its own and an IP; beta's compose not readable; delta on kasbah-net
// and its own network, routed by its own name; ops.yml no project's; the
// mail fragment bare, Traefik's compose file on kasbah-net.
func v1Apps(t *testing.T) string {
	apps := newApps(t, "1.4.0")
	write(t, apps, "traefik/dynamic/alpha.yml", "http:\n  services:\n    web:\n      loadBalancer:\n        servers:\n          - url: http://web:80\n          - url: http://admin:80\n          - url: http://10.0.0.9:80\n")
	write(t, apps, "traefik/dynamic/beta.yml", "http:\n  services:\n    b:\n      loadBalancer:\n        servers:\n          - url: http://beta-web:80\n")
	write(t, apps, "traefik/dynamic/delta.yml", "http:\n  services:\n    d:\n      loadBalancer:\n        servers:\n          - url: http://web:80\n")
	write(t, apps, "traefik/dynamic/ops.yml", "http:\n  services:\n    g:\n      loadBalancer:\n        servers:\n          - url: http://grafana:3000\n")
	write(t, apps, "traefik/dynamic/_shared.yml", "http: {}\n")
	write(t, apps, "traefik/dynamic/_mail.yml", "http:\n  services:\n    webmail:\n      loadBalancer:\n        servers:\n          - url: \"http://mail-cypht:80\"\n")
	v1, _ := os.ReadFile("testdata/traefik-compose-1.yml")
	write(t, apps, "traefik/compose.yml", string(v1))
	for _, p := range []string{"alpha", "beta", "delta"} {
		os.MkdirAll(filepath.Join(apps, p), 0o755)
	}
	return apps
}

const deltaModel = `{"services":{"web":{"networks":{"kasbah":null,"kasbah-net":null}}},"networks":{"kasbah":{"name":"delta_kasbah"},"kasbah-net":{"name":"kasbah-net","external":true}}}`

func v1Models() func(string) func(...string) (string, error) {
	return composeConfig(map[string]string{"alpha": alphaModel, "delta": deltaModel})
}

func v1Docker() *fakeDocker {
	return &fakeDocker{shared: []string{"traefik", "old-web-1", "delta-web-1"}, traefik: []string{"kasbah-net", "alpha_kasbah", "mail_kasbah"}, ps: "a\nb\nc\nd\ne\n",
		inspect: "/traefik||3f1c0e2a9b7d|kasbah-net= alpha_kasbah= mail_kasbah=\n" +
			"/old-web-1|old|8a2e4c6d0b1f|kasbah-net=old-web-1,web \n" +
			"/delta-web-1|delta||kasbah-net=delta-web-1,web delta_kasbah=delta-web-1,web \n" +
			"/alpha-web-1|alpha|alpha|alpha_kasbah=alpha-web-1,web,www alpha_default=alpha-web-1,web \n" +
			"/eps-app-1|eps|web.alpha_kasbah|eps_kasbah=eps-app-1,app \n" +
			"/mail-dms|mail|mail.example.com|mail_kasbah=mail-dms,mail.example.com \n" +
			"/gamma-api-1|gamma||gamma_kasbah=gamma-api-1,web.alpha_kasbah \n"}
}

func TestLost(t *testing.T) {
	apps := v1Apps(t)
	got := lost(apps, v1Docker().run, v1Models())
	want := Cost{Lost: []string{
		"alpha: backend admin in traefik/dynamic/alpha.yml is not one of its own names on alpha_kasbah, so its route answers 502 " + fix,
		"beta is unjudged: its traefik/dynamic/beta.yml could not be read against `docker compose -p beta config` in " + apps + "/beta (exit status 1: no configuration file provided: not found)",
		"eps-app-1 answers the dotted name web.alpha_kasbah on eps_kasbah, so it could hijack another project's scoped backend until it is renamed without a dot and its project redeployed with this kasbah (kasbah help C16)",
		"gamma-api-1 answers the dotted name web.alpha_kasbah on gamma_kasbah, so it could hijack another project's scoped backend until it is renamed without a dot and its project redeployed with this kasbah (kasbah help C16)",
	}, Notes: []string{
		"alpha: backend 10.0.0.9 in traefik/dynamic/alpha.yml is left as written; the next deploy with this kasbah refuses it (kasbah help T07)",
		"traefik/dynamic/ops.yml is left as written: no ops/ under the apps path, so it is no project's fragment",
		"traefik leaves kasbah-net, which delta-web-1, old-web-1 stay on; a route to them is lost only as listed above",
	}}
	if !slices.Equal(got.Lost, want.Lost) || !slices.Equal(got.Notes, want.Notes) {
		t.Errorf("got\n%s\n--\n%s", strings.Join(got.Lost, "\n"), strings.Join(got.Notes, "\n"))
	}
	got = lost(t.TempDir(), func(args ...string) (string, error) { return "", errors.New("Cannot connect to the Docker daemon") }, composeConfig(nil))
	if len(got.Lost) != 1 || !strings.Contains(got.Lost[0], "the running containers are unjudged: docker ps failed: Cannot connect") {
		t.Errorf("no docker: %q", got.Lost)
	}
}

func TestRunScoped(t *testing.T) {
	apps := v1Apps(t)
	d := v1Docker()
	steps := []Step{scoped(d.run, v1Models())}
	files := []string{"traefik/dynamic/alpha.yml", "traefik/dynamic/beta.yml", "traefik/dynamic/delta.yml", "traefik/dynamic/_mail.yml", "traefik/compose.yml"}
	// beta's fragment cannot be scoped in place: the run stops before it
	// rewrites any file, alpha's included, and the probe says so first.
	write(t, apps, "traefik/dynamic/beta.yml", "http:\n  services:\n    b:\n      loadBalancer:\n        servers:\n          - url: |\n              http://beta-web:80\n")
	orig := map[string]string{}
	for _, f := range append(files, "traefik/dynamic/ops.yml") {
		orig[f] = read(t, apps, f)
	}
	pr, err := Probe(apps, "2.0.0", steps)
	if err != nil || len(pr.Stops) != 1 || !strings.HasPrefix(pr.Stops[0], "stops the migration at traefik/dynamic/beta.yml: it cannot be rewritten in place: ") || !strings.Contains(pr.Stops[0], "block scalar") {
		t.Fatalf("probe: %+v %v", pr, err)
	}
	_, err = Run(apps, "2.0.0", steps, now)
	if rf, _ := refusal(err); rf.Way != "fix" || !strings.Contains(err.Error(), "cannot rewrite "+apps+"/traefik/dynamic/beta.yml") || !strings.Contains(err.Error(), "block scalar") {
		t.Fatalf("%v", err)
	}
	for f, body := range orig {
		if read(t, apps, f) != body {
			t.Errorf("a refused run rewrote %s", f)
		}
	}
	if len(d.calls) != 0 || !strings.Contains(read(t, apps, ".kasbah/server.json"), "1.4.0") {
		t.Fatalf("refused: docker %q", d.calls)
	}
	if _, err := os.Stat(filepath.Join(apps, Dir)); !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a refused run leaves no snapshot: %v", err)
	}
	write(t, apps, "traefik/dynamic/beta.yml", "http:\n  services:\n    b:\n      loadBalancer:\n        servers:\n          - url: http://beta-web:80\n")
	orig["traefik/dynamic/beta.yml"] = read(t, apps, "traefik/dynamic/beta.yml")
	r, err := Run(apps, "2.0.0", steps, now.Add(time.Minute))
	if err != nil || r.SnapshotReused || r.Marker != "updated" {
		t.Fatalf("%+v %v", r, err)
	}
	actions := map[string]string{}
	for _, f := range r.Steps[0].Files {
		actions[f.Path] = f.Action
	}
	for _, f := range files {
		if actions[f] != "rewritten" {
			t.Errorf("rerun: %v", actions)
		}
	}
	if _, ok := actions["traefik/dynamic/ops.yml"]; ok || read(t, apps, "traefik/dynamic/ops.yml") != orig["traefik/dynamic/ops.yml"] {
		t.Errorf("ops.yml is no project's fragment: %v", actions)
	}
	if !strings.Contains(read(t, apps, "traefik/dynamic/beta.yml"), "http://beta-web.beta_kasbah:80") || !strings.Contains(read(t, apps, "traefik/dynamic/_mail.yml"), `"http://mail-cypht.mail_kasbah:80"`) ||
		!strings.Contains(read(t, apps, "traefik/dynamic/alpha.yml"), "http://10.0.0.9:80") ||
		strings.Contains(read(t, apps, "traefik/compose.yml"), "kasbah-net") || read(t, apps, "traefik/dynamic/_shared.yml") != "http: {}\n" {
		t.Error("the files are not scoped")
	}
	if !slices.Equal(d.calls, []string{"network disconnect kasbah-net traefik"}) || len(r.Steps[0].Done) != 1 || !strings.HasPrefix(r.Steps[0].Done[0], "traefik disconnected from kasbah-net, which is kept") {
		t.Errorf("act: %q %q", d.calls, r.Steps[0].Done)
	}
	var so bytes.Buffer
	Print(&so, "d@h", r)
	for _, w := range []string{"    traefik/compose.yml rewritten\n", "    traefik disconnected from kasbah-net, which is kept", "`kasbah server upgrade-traefik` recreates Traefik off it", "    warning: alpha: backend admin", "    note: alpha: backend 10.0.0.9"} {
		if !strings.Contains(so.String(), w) {
			t.Errorf("report lacks %q: %s", w, so.String())
		}
	}
	// The snapshot holds the originals, which an undo puts back; Traefik is
	// not put back on kasbah-net, and the report says how.
	names := tarNames(t, r.Snapshot)
	for f, body := range orig {
		if f != "traefik/dynamic/ops.yml" && names[f] != body {
			t.Errorf("snapshot's %s: %q", f, names[f])
		}
	}
	u, err := Undo(apps, steps)
	if err != nil || u.Marker != "restored" || len(u.Left) != 1 || !strings.Contains(u.Left[0], "`docker network connect kasbah-net traefik`") {
		t.Fatalf("%+v %v", u, err)
	}
	for f, body := range orig {
		if read(t, apps, f) != body {
			t.Errorf("undo left %s as %q", f, read(t, apps, f))
		}
	}
	if len(d.calls) != 1 {
		t.Errorf("undo ran docker: %q", d.calls)
	}
	so.Reset()
	Print(&so, "d@h", u)
	for _, w := range []string{"the marker is back at major 1\n", "a kasbah of major 1 refuses as newer", "at " + apps + "/.kasbah/bin/kasbah by hand", "  traefik is still off kasbah-net"} {
		if !strings.Contains(so.String(), w) {
			t.Errorf("undo report lacks %q: %s", w, so.String())
		}
	}
	// After a fresh migration the rerun finds every file at 2.
	write(t, apps, "traefik/dynamic/beta.yml", "http:\n  services:\n    b:\n      loadBalancer:\n        servers:\n          - url: http://beta-web:80\n")
	if _, err := Run(apps, "2.0.0", steps, now.Add(2*time.Minute)); err != nil {
		t.Fatal(err)
	}
	write(t, apps, ".kasbah/server.json", strings.Replace(read(t, apps, ".kasbah/server.json"), "2.0.0", "1.4.0", 1))
	r, err = Run(apps, "2.0.0", steps, now.Add(3*time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range r.Steps[0].Files {
		if f.Action != "skipped" {
			t.Errorf("idempotent: %s %s", f.Path, f.Action)
		}
	}
}

func TestRunServerProbe(t *testing.T) {
	const mk = `{"kasbah_version":"1.4.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1","mem_limit":"1g"}`
	run := func(f *fakeSession) (string, error) {
		var so, se bytes.Buffer
		out := &cli.Output{Stdout: &so, Stderr: &se}
		c := Ctx{Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: out}, Version: "2.0.0",
			Dial: func(string) (Session, error) { return f, nil }, Now: func() time.Time { return now }}
		err := RunServer(c, Options{Server: true, Target: "d@h"})
		return so.String(), err
	}
	f := &fakeSession{marker: mk, apps: "/apps", probe: `{"stops":["stops the migration at traefik/dynamic/b.yml: it is bad"],"warnings":["a: backend x answers 502"],"notes":["a: backend 10.0.0.9 is left as written"]}`}
	out, err := run(f)
	if err == nil || !strings.Contains(err.Error(), "--yes") || !slices.Equal(f.calls, []string{"/apps 2.0.0 probe"}) {
		t.Fatalf("%v %q", err, f.calls)
	}
	if !strings.Contains(out, "  step 1->2: qualifies each backend host") || !strings.HasSuffix(out, "  will stop before rewriting any file (fix it by hand first):\n    - stops the migration at traefik/dynamic/b.yml: it is bad\n"+
		"  will lose its route (answer no to stop here):\n    - a: backend x answers 502\n  left as it is:\n    - a: backend 10.0.0.9 is left as written\n") {
		t.Errorf("%s", out)
	}
	f = &fakeSession{marker: mk, apps: "/apps", probe: `{"stops":[],"warnings":[],"notes":[]}`}
	if out, _ := run(f); !strings.HasSuffix(out, "  nothing found that will lose its route\n") {
		t.Errorf("%s", out)
	}
	f = &fakeSession{marker: mk, apps: "/apps", probeRC: 1}
	if out, err := run(f); !strings.HasSuffix(out, "  what will lose its route is unjudged: the probe on d@h exited 1 (see above); the run's report lists it\n") || !strings.Contains(err.Error(), "--yes") {
		t.Errorf("a failed probe still asks: %s %v", out, err)
	}
	f = &fakeSession{marker: strings.Replace(mk, "1.4.0", "0.9.0", 1), apps: "/apps"}
	if _, err := run(f); len(f.calls) != 1 {
		t.Errorf("0->2 probes once: %q %v", f.calls, err)
	}
}

func TestRemoteProbe(t *testing.T) {
	apps := newApps(t, "1.4.0")
	var so, se bytes.Buffer
	if rc := Remote([]string{"--apps=" + apps, "--version=1.5.0", "--probe"}, &so, &se); rc != 0 || so.String() != "{\"stops\":[],\"warnings\":[],\"notes\":[]}\n" {
		t.Errorf("same major: %d %s %s", rc, so.String(), se.String())
	}
	if rc := Remote([]string{"--apps=" + apps, "--version=1.5.0", "--probe", "--undo"}, &so, &se); rc != 1 || !strings.Contains(se.String(), "usage") {
		t.Errorf("--probe --undo: %d %s", rc, se.String())
	}
	warn := func(string) Cost { return Cost{Lost: []string{"w"}, Notes: []string{"n"}} }
	r, err := Probe(apps, "2.0.0", []Step{step(1, 2), {From: 2, To: 3, Warn: warn, Files: func(string) ([]string, error) { return nil, nil }}})
	if err != nil || r.Warnings == nil || len(r.Warnings) != 0 || len(r.Stops) != 0 {
		t.Errorf("a step with no Warn: %+v %v", r, err)
	}
	r, err = Probe(apps, "3.0.0", []Step{step(1, 2), {From: 2, To: 3, Warn: warn}})
	if err != nil || !slices.Equal(r.Warnings, []string{"w"}) || !slices.Equal(r.Notes, []string{"n"}) {
		t.Errorf("%+v %v", r, err)
	}
}

// A run that stops prints, before its cause, what it found and did; one
// refused before its snapshot prints its cause and the refusal.
func TestRemotePartwayReport(t *testing.T) {
	apps := v1Apps(t)
	o := Server
	t.Cleanup(func() { Server = o })
	s := scoped(v1Docker().run, v1Models())
	s.Act = func(string) ([]string, error) { return nil, errors.New("boom") }
	Server = []Step{s}
	var so, se bytes.Buffer
	rc := Remote([]string{"--apps=" + apps, "--version=2.0.0"}, &so, &se)
	e := se.String()
	if rc != ExitPartway || !strings.Contains(e, "remote: before it stopped:\n  step 1->2: ") || !strings.Contains(e, "    warning: alpha: backend admin") ||
		!strings.Contains(e, "    note: traefik/dynamic/ops.yml is left as written") || strings.Index(e, "then failed: boom") < strings.Index(e, "before it stopped") {
		t.Errorf("%d %s", rc, e)
	}

	apps = v1Apps(t)
	write(t, apps, "traefik/dynamic/beta.yml", "http:\n  services:\n    b:\n      loadBalancer:\n        servers:\n          - url: |\n              http://beta-web:80\n")
	Server = []Step{scoped(v1Docker().run, v1Models())}
	so.Reset()
	se.Reset()
	rc = Remote([]string{"--apps=" + apps, "--version=2.0.0"}, &so, &se)
	if rc != ExitRefused || so.String() != `{"refused":"fix","major":1,"snapshot":""}`+"\n" || !strings.Contains(se.String(), "cannot rewrite "+apps+"/traefik/dynamic/beta.yml") || strings.Contains(se.String(), "before it stopped") {
		t.Errorf("refused: %d %s %s", rc, so.String(), se.String())
	}
}
