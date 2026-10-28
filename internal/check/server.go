package check

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/probe"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/tree"
)

// ErrHelp is --help.
var ErrHelp = errors.New("help")

// Options is `kasbah check`'s command line.
type Options struct {
	Fix, Yes bool
	// Server is --server's target, "" for none or a bare --server.
	Server      string
	ServerGiven bool
}

// Usage is the --help text.
func Usage() string {
	return `Usage: kasbah check [--server [USER@HOST]] [--fix [--yes]]

Runs structural checks against the current project. Exit 0 if no failures
(warnings are informational). See docs/compliance.md for the full rule set.

Flags:
  --server USER@HOST  also ask that VPS: is the project deployed, does its .env
                      still match .env.prod.example, does the mail stack know
                      the claimed domain (M03), is health.container healthy, is
                      there a certificate for the domain, are the effective
                      resource limits within the host's ceiling (R04), and — on
                      a server with backups configured — has the backup stack
                      run, and did the last run work (B01). It also
                      tightens T05 to the hostnames this server really owns.
                      Read-only: --server changes nothing on the server but
                      kasbah's own binary, installed when absent or older.
                      Without USER@HOST it asks the server this project last
                      talked to, and it remembers the one it is given.
  --fix               repair the auto-fixable rules before reporting: C01–C05,
                      C08, R01–R03 and a missing kasbah_version. Only
                      compose.prod.yml and kasbah.yml are ever edited, as
                      targeted changes that leave comments, key order and line
                      endings alone. The diff is shown first and the edits are
                      applied only when you agree.
  --yes               answer that question yes, for a run with no terminal.
`
}

// Parse reads check's arguments.
func Parse(args []string) (Options, error) {
	var o Options
	empty := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--fix":
			o.Fix = true
		case a == "--yes":
			o.Yes = true
		case a == "--server":
			o.ServerGiven = true
			// The value only when there is one to take: bare --server, or
			// --server before another flag, is the remembered server.
			if i+1 < len(args) && args[i+1] != "" && !strings.HasPrefix(args[i+1], "-") {
				o.Server = strings.TrimSuffix(args[i+1], "\r")
				i++
			}
		case strings.HasPrefix(a, "--server="):
			o.ServerGiven = true
			o.Server = strings.TrimSuffix(strings.TrimPrefix(a, "--server="), "\r")
			empty = o.Server == ""
		default:
			return o, cli.Fail("check: unknown argument '%s' (expected --server [USER@HOST], --fix, --yes)", a)
		}
	}
	if o.Yes && !o.Fix {
		return o, cli.Fail("check: --yes answers --fix's prompt; it does nothing on its own")
	}
	if empty {
		return o, cli.Fail("check: --server= must name the server to ask (USER@HOST)")
	}
	return o, nil
}

// Target is the server a run asks: the one given, else this project's
// last_server; "" when no --server.
func Target(o Options) (string, error) {
	if !o.ServerGiven || o.Server != "" {
		return o.Server, nil
	}
	target, _, err := state.Server("", "check --server", "kasbah check --server user@vps")
	return target, err
}

// ServerReport is everything `check --server` reads, in one `kasbah remote
// check` round trip. File bodies are base64; .env holds the project's
// secrets and acme.json private keys, so neither is ever printed.
type ServerReport struct {
	Project       string          `json:"project"`
	EnvState      string          `json:"env_state"`
	Env           string          `json:"env_b64"`
	RegistryState string          `json:"registry_state"`
	Registry      string          `json:"registry_b64"`
	SharedState   string          `json:"shared_state"`
	Shared        string          `json:"shared_b64"`
	AcmeState     string          `json:"acme_state"`
	Acme          string          `json:"acme_b64"`
	HealthState   string          `json:"health_state"`
	HealthHealth  string          `json:"health_health"`
	DockerError   string          `json:"docker_error"`
	Backup        backuprec.Facts `json:"backup"`
	// GroupState is whether the server has the kasbah group; PermsCount
	// counts the apps-tree entries Perms flags, Perms lists the first ones.
	GroupState string   `json:"group_state"`
	PermsCount int      `json:"perms_count"`
	Perms      []string `json:"perms"`
}

