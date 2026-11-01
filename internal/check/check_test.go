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
  ✓ All routed services join the project's kasbah network
  ✓ The kasbah network is the project's own (demo_kasbah)
  ✓ No internal services on the kasbah network or kasbah-net
  ✓ Names on the kasbah network are project-prefixed
  ✓ No deprecated 'version:' field
  ⚠ demo-web will not roll on deploy — the fragment targets its container_name, so it is recreated in place, briefly unrouted

Resources:
  ✓ All services set cpus/mem_limit via KASBAH_* vars
  ✓ No resource reservations

Traefik:
  ✓ traefik-dynamic.yml exists
  ✓ At least one router references manifest domain (demo.example.com)
  ✓ All routers declare entryPoints
  ✓ Secure routers reference http cert resolver
  ✓ A router serves demo.example.com on the web entrypoint
  ✓ No router claims reserved hostnames (traefik.*, mail.*, webmail.*)
  ✓ No router or service reaches a Traefik internal service other than noop@internal
  ✓ Fragment loadBalancer URLs target a service, alias or container_name compose defines
  ✓ compose.prod.yml has no traefik.* labels

Env:
  ✓ .env.prod.example syntax is valid
  ✓ .env.prod.example has no obvious long secrets
  ✓ .env.prod.example leaves the KASBAH_* prefix to kasbah

