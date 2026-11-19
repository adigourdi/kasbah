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
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/composefile"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/resources"
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
	out   *cli.Output
	w     io.Writer
	cache yamlx.Cache
	m     *manifest.Manifest
	// res is kasbah.yml's resources:, unset when R05 refused it.
	res              resources.Spec
	pass, warn, fail int
	// flagged is the first rule a failure named, else the first a warning did.
	flagged, failed string
	srv             *server
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
		m, err := manifest.Require(manifest.File, e.Version)
		if err != nil {
			return e.report(ruled(err))
		}
		c.m = m
		if err := c.fix(e); err != nil {
			return e.report(err)
		}
	}
	fmt.Fprintln(c.w, "Structure:")

	m, err := manifest.Require(manifest.File, e.Version)
	if err != nil {
		return e.report(ruled(err))
	}
	c.m = m
	c.passf("S01,S02", "kasbah.yml exists (schema %s)", m.Schema)

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
		c.passf("S03", "compose.prod.yml exists")
	} else {
		c.failf("S03", "compose.prod.yml missing")
	}
	if isFile(templateFile) {
		c.passf("S04", ".env.prod.example exists")
	} else {
		c.failf("S04", ".env.prod.example missing")
	}
	if gitignoreHas(".env") {
		c.passf("S05", ".gitignore excludes .env")
	} else {
		c.warnf("S05", ".gitignore does not exclude .env")
	}
	if gitignoreHas(".kasbah/") {
		c.passf("S06", ".gitignore excludes .kasbah/")
	} else {
		c.warnf("S06", ".gitignore does not exclude .kasbah/")
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
	if c.warn+c.fail > 0 {
		c.footer()
	}
	if c.fail > 0 {
		return cli.ExitComplianceFail
	}
	return cli.ExitOK
}

// passf, warnf and failf print one verdict line led by the IDs it speaks for
// (comma-separated, each in Rules); "" is a line no catalog rule owns.
func (c *checker) passf(ids, format string, a ...any) {
	c.pass++
	c.line("✓", ids, fmt.Sprintf(format, a...))
}

func (c *checker) warnf(ids, format string, a ...any) {
	c.warn++
	c.flag(ids)
	c.line("⚠", ids, fmt.Sprintf(format, a...))
}

func (c *checker) failf(ids, format string, a ...any) {
	c.fail++
	if c.failed == "" {
		c.failed, _, _ = strings.Cut(ids, ",")
	}
	c.flag(ids)
	c.line("✗", ids, fmt.Sprintf(format, a...))
}

func (c *checker) line(mark, ids, text string) {
	if ids != "" {
		text = ids + " " + text
	}
	fmt.Fprintf(c.w, "  %s %s\n", mark, text)
}

// flag keeps the first rule a warning or failure names, for the footer.
func (c *checker) flag(ids string) {
	if c.flagged == "" {
		c.flagged, _, _ = strings.Cut(ids, ",")
	}
}

// footer points at the help for the lines that warned or failed.
func (c *checker) footer() {
	if c.failed != "" {
		c.flagged = c.failed
	}
	if c.flagged == "" {
		fmt.Fprintln(c.w, "`kasbah help rules` lists every rule and what it asks.")
		return
	}
	fmt.Fprintf(c.w, "`kasbah help %s` (or any ID above) says why a rule exists and what to change.\n", c.flagged)
}

// ruled leads a manifest refusal that is a Structure rule's with its ID, as
// check's own lines do.
func ruled(err error) error {
	var e *cli.Error
	if errors.As(err, &e) && slices.Contains([]string{"S01", "S02", "S07"}, e.HelpTopic()) {
		e.Lines[0] = e.HelpTopic() + " " + e.Lines[0]
	}
	return err
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

func (c *checker) failErr(ids string, err error) {
	c.failf(ids, "%s", strings.ReplaceAll(err.Error(), "\n", "; "))
}

func (c *checker) s08() {
	raw, err := deploy.Field(c.m, "a string", "client")
	if err != nil {
		c.failErr("S08", err)
		return
	}
	switch reason, ok := manifest.ClientCheck(raw); {
	case raw == "":
		c.passf("S08", "client is not set — backups file under the project name (%s)", c.m.Name)
	case ok:
		c.passf("S08", "client '%s' names a backup repository kasbah can create", raw)
	default:
		c.failf("S08", "kasbah.yml: %s", reason)
	}
}

// --- Compose (C01–C05, C07–C11, C14–C16) ----------------------------------------

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
		c.failf("", "compose.prod.yml %s", c.compose.bad)
		return
	}
	if c.servicesBad != "" {
		c.failf("", "compose.prod.yml: %s", c.servicesBad)
		if _, ok := c.compose.root.(*tree.Map); ok {
			c.c05()
		}
		return
	}
	if len(c.services) == 0 {
		// Only the shape deploy brings up without compose up passes; an empty file
		// or one whose services come through include: does not.
		if composefile.ServicelessDoc(c.compose.root) {
			c.passf("", "compose.prod.yml declares no services — a redirect-only project; Compose checks skipped")
		} else {
			c.warnf("", "compose.prod.yml declares no services — skipping Compose checks")
		}
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
		c.passf("C01", "All services set restart policy")
	} else {
		c.failf("C01", "Services missing restart policy: %s", strings.Join(bad, " "))
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
		c.passf("C02", "All services set json-file logging with rotation")
	} else {
		c.failf("C02", "Services missing json-file logging with max-size/max-file: %s", strings.Join(bad, " "))
	}

	c.c09Project(c.networks())
	c.c16()
	c.c10()
	c.c05()
	if c.anyBuilt() {
		c.c08()
	}
	c.c14()
	c.c11()
	c.c15()
}

// c14: no service publishes host port 80 or 443, Traefik's; a host range
// holding either fails too. An entry whose host port needs interpolation is
// left to C12.
func (c *checker) c14() {
	var bad []string
	for _, svc := range c.services {
		for _, p := range asList(c.svc(svc, "ports")) {
			var b deploy.Bind
			ok := false
			if m, isMap := p.(*tree.Map); isMap {
				b, ok = deploy.ParseBind(scalar(opt(m, "host_ip")), scalar(opt(m, "published")), scalar(opt(m, "protocol")))
			} else if str, isStr := p.(string); isStr {
				b, ok, _ = deploy.ParseShortPort(str)
			}
			if ok && (b.Lo <= 80 && 80 <= b.Hi || b.Lo <= 443 && 443 <= b.Hi) {
				bad = append(bad, svc+" ("+b.String()+")")
			}
		}
	}
	if len(bad) == 0 {
		c.passf("C14", "No service publishes host port 80 or 443")
	} else {
		c.failf("C14", "Services publishing host port 80 or 443: %s — those ports belong to the shared Traefik, whatever the protocol (over TCP a bind collides with it, a range may take them while it is down); route through traefik-dynamic.yml or publish another port", strings.Join(bad, " "))
	}
}