// Remote is `kasbah remote check APPS DATA NAME HEALTH`, run by the server
// binary; HEALTH may be empty.
func Remote(args []string, stdout, stderr io.Writer) int {
	if len(args) != 4 || !strings.HasPrefix(args[0], "/") || args[2] == "" {
		fmt.Fprintln(stderr, "remote: usage: kasbah remote check APPS DATA NAME HEALTH")
		return 1
	}
	if err := json.NewEncoder(stdout).Encode(CollectServer(args[0], args[1], args[2], args[3])); err != nil {
		fmt.Fprintf(stderr, "remote: %v\n", err)
		return 1
	}
	return 0
}

// CollectServer reads the server it runs on.
func CollectServer(apps, data, name, health string) *ServerReport {
	dir := apps + "/" + name
	acmePath := data + "/traefik/letsencrypt/acme.json"
	r := &ServerReport{
		Project:       probe.DirState(dir),
		EnvState:      probe.FState(dir + "/.env"),
		Env:           probe.B64(dir + "/.env"),
		RegistryState: probe.FState(mailreg.Path(apps)),
		Registry:      probe.B64(mailreg.Path(apps)),
		SharedState:   probe.FState(apps + "/traefik/dynamic/_shared.yml"),
		Shared:        probe.B64(apps + "/traefik/dynamic/_shared.yml"),
		AcmeState:     probe.FState(acmePath),
		Acme:          probe.B64(acmePath),
		Backup:        backuprec.Collect(apps, data),
	}
	r.GroupState, r.PermsCount, r.Perms = Perms(apps, data, Group)
	switch {
	case health == "":
		r.HealthState, r.HealthHealth = "skipped", "skipped"
	case !probe.HaveDocker():
		r.HealthState, r.HealthHealth = "nodocker", "nodocker"
	default:
		s, rc := probe.Docker("inspect", "-f", "{{.State.Status}}", health)
		s = strings.TrimRight(s, "\n")
		if rc != 0 || s == "" {
			if derr, rc := probe.DockerErr("version", "--format", "{{.Server.Version}}"); rc == 0 {
				s = "absent"
			} else {
				s = "nodaemon"
				r.DockerError = probe.Flat(derr)
			}
		}
		h, rc := probe.Docker("inspect", "-f", "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}", health)
		h = strings.TrimRight(h, "\n")
		if rc != 0 || h == "" {
			h = "none"
		}
		r.HealthState, r.HealthHealth = s, h
	}
	return r
}

// ServerRead is one server's answer: where it was read, its marker and its
// report.
type ServerRead struct {
	Target string
	Marker *marker.Marker
	Report *ServerReport
}

// ServerSession reads one server.
type ServerSession interface {
	Read(name, health string) (*ServerRead, error)
}

// SSH is a ServerSession over ssh.
type SSH struct {
	Conn  *ssh.Conn
	Self  remote.Info
	Local func(arch string) (string, error)
}

// Dial connects.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (ServerSession, error) {
	return func(target string) (ServerSession, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{Conn: c, Self: self, Local: local}, nil
	}
}

// Read ensures the server binary — after the probe's copy of the marker has
// passed the same judgement as the read, so nothing ships to a server whose
// marker is refused — then reads the report.
func (s *SSH) Read(name, health string) (*ServerRead, error) {
	target := s.Conn.Target.String()
	res, mk, err := serverbin.EnsurePrepared(s.Conn, s.Self, s.Local)
	if err != nil {
		return nil, err
	}
	out, err := s.Conn.Run(serverbin.Bounded(serverbin.Path(res.Apps), serverbin.RunTimeout,
		"check", mk.AppsPath, mk.DataPath, name, health)...)
	if err != nil {
		return nil, cli.Fail("could not read %s on %s (%s, see above)", mk.AppsPath, target, serverbin.ExitText(ssh.ExitCode(err), serverbin.RunTimeout))
	}
	r, err := DecodeServer(out, target)
	if err != nil {
		return nil, err
	}
	return &ServerRead{Target: target, Marker: mk, Report: r}, nil
}

