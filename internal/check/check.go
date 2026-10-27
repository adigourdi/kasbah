// Package check is `kasbah check`: the local rules of docs/compliance.md,
// judged from the project directory alone, --fix, and --server's rules.
//
// Each rule queries the parsed files, each read once, and reports a shape it
// cannot accept as its own failure (exit 6). A step it cannot take at all —
// compose's networks:, one of its networks, a service or a router that is not
// a mapping, or a router's tls: that is not one — and a template that cannot
// be read end the run with the report cut short and exit 1.
package check

import (
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/tree"
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
	// compose is compose.prod.yml when it exists; services are its service
	// names in byte order, servicesBad why services: cannot be read.
	compose     yamlDoc
	services    []string
	servicesBad string
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
		sr, err := sess.Read(m.Name, healthOf(m))
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

	if isFile(composeFile) {
		c.compose = c.load(composeFile)
		if c.compose.bad == "" {
			svcs, bad := mapAt(c.compose.root, "services")
			c.services, c.servicesBad = keysOf(svcs), bad
		}
	}

	c.composeSection()
	c.resourcesSection()
	c.traefikSection()
	c.healthSection()
	c.envSection()
	c.hooksSection()
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

func inLines(s, x string) bool {
	for _, l := range strings.Split(s, "\n") {
		if l == x {
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

func (c *checker) failErr(err error) { c.failf("%s", strings.ReplaceAll(err.Error(), "\n", "; ")) }

func (c *checker) s08() {
	raw, err := deploy.Field(c.m, "a string", "client")
	if err != nil {
		c.failErr(err)
		return
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

// svc is the value at path under a service, nil where the file has none.
func (c *checker) svc(name string, p ...string) tree.Value {
	return opt(c.compose.root, append([]string{"services", name}, p...)...)
}

func (c *checker) composeSection() {
	if !isFile(composeFile) {
		return
	}
	c.section("Compose")
	if c.compose.bad != "" {
		c.failf("compose.prod.yml %s", c.compose.bad)
		return
	}
	if c.servicesBad != "" {
		c.failf("compose.prod.yml: %s", c.servicesBad)
		if _, ok := c.compose.root.(*tree.Map); ok {
			c.c05()
		}
		return
	}
	if len(c.services) == 0 {
		c.warnf("compose.prod.yml declares no services — skipping Compose checks")
		c.c05()
		return
	}

	var bad []string
	for _, svc := range c.services {
		if !restartOK.MatchString(scalar(c.svc(svc, "restart"))) {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("All services set restart policy")
	} else {
		c.failf("Services missing restart policy: %s", strings.Join(bad, " "))
	}

	bad = nil
	for _, svc := range c.services {
		drv := scalar(c.svc(svc, "logging", "driver"))
		ms := rotationSet(c.svc(svc, "logging", "options", "max-size"))
		mf := rotationSet(c.svc(svc, "logging", "options", "max-file"))
		if drv != "json-file" || !ms || !mf {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("All services set json-file logging with rotation")
	} else {
		c.failf("Services missing json-file logging with max-size/max-file: %s", strings.Join(bad, " "))
	}

	onHN, defaultAliases := c.networks()
	c.c09(onHN, defaultAliases)
	c.c05()
	if c.anyBuilt() {
		c.c08()
	}
}

func (c *checker) c05() {
	if scalar(c.need(c.compose, "version")) != "" {
		c.warnf("compose.prod.yml uses deprecated 'version:' field")
	} else {
		c.passf("No deprecated 'version:' field")
	}
}

func (c *checker) built(svc string) bool { return hasKey(c.svc(svc), "build") }

func (c *checker) anyBuilt() bool {
	for _, svc := range c.services {
		if c.built(svc) {
			return true
		}
	}
	return false
}

// c08: a built service's image is tagged :current, the tag deploy moves.
func (c *checker) c08() {
	var bad []string
	for _, svc := range c.services {
		if !c.built(svc) {
			continue
		}
		image := scalar(c.svc(svc, "image"))
		switch {
		case image == "":
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
func (c *checker) networks() (on []string, defaultAliases bool) {
	d := c.compose
	defaultAliases = scalar(c.need(d, "networks", "default", "name")) == "kasbah-net"
	defaultExt := c.need(d, "networks", "default", "external") == true
	hnExt := c.need(d, "networks", "kasbah-net", "external") == true
	routed := c.routedHosts()
	_, unread := c.fragment()

	var badC03, badC07 []string
	anyRouted := false
	for _, svc := range c.services {
		joined := joinsNet(c.svc(svc, "networks")) || (defaultAliases && !hasKey(c.svc(svc), "networks"))
		cn := scalar(c.need(d, "services", svc, "container_name"))
		isRouted := cn != "" && inList(routed, cn)
		anyRouted = anyRouted || isRouted
		if joined {
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
	case unread != "" && (defaultAliases || len(on) == 0):
		c.warnf("%s — skipping C03, which needs the services it routes", unread)
	case unread != "":
		c.warnf("%s — skipping C03 and C07, which need the services it routes", unread)
	case len(badC03) > 0:
		c.failf("Routed services not on kasbah-net: %s", strings.Join(badC03, " "))
	case anyRouted:
		c.passf("All routed services join kasbah-net")
	default:
		c.passf("No Traefik-routed services in compose")
	}
	if len(on) > 0 {
		if hnExt || (defaultAliases && defaultExt) {
			c.passf("kasbah-net declared external")
		} else {
			c.failf("kasbah-net not declared external: true")
		}
	}
	switch {
	case defaultAliases:
		c.failf("default network aliases kasbah-net — every service joins the shared network; join it explicitly per routed service and keep the rest on a project-internal network")
	case unread != "" && len(on) > 0:
	case len(badC07) > 0:
		c.failf("Non-routed services on kasbah-net: %s", strings.Join(badC07, " "))
	default:
		c.passf("No internal services on kasbah-net")
	}
	return on, defaultAliases
}

// c09 warns about a service on kasbah-net not named for the project; silent
// with nothing on the network, and under the default-alias shape C07 failed.
func (c *checker) c09(onHN []string, defaultAliases bool) {
	if defaultAliases || len(onHN) == 0 {
		return
	}
	name := c.m.Name
	var bad []string
	for _, svc := range onHN {
		if svc != name && !strings.HasPrefix(svc, name+"-") {
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

func (c *checker) resourcesSection() {
	if !isFile(composeFile) || len(c.services) == 0 {
		return
	}
	c.section("Resources")
	var bad []string
	for _, svc := range c.services {
		var wrong []string
		if scalar(c.svc(svc, "cpus")) != "${KASBAH_CPU_LIMIT}" {
			wrong = append(wrong, "cpus")
		}
		if scalar(c.svc(svc, "mem_limit")) != "${KASBAH_MEM_LIMIT}" {
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
	for _, svc := range c.services {
		if c.svc(svc, "deploy", "resources", "reservations") != nil || c.svc(svc, "mem_reservation") != nil {
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

func (c *checker) traefikSection() {
	c.section("Traefik")
	routers, unread := c.fragment()
	if unread != "" {
		c.warnf("%s — skipping T02–T05 and T08", unread)
	} else {
		c.passf("traefik-dynamic.yml exists")
	}

	if unread == "" {
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
		c.t07()
	}
	c.t06()
}

// fragment is the fragment's router names when T01 reads it; unread says why
// it does not.
func (c *checker) fragment() (routers []string, unread string) {
	if !isFile(traefikFile) {
		return nil, "traefik-dynamic.yml missing"
	}
	d := c.load(traefikFile)
	if d.bad != "" {
		return nil, "traefik-dynamic.yml " + d.bad
	}
	m, bad := mapAt(d.root, "http", "routers")
	if bad != "" {
		return nil, "traefik-dynamic.yml: " + bad
	}
	return keysOf(m), ""
}

// router is the value at path under a router.
func (c *checker) router(r string, p ...string) tree.Value {
	return c.need(c.load(traefikFile), append([]string{"http", "routers", r}, p...)...)
}

func (c *checker) rule(r string) string { return scalar(c.router(r, "rule")) }

func (c *checker) t02(routers []string, domain string) {
	found := false
	for _, r := range routers {
		if strings.Contains(c.rule(r), domain) {
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

func (c *checker) t03(routers []string) {
	var bad []string
	for _, r := range routers {
		switch ep := c.router(r, "entryPoints").(type) {
		case nil:
			bad = append(bad, r)
		case []tree.Value:
			if len(ep) == 0 {
				bad = append(bad, r)
			}
		default:
			bad = append(bad, r+" (entryPoints is "+kind(ep)+", not a list)")
		}
	}
	if len(bad) == 0 {
		c.passf("All routers declare entryPoints")
	} else {
		c.failf("Routers without entryPoints: %s", strings.Join(bad, " "))
	}
}

func (c *checker) t04(routers []string) {
	var bad []string
	for _, r := range routers {
		if !listHas(c.router(r, "entryPoints"), "websecure") {
			continue
		}
		if scalar(c.router(r, "tls", "certResolver")) != "letsencrypt" {
			bad = append(bad, r)
		}
	}
	if len(bad) == 0 {
		c.passf("Secure routers reference letsencrypt cert resolver")
	} else {
		c.failf("Websecure routers without tls.certResolver=letsencrypt: %s", strings.Join(bad, " "))
	}
}

func (c *checker) t08(routers []string, domain string) {
	found := false
	for _, r := range routers {
		if strings.Contains(c.rule(r), domain) && listHas(c.router(r, "entryPoints"), "web") {
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

// reservedLabels are the first DNS labels kasbah's own subdomains use.
var reservedLabels = []string{"traefik", "mail", "webmail"}

// t05 is the local form: a Host() whose first DNS label is one kasbah's own
// subdomains use. The exact match against a server's hostnames is --server's.
func (c *checker) t05(routers []string) {
	if c.srv != nil {
		c.t05Server(routers)
		return
	}
	var bad []string
	for _, r := range routers {
		for _, m := range hostRule.FindAllStringSubmatch(c.rule(r), -1) {
			host := m[1]
			label, _, _ := strings.Cut(host, ".")
			if inList(reservedLabels, label) {
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

func (c *checker) t06() {
	var bad []string
	for _, svc := range c.services {
		if traefikLabel(c.svc(svc, "labels")) {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("compose.prod.yml has no traefik.* labels")
	} else {
		c.failf("Services carry traefik.* labels (file provider only): %s", strings.Join(bad, " "))
	}
}

// traefikLabel is whether labels: names a traefik.* label, as a mapping's
// key or a list's `name=value` entry.
func traefikLabel(labels tree.Value) bool {
	names := keysOf(labels)
	if l, ok := labels.([]tree.Value); ok {
		for _, x := range l {
			name, _, _ := strings.Cut(scalar(x), "=")
			names = append(names, name)
		}
	}
	for _, n := range names {
		if strings.HasPrefix(n, "traefik.") {
			return true
		}
	}
	return false
}

func (c *checker) t07() {
	if len(c.services) == 0 {
		return
	}
	hosts := envtpl.SortUniq(c.routedHosts())
	if len(hosts) == 0 {
		c.passf("Fragment has no loadBalancer server URLs to verify")
		return
	}
	names := c.containerNames()
	var bad []string
	for _, h := range hosts {
		if !inList(names, h) {
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
	blank     = regexp.MustCompile(`^[ \t]*$`)
)

// routedHosts is the host of every string loadBalancer server URL in the
// fragment, none when it cannot be read.
func (c *checker) routedHosts() []string {
	if !isFile(traefikFile) {
		return nil
	}
	d := c.load(traefikFile)
	if d.bad != "" {
		return nil
	}
	svcs, _ := mapAt(d.root, "http", "services")
	if svcs == nil {
		return nil
	}
	var out []string
	for _, k := range svcs.Keys() {
		v, _ := svcs.Get(k)
		servers, _ := opt(v, "loadBalancer", "servers").([]tree.Value)
		for _, s := range servers {
			u, _ := opt(s, "url").(string)
			host := urlTail.ReplaceAllString(urlScheme.ReplaceAllString(u, ""), "")
			if !blank.MatchString(host) {
				out = append(out, host)
			}
		}
	}
	return out
}

// containerNames is every explicit container_name, in service order.
func (c *checker) containerNames() []string {
	var out []string
	for _, svc := range c.services {
		if cn := scalar(c.svc(svc, "container_name")); cn != "" {
			out = append(out, cn)
		}
	}
	return out
}

// --- Healthchecks (H01, H02) ------------------------------------------------

// block is whether the manifest has a block at key, as a deploy reads it:
// absent, null and false are none.
func (c *checker) block(key string) bool {
	v, _ := c.m.Get(key)
	return v != nil && v != false
}

func (c *checker) healthSection() {
	built := isFile(composeFile) && c.anyBuilt()
	health := c.block("health")
	if !built && !health {
		return
	}
	c.section("Healthchecks")
	if built {
		var bad []string
		for _, svc := range c.services {
			if c.built(svc) && c.svc(svc, "healthcheck") == nil {
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
		h, err := deploy.ReadHealth(c.m)
		switch {
		case err != nil:
			c.failErr(err)
		case h.Container == "":
			c.passf("manifest health: names no container — the deploy waits on every container with a healthcheck")
		case inList(c.containerNames(), h.Container):
			c.passf("manifest health.container '%s' exists in compose", h.Container)
		default:
			c.failf("manifest health.container '%s' not found among compose container_names", h.Container)
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
)

// --- Hooks (HK01–HK03) ------------------------------------------------------

func (c *checker) hooksSection() {
	hv, _ := c.m.Get("hooks")
	hooks, backup := hv != nil, c.block("backup")
	if !hooks && !backup {
		return
	}
	c.section("Hooks")
	names := c.containerNames()
	if hooks {
		c.hk01(hv, names)
	}
	if backup {
		c.hk02hk03(names)
	}
}

// hk01: each hook deploy would run names a container compose names, read in
// the manifest's own order.
func (c *checker) hk01(hv tree.Value, names []string) {
	lists, err := deploy.ReadHooks(c.m)
	if err != nil {
		c.failErr(err)
		return
	}
	var hs []string
	for _, k := range keysInOrder(hv) {
		hs = append(hs, lists[k]...)
	}
	if len(hs) == 0 {
		c.passf("Hooks block is empty")
		return
	}
	var bad []string
	for _, h := range hs {
		if ctr := deploy.HookContainer(h); !inList(names, ctr) {
			bad = append(bad, ctr)
		}
	}
	if len(bad) == 0 {
		c.passf("All hook commands target known container_names")
	} else {
		c.failf("Hooks reference unknown container_names: %s (set container_name on the target service in compose.prod.yml)", strings.Join(bad, " "))
	}
}

func keysInOrder(v tree.Value) []string {
	if m, ok := v.(*tree.Map); ok && m != nil {
		return m.Keys()
	}
	return nil
}

// hk02hk03: the backup block's fields, each read as a deploy reads it; with
// all of them there, whatever else a deploy refuses in the block fails too.
func (c *checker) hk02hk03(names []string) {
	if bv, _ := c.m.Get("backup"); kind(bv) != "a mapping" {
		if _, err := deploy.ReadBackup(c.m); err != nil {
			c.failErr(err)
		}
		return
	}
	read := func(f string) (string, error) {
		if v, _ := c.m.Get("backup", f); f == "check" && (v == true || v == false) {
			return tree.Compact(v), nil
		}
		return deploy.Field(c.m, "a string", "backup", f)
	}
	var missing []string
	wrong := false
	for _, f := range []string{"check", "command", "extension"} {
		switch v, err := read(f); {
		case err != nil:
			c.failErr(err)
			wrong = true
		case v == "":
			missing = append(missing, f)
		}
	}
	switch {
	case len(missing) > 0:
		c.failf("Backup hook missing required field(s): %s", strings.Join(missing, " "))
	case !wrong:
		c.passf("Backup hook has check, command, and extension")
	}

	ctr, err := read("container")
	switch {
	case err != nil:
		c.failErr(err)
	case ctr == "":
		c.failf("Backup hook missing 'container' field")
	case inList(names, ctr):
		c.passf("Backup hook container '%s' exists in compose", ctr)
	default:
		c.failf("Backup hook container '%s' not found among compose container_names", ctr)
	}
	if err == nil && ctr != "" && len(missing) == 0 && !wrong {
		if _, err := deploy.ReadBackup(c.m); err != nil {
			c.failErr(err)
		}
	}
}

// --- Mail (M01) -------------------------------------------------------------

func (c *checker) mailSection() {
	if !c.block("mail") {
		return
	}
	c.section("Mail")
	if d, err := deploy.MailDomain(c.m); err != nil {
		c.failErr(err)
	} else {
		c.passf("Mail claim names domain '%s'", d)
	}
}