func (c *checker) c05() {
	if scalar(c.need(c.compose, "version")) != "" {
		c.warnf("C05", "compose.prod.yml uses deprecated 'version:' field")
	} else {
		c.passf("C05", "No deprecated 'version:' field")
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
		c.passf("C08", "All built services reference their image as :current")
	} else {
		c.failf("C08", "Built services whose image: is not tagged :current: %s — deploy moves <image>:current, so a pinned tag keeps the old image running", strings.Join(bad, " "))
	}
}

// c11: every routed service rolls on deploy as far as compose and the
// fragment show; live state and the image's own HEALTHCHECK are the deploy's.
func (c *checker) c11() {
	routed := c.rollHosts()
	if len(routed) == 0 {
		return
	}
	n, warned := 0, false
	var noRoll []string
	shared := c.sharedNets()
	for _, svc := range c.services {
		// One C03 fails is not judged: it reaches Traefik over no network yet.
		if !c.routes(svc, routed) || !joinsNet(c.svc(svc, "networks"), projectNet) || c.joinsAny(svc, shared) {
			continue
		}
		n++
		r := c.rollShape(svc, routed)
		stays := r.Stays(false)
		if len(stays) == 0 {
			continue
		}
		if stays[0] == deploy.StayNoRoll {
			noRoll = append(noRoll, svc+" is recreated in place on deploy, as "+r.Why(deploy.StayNoRoll))
			continue
		}
		warned = true
		st := stays[0]
		if st == deploy.StayNoHealthcheck && r.Health == deploy.HealthUnset {
			if len(stays) == 1 {
				c.warnf("C11", "%s rolls on deploy only if its image declares a HEALTHCHECK — compose gives it none, and without one it is recreated in place, briefly unrouted", svc)
				continue
			}
			st = stays[1]
		}
		c.warnf("C11", "%s will not roll on deploy — %s, so it is recreated in place, briefly unrouted", svc, r.Why(st))
	}
	switch {
	case warned || n == len(noRoll):
	case len(noRoll) > 0:
		c.passf("C11", "All other routed services can roll on deploy")
	default:
		c.passf("C11", "All routed services can roll on deploy")
	}
	for _, line := range noRoll {
		c.passf("C11", "%s — its old containers stop before the new ones start, briefly unrouted", line)
	}
}

// noRollLabels is svc's kasbah.noRoll labels as compose.prod.yml writes
// them, keyed as written (any case matches, as in Traefik): the map form, or
// the list form, a key's last entry winning. A YAML boolean reads as compose
// renders it, "true" or "false", and a whole-number float as an integer
// ("0.0" as "0").
func (c *checker) noRollLabels(svc string) map[string]string {
	out := map[string]string{}
	labels := c.svc(svc, "labels")
	for _, k := range keysOf(labels) {
		if !strings.EqualFold(k, deploy.NoRollLabel) {
			continue
		}
		x := opt(labels, k)
		out[k] = scalar(x)
		if n, ok := x.(tree.Number); ok {
			if _, isInt := n.Int64(); !isInt {
				if f, err := strconv.ParseFloat(string(n), 64); err == nil {
					out[k] = strconv.FormatFloat(f, 'f', -1, 64)
				}
			}
		}
	}
	for _, l := range asList(labels) {
		s, _ := l.(string)
		if k, v, _ := strings.Cut(s, "="); strings.EqualFold(k, deploy.NoRollLabel) {
			out[k] = v
		}
	}
	return out
}

// interpolated is whether compose would interpolate v: it names a variable,
// as $VAR or ${...}; `$$` is a literal `$`.
func interpolated(v string) bool {
	named := false
	envtpl.Interpolate(v, func(string) (string, bool) { named = true; return "", false })
	return named
}

// c15: every kasbah.noRoll label is a boolean as strconv.ParseBool reads it.
// The deploy reads any other value as true; an interpolated one only the
// deploy can resolve.
func (c *checker) c15() {
	seen, bad := false, false
	for _, svc := range c.services {
		labels := c.noRollLabels(svc)
		for _, k := range slices.Sorted(maps.Keys(labels)) {
			seen = true
			v := labels[k]
			if _, err := strconv.ParseBool(v); err == nil {
				continue
			}
			bad = true
			if interpolated(v) {
				c.warnf("C15", "%s: %s is '%s' — check cannot resolve it; a deploy reads the resolved value, and anything but a false boolean as true", svc, k, v)
			} else {
				c.failf("C15", "%s: %s is '%s', not a boolean — write true or false; a deploy reads it as true", svc, k, v)
			}
		}
	}
	if seen && !bad {
		c.passf("C15", "Every %s label is a boolean", deploy.NoRollLabel)
	}
}

// rollHosts is the fragment's routed hosts as C11 judges rolls by: none when
// the fragment cannot be read.
func (c *checker) rollHosts() []string {
	if _, unread := c.fragment(); unread != "" {
		return nil
	}
	return c.routedHosts()
}

// rolls is whether svc is routed and C11 finds nothing to keep it from rolling.
func (c *checker) rolls(svc string, routed []string) bool {
	return c.routes(svc, routed) && len(c.rollShape(svc, routed).Stays(false)) == 0
}

// rollShape is what compose.prod.yml and the fragment's hosts say of svc's
// roll, read as `docker compose config` would normalise it.
func (c *checker) rollShape(svc string, routed []string) deploy.RollShape {
	cn := scalar(c.svc(svc, "container_name"))
	r := deploy.RollShape{ByContainerName: cn != "" && inList(routed, cn), ContainerName: cn != ""}
	labels := c.noRollLabels(svc)
	for k, v := range labels {
		if interpolated(v) {
			delete(labels, k)
		}
	}
	r.NoRoll = deploy.NoRoll(labels)
	for _, p := range asList(c.svc(svc, "ports")) {
		if published(p) {
			r.Published = true
		}
	}
	r.Health = composeHealth(c.svc(svc, "healthcheck"))
	if r.Health == deploy.HealthUnset && scalar(c.svc(svc, "image")) == "" {
		r.Health = deploy.HealthOff
	}
	deps := c.svc(svc, "depends_on")
	for _, d := range keysOf(deps) {
		if cond := scalar(opt(deps, d, "condition")); cond != "" && cond != "service_started" {
			r.Gated = d + " (" + cond + ")"
			break
		}
	}
	return r
}