// DecodeServer reads `remote check`'s answer. It carries acme.json and the
// project's .env, so a bad one is described, never shown.
func DecodeServer(out []byte, target string) (*ServerReport, error) {
	var r ServerReport
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, cli.Fail("the check probe on %s answered with %d bytes that are not a whole report — truncated, or not this kasbah's", target, len(out)).Cont(
			"its output is not shown: it carries acme.json, which holds private key material")
	}
	return &r, nil
}

// server is a --server run's state once the server has answered.
type server struct {
	target, apps, data string
	mk                 *marker.Marker
	r                  *ServerReport
	env, acme          []byte
	registry           []byte
	// T05, per family: the exact hostnames whose source was read, and the
	// first labels whose source was not and so keep the local heuristic.
	reserved, heuristic []string
	note                string
	now                 time.Time
}

func dec(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil
	}
	return b
}

func newServer(sr *ServerRead, now time.Time) *server {
	s := &server{target: sr.Target, apps: sr.Marker.AppsPath, data: sr.Marker.DataPath, mk: sr.Marker, r: sr.Report, now: now}
	s.env, s.acme, s.registry = dec(s.r.Env), dec(s.r.Acme), dec(s.r.Registry)
	apex, err := serverinit.DashboardApex(string(dec(s.r.Shared)))
	if err != nil {
		apex = ""
	}
	if apex != "" {
		s.reserved = append(s.reserved, "traefik."+apex)
	} else {
		s.heuristic = append(s.heuristic, "traefik")
	}
	// The mail pair: the registry's primary when it is read; the apex when
	// there is no registry (init --with-mail defaults to it); the heuristic
	// when a registry is there and cannot be read or is refused.
	base, known := "", true
	switch {
	case s.r.RegistryState == "absent":
		base = apex
	default:
		if reg, err := mailreg.Parse(s.registry, mailreg.Path(s.apps)+" on "+s.target); err == nil {
			base = reg.Primary
		} else {
			known = false
		}
	}
	if known && base != "" {
		s.reserved = append(s.reserved, "mail."+base, "webmail."+base)
	} else {
		s.heuristic = append(s.heuristic, "mail", "webmail")
	}
	if len(s.reserved) == 0 {
		s.note = " — heuristic: " + s.target + " was asked and neither its dashboard fragment nor a mail registry could be read"
	}
	return s
}

// t05Server is T05 under --server: each family exact when its source was
// read, on the heuristic when not — never unguarded.
func (c *checker) t05Server(routers []string) {
	s := c.srv
	var bad []string
	for _, r := range routers {
		for _, m := range hostRule.FindAllStringSubmatch(c.rule(r), -1) {
			host := m[1]
			label, _, _ := strings.Cut(host, ".")
			if inList(s.reserved, host) || inList(s.heuristic, label) {
				bad = append(bad, r+"→"+host)
			}
		}
	}
	against := strings.Join(s.reserved, " ")
	if len(s.reserved) > 0 {
		for _, l := range s.heuristic {
			against += "; " + l + ".* by heuristic"
		}
	}
	switch {
	case len(s.reserved) > 0 && len(bad) > 0:
		c.failf("Routers claim hostnames kasbah owns on %s: %s (%s)", s.target, strings.Join(bad, " "), against)
	case len(s.reserved) > 0:
		c.passf("No router claims a hostname kasbah owns on %s (%s)", s.target, against)
	case len(bad) > 0:
		c.failf("Routers claim reserved hostnames: %s%s", strings.Join(bad, " "), s.note)
	default:
		c.passf("No router claims reserved hostnames (traefik.*, mail.*, webmail.*)%s", s.note)
	}
}

func inList(ss []string, x string) bool {
	for _, s := range ss {
		if s == x {
			return true
		}
	}
	return false
}

func (c *checker) serverSection() {
	s := c.srv
	fmt.Fprintf(c.w, "\nServer (%s at %s):\n", s.target, s.apps)
	c.projectDir()
	c.envDrift()
	c.m03()
	c.serverHealth()
	c.cert()
	c.r04()
	c.b01()
	c.groupPerms()
}

