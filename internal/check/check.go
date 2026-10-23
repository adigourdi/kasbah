// Package check is `kasbah check`: the local rules of docs/compliance.md,
// judged from the project directory alone, --fix, and --server's rules.
//
// Each rule answers its question as a jq filter would under LC_ALL=C.UTF-8 —
// per document, with jq's errors, fallbacks and exit statuses — because that
// answer is the rule's verdict on an odd file. A question that cannot be
// answered at all (a scalar where an object belongs, a name that cannot be
// spliced into a filter, a template that cannot be read) ends the run with the
// report cut short and exit 1.
package check

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

const (
	composeFile  = "compose.prod.yml"
	traefikFile  = "traefik-dynamic.yml"
	templateFile = ".env.prod.example"
	envFile      = ".env"
)

// Env is what a run needs from its process.
type Env struct {
	Out *cli.Output
	// PWD is the directory the report names; the run reads the current one.
	PWD string
	// Version is this kasbah's, for the manifest's newer-schema refusal and
	// the kasbah_version --fix backfills.
	Version string
	// Fix runs --fix before the report; Yes answers its one question.
	Fix, Yes bool
	// Prompt asks that question; nil is the process's own stdin.
	Prompt *prompt.Prompter
	// Server is the target --server asks, "" for a local run; Dial reaches
	// it, and Now is the clock certificates are judged by.
	Server string
	Dial   func(target string) (ServerSession, error)
	Now    func() time.Time
	// Report prints a refusal that cuts the run short and gives its exit
	// code; nil is Out.Report. The CLI's hands a refusal naming another
	// version's work off to that version.
	Report func(error) int
}

func (e Env) report(err error) int {
	if e.Report != nil {
		return e.Report(err)
	}
	return e.Out.Report(err)
}

func (e Env) prompter() *prompt.Prompter {
	if e.Prompt != nil {
		return e.Prompt
	}
	return prompt.Std(e.Out)
}

type abort struct{ code int }

type checker struct {
	out              *cli.Output
	w                io.Writer
	cache            yamlx.Cache
	m                *manifest.Manifest
	pass, warn, fail int
	srv              *server
}

// Run checks the project in the current directory and returns the exit code:
// 0; 6 on any failure; the manifest's own refusal (2 or 1); or 1 for a run
// cut short as the package comment says.
func Run(e Env) (code int) {
	c := &checker{out: e.Out, w: e.Out.Stdout}
	defer func() {
		if r := recover(); r != nil {
			a, ok := r.(abort)
			if !ok {
				panic(r)
			}
			code = a.code
		}
	}()
	fmt.Fprintf(c.w, "Checking %s\n\n", e.PWD)
	if e.Fix {
		if _, err := manifest.Require(manifest.File, e.Version); err != nil {
			return e.report(err)
		}
		if err := c.fix(e); err != nil {
			return e.report(err)
		}
	}
	fmt.Fprintln(c.w, "Structure:")

	m, err := manifest.Require(manifest.File, e.Version)
	if err != nil {
		return e.report(err)
	}
	c.m = m
	c.passf("kasbah.yml exists (schema %s)", m.Schema)

	// Asked before the local rules: T05's verdict depends on the answer.
	if e.Server != "" {
		sess, err := e.Dial(e.Server)
		if err != nil {
			return e.report(err)
		}
		sr, err := sess.Read(m.Name, healthOf(m.Doc))
		if err != nil {
			return e.report(err)
		}
		now := time.Now
		if e.Now != nil {
			now = e.Now
		}
		c.srv = newServer(sr, now())
		if err := state.Record(state.File, e.Version, "last_server", sr.Target); err != nil {
			return e.report(err)
		}
	}

	if isFile(composeFile) {
		c.passf("compose.prod.yml exists")
	} else {
		c.failf("compose.prod.yml missing")
	}
	if isFile(templateFile) {
		c.passf(".env.prod.example exists")
	} else {
		c.failf(".env.prod.example missing")
	}
	if gitignoreHas(".env") {
		c.passf(".gitignore excludes .env")
	} else {
		c.warnf(".gitignore does not exclude .env")
	}
	if gitignoreHas(".kasbah/") {
		c.passf(".gitignore excludes .kasbah/")
	} else {
		c.warnf(".gitignore does not exclude .kasbah/")
	}
	c.s08()

	var services string
	if isFile(composeFile) {
		services = c.q(composeFile, func(d jv.Value, emit func(jv.Value)) error {
			s, err := index(d, "services")
			if err != nil {
				return err
			}
			ks, err := keys(jv.Alt(s, jv.NewMap()))
			for _, k := range ks {
				emit(k)
			}
			return err
		}).sub()
	}

	c.composeSection(services)
	c.resourcesSection(services)
	c.traefikSection(services)
	c.healthSection(services)
	c.envSection()
	c.hooksSection(services)
	c.mailSection()
	if c.srv != nil {
		c.serverSection()
	}

	fmt.Fprintf(c.w, "\nSummary: %d passed, %d warning, %d failed\n", c.pass, c.warn, c.fail)
	if c.fail > 0 {
		return cli.ExitComplianceFail
	}
	return cli.ExitOK
}