// composeHealth is what a compose healthcheck says alone: off when disabled or
// NONE, declared with a test, unset without one.
func composeHealth(hc tree.Value) deploy.Healthcheck {
	test := asList(opt(hc, "test"))
	shell, _ := opt(hc, "test").(string)
	switch {
	case opt(hc, "disable") == true, len(test) > 0 && test[0] == "NONE":
		return deploy.HealthOff
	case len(test) > 0 || shell != "":
		return deploy.HealthDeclared
	}
	return deploy.HealthUnset
}

// published is whether a ports: entry binds a host port: the long form's
// published:, or the host side of "[ip:]host:container[/proto]".
func published(p tree.Value) bool {
	if m, ok := p.(*tree.Map); ok {
		return scalar(opt(m, "published")) != ""
	}
	s, ok := p.(string)
	if !ok {
		return false
	}
	s, _, _ = strings.Cut(s, "/")
	i := strings.LastIndex(s, ":")
	if i < 0 {
		return false
	}
	host := s[:i]
	if j := strings.LastIndex(host, ":"); j >= 0 && !strings.HasSuffix(host, "]") {
		host = host[j+1:]
	} else if strings.HasPrefix(host, "[") {
		host = ""
	}
	return host != ""
}

// projectNet is the compose network key a project's routed services join:
// compose names it <name>_kasbah, and deploy connects Traefik to it.
const projectNet = "kasbah"

// networks is C03, C04 and C07; it returns the services on the project's
// kasbah network, for C09.
func (c *checker) networks() (own []string) {
	routed := c.routedHosts()
	_, unread := c.fragment()
	if c.m.Unrouted && !isFile(traefikFile) {
		unread = ""
	}
	shared := c.sharedNets()

	var badC03, legacy, badC07 []string
	nRouted := 0
	for _, svc := range c.services {
		isRouted := c.routes(svc, routed)
		pn := joinsNet(c.svc(svc, "networks"), projectNet)
		if isRouted {
			nRouted++
		}
		if pn {
			own = append(own, svc)
		}
		switch {
		case isRouted && c.joinsAny(svc, shared):
			legacy = append(legacy, svc)
		case isRouted && !pn:
			badC03 = append(badC03, svc)
		}
		if !isRouted && pn {
			badC07 = append(badC07, svc)
		}
	}

	switch {
	case unread != "" && len(own) == 0:
		c.warnf("C03,C11", "%s — skipping C03 and C11, which need the services it routes", unread)
	case unread != "":
		c.warnf("C03,C07,C11", "%s — skipping C03, C07 and C11, which need the services it routes", unread)
	case len(legacy)+len(badC03) > 0:
		if len(legacy) > 0 {
			c.failf("C03", "Routed services on the shared kasbah-net: %s — Traefik reaches a routed service only over the project's kasbah network: join them to kasbah in its place, declare kasbah: {} and drop kasbah-net; check --fix does where kasbah-net is the network's key", strings.Join(legacy, " "))
		}
		if len(badC03) > 0 {
			c.failf("C03", "Routed services not on the project's kasbah network: %s", strings.Join(badC03, " "))
		}
	case nRouted > 0:
		c.passf("C03", "All routed services join the project's kasbah network")
	default:
		c.passf("C03", "No Traefik-routed services in compose")
	}
	if len(own) > 0 {
		c.c04Project()
	}
	c.c04External(len(own) > 0)
	switch {
	case unread != "" && len(own) > 0:
	case len(badC07) > 0:
		c.failf("C07", "Non-routed services on the kasbah network: %s — Traefik joins it, so only what it routes belongs there", strings.Join(badC07, " "))
	default:
		c.passf("C07", "No internal services on the kasbah network")
	}
	return own
}

// sharedNets is the network keys that are the shared kasbah-net: that key, and
// any network named kasbah-net, compose's default among them.
func (c *checker) sharedNets() []string {
	out := []string{sharedNet}
	c.need(c.compose, "networks", "default") // aborts the check on a networks: that is no mapping
	nets, _ := c.need(c.compose, "networks").(*tree.Map)
	for _, k := range keysOf(nets) {
		if k != sharedNet && realNet(k, opt(nets, k)) == sharedNet {
			out = append(out, k)
		}
	}
	return out
}

// joinsAny is whether svc joins one of the network keys nets, compose's
// default by having no networks: at all.
func (c *checker) joinsAny(svc string, nets []string) bool { return joinsAny(c.svc(svc), nets) }

func joinsAny(svc tree.Value, nets []string) bool {
	for _, k := range nets {
		if joinsNet(opt(svc, "networks"), k) || k == "default" && !hasKey(svc, "networks") {
			return true
		}
	}
	return false
}

// realNet is the name of the network declared under key k: its name:, an
// external's old {name: …}, else the key.
func realNet(k string, n tree.Value) string {
	if x := scalar(opt(n, "name")); x != "" {
		return x
	}
	if x := scalar(opt(n, "external", "name")); x != "" {
		return x
	}
	return k
}

// c04Project is C04 for the project's own network: declared, and exactly {}.
// Compose recreates a network whose settings change, which fails while
// Traefik is attached, so it gets none.
func (c *checker) c04Project() {
	d := c.compose
	name := c.m.Name + "_" + projectNet
	v := c.need(d, "networks", projectNet)
	m, isMap := v.(*tree.Map)
	switch {
	case !hasKey(c.need(d, "networks"), projectNet):
		c.failf("C04", "The kasbah network is not declared under the top-level networks: — add kasbah: {}")
	case v != nil && !isMap:
		c.failf("C04", "The kasbah network is declared as %s — declare it as kasbah: {}", tree.Compact(v))
	case isMap && m != nil && truthy(opt(m, "external")):
		c.failf("C04", "The kasbah network is declared external — it is the project's own: drop external: so compose creates %s, which deploy connects Traefik to", name)
	case isMap && m != nil && m.Len() > 0:
		c.failf("C04", "The kasbah network sets %s — declare it as kasbah: {}: compose recreates a network whose settings change, which fails while Traefik is attached, and every later deploy would fail at up", strings.Join(m.Keys(), ", "))
	default:
		c.passf("C04", "The kasbah network is the project's own (%s)", name)
	}
}

// truthy is a compose external: — true, or the old {name: …} mapping.
func truthy(v tree.Value) bool {
	switch x := v.(type) {
	case bool:
		return x
	case *tree.Map:
		return x != nil
	}
	return false
}