// groupPerms is the multi-operator model: the apps tree is the kasbah
// group's, its directories setgid and group-writable.
func (c *checker) groupPerms() {
	s := c.srv
	switch {
	case s.r.GroupState == "absent":
		c.warnf("%s has no '%s' group — a second operator cannot deploy here. `kasbah server init %s` creates it and converges %s", s.target, Group, s.target, s.apps)
	case s.r.PermsCount == 0:
		c.passf("%s on %s is the '%s' group's, setgid and group-writable", s.apps, s.target, Group)
	default:
		c.warnf("%d entries under %s on %s are not the '%s' group's or lack its write bits — another operator's deploy can fail on them; `kasbah server init %s` converges the tree:", s.r.PermsCount, s.apps, s.target, Group, s.target)
		for _, l := range s.r.Perms {
			fmt.Fprintf(c.w, "      %s\n", l)
		}
		if more := s.r.PermsCount - len(s.r.Perms); more > 0 {
			fmt.Fprintf(c.w, "      and %d more\n", more)
		}
	}
}

func (c *checker) projectDir() {
	s := c.srv
	dir := s.apps + "/" + c.m.Name
	switch s.r.Project {
	case "dir":
		c.passf("%s exists on %s", dir, s.target)
	case "notdir":
		c.failf("%s on %s exists and is not a directory — a deploy would try to write the project into it", dir, s.target)
	default:
		c.warnf("%s does not exist on %s — nothing has been deployed there yet, so the server rules below have nothing to read", dir, s.target)
	}
}

func (c *checker) envDrift() {
	s := c.srv
	if s.r.Project != "dir" {
		return
	}
	path := s.apps + "/" + c.m.Name + "/.env"
	if !isFile(templateFile) {
		c.warnf("no .env.prod.example in this checkout, so %s on %s cannot be checked for drift (S04 has already failed)", path, s.target)
		return
	}
	switch s.r.EnvState {
	case "file", "empty":
	case "absent":
		c.warnf("%s does not exist on %s — the next deploy will run the interactive setup to write one", path, s.target)
		return
	case "unreadable":
		c.warnf("%s on %s cannot be read by this user, so its keys cannot be compared with .env.prod.example", path, s.target)
		return
	default:
		c.failf("%s on %s is not a regular file (it is %s) — compose reads that path as the project's environment", path, s.target, s.r.EnvState)
		return
	}
	if len(s.env) == 0 && s.r.EnvState == "file" {
		c.warnf("%s on %s did not come back as readable bytes, so its keys cannot be compared with .env.prod.example", path, s.target)
		return
	}
	missing, extra := envtpl.DriftKeys(envtpl.Keys(templateFile), envtpl.KeysOf(s.env))
	if len(missing) == 0 {
		c.passf(".env on %s has no missing keys vs .env.prod.example", s.target)
	} else {
		c.warnf(".env on %s is missing keys vs .env.prod.example: %s", s.target, strings.Join(missing, " "))
	}
	if len(extra) == 0 {
		c.passf(".env on %s has no extra keys vs .env.prod.example", s.target)
	} else {
		c.warnf(".env on %s has extra keys not in .env.prod.example: %s", s.target, strings.Join(extra, " "))
	}
}

// manifestMailDomain is the mail domain a deploy would claim, "" for none or
// a mail: block the Mail section fails.
func (c *checker) manifestMailDomain() string {
	d, _ := deploy.MailDomain(c.m)
	return d
}

func (c *checker) healthContainer() string { return healthOf(c.m) }

// healthOf is health.container as a deploy reads it, "" for none.
func healthOf(m *manifest.Manifest) string {
	h, _ := deploy.ReadHealth(m)
	return h.Container
}

