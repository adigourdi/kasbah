package check

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
)

const goodCompose = `services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
    networks: [kasbah-net]
networks:
  kasbah-net: {external: true}
`

const goodFragment = "http:\n  routers:\n" +
	"    demo-http: {rule: \"Host(`demo.example.com`)\", entryPoints: [web], service: noop@internal}\n" +
	"    demo: {rule: \"Host(`demo.example.com`)\", entryPoints: [websecure], tls: {certResolver: letsencrypt}, service: demo}\n" +
	"  services:\n    demo: {loadBalancer: {servers: [{url: \"http://demo-web:80\"}]}}\n"

// project writes a passing project into a fresh working directory, then the
// overrides (an empty body removes the file).
func project(t *testing.T, files map[string]string) {
	t.Helper()
	t.Chdir(t.TempDir())
	base := map[string]string{
		"kasbah.yml":          "schema: 1\nname: demo\ndomain: demo.example.com\n",
		".env.prod.example":   "# c\nDOMAIN=x\n",
		".gitignore":          ".env\n.kasbah/\n",
		"compose.prod.yml":    goodCompose,
		"traefik-dynamic.yml": goodFragment,
	}
	for k, v := range files {
		base[k] = v
	}
	for k, v := range base {
		if v == "" {
			continue
		}
		if err := os.WriteFile(k, []byte(v), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func check(t *testing.T) (string, string, int) {
	t.Helper()
	var o, e bytes.Buffer
	code := Run(Env{Out: &cli.Output{Stdout: &o, Stderr: &e}, PWD: "/p", Version: "1"})
	return o.String(), e.String(), code
}

func TestGoldenProject(t *testing.T) {
	project(t, nil)
	out, _, code := check(t)
	want := `Checking /p

Structure:
  ✓ kasbah.yml exists (schema 1)
  ✓ compose.prod.yml exists
  ✓ .env.prod.example exists
  ✓ .gitignore excludes .env
  ✓ .gitignore excludes .kasbah/
  ✓ client is not set — backups file under the project name (demo)

Compose:
  ✓ All services set restart policy
  ✓ All services set json-file logging with rotation
  ✓ All routed services join kasbah-net
  ✓ kasbah-net declared external
  ✓ No internal services on kasbah-net
  ✓ kasbah-net service names are project-prefixed
  ✓ No deprecated 'version:' field

Resources:
  ✓ All services set cpus/mem_limit via KASBAH_* vars
  ✓ No resource reservations

Traefik:
  ✓ traefik-dynamic.yml exists
  ✓ At least one router references manifest domain (demo.example.com)
  ✓ All routers declare entryPoints
  ✓ Secure routers reference letsencrypt cert resolver
  ✓ A router serves demo.example.com on the web entrypoint
  ✓ No router claims reserved hostnames (traefik.*, mail.*, webmail.*)
  ✓ Fragment loadBalancer URLs target explicit container_names
  ✓ compose.prod.yml has no traefik.* labels

Env:
  ✓ .env.prod.example syntax is valid
  ✓ .env.prod.example has no obvious long secrets
  ✓ .env.prod.example leaves the KASBAH_* prefix to kasbah

Summary: 26 passed, 0 warning, 0 failed
`
	if out != want || code != 0 {
		t.Errorf("exit %d, report:\n%s", code, out)
	}
}

func TestVerdicts(t *testing.T) {
	for _, tc := range []struct {
		name  string
		files map[string]string
		code  int
		lines []string
	}{
		{"no manifest", map[string]string{"kasbah.yml": ""}, 2, nil},
		{"multi-document compose answers per document",
			map[string]string{"compose.prod.yml": goodCompose + "---\n" + goodCompose}, 6,
			[]string{"  ✗ Routed services not on kasbah-net: demo-web demo-web"}},
		// `.services.web.container_name` of a string ran under errexit: jq's 5.
		{"a jq error where Bash had errexit ends the run",
			map[string]string{"compose.prod.yml": "services:\n  web: nginx\n"}, 5,
			[]string{"  ✗ Services missing restart policy: web"}},
		{"local T05 is the first-label heuristic",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers:\n    a: {rule: \"Host(`mail.x.io`) || Host(`mailhog.x.io`)\", entryPoints: [web]}\n"}, 6,
			[]string{"  ✗ Routers claim reserved hostnames: a→mail.x.io"}},
		{"cpus: 0.5 is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "0.5", 1)}, 6,
			[]string{"  ✗ Services with missing or literal resource limits: demo-web(cpus)"}},
		{"drift", map[string]string{".env": "KASBAH_X=1\nEXTRA=2\r\n"}, 0,
			[]string{"  ⚠ .env missing keys vs .env.prod.example: DOMAIN", "  ⚠ .env has extra keys not in .env.prod.example: EXTRA"}},
		{"mail block of the wrong shape", map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nmail: example.com\n"}, 6,
			[]string{"  ✗ mail: has type 'string' — it has to be a block with a domain: under it"}},
		{"T05 reads a Host() line by line, as grep -x did",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers:\n    a: {rule: \"Host(`x\\nmail`)\", entryPoints: [web]}\n"}, 6,
			[]string{"  ✗ Routers claim reserved hostnames: a→x\nmail"}},
		{"a NUL ends a .gitignore line", map[string]string{".gitignore": "x\x00.env\x00.kasbah/"}, 0,
			[]string{"  ✓ .gitignore excludes .env", "  ✓ .gitignore excludes .kasbah/"}},
		{"jq -e takes nan for a number", map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nmail: {domain: x.io, snappymail_domain: sm.json}\n", "sm.json": "1 NaN \n"}, 0,
			[]string{"  ✓ Mail pre-seed 'sm.json' exists and parses"}},
		{"a pre-seed jq -e rejects", map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nmail: {domain: x.io, snappymail_domain: sm.json}\n", "sm.json": "null"}, 6,
			[]string{"  ✗ mail: snappymail_domain 'sm.json' is not valid JSON"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, tc.files)
			out, _, code := check(t)
			if code != tc.code {
				t.Errorf("exit %d, want %d:\n%s", code, tc.code, out)
			}
			for _, l := range tc.lines {
				if !strings.Contains(out, l+"\n") {
					t.Errorf("no line %q in:\n%s", l, out)
				}
			}
		})
	}
}

func TestJQ(t *testing.T) {
	r := run([]jv.Value{jv.Number("1"), "s"}, func(d jv.Value, emit func(jv.Value)) error {
		emit(d)
		_, err := index(d, "a")
		return err
	})
	if r.out != "1\ns\n" || r.rc != 5 || r.or("false") != "1\ns\nfalse" {
		t.Errorf("run = %+v", r)
	}
	for in, want := range map[string]string{`a`: "a", `a\nb`: "a\nb", `\u0041`: "A"} {
		if got, ok := literal(in); !ok || got != want {
			t.Errorf("literal(%q) = %q, %v", in, got, ok)
		}
	}
	for _, in := range []string{`a"b`, `a\qb`, `a\`, `\(x)`} {
		if _, ok := literal(in); ok {
			t.Errorf("literal(%q) compiled", in)
		}
	}
	for v, want := range map[string]string{`""`: "0", `-2`: "2", `0.0`: "0", `{}`: "0", `[1]`: "1", `"é"`: "1"} {
		x, _ := jv.ParseOne([]byte(v))
		if got, err := length(x); err != nil || got != jv.Number(want) {
			t.Errorf("length(%s) = %v, %v", v, got, err)
		}
	}
	if _, err := length(true); err == nil {
		t.Error("length(true) answered")
	}
	if _, err := anyEq("web", "web"); err == nil {
		t.Error("any over a string answered")
	}
	if ok, _ := has(nil, "build"); ok {
		t.Error("null has a key")
	}
	if got := cutAssign("traefik.a=b\nc=d"); got != "traefik.a\nc=d" {
		t.Errorf("cutAssign = %q", got)
	}
}