// c04External: a project takes no network from outside — an external one, or
// one whose name: is not compose's own <name>_<key>, is another stack's
// (mail_kasbah, <other>_kasbah, kasbah-net). The kasbah network is
// c04Project's when it ran.
func (c *checker) c04External(projectDone bool) {
	var bad []string
	nets, _ := c.need(c.compose, "networks").(*tree.Map)
	for _, k := range keysOf(nets) {
		n, _ := opt(nets, k).(*tree.Map)
		switch {
		case n == nil || k == projectNet && projectDone:
		case truthy(opt(n, "external")):
			bad = append(bad, k+" (external "+realNet(k, n)+")")
		case scalar(opt(n, "name")) != "" && realNet(k, n) != c.m.Name+"_"+k:
			bad = append(bad, k+" (named "+realNet(k, n)+")")
		}
	}
	if len(bad) > 0 {
		c.failf("C04", "Networks from outside the project: %s — a network outside the project is shared with whatever else joins it: drop it, or drop its external: and name: so compose creates %s_<key>; a deploy refuses it", strings.Join(bad, " "), c.m.Name)
	}
}

// c09Project fails a name on the kasbah network not named for the project:
// Traefik sits on every project's network and resolves names across them, so
// another project's service, alias or container_name could answer for this one's.
func (c *checker) c09Project(own []string) {
	if len(own) == 0 {
		return
	}
	name := c.m.Name
	ok := func(s string) bool { return s == name || strings.HasPrefix(s, name+"-") }
	var bad []string
	for _, svc := range own {
		if !ok(svc) {
			bad = append(bad, svc+" (service)")
		}
		for _, a := range asList(opt(c.svc(svc, "networks"), projectNet, "aliases")) {
			if s, _ := a.(string); !ok(s) {
				bad = append(bad, tree.Text(a)+" (alias of "+svc+")")
			}
		}
		if cn := scalar(c.svc(svc, "container_name")); cn != "" && !ok(cn) {
			bad = append(bad, cn+" (container_name of "+svc+")")
		}
	}
	if len(bad) == 0 {
		c.passf("C09", "Names on the kasbah network are project-prefixed")
	} else {
		c.failf("C09", "Names on the kasbah network that are not '%s' or '%s-*': %s — Traefik resolves names across every project's network, so another project's name can answer for this one's", name, name, strings.Join(bad, " "))
	}
}

// c16 fails a name with a dot on the kasbah network: Docker answers a whole
// dotted name on every network Traefik is on, so web.<other>_kasbah would
// answer for another project's backend. Silent when none has one.
func (c *checker) c16() {
	var bad []string
	for _, svc := range c.services {
		on := c.svc(svc, "networks")
		if !joinsNet(on, projectNet) {
			continue
		}
		if strings.Contains(svc, ".") {
			bad = append(bad, svc+" (service)")
		}
		var aliases []string
		for _, a := range asList(opt(on, projectNet, "aliases")) {
			if s := tree.Text(a); strings.Contains(s, ".") && !slices.Contains(aliases, s) {
				aliases = append(aliases, s)
			}
		}
		for _, a := range aliases {
			bad = append(bad, a+" (alias of "+svc+")")
		}
		if cn := scalar(c.svc(svc, "container_name")); strings.Contains(cn, ".") {
			bad = append(bad, cn+" (container_name of "+svc+")")
		}
	}
	if len(bad) > 0 {
		c.failf("C16", "Names on the kasbah network with a dot: %s — Docker answers a dotted name on every network Traefik is on, so it could answer for another project's backend or kasbah's own webmail; a deploy refuses it", strings.Join(bad, " "))
	}
}

// c10 warns where the project still names mail-dms: no project shares a
// network with it, and apps submit on mail.<domain>:587 (docs/mail.md).
func (c *checker) c10() {
	var bad []string
	for _, f := range []string{composeFile, templateFile} {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		for _, l := range strings.Split(strings.ReplaceAll(string(b), "\r", ""), "\n") {
			if t := strings.TrimSpace(l); !strings.HasPrefix(t, "#") && strings.Contains(t, "mail-dms") {
				bad = append(bad, f)
				break
			}
		}
	}
	if len(bad) > 0 {
		c.warnf("C10", "mail-dms is named in %s — no project shares a network with the mail server; send through mail.<domain>:587 with a mailbox login", strings.Join(bad, " and "))
	}
}

// --- Resources (R01–R03, R05) -----------------------------------------------

// limitKeys are R01/R02: each top-level key, its compose-spec
// deploy.resources.limits twin, and the reference that tracks the host.
var limitKeys = []struct{ key, deploy, ref, rule string }{
	{"cpus", "cpus", "${KASBAH_CPU_LIMIT}", "R01"},
	{"mem_limit", "memory", "${KASBAH_MEM_LIMIT}", "R02"},
}

// memMin is the smallest memory limit docker accepts.
const memMin = 6 << 20

// limitOf is how a service spells one limit — "ref", "literal", "missing" or
// "malformed" — and whether deploy.resources.limits carries it.
func limitOf(svc tree.Value, key, depKey, ref string) (kind, text string, deploy bool) {
	top, dep := opt(svc, key), opt(svc, "deploy", "resources", "limits", depKey)
	switch {
	case top == nil && dep == nil:
		return "missing", "", false
	case dep == nil:
		kind, text = limitValue(top, key, ref)
		return kind, text, false
	}
	dk, dt := limitValue(dep, key, ref)
	if depKey == "memory" && tree.Kind(dep) == "number" {
		dk = "malformed" // compose's schema takes memory only as a string
	}
	if top == nil {
		return dk, dt, true
	}
	// Both forms: compose refuses them unless they are the same limit.
	tk, tt := limitValue(top, key, ref)
	same := tk == dk && (tk == "ref" || tk == "literal" &&
		(key == "cpus" && resources.CmpCPU(tt, dt) == "same" || key != "cpus" && resources.CmpMem(tt, dt) == "same"))
	if !same {
		return "malformed", tt, true
	}
	return tk, tt, true
}

// limitValue judges one spelling of a limit.
func limitValue(v tree.Value, key, ref string) (kind, text string) {
	t := scalar(v)
	if t == ref {
		return "ref", t
	}
	if k := tree.Kind(v); k != "string" && k != "number" {
		return "malformed", t
	}
	if key == "cpus" {
		if resources.CPUText(t) && strings.ContainsAny(t, "123456789") {
			return "literal", t
		}
	} else if n, ok := resources.MemBytes(t); ok && n >= memMin {
		return "literal", t
	}
	return "malformed", t
}