// m03: the mail stack knows the domain the manifest claims, by the one
// registry reader. A registry it refuses is the finding.
func (c *checker) m03() {
	s := c.srv
	domain := c.manifestMailDomain()
	if domain == "" {
		return
	}
	reg := mailreg.Path(s.apps)
	if s.r.RegistryState == "absent" {
		c.failf("%s claims the mail domain '%s', and there is no mail stack on %s (%s is not there) — enable it with: kasbah server init %s --with-mail", c.m.Name, domain, s.target, reg, s.target)
		return
	}
	if len(s.registry) == 0 {
		c.warnf("%s claims the mail domain '%s', and %s on %s is %s — the registry is the only thing that answers whether this stack serves a domain, so the claim cannot be checked", c.m.Name, domain, reg, s.target, s.r.RegistryState)
		return
	}
	r, err := mailreg.Parse(s.registry, reg+" on "+s.target)
	if errors.Is(err, mailreg.ErrUnparseable) {
		c.warnf("%s claims the mail domain '%s', and %s on %s does not parse as YAML — the claim cannot be checked against a registry kasbah cannot read", c.m.Name, domain, reg, s.target)
		return
	}
	if err != nil {
		c.failf("%s claims the mail domain '%s', and %s — every kasbah command refuses this registry until it is fixed", c.m.Name, domain, strings.ReplaceAll(err.Error(), "\n", "; "))
		return
	}
	if r.Primary == domain {
		c.passf("the mail stack on %s serves '%s' (its primary_domain)", s.target, domain)
		return
	}
	if r.Serves(domain) {
		c.passf("the mail stack on %s serves '%s' (listed under domains:)", s.target, domain)
		return
	}
	c.failf("the mail stack on %s does not serve '%s' — %s serves %s; add it with: kasbah server add-mail-domain %s %s", s.target, domain, reg, strings.Join(r.Domains, " "), s.target, domain)
}

