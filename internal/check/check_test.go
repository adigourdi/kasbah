package check

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

const goodCompose = `services:
  demo-web:
    image: nginx:alpine
    container_name: demo-web
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
    networks: [kasbah]
networks:
  kasbah: {}
`

// legacyCompose routes through the shared kasbah-net, the 1.x shape check
// still accepts with a warning.
const legacyCompose = `services:
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
	"    demo: {rule: \"Host(`demo.example.com`)\", entryPoints: [websecure], tls: {certResolver: http}, service: demo}\n" +
	"  services:\n    demo: {loadBalancer: {servers: [{url: \"http://demo-web:80\"}]}}\n"

// authMW is a basicAuth middleware whose users line is users.
func authMW(users string) string {
	return "  middlewares:\n    demo-auth:\n      basicAuth:\n        users: [\"" + users + "\"]\n"
}

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
  ✓ S01,S02 kasbah.yml exists (schema 1)
  ✓ S03 compose.prod.yml exists
  ✓ S04 .env.prod.example exists
  ✓ S05 .gitignore excludes .env
  ✓ S06 .gitignore excludes .kasbah/
  ✓ S08 client is not set — backups file under the project name (demo)

Compose:
  ✓ C01 All services set restart policy
  ✓ C02 All services set json-file logging with rotation
  ✓ C03 All routed services join the project's kasbah network
  ✓ C04 The kasbah network is the project's own (demo_kasbah)
  ✓ C07 No internal services on the kasbah network or kasbah-net
  ✓ C09 Names on the kasbah network are project-prefixed
  ✓ C05 No deprecated 'version:' field
  ✓ C14 No service publishes host port 80 or 443
  ⚠ C11 demo-web will not roll on deploy — the fragment targets its container_name, so it is recreated in place, briefly unrouted

Resources:
  ✓ R01,R02 All services set cpus/mem_limit via KASBAH_* vars
  ✓ R03 No resource reservations

Traefik:
  ✓ T01 traefik-dynamic.yml exists
  ✓ T02 At least one router references manifest domain (demo.example.com)
  ✓ T03 All routers declare entryPoints
  ✓ T04 Secure routers name a cert resolver
  ✓ T10 No router asks for a wildcard certificate from an HTTP-01 resolver
  ✓ T08 A router serves demo.example.com on the web entrypoint
  ✓ T05 No router claims reserved hostnames (traefik.*, mail.*, webmail.*)
  ✓ T09 No router or service reaches a Traefik internal service other than noop@internal
  ✓ T07 Fragment loadBalancer URLs target a service, alias or container_name compose defines
  ✓ T06 compose.prod.yml has no traefik.* labels

Env:
  ✓ E01 .env.prod.example syntax is valid
  ✓ E04 .env.prod.example has no obvious long secrets
  ✓ E05 .env.prod.example leaves the KASBAH_* prefix to kasbah

Summary: 29 passed, 1 warning, 0 failed
` + "`kasbah help C11`" + ` (or any ID above) says why a rule exists and what to change.
`
	if out != want || code != 0 {
		t.Errorf("exit %d, report:\n%s", code, out)
	}
}

// relayCompose publishes a UDP port and joins no Traefik network.
const relayCompose = `services:
  demo-relay:
    image: alpine/socat
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
    ports: ["5000:5000/udp"]
`