func (c *checker) resourcesSection() {
	block, _ := c.m.Get("resources")
	svcs := isFile(composeFile) && len(c.services) > 0
	if !svcs && block == nil {
		return
	}
	c.section("Resources")
	c.r05(block)
	if !svcs {
		return
	}
	var bad, lits []string
	for _, svc := range c.services {
		var wrong, lit []string
		for _, k := range limitKeys {
			switch kind, t, _ := limitOf(c.svc(svc), k.key, k.deploy, k.ref); kind {
			case "missing", "malformed":
				wrong = append(wrong, k.key)
			case "literal":
				lit = append(lit, k.key+"="+t)
			}
		}
		if len(wrong) > 0 {
			bad = append(bad, svc+"("+strings.Join(wrong, ",")+")")
		}
		if len(lit) > 0 {
			lits = append(lits, svc+"("+strings.Join(lit, ",")+")")
		}
	}
	switch {
	case len(bad) > 0:
		c.failf("R01,R02", "Services with missing or malformed resource limits: %s — each sets cpus: ${KASBAH_CPU_LIMIT} or a positive number (0.5, 2), and mem_limit: ${KASBAH_MEM_LIMIT} or a size of at least docker's 6m (512m, 1.5g, 2GiB) — top-level or under deploy.resources.limits, never two different values", strings.Join(bad, " "))
	case len(lits) == 0:
		c.passf("R01,R02", "All services set cpus/mem_limit via KASBAH_* vars")
	case c.srv != nil:
		c.passf("R01,R02", "All services set cpus/mem_limit, some as literals: %s — compared with the host's ceiling under Server (R04)", strings.Join(lits, " "))
	}
	if len(lits) > 0 && c.srv == nil {
		c.warnf("R01,R02", "Services with literal resource limits: %s — a literal does not follow the host's ceiling, and only check --server can compare it with it", strings.Join(lits, " "))
	}

	bad = nil
	for _, svc := range c.services {
		if c.svc(svc, "deploy", "resources", "reservations") != nil || c.svc(svc, "mem_reservation") != nil {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("R03", "No resource reservations")
	} else {
		c.failf("R03", "Services declare resource reservations: %s", strings.Join(bad, " "))
	}
}

// r05: kasbah.yml's resources: block, silent when there is none.
func (c *checker) r05(block tree.Value) {
	if block == nil {
		return
	}
	spec, err := resources.Read(c.m)
	if err != nil {
		c.failf("R05", "kasbah.yml: %v", err)
		return
	}
	var set []string
	if spec.CPUs != "" {
		set = append(set, "cpus "+spec.CPUs)
	}
	if spec.Memory != "" {
		set = append(set, "memory "+spec.Memory)
	}
	if len(set) == 0 {
		c.passf("R05", "resources: sets nothing — the containers get the server's 90%% ceiling")
		return
	}
	c.res = spec
	c.passf("R05", "resources: %s — resolved on the server at deploy (a %% is a share of the host) and held to its 90%% ceiling", strings.Join(set, ", "))
}

// --- Traefik (T01–T13) ------------------------------------------------------

func (c *checker) traefikSection() {
	c.section("Traefik")
	routers, unread := c.fragment()
	unrouted := c.m.Unrouted
	switch {
	case unrouted && isFile(traefikFile):
		c.failf("T11", "kasbah.yml sets routed: false, yet traefik-dynamic.yml exists — remove one: the fragment to keep the project unrouted, or routed: false to route it")
	case unrouted:
		c.passf("T11", "No traefik-dynamic.yml — the project is unrouted (routed: false)")
	case unread != "":
		c.warnf("T01", "%s — skipping T02–T05 and T08–T10", unread)
	default:
		c.passf("T01", "traefik-dynamic.yml exists")
	}
	if unrouted && c.m.Domain != "" {
		c.warnf("T11", "manifest domain is '%s', but routed: false — nothing routes it to this project; leave domain: out", c.m.Domain)
	}

	if unread == "" {
		domain := c.m.Domain
		if domain != "" {
			c.t02(routers, domain)
		} else if !unrouted {
			c.warnf("T02,T08", "manifest domain is empty — skipping T02 and T08 (both match routers against it)")
		}
		c.t03(routers)
		c.t04(routers)
		c.t10(routers)
		if domain != "" {
			c.t08(routers, domain)
		}
		c.t05(routers)
		c.t09(routers)
		c.t07()
	}
	if !unrouted && isFile(traefikFile) {
		c.t12(unread == "")
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
		c.passf("T02", "At least one router references manifest domain (%s)", domain)
	} else {
		c.failf("T02", "No router rule references manifest domain (%s)", domain)
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
		c.passf("T03", "All routers declare entryPoints")
	} else {
		c.failf("T03", "Routers without entryPoints: %s", strings.Join(bad, " "))
	}
}

// t04: every websecure router names a cert resolver. A name other than http
// is a DNS provider's resolver, which only the server's traefik.yml declares.
func (c *checker) t04(routers []string) {
	var bad, legacy, other, undeclared []string
	for _, r := range routers {
		if !listHas(c.router(r, "entryPoints"), "websecure") {
			continue
		}
		name := scalar(c.router(r, "tls", "certResolver"))
		switch {
		case name == acme.Resolver:
		case name == "letsencrypt":
			legacy = append(legacy, r)
		case name == "":
			bad = append(bad, r)
		case c.srv != nil && c.srv.resolvers != nil:
			if _, ok := c.srv.resolvers[name]; !ok {
				undeclared = append(undeclared, r+"→"+name)
			}
		default:
			other = append(other, r+"→"+name)
		}
	}
	if len(bad)+len(legacy)+len(undeclared) == 0 {
		c.passf("T04", "Secure routers name a cert resolver")
	}
	if len(other) > 0 {
		where := "only `check --server` can verify the server declares them"
		if c.srv != nil {
			where = "traefik.yml on " + c.srv.target + " could not be read, so whether it declares them is unknown"
		}
		c.warnf("T04", "Routers name a cert resolver other than %s: %s — %s (`server init --acme-dns=<provider>:<env file>` adds one)", acme.Resolver, strings.Join(other, " "), where)
	}
	if len(undeclared) > 0 {
		c.failf("T04", "Routers name a cert resolver %s does not declare: %s — `kasbah server init --acme-dns=<provider>:<env file>` adds one", c.srv.target, strings.Join(undeclared, " "))
	}
	if len(legacy) > 0 {
		c.failf("T04", "certResolver letsencrypt was renamed to %s — set tls.certResolver: %s on: %s", acme.Resolver, acme.Resolver, strings.Join(legacy, " "))
	}
	if len(bad) > 0 {
		c.failf("T04", "Websecure routers without tls.certResolver: %s", strings.Join(bad, " "))
	}
}

// t10: a wildcard certificate takes DNS-01. http always answers HTTP-01; any
// other resolver is judged against the server's traefik.yml under --server.
func (c *checker) t10(routers []string) {
	root := c.load(traefikFile).root
	var bad []string
	judge := func(label string, router tree.Value, rule string) {
		name := scalar(opt(router, "tls", "certResolver"))
		var wild []string
		for _, h := range acme.RuleHosts(rule) {
			if strings.HasPrefix(h, "*.") {
				wild = append(wild, h)
			}
		}
		for _, d := range asList(opt(router, "tls", "domains")) {
			names := append([]tree.Value{opt(d, "main")}, asList(opt(d, "sans"))...)
			for _, n := range names {
				if s := scalar(n); strings.HasPrefix(s, "*.") {
					wild = append(wild, s)
				}
			}
		}
		if len(wild) == 0 || name == "" {
			return
		}
		dns, declared := false, false
		switch {
		case name == acme.Resolver || name == "letsencrypt":
			declared = true
		case c.srv != nil && c.srv.resolvers != nil:
			dns, declared = c.srv.resolvers[name]
		default:
			return
		}
		if declared && !dns {
			bad = append(bad, label+"→"+name+" ("+strings.Join(wild, " ")+")")
		}
	}
	for _, r := range routers {
		judge(r, c.router(r), c.rule(r))
	}
	tcp := opt(root, "tcp", "routers")
	for _, r := range keysOf(tcp) {
		judge("tcp "+r, opt(tcp, r), "")
	}
	if len(bad) > 0 {
		c.failf("T10", "Routers ask for a wildcard certificate from a resolver without dnsChallenge (HTTP-01 cannot issue one): %s — name a DNS provider's resolver (`server init --acme-dns=`)", strings.Join(bad, " "))
	} else {
		c.passf("T10", "No router asks for a wildcard certificate from an HTTP-01 resolver")
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
		c.passf("T08", "A router serves %s on the web entrypoint", domain)
	} else {
		c.warnf("T08", "No router serves %s on the web entrypoint — plain HTTP gets Traefik's 404; add a redirect router with middlewares: [\"http-to-https@file\"] and service: noop@internal", domain)
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
		c.failf("T05", "Routers claim reserved hostnames: %s", strings.Join(bad, " "))
	} else {
		c.passf("T05", "No router claims reserved hostnames (traefik.*, mail.*, webmail.*)")
	}
}

// t09: a project may not reach Traefik's own services (api@internal,
// dashboard@internal, ...) from a router, a composing service or an errors
// middleware. noop@internal is the redirect router's placeholder and stays allowed.
func (c *checker) t09(routers []string) {
	var bad []string
	seen := map[string]bool{}
	flag := func(where string, v tree.Value) {
		if s := scalar(v); internalService(s) && !seen[where+"→"+s] {
			seen[where+"→"+s] = true
			bad = append(bad, where+"→"+s)
		}
	}
	for _, r := range routers {
		flag(r, c.router(r, "service"))
	}
	root := c.load(traefikFile).root
	svcs, _ := mapAt(root, "http", "services")
	for _, k := range keysOf(svcs) {
		v, _ := svcs.Get(k)
		where := "services." + k
		flag(where, opt(v, "mirroring", "service"))
		for _, list := range [][]string{{"mirroring", "mirrors"}, {"weighted", "services"}, {"highestRandomWeight", "services"}} {
			for _, x := range asList(opt(v, list...)) {
				flag(where, opt(x, "name"))
			}
		}
		flag(where, opt(v, "failover", "service"))
		flag(where, opt(v, "failover", "fallback"))
	}
	mws, _ := mapAt(root, "http", "middlewares")
	for _, k := range keysOf(mws) {
		v, _ := mws.Get(k)
		flag("middlewares."+k, opt(v, "errors", "service"))
	}
	if len(bad) > 0 {
		c.failf("T09", "Fragment routes to Traefik's internal services (only noop@internal is allowed): %s", strings.Join(bad, " "))
	} else {
		c.passf("T09", "No router or service reaches a Traefik internal service other than noop@internal")
	}
}

// t12 holds the ${KEY}s a deploy fills to keys the template declares, none of
// them kasbah's; t13, when the fragment parses, out of hosts, resolvers and the
// service names T09 reads. Silent for a fragment with none.
func (c *checker) t12(parsed bool) {
	raw, err := os.ReadFile(traefikFile)
	keys := deploy.FragmentKeys(raw)
	if err != nil || len(keys) == 0 {
		return
	}
	declared := map[string]bool{}
	for _, k := range envtpl.Keys(templateFile) {
		declared[k] = true
	}
	var reserved, undeclared []string
	for _, k := range keys {
		switch {
		case strings.HasPrefix(k, envtpl.ReservedPrefix):
			reserved = append(reserved, k)
		case !declared[k]:
			undeclared = append(undeclared, k)
		}
	}
	var parts []string
	if len(reserved) > 0 {
		parts = append(parts, fmt.Sprintf("reserved %s* keys, which a deploy never fills it from: %s", envtpl.ReservedPrefix, strings.Join(reserved, " ")))
	}
	if len(undeclared) > 0 {
		parts = append(parts, fmt.Sprintf("keys .env.prod.example does not declare: %s — a deploy fills ${KEY} from the server's .env, declared keys only", strings.Join(undeclared, " ")))
	}
	if len(parts) > 0 {
		c.failf("T12", "Fragment names %s", strings.Join(parts, "; and "))
	} else {
		c.passf("T12", "Fragment's ${KEY}s are declared in .env.prod.example (%s) — a deploy fills them from the server's .env", strings.Join(keys, " "))
	}
	if parsed {
		c.t13()
	}
}

func (c *checker) t13() {
	var bad []string
	root := c.load(traefikFile).root
	for _, proto := range []string{"http", "tcp"} {
		rs, _ := mapAt(root, proto, "routers")
		for _, r := range keysOf(rs) {
			v, _ := rs.Get(r)
			for _, k := range []string{"rule", "tls", "service", "middlewares"} {
				if x, ok := tree.Lookup(v, k); ok && namesKey(x) {
					bad = append(bad, r+"."+k)
				}
			}
		}
	}
	// The service names T09 reads outside routers stay literal too.
	svcs, _ := mapAt(root, "http", "services")
	for _, k := range keysOf(svcs) {
		v, _ := svcs.Get(k)
		names := []tree.Value{opt(v, "mirroring", "service"), opt(v, "failover", "service"), opt(v, "failover", "fallback")}
		for _, list := range [][]string{{"mirroring", "mirrors"}, {"weighted", "services"}, {"highestRandomWeight", "services"}} {
			for _, x := range asList(opt(v, list...)) {
				names = append(names, opt(x, "name"))
			}
		}
		if slices.ContainsFunc(names, func(n tree.Value) bool { return n != nil && namesKey(n) }) {
			bad = append(bad, "services."+k)
		}
	}
	mws, _ := mapAt(root, "http", "middlewares")
	for _, k := range keysOf(mws) {
		v, _ := mws.Get(k)
		if n := opt(v, "errors", "service"); n != nil && namesKey(n) {
			bad = append(bad, "middlewares."+k+".errors.service")
		}
	}
	if len(bad) > 0 {
		c.failf("T13", "A ${KEY} where a host, resolver or service name must stay literal: %s", strings.Join(bad, " "))
	} else {
		c.passf("T13", "No ${KEY} in a router's rule, tls, service or middlewares, nor a service name T09 reads")
	}
}

// namesKey is whether a ${KEY} is anywhere in v, a mapping's keys included.
func namesKey(v tree.Value) bool {
	switch x := v.(type) {
	case *tree.Map:
		for _, k := range x.Keys() {
			e, _ := x.Get(k)
			if namesKey(k) || namesKey(e) {
				return true
			}
		}
	case []tree.Value:
		for _, e := range x {
			if namesKey(e) {
				return true
			}
		}
	case string:
		return len(deploy.FragmentKeys([]byte(x))) > 0
	}
	return false
}

// internalService is whether a service reference names one of Traefik's own
// services that T09 refuses: any @internal but noop@internal.
func internalService(s string) bool {
	return strings.HasSuffix(s, "@internal") && s != "noop@internal"
}

func (c *checker) t06() {
	var bad []string
	for _, svc := range c.services {
		if traefikLabel(c.svc(svc, "labels")) {
			bad = append(bad, svc)
		}
	}
	if len(bad) == 0 {
		c.passf("T06", "compose.prod.yml has no traefik.* labels")
	} else {
		c.failf("T06", "Services carry traefik.* labels (file provider only): %s", strings.Join(bad, " "))
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
		c.passf("T07", "Fragment has no loadBalancer server URLs to verify")
		return
	}
	names := c.containerNames()
	var own, unjoined []string
	for _, svc := range c.services {
		if joinsNet(c.svc(svc, "networks"), projectNet) {
			own = append(own, c.netNames(svc, projectNet)...)
		} else {
			unjoined = append(unjoined, c.netNames(svc, projectNet)...)
		}
	}
	var bad, off []string
	for _, h := range hosts {
		switch {
		case inList(names, h) || inList(own, h):
		case inList(unjoined, h):
			off = append(off, h)
		default:
			bad = append(bad, h)
		}
	}
	if len(off) > 0 {
		c.failf("T07", "Fragment targets services on no Traefik network: %s — join them to the kasbah network", strings.Join(off, " "))
	}
	switch {
	case len(bad) > 0:
		c.failf("T07", "Fragment targets names no service answers to: %s (target a service on the kasbah network, one of its kasbah aliases, or a container_name)", strings.Join(bad, " "))
	case len(off) == 0:
		c.passf("T07", "Fragment loadBalancer URLs target a service, alias or container_name compose defines")
	}
}

// netNames is what svc answers to on the network keys nets besides a
// container_name: its own name and its aliases there.
func (c *checker) netNames(svc string, nets ...string) []string {
	out := []string{svc}
	for _, k := range nets {
		for _, a := range asList(opt(c.svc(svc, "networks"), k, "aliases")) {
			if s, ok := a.(string); ok && !slices.Contains(out, s) {
				out = append(out, s)
			}
		}
	}
	return out
}

// routes is whether a fragment host names svc, by container_name, service
// name or kasbah alias, or by a kasbah-net alias, so a service routed by one
// is still C03's to fail; T07 accepts no kasbah-net alias.
func (c *checker) routes(svc string, hosts []string) bool {
	if cn := scalar(c.need(c.compose, "services", svc, "container_name")); cn != "" && inList(hosts, cn) {
		return true
	}
	for _, n := range c.netNames(svc, append([]string{projectNet}, c.sharedNets()...)...) {
		if inList(hosts, n) {
			return true
		}
	}
	return false
}

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
	if svcs, _ := mapAt(d.root, "http", "services"); svcs == nil {
		return nil
	}
	return deploy.RoutedHosts(d.root)
}