func (c *checker) serverHealth() {
	s := c.srv
	name := c.healthContainer()
	st, health := s.r.HealthState, s.r.HealthHealth
	if name == "" || st == "skipped" {
		return
	}
	derr := or(s.r.DockerError, "nothing")
	switch st {
	case "nodocker":
		c.warnf("no docker on %s, so the health of '%s' cannot be read", s.target, name)
		return
	case "nodaemon":
		c.warnf("the docker daemon on %s is not answering, so the health of '%s' cannot be read — nothing here says the container is down (docker said: %s)", s.target, name, derr)
		return
	case "absent":
		if s.r.Project == "dir" {
			c.warnf("manifest health.container '%s' is not running on %s — the project is deployed, so either it was stopped or the container is named something else there", name, s.target)
		} else {
			c.warnf("manifest health.container '%s' is not running on %s (nothing has been deployed there yet)", name, s.target)
		}
		return
	}
	switch health {
	case "healthy":
		c.passf("manifest health.container '%s' is %s and healthy on %s", name, st, s.target)
	case "unhealthy":
		c.failf("manifest health.container '%s' is %s and UNHEALTHY on %s — Traefik keeps routing to it, so this is live", name, st, s.target)
	case "starting":
		c.warnf("manifest health.container '%s' is %s and still starting on %s", name, st, s.target)
	case "none":
		c.warnf("manifest health.container '%s' is %s on %s and declares no healthcheck, so nothing there reports health (H01)", name, st, s.target)
	default:
		c.warnf("manifest health.container '%s' is %s on %s and reports health '%s'", name, st, s.target, health)
	}
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func (c *checker) cert() {
	s := c.srv
	path := s.data + "/traefik/letsencrypt/acme.json"
	d := c.m.Domain
	if d == "" {
		c.warnf("the manifest names no domain, so there is no certificate to look for in %s", path)
		return
	}
	switch s.r.AcmeState {
	case "file":
	case "absent":
		c.warnf("no certificate store at %s on %s — `kasbah server init` creates it, so this server's Traefik is not the one kasbah prepared", path, s.target)
		return
	case "empty":
		c.warnf("the certificate store at %s on %s is empty — Traefik has not issued anything yet, so '%s' is served with its self-signed default", path, s.target, d)
		return
	case "unreadable":
		c.warnf("%s on %s cannot be read by this user, so the certificate for '%s' cannot be checked — the store is mode 600 and owned by the deploy user on a server kasbah prepared", path, s.target, d)
		return
	default:
		c.warnf("%s on %s is %s, not a regular file — Traefik bind-mounts that path as its certificate store", path, s.target, s.r.AcmeState)
		return
	}
	if len(s.acme) == 0 {
		c.warnf("%s on %s did not come back as readable bytes, so the certificate for '%s' cannot be checked", path, s.target, d)
		return
	}
	l := acme.Find(s.acme, d, s.now)
	switch l.State {
	case "found":
	case "empty":
		c.warnf("the certificate store at %s on %s holds no certificates — nothing has been issued for '%s' yet", path, s.target, d)
		return
	case "nomatch":
		c.warnf("no certificate for '%s' in %s on %s (%d in the store) — Traefik issues one when a router claims the hostname and it resolves to this server", d, path, s.target, l.Count)
		return
	case "notjson":
		c.warnf("%s on %s does not parse as JSON, so the certificate for '%s' cannot be read (its bytes are not shown: the store holds private key material)", path, s.target, d)
		return
	case "noresolver":
		c.warnf("%s on %s has no '%s' store — that resolver name is a frozen contract, so either the schema has shifted with a Traefik upgrade or this Traefik is configured with another one", path, s.target, acme.Resolver)
		return
	case "notarray":
		c.warnf("%s on %s holds a '%s' whose Certificates is a %s, not a list — the store's schema is not the one this kasbah reads", path, s.target, acme.Resolver, l.Kind)
		return
	case "nocert":
		c.warnf("the entry for '%s' in %s on %s carries no certificate field — the store's schema is not the one this kasbah reads", d, path, s.target)
		return
	case "notbase64":
		c.warnf("the certificate for '%s' in %s on %s is not base64 — the store's schema is not the one this kasbah reads", d, path, s.target)
		return
	default:
		c.warnf("the certificate for '%s' in %s on %s is not a certificate openssl reads", d, path, s.target)
		return
	}
	via, issuer := "", or(l.Issuer, "unknown issuer")
	if l.Main != d {
		via = " (as a SAN of " + l.Main + ")"
	}
	switch {
	case l.Expired:
		c.failf("certificate for '%s'%s EXPIRED %d day(s) ago (%s, %s) — Traefik renews at 30 days remaining, so renewal has been failing", d, via, l.Days, l.NotAfter, issuer)
	case l.Days <= 14:
		c.warnf("certificate for '%s'%s expires in %d day(s) (%s, %s) — Traefik renews at 30 days remaining, so renewal has already missed its window", d, via, l.Days, l.NotAfter, issuer)
	default:
		c.passf("certificate for '%s'%s valid for %d more day(s) (until %s, %s)", d, via, l.Days, l.NotAfter, issuer)
	}
}

// envValue is the last assignment of key in content, as compose reads it.
func envValue(content []byte, key string) string {
	v := ""
	for _, l := range envtpl.Lines(content) {
		if k, val, ok := envtpl.Assign(l); ok && k == key {
			v = val
		}
	}
	return v
}

var reCPU = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)

// cmpCPU is above, below, same or unknown.
func cmpCPU(a, b string) string {
	a, b = strings.TrimSuffix(a, "\r"), strings.TrimSuffix(b, "\r")
	if !reCPU.MatchString(a) || !reCPU.MatchString(b) {
		return "unknown"
	}
	x, _ := strconv.ParseFloat(a, 64)
	y, _ := strconv.ParseFloat(b, 64)
	switch {
	case x > y:
		return "above"
	case x < y:
		return "below"
	}
	return "same"
}

var reMem = regexp.MustCompile(`^([0-9]+)(b|k|kb|m|mb|g|gb)?$`)

// MemBytes is a compose memory size in bytes; ok false when it is not one.
func MemBytes(v string) (int64, bool) {
	m := reMem.FindStringSubmatch(strings.ToLower(strings.TrimSuffix(v, "\r")))
	if m == nil {
		return 0, false
	}
	n, err := strconv.ParseInt(m[1], 10, 64)
	if err != nil {
		return 0, false
	}
	switch m[2] {
	case "k", "kb":
		n *= 1024
	case "m", "mb":
		n *= 1024 * 1024
	case "g", "gb":
		n *= 1024 * 1024 * 1024
	}
	return n, true
}

