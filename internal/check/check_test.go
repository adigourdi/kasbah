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
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "{external: true}", "{external: \"true\"}", 1)}, 6,
			[]string{"  ✗ kasbah-net not declared external: true"}},
		{"reservations: false is still a reservation",
			map[string]string{"compose.prod.yml": strings.Replace(goodCompose, "    networks: [kasbah-net]\n", "    networks: [kasbah-net]\n    deploy: {resources: {reservations: false}}\n", 1)}, 6,
			[]string{"  ✗ Services declare resource reservations: demo-web"}},
		{"routers: that is not a mapping skips the router rules",
			map[string]string{"traefik-dynamic.yml": "http:\n  routers: [a]\n"}, 0,
			[]string{"  ⚠ traefik-dynamic.yml: http.routers is a list, not a mapping — skipping T02–T05 and T08",
				"  ⚠ traefik-dynamic.yml: http.routers is a list, not a mapping — skipping C03 and C07, which need the services it routes"}},
		{"with no fragment read, C03 and C07 conclude nothing",
			map[string]string{"traefik-dynamic.yml": ""}, 0,
			[]string{"  ⚠ traefik-dynamic.yml missing — skipping C03 and C07, which need the services it routes", "  ✓ kasbah-net declared external"}},
		{"with no fragment read and nothing on kasbah-net, C07 still passes",
			map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": strings.Replace(goodCompose, "networks: [kasbah-net]", "networks: [internal]", 1)}, 0,
			[]string{"  ⚠ traefik-dynamic.yml missing — skipping C03, which needs the services it routes", "  ✓ No internal services on kasbah-net"}},
		{"with no fragment read, the default-alias shape still fails C07",
			map[string]string{"traefik-dynamic.yml": "", "compose.prod.yml": goodCompose + "  default: {name: kasbah-net}\n"}, 6,
			[]string{"  ⚠ traefik-dynamic.yml missing — skipping C03, which needs the services it routes", "  ✗ default network aliases kasbah-net — every service joins the shared network; join it explicitly per routed service and keep the rest on a project-internal network"}},
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
			[]string{"  ⚠ traefik-dynamic.yml holds 2 YAML documents, where kasbah reads one — skipping T02–T05 and T08",
				"  ⚠ traefik-dynamic.yml holds 2 YAML documents, where kasbah reads one — skipping C03 and C07, which need the services it routes"}},
		{"entryPoints: that is not a list",
			map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "entryPoints: [web]", "entryPoints: web", 1)}, 6,
			[]string{"  ✗ Routers without entryPoints: demo-http (entryPoints is a string, not a list)"}},
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