// targets is what health.container may name: a
// container_name or a service, which a deploy resolves to its first running
// replica.
func (c *checker) targets() []string {
	return append(c.containerNames(), c.services...)
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

// --- Healthchecks (H01–H03) -------------------------------------------------

// block is whether the manifest has a block at key, as a deploy reads it:
// absent, null and false are none.
func (c *checker) block(key string) bool {
	v, _ := c.m.Get(key)
	return v != nil && v != false
}

func (c *checker) healthSection() {
	built := isFile(composeFile) && c.anyBuilt()
	health := c.block("health")
	h, herr := deploy.ReadHealth(c.m)
	var late []string
	if herr == nil {
		late = c.h03(h)
	}
	if !built && !health && len(late) == 0 {
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
			c.passf("H01", "All built services declare a compose healthcheck")
		} else {
			c.warnf("H01", "Built services without a compose healthcheck (Dockerfile may declare one): %s", strings.Join(bad, " "))
		}
	}
	if health {
		switch {
		case herr != nil:
			c.failErr("H02", herr)
		case h.Container == "":
			c.passf("H02", "manifest health: names no container — the deploy waits on every container with a healthcheck")
		case inList(c.targets(), h.Container):
			c.passf("H02", "manifest health.container '%s' exists in compose", h.Container)
		default:
			c.failf("H02", "manifest health.container '%s' is neither a container_name nor a service in compose", h.Container)
		}
	}
	for _, l := range late {
		c.warnf("H03", "%s", l)
	}
}