func cmpMem(a, b string) string {
	x, ok1 := MemBytes(a)
	y, ok2 := MemBytes(b)
	switch {
	case !ok1 || !ok2:
		return "unknown"
	case x > y:
		return "above"
	case x < y:
		return "below"
	}
	return "same"
}

// r04: the limits the containers get, against the ceiling the host was
// measured at. Above fails; below warns.
func (c *checker) r04() {
	s := c.srv
	if s.r.Project != "dir" || (s.r.EnvState != "file" && s.r.EnvState != "empty") {
		return
	}
	cpu, mem := envValue(s.env, "KASBAH_CPU_LIMIT"), envValue(s.env, "KASBAH_MEM_LIMIT")
	hostCPU, hostMem := s.mk.CPULimit, s.mk.MemLimit
	if cpu == "" && mem == "" {
		c.warnf("%s/%s/.env on %s carries no KASBAH_CPU_LIMIT or KASBAH_MEM_LIMIT, so there is no effective limit to compare with the host's %s cpus / %s — every deploy rewrites that block, so it has been edited out", s.apps, c.m.Name, s.target, hostCPU, hostMem)
		return
	}
	verdict, note := "ok", ""
	add := func(n string) {
		if note != "" {
			note += "; "
		}
		note += n
	}
	switch cmpCPU(cpu, hostCPU) {
	case "above":
		verdict, note = "above", "cpus "+cpu+" > "+hostCPU
	case "below":
		verdict, note = "below", "cpus "+cpu+" < "+hostCPU
	case "unknown":
		note = "cpus '" + or(cpu, "unset") + "' is not a number"
	}
	switch cmpMem(mem, hostMem) {
	case "above":
		add("mem_limit " + mem + " > " + hostMem)
		verdict = "above"
	case "below":
		add("mem_limit " + mem + " < " + hostMem)
		if verdict != "above" {
			verdict = "below"
		}
	case "unknown":
		add("mem_limit '" + or(mem, "unset") + "' is not a size")
	}
	switch {
	case verdict == "above":
		c.failf("effective resource limits on %s are above the host's 90%% ceiling: %s — kasbah's limits are anti-takeover ceilings, and one project over them can take the host down", s.target, note)
	case verdict == "below":
		c.warnf("effective resource limits on %s are below the host's 90%% ceiling: %s — deliberately tighter is allowed, but every deploy rewrites the KASBAH_* block, so this is usually a stale .env", s.target, note)
	case note != "":
		c.warnf("effective resource limits on %s could not all be compared with the host's %s cpus / %s: %s", s.target, hostCPU, hostMem, note)
	default:
		c.passf("effective resource limits on %s match the host's 90%% ceiling (%s cpus, %s)", s.target, cpu, mem)
	}
}