// An unrouted project: no fragment, no domain, and nothing warned about either.
func TestUnroutedProject(t *testing.T) {
	project(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nrouted: false\n", "compose.prod.yml": relayCompose, "traefik-dynamic.yml": ""})
	out, _, code := check(t)
	want := `Checking /p

Structure:
  ✓ S01,S02 kasbah.yml exists (schema 1)
  ✓ S03 compose.prod.yml exists
  ✓ S04 .env.prod.example exists
  ✓ S05 .gitignore excludes .env
  ✓ S06 .gitignore excludes .kasbah/
  ✓ S08 client is not set — backups file under the project name (demo)

Compose:
  ✓ C01 All services set restart policy
  ✓ C02 All services set json-file logging with rotation
  ✓ C03 No Traefik-routed services in compose
  ✓ C07 No internal services on the kasbah network or kasbah-net
  ✓ C05 No deprecated 'version:' field
  ✓ C14 No service publishes host port 80 or 443

Resources:
  ✓ R01,R02 All services set cpus/mem_limit via KASBAH_* vars
  ✓ R03 No resource reservations

Traefik:
  ✓ T11 No traefik-dynamic.yml — the project is unrouted (routed: false)
  ✓ T06 compose.prod.yml has no traefik.* labels

Env:
  ✓ E01 .env.prod.example syntax is valid
  ✓ E04 .env.prod.example has no obvious long secrets
  ✓ E05 .env.prod.example leaves the KASBAH_* prefix to kasbah

Summary: 19 passed, 0 warning, 0 failed
`
	if out != want || code != 0 {
		t.Errorf("exit %d, report:\n%s", code, out)
	}
}

const man = "schema: 1\nname: demo\ndomain: demo.example.com\n"

func TestVerdicts(t *testing.T) {
	for _, tc := range []struct {
		name  string
		files map[string]string
		code  int
		lines []string
	}{
		{"no manifest", map[string]string{"kasbah.yml": ""}, 2, nil},
		{"a compose file of several documents is not read",
			map[string]string{"compose.prod.yml": goodCompose + "---\n" + goodCompose}, 6,
			[]string{"  ✗ compose.prod.yml holds 2 YAML documents, where kasbah reads one"}},
		{"an unanswerable question ends the run",
			map[string]string{"compose.prod.yml": "services:\n  web: nginx\n"}, 1,
			[]string{"  ✗ C01 Services missing restart policy: web"}},
		{"a service name is a name, quotes and backslashes included",
			map[string]string{"compose.prod.yml": "services:\n  'a\"b': {image: nginx}\n  'c\\nd': {image: nginx}\n"}, 6,
			[]string{"  ✗ C01 Services missing restart policy: a\"b c\\nd"}},
		{"services: that is not a mapping",
			map[string]string{"compose.prod.yml": "services: [web]\n"}, 6,
			[]string{"  ✗ compose.prod.yml: services is a list, not a mapping", "  ✓ C05 No deprecated 'version:' field"}},
		{"a compose document that is not a mapping",
			map[string]string{"compose.prod.yml": "[a]\n"}, 6,
			[]string{"  ✗ compose.prod.yml: the document is a list, not a mapping"}},
		{"version: false is still a version: field",
			map[string]string{"compose.prod.yml": goodCompose + "version: false\n"}, 0,
			[]string{"  ⚠ C05 compose.prod.yml uses deprecated 'version:' field"}},
		{"external: only a boolean true is external",
			map[string]string{"compose.prod.yml": strings.Replace(legacyCompose, "{external: true}", "{external: \"true\"}", 1)}, 6,
			[]string{"  ✗ C04 kasbah-net not declared external: true"}},
		{"resources: well formed",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nresources:\n  cpus: 1.5\n  memory: 50%\n"}, 0,
			[]string{"  ✓ R05 resources: cpus 1.5, memory 50% — resolved on the server at deploy (a % is a share of the host) and held to its 90% ceiling"}},
		{"resources: a bare memory fails naming the units",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nresources:\n  memory: 512\n"}, 6,
			[]string{"  ✗ R05 kasbah.yml: resources.memory '512' has no unit — memory takes MiB (512m), GiB (2g) or a share of the host (50%) — m, g or %"}},
		{"resources: is judged without a compose file",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nresources: {cpus: 0}\n", "compose.prod.yml": ""}, 6,
			[]string{"  ✗ R05 kasbah.yml: resources.cpus '0' is not a limit — cpus takes a number of cores with at most one decimal (0.5, 2) or a share of the host (50%)"}},
		{"reservations: false is still a reservation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    networks: [kasbah]\n", "    networks: [kasbah]\n    deploy: {resources: {reservations: false}}\n", 1)}, 6,
			[]string{"  ✗ R03 Services declare resource reservations: demo-web"}},
		{"T04: a DNS provider's resolver warns that only --server can verify it",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "certResolver: http", "certResolver: cloudflare", 1)}, 0,
			[]string{"  ✓ T04 Secure routers name a cert resolver",
				"  ⚠ T04 Routers name a cert resolver other than http: demo→cloudflare — only `check --server` can verify the server declares them (`server init --acme-dns=<provider>:<env file>` adds one)"}},
		{"T04: letsencrypt names the rename",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "certResolver: http", "certResolver: letsencrypt", 1)}, 6,
			[]string{"  ✗ T04 certResolver letsencrypt was renamed to http — set tls.certResolver: http on: demo"}},
		{"T04: a websecure router without a resolver fails",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "tls: {certResolver: http}, ", "", 1)}, 6,
			[]string{"  ✗ T04 Websecure routers without tls.certResolver: demo"}},
		{"T10: a wildcard in tls.domains on http fails",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "tls: {certResolver: http}", "tls: {certResolver: http, domains: [{main: demo.example.com, sans: [\"*.demo.example.com\"]}]}", 1)}, 6,
			[]string{"  ✗ T10 Routers ask for a wildcard certificate from a resolver without dnsChallenge (HTTP-01 cannot issue one): demo→http (*.demo.example.com) — name a DNS provider's resolver (`server init --acme-dns=`)"}},
		{"T10: a double-quoted wildcard Host() on http fails",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "rule: \"Host(`demo.example.com`)\", entryPoints: [websecure]", "rule: 'Host(`demo.example.com`) || Host(\"*.demo.example.com\")', entryPoints: [websecure]", 1)}, 6,
			[]string{"  ✗ T10 Routers ask for a wildcard certificate from a resolver without dnsChallenge (HTTP-01 cannot issue one): demo→http (*.demo.example.com) — name a DNS provider's resolver (`server init --acme-dns=`)"}},
		{"T10: a wildcard in a tcp router's tls.domains on http fails",
			map[string]string{"traefik-dynamic.yml": goodFragment + "tcp:\n  routers:\n    db: {rule: \"HostSNI(`*`)\", tls: {certResolver: http, domains: [{main: \"*.db.example.com\"}]}}\n"}, 6,
			[]string{"  ✗ T10 Routers ask for a wildcard certificate from a resolver without dnsChallenge (HTTP-01 cannot issue one): tcp db→http (*.db.example.com) — name a DNS provider's resolver (`server init --acme-dns=`)"}},
		{"T10: a wildcard on a DNS provider's resolver passes locally",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "tls: {certResolver: http}", "tls: {certResolver: cloudflare, domains: [{main: \"*.demo.example.com\"}]}", 1)}, 0,
			[]string{"  ✓ T10 No router asks for a wildcard certificate from an HTTP-01 resolver"}},
		{"routers: that is not a mapping skips the router rules",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers: [a]\n"}, 0,
			[]string{"  ⚠ T01 traefik-dynamic.yml: http.routers is a list, not a mapping — skipping T02–T05 and T08–T10",
				"  ⚠ C03,C07,C11 traefik-dynamic.yml: http.routers is a list, not a mapping — skipping C03, C07 and C11, which need the services it routes"}},
		{"with no fragment read, C03, C07 and C11 conclude nothing",
			map[string]string{"traefik-dynamic.yml": ""}, 0,
			[]string{"  ⚠ C03,C07,C11 traefik-dynamic.yml missing — skipping C03, C07 and C11, which need the services it routes", "  ✓ C04 The kasbah network is the project's own (demo_kasbah)"}},
		{"with no fragment read and nothing on kasbah-net, C07 still passes",
			map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": strings.Replace(goodCompose, "networks: [kasbah]", "networks: [internal]", 1)}, 0,
			[]string{"  ⚠ C03,C11 traefik-dynamic.yml missing — skipping C03 and C11, which need the services it routes", "  ✓ C07 No internal services on the kasbah network or kasbah-net"}},
		{"with no fragment read, the default-alias shape still fails C07",
			map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": legacyCompose + "  default: {name: kasbah-net}\n"}, 6,
			[]string{"  ⚠ C03,C11 traefik-dynamic.yml missing — skipping C03 and C11, which need the services it routes", "  ✗ C07 default network aliases kasbah-net — every service joins the shared network; join it explicitly per routed service and keep the rest on a project-internal network"}},
		{"routed: false still judges C07: nothing may join the kasbah network",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\nrouted: false\n", "traefik-dynamic.yml": ""}, 6,
			[]string{"  ✓ C03 No Traefik-routed services in compose", "  ✗ C07 Non-routed services on the kasbah network: demo-web — Traefik joins it, so only what it routes belongs there",
				"  ✓ T11 No traefik-dynamic.yml — the project is unrouted (routed: false)"}},
		{"routed: false and a fragment contradict",
			map[string]string{"kasbah.yml": man + "routed: false\n"}, 6,
			[]string{"  ✗ T11 kasbah.yml sets routed: false, yet traefik-dynamic.yml exists — remove one: the fragment to keep the project unrouted, or routed: false to route it",
				"  ⚠ T11 manifest domain is 'demo.example.com', but routed: false — nothing routes it to this project; leave domain: out"}},
		{"routed: false with a domain warns that nothing routes it",
			map[string]string{"kasbah.yml": man + "routed: false\n", "traefik-dynamic.yml": "", "compose.prod.yml": relayCompose}, 0,
			[]string{"  ✓ T11 No traefik-dynamic.yml — the project is unrouted (routed: false)",
				"  ⚠ T11 manifest domain is 'demo.example.com', but routed: false — nothing routes it to this project; leave domain: out"}},
		{"routed: true with no fragment is today's project",
			map[string]string{"kasbah.yml": man + "routed: true\n", "traefik-dynamic.yml": ""}, 0,
			[]string{"  ⚠ T01 traefik-dynamic.yml missing — skipping T02–T05 and T08–T10"}},
		{"a legacy project on kasbah-net passes C03 and is warned to move",
			map[string]string{"compose.prod.yml": legacyCompose}, 0,
			[]string{"  ✓ C03 All routed services join kasbah-net", "  ⚠ C03 Routed through the shared kasbah-net: demo-web — every project's routed containers reach each other there; move them to a project network under the key kasbah",
				"  ✓ C04 kasbah-net declared external", "  ✓ C09 kasbah-net service names are project-prefixed"}},
		{"a routed service on neither network fails C03",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "networks: [kasbah]", "networks: [internal]", 1)}, 6,
			[]string{"  ✗ C03 Routed services on neither the project's kasbah network nor kasbah-net: demo-web"}},
		{"an external kasbah network fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah: {external: true}", 1)}, 6,
			[]string{"  ✗ C04 The kasbah network is declared external — it is the project's own: drop external: so compose creates demo_kasbah, which deploy connects Traefik to"}},
		{"a renamed kasbah network fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah: {name: shared}", 1)}, 6,
			[]string{"  ✗ C04 The kasbah network sets name — declare it as kasbah: {}: compose recreates a network whose settings change, which fails while Traefik is attached, and every later deploy would fail at up"}},
		{"any setting on the kasbah network fails C04, naming it",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah: {driver: bridge, labels: {a: b}}", 1)}, 6,
			[]string{"  ✗ C04 The kasbah network sets driver, labels — declare it as kasbah: {}: compose recreates a network whose settings change, which fails while Traefik is attached, and every later deploy would fail at up"}},
		{"a null kasbah network is as empty as {}",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah:", 1)}, 0,
			[]string{"  ✓ C04 The kasbah network is the project's own (demo_kasbah)"}},
		{"another stack's network, taken external, fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "  kasbah: {}\n", "  kasbah: {}\n  m: {name: mail_kasbah, external: true}\n  o: {external: {name: shop_kasbah}}\n", 1)}, 6,
			[]string{"  ✗ C04 External networks other than kasbah-net: m (mail_kasbah) o (shop_kasbah) — a project joins only its own networks and the legacy kasbah-net"}},
		{"a name on the kasbah network not named for the project fails C09",
			map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, "  demo-web:\n", "  web:\n", 1),
				"    networks: [kasbah]\n", "    networks: {kasbah: {aliases: [demo-api, krvb-w]}}\n", 1)}, 6,
			[]string{"  ✗ C09 Names on the kasbah network that are not 'demo' or 'demo-*': web (service) krvb-w (alias of web) — Traefik resolves names across every project's network, so another project's name can answer for this one's"}},
		{"a container_name on the kasbah network not named for the project fails C09",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "container_name: demo-web", "container_name: krvb-w", 1),
				"traefik-dynamic.yml": strings.Replace(goodFragment, "demo-web:80", "krvb-w:80", 1)}, 6,
			[]string{"  ✗ C09 Names on the kasbah network that are not 'demo' or 'demo-*': krvb-w (container_name of demo-web) — Traefik resolves names across every project's network, so another project's name can answer for this one's"}},
		{"a commented mail-dms is not a use of it",
			map[string]string{".env.prod.example": "# c\n# SMTP_HOST=mail-dms was the old way\nDOMAIN=x\n"}, 0,
			[]string{"  ✓ E01 .env.prod.example syntax is valid"}},
		{"a quoted span is one entry to E01-E03",
			map[string]string{".env.prod.example": "DOMAIN=x\nTLS_KEY=\"-----BEGIN\nX=1\n-----END\"\n", ".env": "DOMAIN=y\nTLS_KEY='-----BEGIN\r\nY=2\r\n-----END'\r\n"}, 0,
			[]string{"  ✓ E01 .env.prod.example syntax is valid", "  ✓ E02 .env has no missing keys vs .env.prod.example", "  ✓ E03 .env has no extra keys vs .env.prod.example"}},
		{"a template quote that never closes fails E01",
			map[string]string{".env.prod.example": "DOMAIN=x\nTLS_KEY=\"-----BEGIN\nX=1\n"}, 6,
			[]string{"  ✗ E01 .env.prod.example has invalid lines (line numbers: 2)"}},
		{"an undeclared kasbah network fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "  kasbah: {}\n", "  other: {}\n", 1)}, 6,
			[]string{"  ✗ C04 The kasbah network is not declared under the top-level networks: — add kasbah: {}"}},
		{"a non-routed service on the kasbah network fails C07",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "networks:\n  kasbah", "  db: {image: postgres, restart: always, cpus: 1, mem_limit: 1g, logging: {driver: json-file, options: {max-size: 1m, max-file: 1}}, networks: [kasbah]}\nnetworks:\n  kasbah", 1)}, 6,
			[]string{"  ✗ C07 Non-routed services on the kasbah network: db — Traefik joins it, so only what it routes belongs there"}},
		{"a compose or env template naming mail-dms is warned",
			map[string]string{".env.prod.example": "# c\nSMTP_HOST=mail-dms\n"}, 0,
			[]string{"  ⚠ C10 mail-dms is named in .env.prod.example — no project shares a network with the mail server; send through mail.<domain>:587 with a mailbox login"}},
		{"max-size: false is no rotation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "max-size: 10m", "max-size: false", 1)}, 6,
			[]string{"  ✗ C02 Services missing json-file logging with max-size/max-file: demo-web"}},
		{"max-file: {a: 1} is no rotation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, `max-file: "3"`, "max-file: {a: 1}", 1)}, 6,
			[]string{"  ✗ C02 Services missing json-file logging with max-size/max-file: demo-web"}},
		{"numeric rotation values are given",
			map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, `max-file: "3"`, "max-file: 3", 1), "max-size: 10m", "max-size: 1000", 1)}, 0,
			[]string{"  ✓ C02 All services set json-file logging with rotation"}},
		{"a fragment of several documents is not read",
			map[string]string{"traefik-dynamic.yml": goodFragment + "---\n" + goodFragment}, 0,
			[]string{"  ⚠ T01 traefik-dynamic.yml holds 2 YAML documents, where kasbah reads one — skipping T02–T05 and T08–T10",
				"  ⚠ C03,C07,C11 traefik-dynamic.yml holds 2 YAML documents, where kasbah reads one — skipping C03, C07 and C11, which need the services it routes"}},
		{"entryPoints: that is not a list",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "entryPoints: [web]", "entryPoints: web", 1)}, 6,
			[]string{"  ✗ T03 Routers without entryPoints: demo-http (entryPoints is a string, not a list)"}},
		{"T09 fails a router on api@internal, names router and service",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "service: demo}", "service: api@internal}", 1)}, 6,
			[]string{"  ✗ T09 Fragment routes to Traefik's internal services (only noop@internal is allowed): demo→api@internal"}},
		{"T09 fails weighted, mirroring and failover entries on @internal",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "  services:\n",
				"  services:\n    w: {weighted: {services: [{name: demo}, {name: dashboard@internal}]}}\n"+
					"    m: {mirroring: {service: rest@internal, mirrors: [{name: ping@internal}, {name: noop@internal}]}}\n"+
					"    f: {failover: {service: demo, fallback: api@internal}}\n"+
					"    h: {highestRandomWeight: {services: [{name: api@internal}, {name: api@internal}]}}\n", 1)}, 6,
			[]string{"  ✗ T09 Fragment routes to Traefik's internal services (only noop@internal is allowed): services.f→api@internal services.h→api@internal services.m→rest@internal services.m→ping@internal services.w→dashboard@internal"}},
		{"T09 fails an errors middleware's service on @internal",
			map[string]string{"traefik-dynamic.yml": goodFragment + "  middlewares:\n    oops: {errors: {status: [\"500\"], service: api@internal, query: /}}\n"}, 6,
			[]string{"  ✗ T09 Fragment routes to Traefik's internal services (only noop@internal is allowed): middlewares.oops→api@internal"}},
		{"T09 passes noop@internal",
			nil, 0,
			[]string{"  ✓ T09 No router or service reaches a Traefik internal service other than noop@internal"}},
		{"local T05 is the first-label heuristic",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers:\n    a: {rule: \"Host(`mail.x.io`) || Host(`mailhog.x.io`)\", entryPoints: [web]}\n"}, 6,
			[]string{"  ✗ T05 Routers claim reserved hostnames: a→mail.x.io"}},
		{"cpus: 0.5 is a literal, warned locally", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "0.5", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(cpus=0.5) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"quoted cpus and a size are literals", map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", `"1.5"`, 1), "${KASBAH_MEM_LIMIT}", "2G", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(cpus=1.5,mem_limit=2G) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"a byte count is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", "536870912", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=536870912) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"cpus: 0 is no limit", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "0", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(cpus) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"malformed literals fail", map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "1,5", 1), "${KASBAH_MEM_LIMIT}", "{a: 1}", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(cpus,mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"another variable is not a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", "${MY_MEM}", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"mem_limit: 1.5g is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `1.5g`, 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=1.5g) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 2GiB is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `2GiB`, 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=2GiB) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 1t is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `1t`, 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=1t) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 512 MB is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `"512 MB"`, 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=512 MB) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 6m is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `6m`, 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=6m) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"512mi is no unit docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `512mi`, 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"512 bytes is under docker's 6m minimum", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `512`, 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"99999999999t overflows", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `99999999999t`, 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"5.5.5m is no number", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `5.5.5m`, 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"cpus: \".5\" is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", `".5"`, 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(cpus=.5) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"deploy.resources.limits is the service's limit", map[string]string{"compose.prod.yml": strings.Replace(goodCompose,
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    deploy: {resources: {limits: {cpus: \"0.5\", memory: 1g}}}\n", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(cpus=0.5,mem_limit=1g) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"deploy.resources.limits may hold the references", map[string]string{"compose.prod.yml": strings.Replace(goodCompose,
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    deploy: {resources: {limits: {cpus: \"${KASBAH_CPU_LIMIT}\", memory: \"${KASBAH_MEM_LIMIT}\"}}}\n", 1)}, 0,
			[]string{"  ✓ R01,R02 All services set cpus/mem_limit via KASBAH_* vars"}},
		{"two different values fail", map[string]string{"compose.prod.yml": strings.Replace(goodCompose,
			"    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    mem_limit: ${KASBAH_MEM_LIMIT}\n    deploy: {resources: {limits: {cpus: 1, memory: \"${KASBAH_MEM_LIMIT}\"}}}\n", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(cpus) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"the same limit spelled twice passes", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "    cpus: 0.5\n    deploy: {resources: {limits: {cpus: \"0.50\"}}}\n", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(cpus=0.5) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"the same size spelled twice passes", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    mem_limit: 512m\n    deploy: {resources: {limits: {memory: \"512M\"}}}\n", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(mem_limit=512m) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"two different sizes fail", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    mem_limit: 512m\n    deploy: {resources: {limits: {memory: 1g}}}\n", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"deploy memory as a number fails", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    deploy: {resources: {limits: {memory: 536870912}}}\n", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"deploy cpus as a number is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "    deploy: {resources: {limits: {cpus: 1}}}\n", 1)}, 0,
			[]string{"  ⚠ R01,R02 Services with literal resource limits: demo-web(cpus=1) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"missing cpus fails", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "", 1)}, 6,
			[]string{"  ✗ R01,R02 Services with missing or malformed resource limits: demo-web(cpus) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"drift", map[string]string{".env": "KASBAH_X=1\nEXTRA=2\r\n"}, 0,
			[]string{"  ⚠ E02 .env missing keys vs .env.prod.example: DOMAIN", "  ⚠ E03 .env has extra keys not in .env.prod.example: EXTRA"}},
		{"mail block of the wrong shape", map[string]string{"kasbah.yml": man + "mail: example.com\n"}, 6,
			[]string{"  ✗ M01 kasbah.yml: mail: is not a block — it has to be a block with a domain: under it"}},
		{"mail: \"\" is a mail: block deploy refuses", map[string]string{"kasbah.yml": man + "mail: \"\"\n"}, 6,
			[]string{"  ✗ M01 kasbah.yml: mail: is not a block — it has to be a block with a domain: under it"}},
		{"T05 matches a Host()'s first label whole",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers:\n    a: {rule: \"Host(`x\\nmail`)\", entryPoints: [web]}\n"}, 6,
			[]string{"  ✓ T05 No router claims reserved hostnames (traefik.*, mail.*, webmail.*)"}},
		{"client: true is not a repository name", map[string]string{"kasbah.yml": man + "client: true\n"}, 6,
			[]string{"  ✗ S08 kasbah.yml: client must be a string, not true"}},
		{"hooks: false is a hooks: block deploy refuses", map[string]string{"kasbah.yml": man + "hooks: false\n"}, 6,
			[]string{"  ✗ HK01 kasbah.yml: hooks: is not a block — it holds the lists backup:, pre-deploy:, post-deploy:, restore:, pre-rollback: and post-rollback:"}},
		{"HK01 refuses a hook list deploy does not run", map[string]string{"kasbah.yml": man + "hooks:\n  post-deploy: [\"demo-web true\"]\n  pre_deploy: [\"ghost true\"]\n"}, 6,
			[]string{"  ✗ HK01 kasbah.yml: hooks.pre_deploy is not a hook kasbah runs — hooks: holds the lists backup:, pre-deploy:, post-deploy:, restore:, pre-rollback: and post-rollback:"}},
		{"a hook entry that is not a string", map[string]string{"kasbah.yml": man + "hooks:\n  post-deploy: [{a: b}]\n"}, 6,
			[]string{"  ✗ HK01 kasbah.yml: hooks.post-deploy holds {\"a\":\"b\"} — each entry must be a string, one shell command"}},
		{"HK01 refuses a hook on two lines", map[string]string{"kasbah.yml": man + "hooks:\n  post-deploy:\n    - |\n      php artisan down\n      php artisan migrate\n"}, 6,
			[]string{"  ✗ HK01 kasbah.yml: the post-deploy hook 'php artisan down…' spans more than one line — a hook is one line of shell, and a multi-line value would be run as several hooks; chain with && or call a script"}},
		{"HK01 refuses an empty hook", map[string]string{"kasbah.yml": man + "hooks:\n  pre-deploy: [\"\"]\n"}, 6,
			[]string{"  ✗ HK01 kasbah.yml: hooks.pre-deploy holds an empty entry — each entry is one shell command"}},
		{"HK01 passes shell that names no container", map[string]string{"kasbah.yml": man + "hooks:\n  pre-deploy: [\"docker compose exec -T ghost true\"]\n"}, 0,
			[]string{"  ✓ HK01 Every hook is one line of shell"}},
		{"health: that is not a block", map[string]string{"kasbah.yml": man + "health: demo-web\n"}, 6,
			[]string{"  ✗ H02 kasbah.yml: health: is not a block — it holds container: and timeout:"}},
		{"H02 refuses a timeout deploy refuses", map[string]string{"kasbah.yml": man + "health: {container: demo-web, timeout: soon}\n"}, 6,
			[]string{"  ✗ H02 kasbah.yml: health.timeout 'soon' is not a duration kasbah can use — write it as 120s, 5m or 2h"}},
		{"HK02 refuses a top-level backup: block", map[string]string{"kasbah.yml": man + "backup: {check: true, command: dump, extension: sql, container: demo-web}\n"}, 6,
			[]string{"  ✗ HK02 kasbah.yml: backup: is not a key kasbah reads — a backup is the hooks.backup list, plain shell that writes into $KASBAH_BACKUP_DIR"}},
		{"HK02 refuses backup: whatever it holds", map[string]string{"kasbah.yml": man + "backup: false\n"}, 6,
			[]string{"  ✗ HK02 kasbah.yml: backup: is not a key kasbah reads — a backup is the hooks.backup list, plain shell that writes into $KASBAH_BACKUP_DIR"}},
		{"HK01 reads the backup and restore hooks", map[string]string{"kasbah.yml": man + "hooks:\n  backup: ['docker compose exec -T db pg_dump app > \"$KASBAH_BACKUP_DIR/db.sql\"']\n  restore: [\"\"]\n"}, 6,
			[]string{"  ✗ HK01 kasbah.yml: hooks.restore holds an empty entry — each entry is one shell command"}},
		{"HK01 passes a backup hook", map[string]string{"kasbah.yml": man + "hooks:\n  backup: ['pg_dump > \"$KASBAH_BACKUP_DIR/db.sql\"']\n  restore: ['psql < \"$KASBAH_BACKUP_DIR/db.sql\"']\n"}, 0,
			[]string{"  ✓ HK01 Every hook is one line of shell"}},
		{"T12: a declared ${KEY} passes, and T13 with it",
			map[string]string{"traefik-dynamic.yml": goodFragment + authMW("${AUTH_USERS}") + "# also $${LITERAL} and $apr1$x$y\n", ".env.prod.example": "DOMAIN=x\nAUTH_USERS=\n"}, 0,
			[]string{"  ✓ T12 Fragment's ${KEY}s are declared in .env.prod.example (AUTH_USERS) — a deploy fills them from the server's .env",
				"  ✓ T13 No ${KEY} in a router's rule, tls, service or middlewares, nor a service name T09 reads", "  ✓ T09 No router or service reaches a Traefik internal service other than noop@internal",
				"  ✓ T02 At least one router references manifest domain (demo.example.com)"}},
		{"T12: an undeclared ${KEY} fails",
			map[string]string{"traefik-dynamic.yml": goodFragment + authMW("${AUTH_USERS}") + "# ${OTHER}\n"}, 6,
			[]string{"  ✗ T12 Fragment names keys .env.prod.example does not declare: AUTH_USERS OTHER — a deploy fills ${KEY} from the server's .env, declared keys only"}},
		{"T12: a KASBAH_ key fails, even declared",
			map[string]string{"traefik-dynamic.yml": goodFragment + authMW("${KASBAH_CPU_LIMIT}"), ".env.prod.example": "DOMAIN=x\nKASBAH_CPU_LIMIT=1\n"}, 6,
			[]string{"  ✗ T12 Fragment names reserved KASBAH_* keys, which a deploy never fills it from: KASBAH_CPU_LIMIT"}},
		{"T13: a ${KEY} in a rule or under tls fails",
			map[string]string{"traefik-dynamic.yml": strings.Replace(strings.Replace(goodFragment, "Host(`demo.example.com`)\", entryPoints: [web]", "Host(`${HOST}`)\", entryPoints: [web]", 1),
				"certResolver: http", "certResolver: \"${RESOLVER}\"", 1), ".env.prod.example": "DOMAIN=x\nHOST=\nRESOLVER=\n"}, 6,
			[]string{"  ✓ T12 Fragment's ${KEY}s are declared in .env.prod.example (HOST RESOLVER) — a deploy fills them from the server's .env",
				"  ✗ T13 A ${KEY} where a host, resolver or service name must stay literal: demo.tls demo-http.rule"}},
		{"T13: a ${KEY} as a router's service or middleware fails",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "service: demo}", "service: \"${SVC}\", middlewares: [\"${MW}\"]}", 1), ".env.prod.example": "DOMAIN=x\nSVC=\nMW=\n"}, 6,
			[]string{"  ✗ T13 A ${KEY} where a host, resolver or service name must stay literal: demo.service demo.middlewares"}},
		{"T13: a ${KEY} as a service name T09 reads outside routers fails",
			map[string]string{"traefik-dynamic.yml": goodFragment + "    split: {weighted: {services: [{name: \"${W}\", weight: 1}]}}\n" +
				"  middlewares:\n    oops: {errors: {status: [\"500\"], service: \"${E}\", query: /}}\n", ".env.prod.example": "DOMAIN=x\nW=\nE=\n"}, 6,
			[]string{"  ✗ T13 A ${KEY} where a host, resolver or service name must stay literal: services.split middlewares.oops.errors.service"}},
		{"T12: reserved and undeclared keys on one line, reserved first",
			map[string]string{"traefik-dynamic.yml": goodFragment + authMW("${OTHER}") + "# ${KASBAH_CPU_LIMIT}\n"}, 6,
			[]string{"  ✗ T12 Fragment names reserved KASBAH_* keys, which a deploy never fills it from: KASBAH_CPU_LIMIT; and keys .env.prod.example does not declare: OTHER — a deploy fills ${KEY} from the server's .env, declared keys only"}},
		{"T12 reads a fragment YAML refuses; T13 needs it read",
			map[string]string{"traefik-dynamic.yml": "http: [\n# ${NOPE}\n"}, 6,
			[]string{"  ✗ T12 Fragment names keys .env.prod.example does not declare: NOPE — a deploy fills ${KEY} from the server's .env, declared keys only"}},
		{"a NUL ends a .gitignore line", map[string]string{".gitignore": "x\x00.env\x00.kasbah/"}, 0,
			[]string{"  ✓ S05 .gitignore excludes .env", "  ✓ S06 .gitignore excludes .kasbah/"}},
		{"a mail: key kasbah does not know is not read", map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nmail: {domain: x.io, snappymail_domain: ./x.json}\n"}, 0,
			[]string{"  ✓ M01 Mail claim names domain 'x.io'"}},
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

// hcCompose is goodCompose with demo-web's healthcheck set to hc, and the
// services in more appended.
func hcCompose(hc, more string) string {
	return strings.Replace(goodCompose, "    networks: [kasbah]\n", "    networks: [kasbah]\n    healthcheck: "+hc+"\n"+more, 1)
}

func TestH03(t *testing.T) {
	const late = "  ⚠ H03 demo-web's first healthcheck probe comes "
	const worker = "  demo-worker:\n    image: busybox\n    healthcheck: {test: [CMD, \"true\"], interval: 10m}\n"
	for _, tc := range []struct {
		name, compose, health string
		line                  string // "" is no H03 line
	}{
		{"interval past the timeout", `{test: [CMD, "true"], interval: 60s}`, "{timeout: 30s}",
			late + "60s after it starts, past health.timeout (30s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"interval equal to the timeout", `{test: [CMD, "true"], interval: 30s}`, "{timeout: 30s}", ""},
		{"interval unset is Docker's 30s", `{test: "true"}`, "{timeout: 20s}",
			late + "30s after it starts, past health.timeout (20s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"no health block waits 120s", `{test: [CMD, "true"], interval: 2m30s}`, "",
			late + "150s after it starts, past health.timeout (120s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"compose's compound durations", `{test: [CMD, "true"], interval: 1m30s}`, "", ""},
		{"sub-second durations", `{test: [CMD, "true"], interval: 500ms}`, "{timeout: 1s}", ""},
		{"start_interval inside a start_period", `{test: [CMD, "true"], interval: 60s, start_period: 30s, start_interval: 2s}`, "{timeout: 30s}", ""},
		{"a start_period alone probes every 5s", `{test: [CMD, "true"], interval: 60s, start_period: 30s}`, "{timeout: 30s}", ""},
		{"a start_period's default start_interval past the timeout", `{test: [CMD, "true"], interval: 60s, start_period: 30s}`, "{timeout: 4s}",
			late + "5s after it starts, past health.timeout (4s), so a deploy that creates or recreates it fails on health — set a shorter start_interval, or raise health.timeout"},
		{"a start_interval past the timeout", `{test: [CMD, "true"], interval: 10s, start_period: 1m, start_interval: 1500ms}`, "{timeout: 1s}",
			late + "1.5s after it starts, past health.timeout (1s), so a deploy that creates or recreates it fails on health — shorten healthcheck.start_interval, or raise health.timeout"},
		{"start_interval without a start_period", `{test: [CMD, "true"], interval: 60s, start_interval: 2s}`, "{timeout: 30s}",
			late + "60s after it starts, past health.timeout (30s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"days", `{test: [CMD, "true"], interval: 1d}`, "",
			late + "86400s after it starts, past health.timeout (120s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"days with Go's units", `{test: [CMD, "true"], interval: 1h1d}`, "",
			late + "90000s after it starts, past health.timeout (120s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"weeks", `{test: [CMD, "true"], interval: 1w}`, "",
			late + "604800s after it starts, past health.timeout (120s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"zero days is unset", `{test: [CMD, "true"], interval: 0d}`, "{timeout: 20s}",
			late + "30s after it starts, past health.timeout (20s), so a deploy that creates or recreates it fails on health — shorten healthcheck.interval or set a start_period (Docker 25 or later), or raise health.timeout"},
		{"disabled", `{disable: true, test: [CMD, "true"], interval: 10m}`, "", ""},
		{"NONE", `{test: [NONE], interval: 10m}`, "", ""},
		{"no test in compose", `{interval: 10m}`, "", ""},
		{"a duration compose refuses", `{test: [CMD, "true"], interval: soon}`, "{timeout: 1s}", ""},
		{"a bare number", `{test: [CMD, "true"], interval: 600}`, "{timeout: 1s}", ""},
		{"a negative duration", `{test: [CMD, "true"], interval: -1m}`, "{timeout: 1s}", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			m := man
			if tc.health != "" {
				m += "health: " + tc.health + "\n"
			}
			project(t, map[string]string{"kasbah.yml": m, "compose.prod.yml": hcCompose(tc.compose, "")})
			out, _, code := check(t)
			if code != 0 {
				t.Errorf("exit %d:\n%s", code, out)
			}
			if tc.line == "" && strings.Contains(out, "first healthcheck probe") {
				t.Errorf("H03 should be silent:\n%s", out)
			}
			if tc.line != "" && !strings.Contains(out, "Healthchecks:\n") {
				t.Errorf("no Healthchecks: section to carry H03:\n%s", out)
			}
			if tc.line != "" && !strings.Contains(out, tc.line+"\n") {
				t.Errorf("no line %q in:\n%s", tc.line, out)
			}
		})
	}
	// The wait covers health.container alone, or every service, and every
	// service that rolls. demo-web probes at 5s unless a case says otherwise.
	const fast, slow = `{test: [CMD, "true"], interval: 5s}`, `{test: [CMD, "true"], interval: 60s}`
	noCN := func(c string) string { return strings.Replace(c, "    container_name: demo-web\n", "", 1) }
	workerCN := func(cn string) string {
		return strings.Replace(worker, "  demo-worker:\n", "  demo-worker:\n    container_name: "+cn+"\n", 1)
	}
	for _, tc := range []struct {
		name, compose, health string
		warned                []string
		fragment              string // "" is goodFragment
	}{
		{"every service", hcCompose(fast, worker), "{timeout: 30s}", []string{"demo-worker"}, ""},
		{"health.container elsewhere", hcCompose(fast, worker), "{container: demo-web, timeout: 30s}", nil, ""},
		{"health.container names the service", hcCompose(fast, worker), "{container: demo-worker, timeout: 30s}", []string{"demo-worker"}, ""},
		{"health.container compose lacks", hcCompose(fast, worker), "{container: ghost, timeout: 30s}", nil, ""},
		{"a timeout deploy refuses", hcCompose(fast, worker), "{timeout: soon}", nil, ""},
		{"health.container names a container_name", hcCompose(fast, workerCN("wk")), "{container: wk, timeout: 30s}", []string{"demo-worker"}, ""},
		{"a container_name wins over a service name", noCN(hcCompose(fast, workerCN("demo-web"))), "{container: demo-web, timeout: 30s}", []string{"demo-worker"}, ""},
		{"a rolling service is waited on whatever health.container says", noCN(hcCompose(slow, worker)), "{container: demo-worker, timeout: 30s}", []string{"demo-web", "demo-worker"}, ""},
		{"a routed service that cannot roll is not", hcCompose(slow, worker), "{container: demo-worker, timeout: 30s}", []string{"demo-worker"}, ""},
		{"nor one the fragment does not route", noCN(hcCompose(slow, worker)), "{container: demo-worker, timeout: 30s}", []string{"demo-worker"},
			strings.Replace(goodFragment, "http://demo-web:80", "http://elsewhere:80", 1)},
	} {
		t.Run(tc.name, func(t *testing.T) {
			files := map[string]string{"kasbah.yml": man + "health: " + tc.health + "\n", "compose.prod.yml": tc.compose}
			if tc.fragment != "" {
				files["traefik-dynamic.yml"] = tc.fragment
			}
			project(t, files)
			out, _, _ := check(t)
			for _, svc := range []string{"demo-web", "demo-worker"} {
				got := strings.Contains(out, "  ⚠ H03 "+svc+"'s first healthcheck probe comes ")
				if want := inList(tc.warned, svc); got != want {
					t.Errorf("%s warned %v, want %v:\n%s", svc, got, want, out)
				}
			}
		})
	}
}

// A question the run cannot answer names the file and the key, in words.
func TestUnanswerable(t *testing.T) {
	for _, tc := range []struct{ compose, fragment, want string }{
		{"services:\n  web: nginx\n", "", "error: cannot check compose.prod.yml: services.web is a string, not a mapping\n"},
		{"services:\n  web: {image: x}\nnetworks: [a]\n", "", "error: cannot check compose.prod.yml: networks is a list, not a mapping\n"},
		{"", "http:\n  routers:\n    a: {rule: x, entryPoints: [websecure], tls: true}\n",
			"error: cannot check traefik-dynamic.yml: http.routers.a.tls is a boolean, not a mapping\n"},
	} {
		files := map[string]string{}
		if tc.compose != "" {
			files["compose.prod.yml"] = tc.compose
		}
		if tc.fragment != "" {
			files["traefik-dynamic.yml"] = tc.fragment
		}
		project(t, files)
		out, errs, code := check(t)
		if code != 1 || errs != tc.want || strings.Contains(out, "Summary:") {
			t.Errorf("exit %d, stderr %q, want %q:\n%s", code, errs, tc.want, out)
		}
	}
}

// rollCompose is a routed service that rolls: no container_name, no host
// port, a healthcheck, no gating depends_on.
const rollCompose = `services:
  demo-web:
    image: nginx:alpine
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
    healthcheck: {test: [CMD, wget, -q, --spider, "http://127.0.0.1/"]}
    networks: [kasbah, internal]
  db:
    image: postgres
    restart: always
    cpus: 1
    mem_limit: 1g
    logging: {driver: json-file, options: {max-size: 1m, max-file: 1}}
    networks: [internal]
networks:
  kasbah: {}
  internal: {}
`

func TestC11(t *testing.T) {
	web := "    networks: [kasbah, internal]\n  db:"
	with := func(lines string) string { return strings.Replace(rollCompose, web, lines+web, 1) }
	noHC := strings.Replace(rollCompose, "    healthcheck: {test: [CMD, wget, -q, --spider, \"http://127.0.0.1/\"]}\n", "", 1)
	const unrouted = ", so it is recreated in place, briefly unrouted"
	for _, tc := range []struct{ name, compose, want string }{
		{"a rollable service passes", rollCompose, "  ✓ C11 All routed services can roll on deploy"},
		{"a container_name the fragment does not target", with("    container_name: demo-web-1\n"),
			"  ⚠ C11 demo-web will not roll on deploy — it sets container_name" + unrouted},
		{"a host port", with("    ports: [\"127.0.0.1:8080:80\"]\n"),
			"  ⚠ C11 demo-web will not roll on deploy — it publishes a host port a second replica cannot bind" + unrouted},
		{"a host port in the long form", with("    ports: [{target: 80, published: 8080}]\n"),
			"  ⚠ C11 demo-web will not roll on deploy — it publishes a host port a second replica cannot bind" + unrouted},
		{"an ephemeral port binds nothing", with("    ports: [\"80\", \"127.0.0.1::81\", 82]\n"), "  ✓ C11 All routed services can roll on deploy"},
		{"no compose healthcheck leaves it to the image", noHC,
			"  ⚠ C11 demo-web rolls on deploy only if its image declares a HEALTHCHECK — compose gives it none, and without one it is recreated in place, briefly unrouted"},
		{"a shell-string healthcheck is one", strings.Replace(rollCompose, "{test: [CMD, wget, -q, --spider, \"http://127.0.0.1/\"]}", "{test: \"wget -q --spider http://127.0.0.1/\"}", 1),
			"  ✓ C11 All routed services can roll on deploy"},
		{"a disabled healthcheck", strings.Replace(rollCompose, "{test: [CMD", "{disable: true, test: [CMD", 1),
			"  ⚠ C11 demo-web will not roll on deploy — it declares no healthcheck to swap on" + unrouted},
		{"a gating depends_on", with("    depends_on: {db: {condition: service_healthy}}\n"),
			"  ⚠ C11 demo-web will not roll on deploy — it depends_on db (service_healthy), a condition only a plain up waits for" + unrouted},
		{"a plain depends_on list does not gate", with("    depends_on: [db]\n"), "  ✓ C11 All routed services can roll on deploy"},
		{"a definite reason outranks the image's healthcheck",
			strings.Replace(noHC, web, "    depends_on: {db: {condition: service_completed_successfully}}\n"+web, 1),
			"  ⚠ C11 demo-web will not roll on deploy — it depends_on db (service_completed_successfully), a condition only a plain up waits for" + unrouted},
		{"the fragment targeting its container_name", goodCompose,
			"  ⚠ C11 demo-web will not roll on deploy — the fragment targets its container_name" + unrouted},
		{"reached by name off the project network", strings.Replace(legacyCompose, "    container_name: demo-web\n", "", 1),
			"  ⚠ C11 demo-web will not roll on deploy — the fragment reaches it by a name it answers only off the project's kasbah network" + unrouted},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, map[string]string{"compose.prod.yml": tc.compose})
			out, _, _ := check(t)
			if !strings.Contains(out, tc.want+"\n") {
				t.Errorf("no line %q in:\n%s", tc.want, out)
			}
			if n := strings.Count(out, "roll on deploy") + strings.Count(out, "rolls on deploy"); n != 1 {
				t.Errorf("%d roll lines, want one:\n%s", n, out)
			}
			if strings.Contains(out, "db will not roll") || strings.Contains(out, "db rolls") {
				t.Errorf("an unrouted service is reported:\n%s", out)
			}
		})
	}
	project(t, map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": noHC})
	if out, _, _ := check(t); strings.Contains(out, "roll") {
		t.Errorf("with no fragment read, nothing is said of rolling:\n%s", out)
	}
}

func TestC11NoRoll(t *testing.T) {
	web := "    networks: [kasbah, internal]\n  db:"
	with := func(compose, lines string) string { return strings.Replace(compose, web, lines+web, 1) }
	block := rollCompose[strings.Index(rollCompose, "  demo-web:"):strings.Index(rollCompose, "  db:")]
	two := strings.Replace(rollCompose, "  db:", strings.Replace(block, "demo-web", "demo-api", 1)+"  db:", 1)
	twoFragment := strings.Replace(goodFragment, `[{url: "http://demo-web:80"}]`, `[{url: "http://demo-web:80"}, {url: "http://demo-api:80"}]`, 1)
	const inPlace = " — its old containers stop before the new ones start, briefly unrouted"
	webLine := "  ✓ C11 demo-web is recreated in place on deploy, as it is labelled kasbah.noRoll" + inPlace
	apiLine := "  ✓ C11 demo-api is recreated in place on deploy, as it is labelled kasbah.noRoll" + inPlace
	for _, tc := range []struct {
		name, compose, fragment string
		want, not               []string
	}{
		{"labelled, other reasons go unsaid", with(rollCompose, "    container_name: demo-web-1\n    ports: [\"8080:80\"]\n    labels: {kasbah.noRoll: true}\n"), "",
			[]string{webLine}, []string{"will not roll", "can roll"}},
		{"list form, any key case, ParseBool's 1", with(rollCompose, "    labels: [\"kasbah.noroll=1\"]\n"), "",
			[]string{webLine}, []string{"can roll"}},
		{"false rolls", with(rollCompose, "    labels: {kasbah.noRoll: \"false\"}\n"), "",
			[]string{"  ✓ C11 All routed services can roll on deploy"}, []string{"recreated in place on deploy"}},
		{"a value that is no boolean reads as true", with(rollCompose, "    labels: {kasbah.noRoll: \"yes\"}\n"), "",
			[]string{"  ✓ C11 demo-web is recreated in place on deploy, as it is labelled kasbah.noRoll=yes, which reads as true" + inPlace}, nil},
		{"an interpolated value leaves C11 as it was", with(rollCompose, "    container_name: demo-web-1\n    labels: {kasbah.noRoll: \"${NR}\"}\n"), "",
			[]string{"  ⚠ C11 demo-web will not roll on deploy — it sets container_name, so it is recreated in place, briefly unrouted"}, []string{"recreated in place on deploy"}},
		{"a $VAR value leaves C11 as it was", with(rollCompose, "    container_name: demo-web-1\n    labels: {kasbah.noRoll: $NR}\n"), "",
			[]string{"  ⚠ C11 demo-web will not roll on deploy — it sets container_name, so it is recreated in place, briefly unrouted"}, []string{"recreated in place on deploy"}},
		{"$$ is a literal, so no boolean", with(rollCompose, "    labels: {kasbah.noRoll: \"$${NR}\"}\n"), "",
			[]string{"  ✓ C11 demo-web is recreated in place on deploy, as it is labelled kasbah.noRoll=$${NR}, which reads as true" + inPlace}, nil},
		{"a whole-number float reads as compose renders it", with(rollCompose, "    labels: {kasbah.noRoll: 0.0}\n"), "",
			[]string{"  ✓ C11 All routed services can roll on deploy"}, []string{"recreated in place on deploy"}},
		{"the others roll", with(two, "    labels: {kasbah.noRoll: \"true\"}\n"), twoFragment,
			[]string{"  ✓ C11 All other routed services can roll on deploy", apiLine}, []string{"demo-web is recreated", "All routed services can roll"}},
		{"another one warns", strings.Replace(with(two, "    labels: {kasbah.noRoll: \"true\"}\n"), "  demo-web:\n", "  demo-web:\n    container_name: demo-web-1\n", 1), twoFragment,
			[]string{"  ⚠ C11 demo-web will not roll on deploy — it sets container_name, so it is recreated in place, briefly unrouted", apiLine}, []string{"can roll"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			files := map[string]string{"compose.prod.yml": tc.compose}
			if tc.fragment != "" {
				files["traefik-dynamic.yml"] = tc.fragment
			}
			project(t, files)
			out, _, _ := check(t)
			for _, w := range tc.want {
				if !strings.Contains(out, w+"\n") {
					t.Errorf("no line %q in:\n%s", w, out)
				}
			}
			for _, n := range tc.not {
				if strings.Contains(out, n) {
					t.Errorf("%q in:\n%s", n, out)
				}
			}
		})
	}
}

func TestC15(t *testing.T) {
	with := func(lines string) string {
		return strings.Replace(rollCompose, "    networks: [internal]\n", lines+"    networks: [internal]\n", 1)
	}
	const pass = "  ✓ C15 Every kasbah.noRoll label is a boolean"
	for _, tc := range []struct{ name, compose, want string }{
		{"a boolean passes, on an unrouted service too", with("    labels: {kasbah.noRoll: true}\n"), pass},
		{"ParseBool's forms, in the list form", with("    labels: [\"KASBAH.NOROLL=F\", other=x]\n"), pass},
		{"no boolean", with("    labels: {kasbah.noRoll: \"yes\"}\n"),
			"  ✗ C15 db: kasbah.noRoll is 'yes', not a boolean — write true or false; a deploy reads it as true"},
		{"no value", with("    labels: [kasbah.noroll]\n"),
			"  ✗ C15 db: kasbah.noroll is '', not a boolean — write true or false; a deploy reads it as true"},
		{"1.0 is compose's 1", with("    labels: {kasbah.noRoll: 1.0}\n"), pass},
		{"$$ is a literal", with("    labels: {kasbah.noRoll: \"$$NR\"}\n"),
			"  ✗ C15 db: kasbah.noRoll is '$$NR', not a boolean — write true or false; a deploy reads it as true"},
		{"interpolated as $VAR", with("    labels: {kasbah.noRoll: $NR}\n"),
			"  ⚠ C15 db: kasbah.noRoll is '$NR' — check cannot resolve it; a deploy reads the resolved value, and anything but a false boolean as true"},
		{"interpolated", with("    labels: {kasbah.noRoll: \"${NR}\"}\n"),
			"  ⚠ C15 db: kasbah.noRoll is '${NR}' — check cannot resolve it; a deploy reads the resolved value, and anything but a false boolean as true"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, map[string]string{"compose.prod.yml": tc.compose})
			out, _, _ := check(t)
			if !strings.Contains(out, tc.want+"\n") {
				t.Errorf("no line %q in:\n%s", tc.want, out)
			}
			if n := strings.Count(out, " C15 "); n != 1 {
				t.Errorf("%d C15 lines, want one:\n%s", n, out)
			}
		})
	}
	project(t, map[string]string{"compose.prod.yml": rollCompose})
	if out, _, _ := check(t); strings.Contains(out, "C15") {
		t.Errorf("C15 speaks with no label:\n%s", out)
	}
}

func TestC16(t *testing.T) {
	web := "    networks: [kasbah, internal]\n  db:"
	with := func(lines string) string { return strings.Replace(rollCompose, web, lines, 1) }
	const why = " — Docker answers a dotted name on every network Traefik is on, so it could answer for another project's backend; a deploy refuses it"
	for _, tc := range []struct{ name, compose, want string }{
		{"a kasbah alias", with("    networks: {kasbah: {aliases: [demo-www, web.other_kasbah]}, internal: {}}\n  db:"),
			"  ✗ C16 Names on the kasbah network or kasbah-net with a dot: web.other_kasbah (alias of demo-web)" + why},
		{"a container_name and a service name", strings.Replace(with("    container_name: demo.web\n"+web), "  demo-web:", "  demo.site:", 1),
			"  ✗ C16 Names on the kasbah network or kasbah-net with a dot: demo.site (service) demo.web (container_name of demo.site)" + why},
		// Traefik is on kasbah-net too, joined by name or as the default network.
		{"a kasbah-net alias", strings.Replace(legacyCompose, "    networks: [kasbah-net]\n", "    networks: {kasbah-net: {aliases: [web.victim_kasbah]}}\n", 1),
			"  ✗ C16 Names on the kasbah network or kasbah-net with a dot: web.victim_kasbah (alias of demo-web)" + why},
		{"a default network named kasbah-net", strings.Replace(strings.Replace(legacyCompose, "    networks: [kasbah-net]\n", "", 1), "container_name: demo-web", "container_name: web.victim_kasbah", 1) + "  default: {name: kasbah-net, external: true}\n",
			"  ✗ C16 Names on the kasbah network or kasbah-net with a dot: web.victim_kasbah (container_name of demo-web)" + why},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, map[string]string{"compose.prod.yml": tc.compose})
			if out, _, code := check(t); !strings.Contains(out, tc.want+"\n") || code == 0 {
				t.Errorf("exit %d, no line %q in:\n%s", code, tc.want, out)
			}
		})
	}
	// Off the kasbah network a dot is no business of C16's; silent when it passes.
	project(t, map[string]string{"compose.prod.yml": strings.Replace(rollCompose, "    networks: [internal]\n", "    container_name: db.internal\n    networks: [internal]\n", 1)})
	if out, _, _ := check(t); strings.Contains(out, "C16") {
		t.Errorf("C16 speaks:\n%s", out)
	}
}

func TestC14(t *testing.T) {
	with := func(ports string) string {
		return strings.Replace(relayCompose, `    ports: ["5000:5000/udp"]`, "    ports: "+ports, 1)
	}
	const why = " — those ports belong to the shared Traefik, whatever the protocol (over TCP a bind collides with it, a range may take them while it is down); route through traefik-dynamic.yml or publish another port"
	for _, tc := range []struct{ name, ports, want string }{
		{"other host ports pass", `["8080:80", "443", "127.0.0.1::443", "8443:443/udp", "${P:-80}:80"]`, "  ✓ C14 No service publishes host port 80 or 443"},
		{"short form, any address", `["80:8080", "127.0.0.1:443:8443"]`, "  ✗ C14 Services publishing host port 80 or 443: demo-relay (80/tcp) demo-relay (127.0.0.1:443/tcp)" + why},
		{"IPv6 and UDP", `["[::1]:443:443/udp"]`, "  ✗ C14 Services publishing host port 80 or 443: demo-relay ([::1]:443/udp)" + why},
		{"long form", `[{target: 8080, published: 80, host_ip: 0.0.0.0}, {target: 443, published: "443", protocol: UDP}]`,
			"  ✗ C14 Services publishing host port 80 or 443: demo-relay (0.0.0.0:80/tcp) demo-relay (443/udp)" + why},
		{"target alone publishes nothing", `[{target: 80}]`, "  ✓ C14 No service publishes host port 80 or 443"},
		{"only the host port's interpolation skips", `["${IP}:80:80"]`, "  ✗ C14 Services publishing host port 80 or 443: demo-relay (${IP}:80/tcp)" + why},
		{"a host range holding 80 or 443", `["70-90:80", "400-500:400-500", "81-442:81-442"]`,
			"  ✗ C14 Services publishing host port 80 or 443: demo-relay (70-90/tcp) demo-relay (400-500/tcp)" + why},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nrouted: false\n", "compose.prod.yml": with(tc.ports), "traefik-dynamic.yml": ""})
			out, _, code := check(t)
			if !strings.Contains(out, tc.want+"\n") {
				t.Errorf("no line %q in:\n%s", tc.want, out)
			}
			if fail := strings.HasPrefix(tc.want, "  ✗"); fail != (code != 0) {
				t.Errorf("exit %d for %q", code, tc.want)
			}
		})
	}
}

func TestC10SkipsComments(t *testing.T) {
	project(t, map[string]string{".env.prod.example": "# c\r\n  # SMTP_HOST=mail-dms was the old way\r\nDOMAIN=x\r\n"})
	if out, _, _ := check(t); strings.Contains(out, "mail-dms") {
		t.Fatalf("a commented mail-dms warned:\n%s", out)
	}
	project(t, map[string]string{"compose.prod.yml": goodCompose + "x-smtp: mail-dms # still used\n"})
	if out, _, _ := check(t); !strings.Contains(out, "⚠ C10 mail-dms is named in compose.prod.yml — ") {
		t.Fatalf("a used mail-dms did not warn:\n%s", out)
	}
}

// The footer names the first failed rule, even after a warning.
func TestFooterPrefersFailure(t *testing.T) {
	var b bytes.Buffer
	c := &checker{w: &b}
	c.warnf("S05", "warned")
	c.failf("C01,C02", "failed")
	c.footer()
	if !strings.HasSuffix(b.String(), "`kasbah help C01` (or any ID above) says why a rule exists and what to change.\n") {
		t.Errorf("footer:\n%s", b.String())
	}
}