// h03 is a line for each service a deploy waits on under health.timeout —
// healthWaitFor's set and every rolling service — that cannot be healthy by it.
func (c *checker) h03(h deploy.Health) []string {
	waited := c.services
	if h.Container != "" {
		waited = nil
		for _, svc := range c.services {
			if scalar(c.svc(svc, "container_name")) == h.Container {
				waited = []string{svc}
				break
			}
		}
		if waited == nil && inList(c.services, h.Container) {
			waited = []string{h.Container}
		}
		if routed := c.rollHosts(); len(routed) > 0 {
			for _, svc := range c.services {
				if !inList(waited, svc) && c.rolls(svc, routed) {
					waited = append(waited, svc)
				}
			}
		}
	}
	timeout := time.Duration(h.Timeout) * time.Second
	var out []string
	for _, svc := range c.services {
		if !inList(waited, svc) {
			continue
		}
		hc := c.svc(svc, "healthcheck")
		first, inStart, ok := firstProbe(hc)
		if !ok || first <= timeout {
			continue
		}
		fix := "shorten healthcheck.interval or set a start_period (Docker 25 or later)"
		if inStart {
			fix = "shorten healthcheck.start_interval"
			if set, _ := composeDuration(opt(hc, "start_interval"), 0); set == 0 {
				fix = "set a shorter start_interval"
			}
		}
		out = append(out, fmt.Sprintf("%s's first healthcheck probe comes %s after it starts, past health.timeout (%ds), so a deploy that creates or recreates it fails on health — %s, or raise health.timeout",
			svc, seconds(first), h.Timeout, fix))
	}
	return out
}