func (c *checker) passf(format string, a ...any) {
	c.pass++
	fmt.Fprintf(c.w, "  ✓ %s\n", fmt.Sprintf(format, a...))
}

func (c *checker) warnf(format string, a ...any) {
	c.warn++
	fmt.Fprintf(c.w, "  ⚠ %s\n", fmt.Sprintf(format, a...))
}

func (c *checker) failf(format string, a ...any) {
	c.fail++
	fmt.Fprintf(c.w, "  ✗ %s\n", fmt.Sprintf(format, a...))
}

func (c *checker) section(name string) { fmt.Fprintf(c.w, "\n%s:\n", name) }

func isFile(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

// lines is a here-string's lines: `while read` over "$s" sees each.
func lines(s string) []string { return strings.Split(s, "\n") }

func inLines(s, x string) bool {
	for _, l := range lines(s) {
		if l == x {
			return true
		}
	}
	return false
}

// grepX is `grep -qxF -- PATTERN <<<"$s"`: each line of a multi-line pattern
// is a pattern of its own.
func grepX(s, pattern string) bool {
	for _, p := range lines(pattern) {
		if inLines(s, p) {
			return true
		}
	}
	return false
}

// gitignoreHas is a line of .gitignore equal to pattern, every CR removed. A
// NUL ends a line too, as it does for GNU grep reading a binary file.
func gitignoreHas(pattern string) bool {
	if !isFile(".gitignore") {
		return false
	}
	data, err := os.ReadFile(".gitignore")
	if err != nil {
		return false
	}
	s := strings.NewReplacer("\r", "", "\x00", "\n").Replace(string(data))
	return inLines(s, pattern)
}

// q asks a project file; the manifest is answered from the validated document.
func (c *checker) q(file string, f gen) result {
	var r result
	if file == manifest.File {
		r = run([]jv.Value{c.m.Doc}, f)
	} else if fl := c.cache.Get(file); fl.Err != nil {
		return result{rc: 2}
	} else {
		r = run(fl.Docs, f)
	}
	if r.msg != "" {
		r.msg = "error: cannot check " + file + ", " + r.msg
	}
	return r
}

// must is a question the run cannot go on without: a failed query ends it
// with exit 1 and its diagnostic on stderr.
func (c *checker) must(r result) string {
	if r.rc != 0 {
		if r.msg != "" {
			fmt.Fprintln(c.out.Stderr, r.msg)
		}
		panic(abort{cli.ExitFailure})
	}
	return r.sub()
}

// at asks `.[a][b]… // def` of a file.
func (c *checker) at(file string, def jv.Value, p ...string) result {
	return c.then(file, func(v jv.Value) (jv.Value, error) { return jv.Alt(v, def), nil }, p...)
}

// then asks `.[a][b]… | f`.
func (c *checker) then(file string, f func(v jv.Value) (jv.Value, error), p ...string) result {
	g, ok := pathThen(f, p...)
	if !ok {
		name := ""
		for _, k := range p {
			if _, lit := literal(k); !lit {
				name = k
			}
		}
		return result{rc: 3, msg: fmt.Sprintf("error: cannot check %s, the name '%s' holds a character kasbah's rules cannot quote", file, name)}
	}
	return c.q(file, g)
}

// pathThen is the filter `.[a][b]… | f`; ok is false where it would not
// compile. Names spliced into the filter (a service or router) are decoded as
// the filter's string literal.
func pathThen(f func(v jv.Value) (jv.Value, error), p ...string) (g gen, ok bool) {
	keys := make([]string, len(p))
	for i, k := range p {
		if keys[i], ok = literal(k); !ok {
			return nil, false
		}
	}
	return func(d jv.Value, emit func(jv.Value)) error {
		v, err := path(d, keys...)
		if err != nil {
			return err
		}
		x, err := f(v)
		if err != nil {
			return err
		}
		emit(x)
		return nil
	}, true
}

func hasKey(k string) func(jv.Value) (jv.Value, error) {
	return func(v jv.Value) (jv.Value, error) { return has(v, k) }
}

func anyOf(s string) func(jv.Value) (jv.Value, error) {
	return func(v jv.Value) (jv.Value, error) { return anyEq(jv.Alt(v, []jv.Value{}), s) }
}

func (c *checker) s08() {
	v, _ := c.m.Get("client")
	raw := strings.TrimRight(jv.Raw(jv.ToString(jv.Alt(v, ""))), "\n")
	raw = strings.TrimSuffix(raw, "\r")
	if raw == "null" {
		raw = ""
	}
	switch reason, ok := manifest.ClientCheck(raw); {
	case raw == "":
		c.passf("client is not set — backups file under the project name (%s)", c.m.Name)
	case ok:
		c.passf("client '%s' names a backup repository kasbah can create", raw)
	default:
		c.failf("kasbah.yml: %s", reason)
	}
}

// --- Compose (C01–C05, C07–C09) ---------------------------------------------

var restartOK = regexp.MustCompile(`^(unless-stopped|always|on-failure(:[0-9]+)?)$`)

func (c *checker) composeSection(services string) {
	if !isFile(composeFile) {
		return
	}
	c.section("Compose")
	if c.cache.Get(composeFile).Err != nil {
		c.failf("compose.prod.yml does not parse as YAML")
		return
	}
	if services == "" {
		c.warnf("compose.prod.yml declares no services — skipping Compose checks")
		c.c05()
		return
	}

	var bad []string
	for _, svc := range lines(services) {
		r := c.at(composeFile, "", "services", svc, "restart").or("")
		if !restartOK.MatchString(r) {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("All services set restart policy")
	} else {
		c.failf("Services missing restart policy: %s", strings.Join(bad, " "))
	}

	bad = nil
	for _, svc := range lines(services) {
		drv := c.at(composeFile, "", "services", svc, "logging", "driver").or("")
		ms := c.at(composeFile, "", "services", svc, "logging", "options", "max-size").or("")
		mf := c.at(composeFile, "", "services", svc, "logging", "options", "max-file").or("")
		if drv != "json-file" || ms == "" || mf == "" {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("All services set json-file logging with rotation")
	} else {
		c.failf("Services missing json-file logging with max-size/max-file: %s", strings.Join(bad, " "))
	}

	onHN, defaultAliases := c.networks(services)
	c.c09(onHN, defaultAliases)
	c.c05()
	if c.anyBuilt(services) {
		c.c08(services)
	}
}

func (c *checker) c05() {
	if c.must(c.at(composeFile, "", "version")) != "" {
		c.warnf("compose.prod.yml uses deprecated 'version:' field")
	} else {
		c.passf("No deprecated 'version:' field")
	}
}

func (c *checker) built(svc string) bool {
	return c.then(composeFile, hasKey("build"), "services", svc).or("false") == "true"
}

func (c *checker) anyBuilt(services string) bool {
	for _, svc := range lines(services) {
		if svc != "" && c.built(svc) {
			return true
		}
	}
	return false
}

// c08: a built service's image is tagged :current, the tag deploy moves.
func (c *checker) c08(services string) {
	var bad []string
	for _, svc := range lines(services) {
		if svc == "" || !c.built(svc) {
			continue
		}
		image := c.at(composeFile, "", "services", svc, "image").or("")
		switch {
		case image == "" || image == "null":
			bad = append(bad, svc+" (no image:)")
		case !strings.HasSuffix(image, ":current"):
			bad = append(bad, svc+" ("+image+")")
		}
	}
	if len(bad) == 0 {
		c.passf("All built services reference their image as :current")
	} else {
		c.failf("Built services whose image: is not tagged :current: %s — deploy moves <image>:current, so a pinned tag keeps the old image running", strings.Join(bad, " "))
	}
}

// networks is C03, C04 and C07; it returns the services on kasbah-net and
// whether the banned default-alias shape put them there, for C09.
func (c *checker) networks(services string) (onHN string, defaultAliases bool) {
	defaultName := c.must(c.at(composeFile, "", "networks", "default", "name"))
	defaultExt := c.must(c.at(composeFile, false, "networks", "default", "external"))
	hnExt := c.must(c.at(composeFile, false, "networks", "kasbah-net", "external"))
	defaultAliases = defaultName == "kasbah-net"

	routed := strings.Join(envtpl.SortUniq(c.routedHosts()), "\n")

	var badC03, badC07, on []string
	anyOn, anyRouted := false, false
	for _, svc := range lines(services) {
		if svc == "" {
			continue
		}
		joined, isRouted := false, false
		hn := c.then(composeFile, func(v jv.Value) (jv.Value, error) {
			switch m := v.(type) {
			case nil:
				v = []jv.Value{}
			case *jv.Map:
				ks, _ := keys(m)
				v = ks
			}
			return anyEq(v, "kasbah-net")
		}, "services", svc, "networks").or("false")
		if hn == "true" {
			joined = true
		} else if defaultAliases {
			if c.then(composeFile, hasKey("networks"), "services", svc).or("false") != "true" {
				joined = true
			}
		}
		cn := c.must(c.at(composeFile, "", "services", svc, "container_name"))
		if cn != "" && cn != "null" && routed != "" && grepX(routed, cn) {
			isRouted, anyRouted = true, true
		}
		if joined {
			anyOn = true
			on = append(on, svc)
		}
		if isRouted && !joined {
			badC03 = append(badC03, svc)
		}
		if !isRouted && joined && !defaultAliases {
			badC07 = append(badC07, svc)
		}
	}

	switch {
	case len(badC03) > 0:
		c.failf("Routed services not on kasbah-net: %s", strings.Join(badC03, " "))
	case anyRouted:
		c.passf("All routed services join kasbah-net")
	default:
		c.passf("No Traefik-routed services in compose")
	}
	if anyOn {
		if hnExt == "true" || (defaultAliases && defaultExt == "true") {
			c.passf("kasbah-net declared external")
		} else {
			c.failf("kasbah-net not declared external: true")
		}
	}
	switch {
	case defaultAliases:
		c.failf("default network aliases kasbah-net — every service joins the shared network; join it explicitly per routed service and keep the rest on a project-internal network")
	case len(badC07) > 0:
		c.failf("Non-routed services on kasbah-net: %s", strings.Join(badC07, " "))
	default:
		c.passf("No internal services on kasbah-net")
	}
	return strings.Join(on, "\n"), defaultAliases
}

// c09 warns about a service on kasbah-net not named for the project; silent
// with nothing on the network, and under the default-alias shape C07 failed.
func (c *checker) c09(onHN string, defaultAliases bool) {
	if defaultAliases || onHN == "" {
		return
	}
	name := c.m.Name
	var bad []string
	for _, svc := range lines(onHN) {
		if svc != "" && svc != name && !strings.HasPrefix(svc, name+"-") {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("kasbah-net service names are project-prefixed")
	} else {
		c.warnf("Services on kasbah-net whose name is not '%s' or '%s-*': %s — the service name is a DNS alias on the shared network, so a generic one collides with every other project using it", name, name, strings.Join(bad, " "))
	}
}

// --- Resources (R01–R03) ----------------------------------------------------

func (c *checker) resourcesSection(services string) {
	if !isFile(composeFile) || services == "" || c.cache.Get(composeFile).Err != nil {
		return
	}
	c.section("Resources")
	var bad []string
	for _, svc := range lines(services) {
		if svc == "" {
			continue
		}
		var wrong []string
		if c.at(composeFile, "", "services", svc, "cpus").or("") != "${KASBAH_CPU_LIMIT}" {
			wrong = append(wrong, "cpus")
		}
		if c.at(composeFile, "", "services", svc, "mem_limit").or("") != "${KASBAH_MEM_LIMIT}" {
			wrong = append(wrong, "mem_limit")
		}
		if len(wrong) > 0 {
			bad = append(bad, svc+"("+strings.Join(wrong, ",")+")")
		}
	}
	if len(bad) == 0 {
		c.passf("All services set cpus/mem_limit via KASBAH_* vars")
	} else {
		c.failf("Services with missing or literal resource limits: %s", strings.Join(bad, " "))
	}

	bad = nil
	for _, svc := range lines(services) {
		if svc == "" {
			continue
		}
		resv := c.at(composeFile, nil, "services", svc, "deploy", "resources", "reservations").or("null")
		memr := c.at(composeFile, "", "services", svc, "mem_reservation").or("")
		if resv != "null" || (memr != "" && memr != "null") {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("No resource reservations")
	} else {
		c.failf("Services declare resource reservations: %s", strings.Join(bad, " "))
	}
}

// --- Traefik (T01–T08) ------------------------------------------------------

func (c *checker) traefikSection(services string) {
	c.section("Traefik")
	var routers string
	parsed := false
	if !isFile(traefikFile) {
		c.warnf("traefik-dynamic.yml missing — skipping T02–T05 and T08")
	} else if r := c.q(traefikFile, func(d jv.Value, emit func(jv.Value)) error {
		h, err := path(d, "http", "routers")
		if err != nil {
			return err
		}
		ks, err := keys(jv.Alt(h, jv.NewMap()))
		for _, k := range ks {
			emit(k)
		}
		return err
	}); r.rc != 0 {
		c.warnf("traefik-dynamic.yml does not parse as YAML — skipping T02–T05 and T08")
	} else {
		c.passf("traefik-dynamic.yml exists")
		routers, parsed = r.sub(), true
	}

	if parsed {
		domain := c.m.Domain
		if domain != "" {
			c.t02(routers, domain)
		} else {
			c.warnf("manifest domain is empty — skipping T02 and T08 (both match routers against it)")
		}
		c.t03(routers)
		c.t04(routers)
		if domain != "" {
			c.t08(routers, domain)
		}
		c.t05(routers)
		c.t07(services)
	}
	c.t06(services)
}

func (c *checker) rule(r string) string {
	return c.must(c.at(traefikFile, "", "http", "routers", r, "rule"))
}

func (c *checker) t02(routers, domain string) {
	found := false
	for _, r := range lines(routers) {
		if r != "" && strings.Contains(c.rule(r), domain) {
			found = true
			break
		}
	}
	if found {
		c.passf("At least one router references manifest domain (%s)", domain)
	} else {
		c.failf("No router rule references manifest domain (%s)", domain)
	}
}

func (c *checker) t03(routers string) {
	var bad []string
	for _, r := range lines(routers) {
		if r == "" {
			continue
		}
		n := c.must(c.then(traefikFile, func(v jv.Value) (jv.Value, error) {
			return length(jv.Alt(v, []jv.Value{}))
		}, "http", "routers", r, "entryPoints"))
		if n == "0" {
			bad = append(bad, r)
		}
	}
	if len(bad) == 0 {
		c.passf("All routers declare entryPoints")
	} else {
		c.failf("Routers without entryPoints: %s", strings.Join(bad, " "))
	}
}

func (c *checker) t04(routers string) {
	var bad []string
	for _, r := range lines(routers) {
		if r == "" {
			continue
		}
		if c.must(c.then(traefikFile, anyOf("websecure"), "http", "routers", r, "entryPoints")) != "true" {
			continue
		}
		if c.must(c.at(traefikFile, "", "http", "routers", r, "tls", "certResolver")) != "letsencrypt" {
			bad = append(bad, r)
		}
	}
	if len(bad) == 0 {
		c.passf("Secure routers reference letsencrypt cert resolver")
	} else {
		c.failf("Websecure routers without tls.certResolver=letsencrypt: %s", strings.Join(bad, " "))
	}
}

func (c *checker) t08(routers, domain string) {
	found := false
	for _, r := range lines(routers) {
		if r == "" || !strings.Contains(c.rule(r), domain) {
			continue
		}
		if c.must(c.then(traefikFile, anyOf("web"), "http", "routers", r, "entryPoints")) == "true" {
			found = true
			break
		}
	}
	if found {
		c.passf("A router serves %s on the web entrypoint", domain)
	} else {
		c.warnf("No router serves %s on the web entrypoint — plain HTTP gets Traefik's 404; add a redirect router with middlewares: [\"http-to-https@file\"] and service: noop@internal", domain)
	}
}

var hostRule = regexp.MustCompile("Host\\(`([^`]+)`\\)")

// t05 is the local form: a Host() whose first DNS label is one kasbah's own
// subdomains use. The exact match against a server's hostnames is --server's.
func (c *checker) t05(routers string) {
	if c.srv != nil {
		c.t05Server(routers)
		return
	}
	var bad []string
	for _, r := range lines(routers) {
		if r == "" {
			continue
		}
		for _, m := range hostRule.FindAllStringSubmatch(c.rule(r), -1) {
			host := m[1]
			label, _, _ := strings.Cut(host, ".")
			if grepX("traefik\nmail\nwebmail", label) {
				bad = append(bad, r+"→"+host)
			}
		}
	}
	if len(bad) > 0 {
		c.failf("Routers claim reserved hostnames: %s", strings.Join(bad, " "))
	} else {
		c.passf("No router claims reserved hostnames (traefik.*, mail.*, webmail.*)")
	}
}

func (c *checker) t06(services string) {
	if services == "" {
		c.passf("compose.prod.yml has no traefik.* labels")
		return
	}
	var bad []string
	for _, svc := range lines(services) {
		if svc == "" {
			continue
		}
		has := c.then(composeFile, func(v jv.Value) (jv.Value, error) {
			var names []jv.Value
			switch m := v.(type) {
			case nil:
			case *jv.Map:
				names, _ = keys(m)
			default:
				xs, err := iter(v, false)
				if err != nil {
					return nil, err
				}
				for _, x := range xs {
					names = append(names, cutAssign(jv.ToString(x)))
				}
			}
			for _, n := range names {
				if strings.HasPrefix(n.(string), "traefik.") {
					return true, nil
				}
			}
			return false, nil
		}, "services", svc, "labels").or("false")
		if has == "true" {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("compose.prod.yml has no traefik.* labels")
	} else {
		c.failf("Services carry traefik.* labels (file provider only): %s", strings.Join(bad, " "))
	}
}

// cutAssign is jq's `sub("=.*"; "")`, whose `.` stops at a newline.
func cutAssign(s string) string {
	i := strings.IndexByte(s, '=')
	if i < 0 {
		return s
	}
	if j := strings.IndexByte(s[i:], '\n'); j >= 0 {
		return s[:i] + s[i+j:]
	}
	return s[:i]
}

func (c *checker) t07(services string) {
	if services == "" {
		return
	}
	hosts := envtpl.SortUniq(c.routedHosts())
	if len(hosts) == 0 {
		c.passf("Fragment has no loadBalancer server URLs to verify")
		return
	}
	names := strings.Join(envtpl.SortUniq(c.containerNames(services)), "\n")
	var bad []string
	for _, h := range hosts {
		if h != "" && !grepX(names, h) {
			bad = append(bad, h)
		}
	}
	if len(bad) == 0 {
		c.passf("Fragment loadBalancer URLs target explicit container_names")
	} else {
		c.failf("Fragment targets unknown container_names: %s (set container_name in compose.prod.yml)", strings.Join(bad, " "))
	}
}

var (
	urlScheme = regexp.MustCompile(`^[A-Za-z0-9+.-]+://`)
	urlTail   = regexp.MustCompile(`[:/].*$`)
	awkBlank  = regexp.MustCompile(`^[ \t]*$`)
)

// routedHosts is every loadBalancer server URL's host, one per line as the
// `sed`/`awk` pipeline would leave them, before sorting.
func (c *checker) routedHosts() []string {
	if !isFile(traefikFile) {
		return nil
	}
	r := c.q(traefikFile, func(d jv.Value, emit func(jv.Value)) error {
		s, err := path(d, "http", "services")
		if err != nil {
			return err
		}
		_, vs, err := entries(jv.Alt(s, jv.NewMap()))
		if err != nil {
			return err
		}
		for _, v := range vs {
			srv, err := path(v, "loadBalancer", "servers")
			if err != nil {
				return err
			}
			xs, err := iter(jv.Alt(srv, []jv.Value{}), false)
			if err != nil {
				return err
			}
			for _, x := range xs {
				u, err := index(x, "url")
				if err != nil {
					return err
				}
				emit(jv.Alt(u, ""))
			}
		}
		return nil
	})
	var out []string
	for _, l := range strings.SplitAfter(r.out, "\n") {
		if l == "" {
			continue
		}
		l = strings.TrimSuffix(l, "\n")
		l = urlTail.ReplaceAllString(urlScheme.ReplaceAllString(l, ""), "")
		if !awkBlank.MatchString(l) {
			out = append(out, l)
		}
	}
	return out
}

// containerNames is every explicit container_name, as lines. It ran in a
// command substitution, where errexit is off: a failed query keeps going.
func (c *checker) containerNames(services string) []string {
	var b strings.Builder
	for _, svc := range lines(services) {
		if svc == "" {
			continue
		}
		cn := c.at(composeFile, "", "services", svc, "container_name").sub()
		if cn != "" && cn != "null" {
			b.WriteString(cn + "\n")
		}
	}
	s := strings.TrimSuffix(b.String(), "\n")
	if b.Len() == 0 {
		return nil
	}
	return lines(s)
}

// --- Healthchecks (H01, H02) ------------------------------------------------

func (c *checker) hasBlock(key string) bool {
	v := c.at(manifest.File, nil, key).sub()
	return v != "null" && v != ""
}

func (c *checker) healthSection(services string) {
	built := isFile(composeFile) && services != "" && c.anyBuilt(services)
	health := c.hasBlock("health")
	if !built && !health {
		return
	}
	c.section("Healthchecks")
	if built {
		var bad []string
		for _, svc := range lines(services) {
			if svc == "" || !c.built(svc) {
				continue
			}
			if c.must(c.at(composeFile, nil, "services", svc, "healthcheck")) == "null" {
				bad = append(bad, svc)
			}
		}
		if len(bad) == 0 {
			c.passf("All built services declare a compose healthcheck")
		} else {
			c.warnf("Built services without a compose healthcheck (Dockerfile may declare one): %s", strings.Join(bad, " "))
		}
	}
	if health {
		ctr := c.must(c.at(manifest.File, "", "health", "container"))
		switch {
		case ctr == "" || ctr == "null":
			c.passf("manifest health: names no container — the deploy waits on every container with a healthcheck")
		case grepX(strings.Join(c.containerNames(services), "\n"), ctr):
			c.passf("manifest health.container '%s' exists in compose", ctr)
		default:
			c.failf("manifest health.container '%s' not found among compose container_names", ctr)
		}
	}
}

// --- Env (E01–E05) ----------------------------------------------------------

func (c *checker) envSection() {
	if !isFile(templateFile) {
		return
	}
	c.section("Env")
	data, err := os.ReadFile(templateFile)
	if err != nil {
		fmt.Fprintf(c.out.Stderr, "%s: %v\n", templateFile, err)
		panic(abort{cli.ExitFailure})
	}
	tpl := envtpl.Lines(data)

	var badLines []string
	for i, l := range tpl {
		if envtpl.Blank(l) || envtpl.Comment(l) {
			continue
		}
		if _, _, ok := envtpl.Assign(l); ok {
			continue
		}
		badLines = append(badLines, fmt.Sprint(i+1))
	}
	if len(badLines) == 0 {
		c.passf(".env.prod.example syntax is valid")
	} else {
		c.failf(".env.prod.example has invalid lines (line numbers: %s)", strings.Join(badLines, " "))
	}

	if isFile(envFile) {
		missing, extra := envtpl.Drift(templateFile, envFile)
		if len(missing) == 0 {
			c.passf(".env has no missing keys vs .env.prod.example")
		} else {
			c.warnf(".env missing keys vs .env.prod.example: %s", strings.Join(missing, " "))
		}
		if len(extra) == 0 {
			c.passf(".env has no extra keys vs .env.prod.example")
		} else {
			c.warnf(".env has extra keys not in .env.prod.example: %s", strings.Join(extra, " "))
		}
	}

	var long []string
	for _, l := range tpl {
		key, val, ok := envtpl.Assign(l)
		if !ok || generator.MatchString(val) || hint.MatchString(val) {
			continue
		}
		if loc := inlineHint.FindStringIndex(val); loc != nil {
			val = val[:loc[0]]
		}
		if envtpl.Len(val) > 64 {
			long = append(long, key)
		}
	}
	if len(long) == 0 {
		c.passf(".env.prod.example has no obvious long secrets")
	} else {
		c.warnf(".env.prod.example has values >64 chars (possibly leaked secrets): %s", strings.Join(long, " "))
	}

	var reserved []string
	for _, k := range envtpl.Keys(templateFile) {
		if strings.HasPrefix(k, envtpl.ReservedPrefix) {
			reserved = append(reserved, k)
		}
	}
	if len(reserved) == 0 {
		c.passf(".env.prod.example leaves the %s* prefix to kasbah", envtpl.ReservedPrefix)
	} else {
		c.warnf(".env.prod.example defines reserved %s* keys (kasbah injects these): %s", envtpl.ReservedPrefix, strings.Join(reserved, " "))
	}
}

var (
	generator  = regexp.MustCompile(`^` + envtpl.Space + `*!`)
	hint       = regexp.MustCompile(`^` + envtpl.Space + `*#`)
	inlineHint = regexp.MustCompile(envtpl.Space + `+#.*$`)
	firstSpace = regexp.MustCompile(envtpl.Space)
)

// --- Hooks (HK01–HK03) ------------------------------------------------------

func (c *checker) hooksSection(services string) {
	hooks, backup := c.hasBlock("hooks"), c.hasBlock("backup")
	if !hooks && !backup {
		return
	}
	c.section("Hooks")
	names := strings.Join(envtpl.SortUniq(c.containerNames(services)), "\n")

	if hooks {
		hs := c.must(c.q(manifest.File, func(d jv.Value, emit func(jv.Value)) error {
			h, err := index(d, "hooks")
			if err != nil {
				return err
			}
			_, vs, err := entries(jv.Alt(h, jv.NewMap()))
			if err != nil {
				return err
			}
			for _, v := range vs {
				xs, _ := iter(v, true)
				for _, x := range xs {
					emit(x)
				}
			}
			return nil
		}))
		if hs == "" {
			c.passf("Hooks block is empty")
		} else {
			var bad []string
			for _, h := range lines(hs) {
				if h == "" {
					continue
				}
				ctr := h
				if loc := firstSpace.FindStringIndex(h); loc != nil {
					ctr = h[:loc[0]]
				}
				if !grepX(names, ctr) {
					bad = append(bad, ctr)
				}
			}
			if len(bad) == 0 {
				c.passf("All hook commands target known container_names")
			} else {
				c.failf("Hooks reference unknown container_names: %s (set container_name on the target service in compose.prod.yml)", strings.Join(bad, " "))
			}
		}
	}

	if backup {
		var missing []string
		for _, f := range []string{"check", "command", "extension"} {
			v := c.must(c.at(manifest.File, "", "backup", f))
			if v == "" || v == "null" {
				missing = append(missing, f)
			}
		}
		if len(missing) == 0 {
			c.passf("Backup hook has check, command, and extension")
		} else {
			c.failf("Backup hook missing required field(s): %s", strings.Join(missing, " "))
		}

		ctr := c.must(c.at(manifest.File, "", "backup", "container"))
		switch {
		case ctr == "" || ctr == "null":
			c.failf("Backup hook missing 'container' field")
		case grepX(names, ctr):
			c.passf("Backup hook container '%s' exists in compose", ctr)
		default:
			c.failf("Backup hook container '%s' not found among compose container_names", ctr)
		}
	}
}

// --- Mail (M01) -------------------------------------------------------------

func (c *checker) mailSection() {
	if !c.hasBlock("mail") {
		return
	}
	c.section("Mail")
	kind := strings.TrimSuffix(c.then(manifest.File, func(v jv.Value) (jv.Value, error) {
		return jv.Type(v), nil
	}, "mail").sub(), "\r")
	if kind != "object" {
		if kind == "" {
			kind = "unknown"
		}
		c.failf("mail: has type '%s' — it has to be a block with a domain: under it", kind)
		return
	}

	d := strings.TrimSuffix(c.at(manifest.File, "", "mail", "domain").sub(), "\r")
	if d == "" || d == "null" {
		c.failf("mail: has no domain: (the claim is that the VPS mail stack handles that domain)")
	} else {
		c.passf("Mail claim names domain '%s'", d)
	}
}