// b01: has this server's backup stack run, and did the last run work? Asked
// only of a server whose marker records backups. Absence warns; a failed
// run, an overdue deadline and a stopped scheduler fail — the scheduler first.
func (c *checker) b01() {
	s := c.srv
	if en, _ := tree.Lookup(s.mk.JSON, "backup", "enabled"); en != true {
		return
	}
	dir := s.apps + "/.kasbah/backup"
	rec := dir + "/state/status"
	b := s.r.Backup
	cstate := b.Container.State
	r := backuprec.Read(b.Dir, b.Record, b.Content(), b.Now)
	clock := ""
	if r.Clock == "local" {
		clock = " (judged against this machine's clock: the probe did not report the server's)"
	}
	switch r.Verdict {
	case backuprec.NoStack:
		c.warnf("%s/.kasbah/server.json on %s records off-box backups and %s %s — nothing on this server would take one, and there is no record here to say when the last one ran; re-run: kasbah server init %s --with-backup", s.apps, s.target, dir, r.Reason, s.target)
	case backuprec.NoRecord:
		c.warnf("the backup scheduler on %s has written no record at %s — it writes one as its first act, so it has not started since backups were configured (its container is %s); bring it up: docker compose -p kasbah-backup up -d", s.target, rec, cstate)
	case backuprec.Unreadable:
		c.warnf("%s on %s %s, so nothing here says whether a backup has ever run — this is not the same fact as a backup that has stopped", rec, s.target, r.Reason)
	case backuprec.Unparsed:
		c.warnf("%s on %s is not a record this kasbah reads — it %s, so nothing here says whether a backup has ever run", rec, s.target, r.Reason)
	default:
		c.b01Verdict(r, b, clock)
	}

	missing, orphan := backuprec.Diff(b.Repos(), b.HasPass)
	if len(missing) > 0 {
		c.warnf("backup repositories on %s with no password: %s — a repository with no password is not backed up at all (docs/backup.md), and the run says so only in its own log; supply one with: kasbah server init %s --with-backup", s.target, strings.Join(missing, " "), s.target)
	}
	if len(orphan) > 0 {
		c.warnf("backup repository passwords on %s that no project files into any more: %s — the last project of that client was dropped and its password stayed behind at mode 600. Keep it: it is what decrypts the snapshots already off-box, and kasbah never deletes one. Take it off by hand once that repository has been handed over or emptied (docs/backup.md → Handover).", s.target, strings.Join(orphan, " "))
	}
}

func (c *checker) b01Verdict(r *backuprec.Record, b backuprec.Facts, clock string) {
	s := c.srv
	ago, due := backuprec.Ago(r.Age), backuprec.Ago(r.Overdue)
	repos := strings.TrimPrefix(r.Repos, " ")
	switch b.Container.State {
	case "running":
	case "nodocker":
		c.warnf("there is no docker on %s, so whether its backup scheduler is running cannot be read — the record says '%s'", s.target, r.Verdict)
		return
	case "nodaemon":
		c.warnf("the docker daemon on %s is not answering, so whether its backup scheduler is running cannot be read — nothing here says it is down (docker said: %s)", s.target, or(s.r.DockerError, "nothing"))
		return
	case "notours":
		c.failf("the container named kasbah-backup on %s is not in the kasbah-backup compose project, so kasbah's scheduler is not the thing running under that name and nothing is shipping this server off-box", s.target)
		return
	default:
		last := ""
		if r.Age >= 0 {
			last = ", last run " + ago + " ago"
		}
		c.failf("the backup scheduler on %s is %s, so nothing is being shipped off-box — its record still reads '%s'%s; bring it up: docker compose -p kasbah-backup up -d", s.target, b.Container.State, r.Verdict, last)
		return
	}
	switch r.Verdict {
	case backuprec.Failed:
		past := ""
		if r.Overdue != 0 {
			past = ", and the scheduler is " + due + " past its own deadline"
		}
		c.failf("the last backup on %s FAILED %s ago (repositories backed up: %s) — nothing new has been shipped off-box since; docker logs kasbah-backup says which repository and why%s%s", s.target, ago, or(repos, "-"), past, clock)
	case backuprec.Overdue:
		finished := ""
		if r.Age >= 0 {
			finished = " (the last run finished " + ago + " ago)"
		}
		c.failf("the backup scheduler on %s is %s past its own deadline in state '%s' — a run that never returned, or a sleep that never woke, so nothing is being shipped off-box%s; docker logs kasbah-backup%s", s.target, due, r.State, finished, clock)
	case backuprec.Never:
		c.warnf("backups are configured on %s and no run has finished yet — the scheduler is '%s' and inside its own deadline, so this is a stack that has not fired rather than one that has stopped%s", s.target, r.State, clock)
	case backuprec.OK:
		if repos == "" || repos == "none" {
			c.warnf("the last backup on %s finished %s ago and shipped nothing — no repository had anything to back up, so nothing of this server exists off-box yet%s", s.target, ago, clock)
		} else {
			c.passf("the last backup on %s finished %s ago and succeeded (repositories: %s)%s", s.target, ago, repos, clock)
		}
	}
}