// firstProbe is when Docker 25+ first probes the compose healthcheck hc, and
// whether inside its start_period, with Docker's defaults for unset keys; not
// ok for a disabled, NONE or test-less healthcheck or an unreadable duration.
func firstProbe(hc tree.Value) (first time.Duration, inStart, ok bool) {
	if composeHealth(hc) != deploy.HealthDeclared {
		return 0, false, false
	}
	interval, ok1 := composeDuration(opt(hc, "interval"), 30*time.Second)
	period, ok2 := composeDuration(opt(hc, "start_period"), 0)
	startInterval, ok3 := composeDuration(opt(hc, "start_interval"), 5*time.Second)
	if !ok1 || !ok2 || !ok3 {
		return 0, false, false
	}
	if period > 0 {
		return startInterval, true, true
	}
	return interval, false, true
}

// longUnits is each count of days or weeks in a compose duration (1h1d, 2w).
var longUnits = regexp.MustCompile(`([0-9]*\.?[0-9]+)([dw])`)

// composeDuration is a healthcheck duration string in Go's units plus d and w
// (1h1d, 500ms, 1w); unset or zero is Docker's default, def. A negative is
// not read.
func composeDuration(v tree.Value, def time.Duration) (time.Duration, bool) {
	if v == nil {
		return def, true
	}
	s, isStr := v.(string)
	if !isStr || strings.HasPrefix(s, "-") {
		return 0, false
	}
	var d time.Duration
	ds := longUnits.FindAllStringSubmatch(s, -1)
	for _, m := range ds {
		n, err := time.ParseDuration(m[1] + "h")
		if err != nil {
			return 0, false
		}
		if m[2] == "w" {
			n *= 7
		}
		d += 24 * n
	}
	if rest := longUnits.ReplaceAllString(s, ""); rest != "" || len(ds) == 0 {
		n, err := time.ParseDuration(rest)
		if err != nil {
			return 0, false
		}
		d += n
	}
	switch {
	case d < 0:
		return 0, false
	case d == 0:
		return def, true
	}
	return d, true
}

// seconds is d in whole seconds where it is one, Go's notation otherwise.
func seconds(d time.Duration) string {
	if d%time.Second == 0 {
		return fmt.Sprintf("%ds", d/time.Second)
	}
	return d.String()
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
	raw := envtpl.RawLines(data)
	tpl := envtpl.Folded(data)

	var badLines []string
	for _, e := range envtpl.Entries(raw) {
		if l := strings.TrimSuffix(raw[e.Line], "\r"); e.Refused() == nil && (e.Key != "" || envtpl.Blank(l) || envtpl.Comment(l)) {
			continue
		}
		badLines = append(badLines, fmt.Sprint(e.Line+1))
	}
	if len(badLines) == 0 {
		c.passf("E01", ".env.prod.example syntax is valid")
	} else {
		c.failf("E01", ".env.prod.example has invalid lines (line numbers: %s)", strings.Join(badLines, " "))
	}

	if isFile(envFile) {
		missing, extra := envtpl.Drift(templateFile, envFile)
		if len(missing) == 0 {
			c.passf("E02", ".env has no missing keys vs .env.prod.example")
		} else {
			c.warnf("E02", ".env missing keys vs .env.prod.example: %s", strings.Join(missing, " "))
		}
		if len(extra) == 0 {
			c.passf("E03", ".env has no extra keys vs .env.prod.example")
		} else {
			c.warnf("E03", ".env has extra keys not in .env.prod.example: %s", strings.Join(extra, " "))
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
		c.passf("E04", ".env.prod.example has no obvious long secrets")
	} else {
		c.warnf("E04", ".env.prod.example has values >64 chars (possibly leaked secrets): %s", strings.Join(long, " "))
	}

	var reserved []string
	for _, k := range envtpl.Keys(templateFile) {
		if strings.HasPrefix(k, envtpl.ReservedPrefix) {
			reserved = append(reserved, k)
		}
	}
	if len(reserved) == 0 {
		c.passf("E05", ".env.prod.example leaves the %s* prefix to kasbah", envtpl.ReservedPrefix)
	} else {
		c.warnf("E05", ".env.prod.example defines reserved %s* keys (kasbah injects these): %s", envtpl.ReservedPrefix, strings.Join(reserved, " "))
	}
}

var (
	generator  = regexp.MustCompile(`^` + envtpl.Space + `*!`)
	hint       = regexp.MustCompile(`^` + envtpl.Space + `*#`)
	inlineHint = regexp.MustCompile(envtpl.Space + `+#.*$`)
)

// --- Hooks (HK01, HK02) -----------------------------------------------------

func (c *checker) hooksSection() {
	hv, _ := c.m.Get("hooks")
	_, backup := c.m.Get("backup")
	if hv == nil && !backup {
		return
	}
	c.section("Hooks")
	if hv != nil {
		c.hk01()
	}
	if backup {
		c.hk02()
	}
}

// hk01: each hook is one non-empty line of shell, read as a deploy reads it.
func (c *checker) hk01() {
	lists, err := deploy.ReadHooks(c.m)
	if err != nil {
		c.failErr("HK01", err)
		return
	}
	n := 0
	for _, l := range lists {
		n += len(l)
	}
	if n == 0 {
		c.passf("HK01", "Hooks block is empty")
		return
	}
	c.passf("HK01", "Every hook is one line of shell")
}

// hk02: a top-level backup: is refused, as a deploy refuses it.
func (c *checker) hk02() {
	if err := deploy.ReadBackup(c.m, ""); err != nil {
		c.failErr("HK02", err)
	}
}

// --- Mail (M01) -------------------------------------------------------------

func (c *checker) mailSection() {
	if !c.block("mail") {
		return
	}
	c.section("Mail")
	if d, err := deploy.MailDomain(c.m); err != nil {
		c.failErr("M01", err)
	} else {
		c.passf("M01", "Mail claim names domain '%s'", d)
	}
}