Summary: 27 passed, 1 warning, 0 failed
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
			[]string{"  ✗ Services missing restart policy: web"}},
		{"a service name is a name, quotes and backslashes included",
			map[string]string{"compose.prod.yml": "services:\n  'a\"b': {image: nginx}\n  'c\\nd': {image: nginx}\n"}, 6,
			[]string{"  ✗ Services missing restart policy: a\"b c\\nd"}},
		{"services: that is not a mapping",
			map[string]string{"compose.prod.yml": "services: [web]\n"}, 6,
			[]string{"  ✗ compose.prod.yml: services is a list, not a mapping", "  ✓ No deprecated 'version:' field"}},
		{"a compose document that is not a mapping",
			map[string]string{"compose.prod.yml": "[a]\n"}, 6,
			[]string{"  ✗ compose.prod.yml: the document is a list, not a mapping"}},
		{"version: false is still a version: field",
			map[string]string{"compose.prod.yml": goodCompose + "version: false\n"}, 0,
			[]string{"  ⚠ compose.prod.yml uses deprecated 'version:' field"}},
		{"external: only a boolean true is external",
			map[string]string{"compose.prod.yml": strings.Replace(legacyCompose, "{external: true}", "{external: \"true\"}", 1)}, 6,
			[]string{"  ✗ kasbah-net not declared external: true"}},
		{"resources: well formed",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nresources:\n  cpus: 1.5\n  memory: 50%\n"}, 0,
			[]string{"  ✓ resources: cpus 1.5, memory 50% — resolved on the server at deploy (a % is a share of the host) and held to its 90% ceiling"}},
		{"resources: a bare memory fails naming the units",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nresources:\n  memory: 512\n"}, 6,
			[]string{"  ✗ kasbah.yml: resources.memory '512' has no unit — memory takes MiB (512m), GiB (2g) or a share of the host (50%) — m, g or %"}},
		{"resources: is judged without a compose file",
			map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nresources: {cpus: 0}\n", "compose.prod.yml": ""}, 6,
			[]string{"  ✗ kasbah.yml: resources.cpus '0' is not a limit — cpus takes a number of cores with at most one decimal (0.5, 2) or a share of the host (50%)"}},
		{"reservations: false is still a reservation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    networks: [kasbah]\n", "    networks: [kasbah]\n    deploy: {resources: {reservations: false}}\n", 1)}, 6,
			[]string{"  ✗ Services declare resource reservations: demo-web"}},
		{"routers: that is not a mapping skips the router rules",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers: [a]\n"}, 0,
			[]string{"  ⚠ traefik-dynamic.yml: http.routers is a list, not a mapping — skipping T02–T05, T08 and T09",
				"  ⚠ traefik-dynamic.yml: http.routers is a list, not a mapping — skipping C03, C07 and C11, which need the services it routes"}},
		{"with no fragment read, C03, C07 and C11 conclude nothing",
			map[string]string{"traefik-dynamic.yml": ""}, 0,
			[]string{"  ⚠ traefik-dynamic.yml missing — skipping C03, C07 and C11, which need the services it routes", "  ✓ The kasbah network is the project's own (demo_kasbah)"}},
		{"with no fragment read and nothing on kasbah-net, C07 still passes",
			map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": strings.Replace(goodCompose, "networks: [kasbah]", "networks: [internal]", 1)}, 0,
			[]string{"  ⚠ traefik-dynamic.yml missing — skipping C03 and C11, which need the services it routes", "  ✓ No internal services on the kasbah network or kasbah-net"}},
		{"with no fragment read, the default-alias shape still fails C07",
			map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": legacyCompose + "  default: {name: kasbah-net}\n"}, 6,
			[]string{"  ⚠ traefik-dynamic.yml missing — skipping C03 and C11, which need the services it routes", "  ✗ default network aliases kasbah-net — every service joins the shared network; join it explicitly per routed service and keep the rest on a project-internal network"}},
		{"a legacy project on kasbah-net passes C03 and is warned to move",
			map[string]string{"compose.prod.yml": legacyCompose}, 0,
			[]string{"  ✓ All routed services join kasbah-net", "  ⚠ Routed through the shared kasbah-net: demo-web — every project's routed containers reach each other there; move them to a project network under the key kasbah (docs/traefik.md → Network)",
				"  ✓ kasbah-net declared external", "  ✓ kasbah-net service names are project-prefixed"}},
		{"a routed service on neither network fails C03",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "networks: [kasbah]", "networks: [internal]", 1)}, 6,
			[]string{"  ✗ Routed services on neither the project's kasbah network nor kasbah-net: demo-web"}},
		{"an external kasbah network fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah: {external: true}", 1)}, 6,
			[]string{"  ✗ The kasbah network is declared external — it is the project's own: drop external: so compose creates demo_kasbah, which deploy connects Traefik to"}},
		{"a renamed kasbah network fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah: {name: shared}", 1)}, 6,
			[]string{"  ✗ The kasbah network sets name — declare it as kasbah: {}: compose recreates a network whose settings change, which fails while Traefik is attached, and every later deploy would fail at up"}},
		{"any setting on the kasbah network fails C04, naming it",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah: {driver: bridge, labels: {a: b}}", 1)}, 6,
			[]string{"  ✗ The kasbah network sets driver, labels — declare it as kasbah: {}: compose recreates a network whose settings change, which fails while Traefik is attached, and every later deploy would fail at up"}},
		{"a null kasbah network is as empty as {}",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "kasbah: {}", "kasbah:", 1)}, 0,
			[]string{"  ✓ The kasbah network is the project's own (demo_kasbah)"}},
		{"another stack's network, taken external, fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "  kasbah: {}\n", "  kasbah: {}\n  m: {name: mail_kasbah, external: true}\n  o: {external: {name: shop_kasbah}}\n", 1)}, 6,
			[]string{"  ✗ External networks other than kasbah-net: m (mail_kasbah) o (shop_kasbah) — a project joins only its own networks and the legacy kasbah-net"}},
		{"a name on the kasbah network not named for the project fails C09",
			map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, "  demo-web:\n", "  web:\n", 1),
				"    networks: [kasbah]\n", "    networks: {kasbah: {aliases: [demo-api, krvb-w]}}\n", 1)}, 6,
			[]string{"  ✗ Names on the kasbah network that are not 'demo' or 'demo-*': web (service) krvb-w (alias of web) — Traefik resolves names across every project's network, so another project's name can answer for this one's"}},
		{"a container_name on the kasbah network not named for the project fails C09",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "container_name: demo-web", "container_name: krvb-w", 1),
				"traefik-dynamic.yml": strings.Replace(goodFragment, "demo-web:80", "krvb-w:80", 1)}, 6,
			[]string{"  ✗ Names on the kasbah network that are not 'demo' or 'demo-*': krvb-w (container_name of demo-web) — Traefik resolves names across every project's network, so another project's name can answer for this one's"}},
		{"a commented mail-dms is not a use of it",
			map[string]string{".env.prod.example": "# c\n# SMTP_HOST=mail-dms was the old way\nDOMAIN=x\n"}, 0,
			[]string{"  ✓ .env.prod.example syntax is valid"}},
		{"an undeclared kasbah network fails C04",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "  kasbah: {}\n", "  other: {}\n", 1)}, 6,
			[]string{"  ✗ The kasbah network is not declared under the top-level networks: — add kasbah: {}"}},
		{"a non-routed service on the kasbah network fails C07",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "networks:\n  kasbah", "  db: {image: postgres, restart: always, cpus: 1, mem_limit: 1g, logging: {driver: json-file, options: {max-size: 1m, max-file: 1}}, networks: [kasbah]}\nnetworks:\n  kasbah", 1)}, 6,
			[]string{"  ✗ Non-routed services on the kasbah network: db — Traefik joins it, so only what it routes belongs there"}},
		{"a compose or env template naming mail-dms is warned",
			map[string]string{".env.prod.example": "# c\nSMTP_HOST=mail-dms\n"}, 0,
			[]string{"  ⚠ mail-dms is named in .env.prod.example — no project shares a network with the mail server; send through mail.<domain>:587 with a mailbox login (docs/mail.md → SMTP access from apps)"}},
		{"max-size: false is no rotation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "max-size: 10m", "max-size: false", 1)}, 6,
			[]string{"  ✗ Services missing json-file logging with max-size/max-file: demo-web"}},
		{"max-file: {a: 1} is no rotation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, `max-file: "3"`, "max-file: {a: 1}", 1)}, 6,
			[]string{"  ✗ Services missing json-file logging with max-size/max-file: demo-web"}},
		{"numeric rotation values are given",
			map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, `max-file: "3"`, "max-file: 3", 1), "max-size: 10m", "max-size: 1000", 1)}, 0,
			[]string{"  ✓ All services set json-file logging with rotation"}},
		{"a fragment of several documents is not read",
			map[string]string{"traefik-dynamic.yml": goodFragment + "---\n" + goodFragment}, 0,
			[]string{"  ⚠ traefik-dynamic.yml holds 2 YAML documents, where kasbah reads one — skipping T02–T05, T08 and T09",
				"  ⚠ traefik-dynamic.yml holds 2 YAML documents, where kasbah reads one — skipping C03, C07 and C11, which need the services it routes"}},
		{"entryPoints: that is not a list",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "entryPoints: [web]", "entryPoints: web", 1)}, 6,
			[]string{"  ✗ Routers without entryPoints: demo-http (entryPoints is a string, not a list)"}},
		{"T09 fails a router on api@internal, names router and service",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "service: demo}", "service: api@internal}", 1)}, 6,
			[]string{"  ✗ Fragment routes to Traefik's internal services (only noop@internal is allowed): demo→api@internal"}},
		{"T09 fails weighted, mirroring and failover entries on @internal",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "  services:\n",
				"  services:\n    w: {weighted: {services: [{name: demo}, {name: dashboard@internal}]}}\n"+
					"    m: {mirroring: {service: rest@internal, mirrors: [{name: ping@internal}, {name: noop@internal}]}}\n"+
					"    f: {failover: {service: demo, fallback: api@internal}}\n"+
					"    h: {highestRandomWeight: {services: [{name: api@internal}, {name: api@internal}]}}\n", 1)}, 6,
			[]string{"  ✗ Fragment routes to Traefik's internal services (only noop@internal is allowed): services.f→api@internal services.h→api@internal services.m→rest@internal services.m→ping@internal services.w→dashboard@internal"}},
		{"T09 fails an errors middleware's service on @internal",
			map[string]string{"traefik-dynamic.yml": goodFragment + "  middlewares:\n    oops: {errors: {status: [\"500\"], service: api@internal, query: /}}\n"}, 6,
			[]string{"  ✗ Fragment routes to Traefik's internal services (only noop@internal is allowed): middlewares.oops→api@internal"}},
		{"T09 passes noop@internal",
			nil, 0,
			[]string{"  ✓ No router or service reaches a Traefik internal service other than noop@internal"}},
		{"local T05 is the first-label heuristic",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers:\n    a: {rule: \"Host(`mail.x.io`) || Host(`mailhog.x.io`)\", entryPoints: [web]}\n"}, 6,
			[]string{"  ✗ Routers claim reserved hostnames: a→mail.x.io"}},
		{"cpus: 0.5 is a literal, warned locally", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "0.5", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(cpus=0.5) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"quoted cpus and a size are literals", map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", `"1.5"`, 1), "${KASBAH_MEM_LIMIT}", "2G", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(cpus=1.5,mem_limit=2G) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"a byte count is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", "536870912", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=536870912) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"cpus: 0 is no limit", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "0", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(cpus) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"malformed literals fail", map[string]string{"compose.prod.yml": strings.Replace(strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", "1,5", 1), "${KASBAH_MEM_LIMIT}", "{a: 1}", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(cpus,mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"another variable is not a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", "${MY_MEM}", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"mem_limit: 1.5g is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `1.5g`, 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=1.5g) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 2GiB is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `2GiB`, 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=2GiB) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 1t is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `1t`, 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=1t) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 512 MB is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `"512 MB"`, 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=512 MB) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"mem_limit: 6m is a size docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `6m`, 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=6m) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"512mi is no unit docker reads", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `512mi`, 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"512 bytes is under docker's 6m minimum", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `512`, 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"99999999999t overflows", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `99999999999t`, 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"5.5.5m is no number", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_MEM_LIMIT}", `5.5.5m`, 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"cpus: \".5\" is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", `".5"`, 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(cpus=.5) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"deploy.resources.limits is the service's limit", map[string]string{"compose.prod.yml": strings.Replace(goodCompose,
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    deploy: {resources: {limits: {cpus: \"0.5\", memory: 1g}}}\n", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(cpus=0.5,mem_limit=1g) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"deploy.resources.limits may hold the references", map[string]string{"compose.prod.yml": strings.Replace(goodCompose,
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    deploy: {resources: {limits: {cpus: \"${KASBAH_CPU_LIMIT}\", memory: \"${KASBAH_MEM_LIMIT}\"}}}\n", 1)}, 0,
			[]string{"  ✓ All services set cpus/mem_limit via KASBAH_* vars"}},
		{"two different values fail", map[string]string{"compose.prod.yml": strings.Replace(goodCompose,
			"    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    mem_limit: ${KASBAH_MEM_LIMIT}\n    deploy: {resources: {limits: {cpus: 1, memory: \"${KASBAH_MEM_LIMIT}\"}}}\n", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(cpus) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"the same limit spelled twice passes", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "    cpus: 0.5\n    deploy: {resources: {limits: {cpus: \"0.50\"}}}\n", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(cpus=0.5) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"the same size spelled twice passes", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    mem_limit: 512m\n    deploy: {resources: {limits: {memory: \"512M\"}}}\n", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(mem_limit=512m) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"two different sizes fail", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    mem_limit: 512m\n    deploy: {resources: {limits: {memory: 1g}}}\n", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"deploy memory as a number fails", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    mem_limit: ${KASBAH_MEM_LIMIT}\n", "    deploy: {resources: {limits: {memory: 536870912}}}\n", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(mem_limit) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"deploy cpus as a number is a literal", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "    deploy: {resources: {limits: {cpus: 1}}}\n", 1)}, 0,
			[]string{"  ⚠ Services with literal resource limits: demo-web(cpus=1) — a literal does not follow the host's ceiling, and only check --server can compare it with it"}},
		{"missing cpus fails", map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "", 1)}, 6,
			[]string{"  ✗ Services with missing or malformed resource limits: demo-web(cpus) — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values"}},
		{"drift", map[string]string{".env": "KASBAH_X=1\nEXTRA=2\r\n"}, 0,
			[]string{"  ⚠ .env missing keys vs .env.prod.example: DOMAIN", "  ⚠ .env has extra keys not in .env.prod.example: EXTRA"}},
		{"mail block of the wrong shape", map[string]string{"kasbah.yml": man + "mail: example.com\n"}, 6,
			[]string{"  ✗ kasbah.yml: mail: is not a block — it has to be a block with a domain: under it (docs/project-manifest.md → mail)"}},
		{"mail: \"\" is a mail: block deploy refuses", map[string]string{"kasbah.yml": man + "mail: \"\"\n"}, 6,
			[]string{"  ✗ kasbah.yml: mail: is not a block — it has to be a block with a domain: under it (docs/project-manifest.md → mail)"}},
		{"T05 matches a Host()'s first label whole",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers:\n    a: {rule: \"Host(`x\\nmail`)\", entryPoints: [web]}\n"}, 6,
			[]string{"  ✓ No router claims reserved hostnames (traefik.*, mail.*, webmail.*)"}},
		{"client: true is not a repository name", map[string]string{"kasbah.yml": man + "client: true\n"}, 6,
			[]string{"  ✗ kasbah.yml: client must be a string, not true"}},
		{"hooks: false is a hooks: block deploy refuses", map[string]string{"kasbah.yml": man + "hooks: false\n"}, 6,
			[]string{"  ✗ kasbah.yml: hooks: is not a block — it holds the lists pre-deploy:, post-deploy:, pre-rollback: and post-rollback: (docs/project-manifest.md)"}},
		{"HK01 refuses a hook list deploy does not run", map[string]string{"kasbah.yml": man + "hooks:\n  post-deploy: [\"demo-web true\"]\n  pre_deploy: [\"ghost true\"]\n"}, 6,
			[]string{"  ✗ kasbah.yml: hooks.pre_deploy is not a hook kasbah runs — hooks: holds the lists pre-deploy:, post-deploy:, pre-rollback: and post-rollback: (docs/project-manifest.md)"}},
		{"a hook entry that is not a string", map[string]string{"kasbah.yml": man + "hooks:\n  post-deploy: [{a: b}]\n"}, 6,
			[]string{"  ✗ kasbah.yml: hooks.post-deploy holds {\"a\":\"b\"} — each entry must be a string, \"<container> <command…>\""}},
		{"health: that is not a block", map[string]string{"kasbah.yml": man + "health: demo-web\n"}, 6,
			[]string{"  ✗ kasbah.yml: health: is not a block — it holds container: and timeout: (docs/project-manifest.md)"}},
		{"H02 refuses a timeout deploy refuses", map[string]string{"kasbah.yml": man + "health: {container: demo-web, timeout: soon}\n"}, 6,
			[]string{"  ✗ kasbah.yml: health.timeout 'soon' is not a duration kasbah can use — write it as 120s, 5m or 2h"}},
		{"backup: that is not a block", map[string]string{"kasbah.yml": man + "backup: yes\n"}, 6,
			[]string{"  ✗ kasbah.yml: backup: is not a block — it holds check:, command:, extension: and container: (docs/project-manifest.md)"}},
		{"a boolean backup.command is refused, a boolean check is a command",
			map[string]string{"kasbah.yml": man + "backup: {check: true, command: true, extension: sql, container: demo-web}\n"}, 6,
			[]string{"  ✗ kasbah.yml: backup.command must be a string, not true", "  ✓ Backup hook container 'demo-web' exists in compose"}},
		{"what else deploy refuses in a complete backup block fails too",
			map[string]string{"kasbah.yml": man + "backup: {check: true, command: dump, extension: sql, container: demo-web, retain: 0}\n"}, 6,
			[]string{"  ✓ Backup hook has check, command, and extension", "  ✗ kasbah.yml: backup.retain is 0 — rotation would delete the backup it just took"}},
		{"a NUL ends a .gitignore line", map[string]string{".gitignore": "x\x00.env\x00.kasbah/"}, 0,
			[]string{"  ✓ .gitignore excludes .env", "  ✓ .gitignore excludes .kasbah/"}},
		{"a mail: key kasbah does not know is not read", map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nmail: {domain: x.io, snappymail_domain: ./x.json}\n"}, 0,
			[]string{"  ✓ Mail claim names domain 'x.io'"}},
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
		{"a rollable service passes", rollCompose, "  ✓ All routed services can roll on deploy"},
		{"a container_name the fragment does not target", with("    container_name: demo-web-1\n"),
			"  ⚠ demo-web will not roll on deploy — it sets container_name" + unrouted},
		{"a host port", with("    ports: [\"127.0.0.1:8080:80\"]\n"),
			"  ⚠ demo-web will not roll on deploy — it publishes a host port a second replica cannot bind" + unrouted},
		{"a host port in the long form", with("    ports: [{target: 80, published: 8080}]\n"),
			"  ⚠ demo-web will not roll on deploy — it publishes a host port a second replica cannot bind" + unrouted},
		{"an ephemeral port binds nothing", with("    ports: [\"80\", \"127.0.0.1::81\", 82]\n"), "  ✓ All routed services can roll on deploy"},
		{"no compose healthcheck leaves it to the image", noHC,
			"  ⚠ demo-web rolls on deploy only if its image declares a HEALTHCHECK — compose gives it none, and without one it is recreated in place, briefly unrouted"},
		{"a shell-string healthcheck is one", strings.Replace(rollCompose, "{test: [CMD, wget, -q, --spider, \"http://127.0.0.1/\"]}", "{test: \"wget -q --spider http://127.0.0.1/\"}", 1),
			"  ✓ All routed services can roll on deploy"},
		{"a disabled healthcheck", strings.Replace(rollCompose, "{test: [CMD", "{disable: true, test: [CMD", 1),
			"  ⚠ demo-web will not roll on deploy — it declares no healthcheck to swap on" + unrouted},
		{"a gating depends_on", with("    depends_on: {db: {condition: service_healthy}}\n"),
			"  ⚠ demo-web will not roll on deploy — it depends_on db (service_healthy), a condition only a plain up waits for" + unrouted},
		{"a plain depends_on list does not gate", with("    depends_on: [db]\n"), "  ✓ All routed services can roll on deploy"},
		{"a definite reason outranks the image's healthcheck",
			strings.Replace(noHC, web, "    depends_on: {db: {condition: service_completed_successfully}}\n"+web, 1),
			"  ⚠ demo-web will not roll on deploy — it depends_on db (service_completed_successfully), a condition only a plain up waits for" + unrouted},
		{"the fragment targeting its container_name", goodCompose,
			"  ⚠ demo-web will not roll on deploy — the fragment targets its container_name" + unrouted},
		{"reached by name off the project network", strings.Replace(legacyCompose, "    container_name: demo-web\n", "", 1),
			"  ⚠ demo-web will not roll on deploy — the fragment reaches it by a name it answers only off the project's kasbah network" + unrouted},
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

func TestC10SkipsComments(t *testing.T) {
	project(t, map[string]string{".env.prod.example": "# c\r\n  # SMTP_HOST=mail-dms was the old way\r\nDOMAIN=x\r\n"})
	if out, _, _ := check(t); strings.Contains(out, "mail-dms") {
		t.Fatalf("a commented mail-dms warned:\n%s", out)
	}
	project(t, map[string]string{"compose.prod.yml": goodCompose + "x-smtp: mail-dms # still used\n"})
	if out, _, _ := check(t); !strings.Contains(out, "⚠ mail-dms is named in compose.prod.yml — ") {
		t.Fatalf("a used mail-dms did not warn:\n%s", out)
	}
}
