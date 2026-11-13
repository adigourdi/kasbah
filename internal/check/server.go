package check

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"math/big"
	"os"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/probe"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/resources"
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
(warnings are informational). Each line leads with its rule's ID: kasbah help
<id> explains it, kasbah help rules lists them all, and docs/compliance.md has
the full rule set.

Flags:
  --server USER@HOST  also ask that VPS: is the project deployed, does its .env
                      still match .env.prod.example, does the mail stack know
                      the claimed domain (M03) and hold a DKIM key for every
                      domain it serves (M04), is health.container healthy, is
                      there a certificate for the domain, are the effective
                      resource limits within the host's ceiling (R04), do the
                      projects' own limits fit the host together (R06), on
                      a server with backups configured has the backup stack
                      run and did the last run work (B01), and does any
                      project hold a leftover backup directory, kept-aside
                      snapshot or rollback extraction, each perhaps with a
                      copy of .env (B02). It also tightens T05 to the
                      hostnames this server really owns.
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
	Project       string `json:"project"`
	EnvState      string `json:"env_state"`
	Env           string `json:"env_b64"`
	RegistryState string `json:"registry_state"`
	Registry      string `json:"registry_b64"`
	SharedState   string `json:"shared_state"`
	Shared        string `json:"shared_b64"`
	// Static is traefik.yml, read for the cert resolvers it declares.
	StaticState  string          `json:"static_state"`
	Static       string          `json:"static_b64"`
	AcmeState    string          `json:"acme_state"`
	Acme         string          `json:"acme_b64"`
	HealthState  string          `json:"health_state"`
	HealthHealth string          `json:"health_health"`
	DockerError  string          `json:"docker_error"`
	Backup       backuprec.Facts `json:"backup"`
	// GroupState is whether the server has the kasbah group; PermsCount
	// counts the apps-tree entries Perms flags, Perms lists the first ones.
	GroupState string   `json:"group_state"`
	PermsCount int      `json:"perms_count"`
	Perms      []string `json:"perms"`
	// DKIMState is mail.DKIMDir's state; DKIMKeys its *.private.txt names,
	// listed and never read. DKIMConf is the 644 signing override.
	DKIMState     string   `json:"dkim_state"`
	DKIMKeys      []string `json:"dkim_keys"`
	DKIMConfState string   `json:"dkim_conf_state"`
	DKIMConf      string   `json:"dkim_conf_b64"`
	// Limits is every project's KASBAH_CPU_LIMIT / KASBAH_MEM_LIMIT, read from
	// its .env's managed block and nothing else of it; Host* the host's totals.
	Limits    []ProjectLimits `json:"limits"`
	HostCores int64           `json:"host_cores"`
	HostMemKB int64           `json:"host_mem_kb"`
	// Leftovers is every project under apps with something a run left that
	// may hold .env (B02).
	Leftovers []ProjectLeftovers `json:"leftovers"`
	// Outsiders is the containers outside this project that could collide
	// with it (C12, C13); OutsidersError why docker could not say.
	Outsiders      []deploy.Holder `json:"outsiders"`
	OutsidersError string          `json:"outsiders_error"`
}

// ProjectLeftovers is one project's leftovers.
type ProjectLeftovers struct {
	Name string `json:"name"`
	deploy.Leftovers
}

// projectLeftovers scans every project directory under apps.
func projectLeftovers(apps string) []ProjectLeftovers {
	out := []ProjectLeftovers{}
	ents, err := os.ReadDir(apps)
	if err != nil {
		return out
	}
	for _, e := range ents {
		if n := e.Name(); deploy.IsProject(apps, n) {
			if l := deploy.ScanAgainstLock(apps + "/" + n); l.Report() {
				out = append(out, ProjectLeftovers{Name: n, Leftovers: l})
			}
		}
	}
	return out
}

// ProjectLimits is one project's managed limits.
type ProjectLimits struct {
	Name string `json:"name"`
	CPU  string `json:"cpu"`
	Mem  string `json:"mem"`
}

// projectLimits reads the managed block of every project's .env under apps.
func projectLimits(apps string) []ProjectLimits {
	out := []ProjectLimits{}
	ents, err := os.ReadDir(apps)
	if err != nil {
		return out
	}
	for _, e := range ents {
		n := e.Name()
		if !e.IsDir() || probe.IsReserved(n) || strings.HasPrefix(n, ".") {
			continue
		}
		if cpu, mem, ok := env.ManagedLimits(apps + "/" + n + "/.env"); ok && (cpu != "" || mem != "") {
			out = append(out, ProjectLimits{Name: n, CPU: cpu, Mem: mem})
		}
	}
	return out
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
		StaticState:   probe.FState(apps + "/traefik/traefik.yml"),
		Static:        probe.B64(apps + "/traefik/traefik.yml"),
		AcmeState:     probe.FState(acmePath),
		Acme:          probe.B64(acmePath),
		Backup:        backuprec.Collect(apps, data),
	}
	r.GroupState, r.PermsCount, r.Perms = Perms(apps, data, Group)
	r.Limits = projectLimits(apps)
	r.Leftovers = projectLeftovers(apps)
	r.Outsiders, r.OutsidersError = outsiders(name, dir)
	r.HostCores, r.HostMemKB, _ = resources.Host()
	r.DKIMState, r.DKIMKeys = dkimKeys(mail.DKIMDir(data))
	if r.DKIMConfState = stated(mail.DKIMConf(data), probe.FState); r.DKIMConfState == "file" {
		r.DKIMConf = probe.B64(mail.DKIMConf(data))
	}
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

// outsiders is deploy's own read of the containers outside the project.
func outsiders(name, dir string) ([]deploy.Holder, string) {
	if !probe.HaveDocker() {
		return nil, "there is no docker on the server"
	}
	hs, err := deploy.Outsiders(name, dir, func(args ...string) (string, error) {
		if len(args) == 0 || args[0] != "ps" {
			return "", fmt.Errorf("docker %s is not a read", strings.Join(args, " "))
		}
		out, rc := probe.Docker(append([]string{"ps"}, args[1:]...)...)
		if rc != 0 {
			return "", fmt.Errorf("docker ps -a exited %d", rc)
		}
		return out, nil
	})
	if err != nil {
		return nil, err.Error()
	}
	return hs, ""
}

// stated is state(p), except that a stat failing for any reason but a
// missing path is unreadable: probe's states call a closed parent absent.
func stated(p string, state func(string) string) string {
	if _, err := os.Stat(p); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return "unreadable"
	}
	return state(p)
}

// dkimKeys lists a key directory's private-key names: absent, notdir,
// unreadable (this user cannot reach or list it) or dir.
func dkimKeys(dir string) (string, []string) {
	st := stated(dir, probe.DirState)
	if st != "dir" {
		return st, nil
	}
	es, err := os.ReadDir(dir)
	if err != nil {
		return "unreadable", nil
	}
	var keys []string
	for _, e := range es {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".private.txt") {
			keys = append(keys, e.Name())
		}
	}
	return "dir", keys
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
	// envVals is the server .env as compose reads it; envErr its first line
	// kasbah cannot read as compose does.
	envVals map[string]string
	envErr  error
	// T05, per family: the exact hostnames whose source was read, and the
	// first labels whose source was not and so keep the local heuristic.
	reserved, heuristic []string
	// dashOff is a _shared.yml read with no dashboard router: traefik.* is
	// nobody's.
	dashOff bool
	// resolvers is every cert resolver traefik.yml declares, true for DNS-01;
	// nil when it could not be read.
	resolvers map[string]bool
	note      string
	now       time.Time
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
	s.envVals, s.envErr = envtpl.ValuesOf(s.env)
	if static := string(dec(s.r.Static)); s.r.StaticState == "file" {
		if rs, err := serverinit.StaticResolvers(static); err == nil && rs != nil {
			s.resolvers = rs
		}
	}
	shared := string(dec(s.r.Shared))
	apex, err := serverinit.DashboardApex(shared)
	if err != nil {
		apex = ""
	}
	on, err := serverinit.DashboardOn(shared)
	s.dashOff = err == nil && strings.TrimSpace(shared) != "" && !on
	switch {
	case s.dashOff:
	case apex != "":
		s.reserved = append(s.reserved, "traefik."+apex)
	default:
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
	switch {
	case len(s.reserved) > 0:
	case !s.dashOff:
		s.note = " — heuristic: " + s.target + " was asked and neither its dashboard fragment nor a mail registry could be read"
	case !known:
		s.note = " — heuristic: " + s.target + " was asked and its mail registry could not be read"
	default:
		s.note = " — heuristic: " + s.target + " has no mail registry, and no dashboard apex to name mail.* from"
	}
	if s.dashOff {
		s.note += " — the dashboard is off on " + s.target + ", so traefik.* is not reserved"
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
	var labels []string
	for _, l := range s.heuristic {
		against += "; " + l + ".* by heuristic"
		labels = append(labels, l+".*")
	}
	note := s.note
	if len(s.reserved) > 0 && s.dashOff {
		note = ""
		against += "; dashboard off, traefik.* not reserved"
	}
	switch {
	case len(s.reserved) > 0 && len(bad) > 0:
		c.failf("T05", "Routers claim hostnames kasbah owns on %s: %s (%s)", s.target, strings.Join(bad, " "), against)
	case len(s.reserved) > 0:
		c.passf("T05", "No router claims a hostname kasbah owns on %s (%s)", s.target, against)
	case len(bad) > 0:
		c.failf("T05", "Routers claim reserved hostnames: %s%s", strings.Join(bad, " "), note)
	default:
		c.passf("T05", "No router claims reserved hostnames (%s)%s", strings.Join(labels, ", "), note)
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
	c.m04()
	c.serverHealth()
	c.cert()
	c.r04()
	c.r06()
	c.memoryController()
	c.outsiders()
	c.b01()
	c.b02()
	c.groupPerms()
}

// groupPerms is the multi-operator model: the apps tree is the kasbah
// group's, its directories setgid and group-writable.
func (c *checker) groupPerms() {
	s := c.srv
	switch {
	case s.r.GroupState == "absent":
		c.warnf("", "%s has no '%s' group — a second operator cannot deploy here. `kasbah server init %s` creates it and converges %s", s.target, Group, s.target, s.apps)
	case s.r.PermsCount == 0:
		c.passf("", "%s on %s is the '%s' group's, setgid and group-writable", s.apps, s.target, Group)
	default:
		c.warnf("", "%d entries under %s on %s are not the '%s' group's or lack its write bits — another operator's deploy can fail on them; `kasbah server init %s` converges the tree:", s.r.PermsCount, s.apps, s.target, Group, s.target)
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
		c.passf("", "%s exists on %s", dir, s.target)
	case "notdir":
		c.failf("", "%s on %s exists and is not a directory — a deploy would try to write the project into it", dir, s.target)
	default:
		c.warnf("", "%s does not exist on %s — nothing has been deployed there yet, so the server rules below have nothing to read", dir, s.target)
	}
}

func (c *checker) envDrift() {
	s := c.srv
	if s.r.Project != "dir" {
		return
	}
	path := s.apps + "/" + c.m.Name + "/.env"
	if !isFile(templateFile) {
		c.warnf("E02,E03", "no .env.prod.example in this checkout, so %s on %s cannot be checked for drift (S04 has already failed)", path, s.target)
		return
	}
	switch s.r.EnvState {
	case "file", "empty":
	case "absent":
		c.warnf("E02,E03", "%s does not exist on %s — the next deploy will run the interactive setup to write one", path, s.target)
		return
	case "unreadable":
		c.warnf("E02,E03", "%s on %s cannot be read by this user, so its keys cannot be compared with .env.prod.example", path, s.target)
		return
	default:
		c.failf("", "%s on %s is not a regular file (it is %s) — compose reads that path as the project's environment", path, s.target, s.r.EnvState)
		return
	}
	if len(s.env) == 0 && s.r.EnvState == "file" {
		c.warnf("E02,E03", "%s on %s did not come back as readable bytes, so its keys cannot be compared with .env.prod.example", path, s.target)
		return
	}
	missing, extra := envtpl.DriftKeys(envtpl.Keys(templateFile), envtpl.KeysOf(s.env))
	if len(missing) == 0 {
		c.passf("E02", ".env on %s has no missing keys vs .env.prod.example", s.target)
	} else {
		c.warnf("E02", ".env on %s is missing keys vs .env.prod.example: %s", s.target, strings.Join(missing, " "))
	}
	if len(extra) == 0 {
		c.passf("E03", ".env on %s has no extra keys vs .env.prod.example", s.target)
	} else {
		c.warnf("E03", ".env on %s has extra keys not in .env.prod.example: %s", s.target, strings.Join(extra, " "))
	}
}

// m04: every domain the mail stack serves has both keys the signing override
// names, and the override lists them, or its mail leaves unsigned and lands
// in spam. Any project, like B01; silent without mail.
func (c *checker) m04() {
	s := c.srv
	regPath := mailreg.Path(s.apps)
	if s.r.RegistryState == "absent" {
		return
	}
	reg, err := mailreg.Parse(s.registry, regPath+" on "+s.target)
	if s.r.RegistryState != "file" {
		err = fmt.Errorf("%s on %s is %s", regPath, s.target, s.r.RegistryState)
	}
	if err != nil {
		c.warnf("M04", "%s — so whether the mail domains are DKIM-signed cannot be checked", strings.ReplaceAll(err.Error(), "\n", "; "))
		return
	}
	dir, conf := mail.DKIMDir(s.data), mail.DKIMConf(s.data)
	switch s.r.DKIMState {
	case "dir", "absent":
	case "unreadable":
		c.warnf("M04", "%s on %s cannot be listed by this user, so whether the mail domains are DKIM-signed cannot be checked", dir, s.target)
		return
	default:
		c.warnf("M04", "%s on %s is not a directory (it is %s), so whether the mail domains are DKIM-signed cannot be checked", dir, s.target, or(s.r.DKIMState, "unreported"))
		return
	}
	confText := string(dec(s.r.DKIMConf))
	switch {
	case s.r.DKIMConfState == "empty":
	case s.r.DKIMConfState != "file":
		c.warnf("M04", "%s on %s is %s, so whether the mail domains are DKIM-signed cannot be checked", conf, s.target, or(s.r.DKIMConfState, "unreported"))
		return
	case confText == "":
		c.warnf("M04", "%s on %s did not come back as readable bytes, so whether the mail domains are DKIM-signed cannot be checked", conf, s.target)
		return
	}
	missing := 0
	for _, d := range reg.Domains {
		absent, unlisted := mail.DKIMGaps(d, s.r.DKIMKeys, confText)
		if len(absent)+len(unlisted) == 0 {
			continue
		}
		missing++
		var why []string
		if len(absent) > 0 {
			why = append(why, "no "+strings.Join(absent, " or ")+" in "+dir+"/")
		}
		if len(unlisted) > 0 {
			why = append(why, conf+" does not list "+strings.Join(unlisted, " or "))
		}
		c.warnf("M04", "mail domain '%s' on %s is not DKIM-signed: %s — its mail leaves unsigned and receivers file it as spam; this makes its missing keys and renders the override:", d, s.target, strings.Join(why, ", and "))
		fmt.Fprintf(c.w, "      kasbah server mail-dkim %s %s --keep-keys\n", s.target, d)
	}
	if missing == 0 {
		c.passf("M04", "every mail domain on %s has both DKIM keys, listed in its signing override (%s)", s.target, strings.Join(reg.Domains, " "))
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
		c.failf("M03", "%s claims the mail domain '%s', and there is no mail stack on %s (%s is not there) — enable it with: kasbah server init %s --with-mail", c.m.Name, domain, s.target, reg, s.target)
		return
	}
	if len(s.registry) == 0 {
		c.warnf("M03", "%s claims the mail domain '%s', and %s on %s is %s — the registry is the only thing that answers whether this stack serves a domain, so the claim cannot be checked", c.m.Name, domain, reg, s.target, s.r.RegistryState)
		return
	}
	r, err := mailreg.Parse(s.registry, reg+" on "+s.target)
	if errors.Is(err, mailreg.ErrUnparseable) {
		c.warnf("M03", "%s claims the mail domain '%s', and %s on %s does not parse as YAML — the claim cannot be checked against a registry kasbah cannot read", c.m.Name, domain, reg, s.target)
		return
	}
	if err != nil {
		c.failf("M03", "%s claims the mail domain '%s', and %s — every kasbah command refuses this registry until it is fixed", c.m.Name, domain, strings.ReplaceAll(err.Error(), "\n", "; "))
		return
	}
	if r.Primary == domain {
		c.passf("M03", "the mail stack on %s serves '%s' (its primary_domain)", s.target, domain)
		return
	}
	if r.Serves(domain) {
		c.passf("M03", "the mail stack on %s serves '%s' (listed under domains:)", s.target, domain)
		return
	}
	c.failf("M03", "the mail stack on %s does not serve '%s' — %s serves %s; add it with: kasbah server add-mail-domain %s %s", s.target, domain, reg, strings.Join(r.Domains, " "), s.target, domain)
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
		c.warnf("", "no docker on %s, so the health of '%s' cannot be read", s.target, name)
		return
	case "nodaemon":
		c.warnf("", "the docker daemon on %s is not answering, so the health of '%s' cannot be read — nothing here says the container is down (docker said: %s)", s.target, name, derr)
		return
	case "absent":
		if s.r.Project == "dir" {
			c.warnf("", "manifest health.container '%s' is not running on %s — the project is deployed, so either it was stopped or the container is named something else there", name, s.target)
		} else {
			c.warnf("", "manifest health.container '%s' is not running on %s (nothing has been deployed there yet)", name, s.target)
		}
		return
	}
	switch health {
	case "healthy":
		c.passf("", "manifest health.container '%s' is %s and healthy on %s", name, st, s.target)
	case "unhealthy":
		c.failf("", "manifest health.container '%s' is %s and UNHEALTHY on %s — Traefik keeps routing to it, so this is live", name, st, s.target)
	case "starting":
		c.warnf("", "manifest health.container '%s' is %s and still starting on %s", name, st, s.target)
	case "none":
		c.warnf("", "manifest health.container '%s' is %s on %s and declares no healthcheck, so nothing there reports health (H01)", name, st, s.target)
	default:
		c.warnf("", "manifest health.container '%s' is %s on %s and reports health '%s'", name, st, s.target, health)
	}
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

// cert is silent for an unrouted project: nothing on it asks for a certificate.
func (c *checker) cert() {
	if c.m.Unrouted {
		return
	}
	s := c.srv
	path := s.data + "/traefik/letsencrypt/acme.json"
	d := c.m.Domain
	if d == "" {
		c.warnf("", "the manifest names no domain, so there is no certificate to look for in %s", path)
		return
	}
	resolver := acme.Resolver
	if isFile(traefikFile) {
		raw, err := os.ReadFile(traefikFile)
		f := c.load(traefikFile)
		if err == nil && f.bad == "" && acme.PlainHTTP(raw, f.root, d) {
			c.passf("", "this checkout's fragment has no HTTPS router, so '%s' is served over plain HTTP and no certificate is expected", d)
			return
		}
		if f.bad == "" {
			resolver = acme.ResolverFor(acme.Routes(f.root), d)
		}
	}
	switch s.r.AcmeState {
	case "file":
	case "absent":
		c.warnf("", "no certificate store at %s on %s — `kasbah server init` creates it, so this server's Traefik is not the one kasbah prepared", path, s.target)
		return
	case "empty":
		c.warnf("", "the certificate store at %s on %s is empty — Traefik has not issued anything yet, so '%s' is served with its self-signed default", path, s.target, d)
		return
	case "unreadable":
		c.warnf("", "%s on %s cannot be read by this user, so the certificate for '%s' cannot be checked — the store is mode 600 and owned by the deploy user on a server kasbah prepared", path, s.target, d)
		return
	default:
		c.warnf("", "%s on %s is %s, not a regular file — Traefik bind-mounts that path as its certificate store", path, s.target, s.r.AcmeState)
		return
	}
	if len(s.acme) == 0 {
		c.warnf("", "%s on %s did not come back as readable bytes, so the certificate for '%s' cannot be checked", path, s.target, d)
		return
	}
	l := acme.FindIn(s.acme, resolver, d, s.now)
	switch l.State {
	case "found":
	case "empty":
		c.warnf("", "the certificate store at %s on %s holds no certificates — nothing has been issued for '%s' yet", path, s.target, d)
		return
	case "nomatch":
		c.warnf("", "no certificate for '%s' in %s on %s (%d in the store) — Traefik issues one when a router claims the hostname and it resolves to this server", d, path, s.target, l.Count)
		return
	case "notjson":
		c.warnf("", "%s on %s does not parse as JSON, so the certificate for '%s' cannot be read (its bytes are not shown: the store holds private key material)", path, s.target, d)
		return
	case "noresolver":
		if resolver != acme.Resolver {
			c.warnf("", "%s on %s has no '%s' store — the resolver this checkout's router names for '%s' has issued nothing yet", path, s.target, resolver, d)
			return
		}
		c.warnf("", "%s on %s has no '%s' store — a store filled under the resolver's former name 'letsencrypt' reads this way until Traefik issues under the new one; otherwise the schema has shifted with a Traefik upgrade", path, s.target, acme.Resolver)
		return
	case "notarray":
		c.warnf("", "%s on %s holds a '%s' whose Certificates is a %s, not a list — the store's schema is not the one this kasbah reads", path, s.target, resolver, l.Kind)
		return
	case "nocert":
		c.warnf("", "the entry for '%s' in %s on %s carries no certificate field — the store's schema is not the one this kasbah reads", d, path, s.target)
		return
	case "notbase64":
		c.warnf("", "the certificate for '%s' in %s on %s is not base64 — the store's schema is not the one this kasbah reads", d, path, s.target)
		return
	default:
		c.warnf("", "the certificate for '%s' in %s on %s is not a certificate openssl reads", d, path, s.target)
		return
	}
	via, issuer := "", or(l.Issuer, "unknown issuer")
	if l.Main != d {
		via = " (as a SAN of " + l.Main + ")"
	}
	switch {
	case l.Expired:
		c.failf("", "certificate for '%s'%s EXPIRED %d day(s) ago (%s, %s) — Traefik renews at 30 days remaining, so renewal has been failing", d, via, l.Days, l.NotAfter, issuer)
	case l.Days <= 14:
		c.warnf("", "certificate for '%s'%s expires in %d day(s) (%s, %s) — Traefik renews at 30 days remaining, so renewal has already missed its window", d, via, l.Days, l.NotAfter, issuer)
	default:
		c.passf("", "certificate for '%s'%s valid for %d more day(s) (until %s, %s)", d, via, l.Days, l.NotAfter, issuer)
	}
}

// r04: the limits the containers get, against the ceiling the host was
// measured at. Above fails; below warns. A literal in compose.prod.yml is
// compared as written; a KASBAH_* reference through the server's .env.
func (c *checker) r04() {
	s := c.srv
	// A 0 ceiling compares as the number 0, not as "no limit"; init never writes one.
	hostCPU, hostMem := s.mk.CPULimit, s.mk.MemLimit
	useCPU, useMem := c.r04Literals(hostCPU, hostMem)
	if !useCPU && !useMem {
		return
	}
	if s.r.Project != "dir" || (s.r.EnvState != "file" && s.r.EnvState != "empty") {
		return
	}
	cpu, mem := s.envVals["KASBAH_CPU_LIMIT"], s.envVals["KASBAH_MEM_LIMIT"]
	if cpu == "" && mem == "" {
		c.warnf("R04", "%s/%s/.env on %s carries no KASBAH_CPU_LIMIT or KASBAH_MEM_LIMIT, so there is no effective limit to compare with the host's %s cpus / %s — every deploy rewrites that block, so it has been edited out", s.apps, c.m.Name, s.target, hostCPU, hostMem)
		return
	}
	verdict, note := "ok", ""
	add := func(n string) {
		if note != "" {
			note += "; "
		}
		note += n
	}
	cmpC, cmpM := resources.CmpCPU(cpu, hostCPU), resources.CmpMem(mem, hostMem)
	if !useCPU {
		cmpC = "same"
	}
	if !useMem {
		cmpM = "same"
	}
	// Below the ceiling is what kasbah.yml's resources: asks for.
	var own []string
	if cmpC == "below" && c.res.CPUs != "" {
		cmpC, own = "same", append(own, "cpus")
	}
	if cmpM == "below" && c.res.Memory != "" {
		cmpM, own = "same", append(own, "memory")
	}
	switch cmpC {
	case "above":
		verdict, note = "above", "cpus "+cpu+" > "+hostCPU
	case "below":
		verdict, note = "below", "cpus "+cpu+" < "+hostCPU
	case "unknown":
		note = "cpus '" + or(cpu, "unset") + "' is not a number"
	}
	switch cmpM {
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
		c.failf("R04", "effective resource limits on %s are above the host's 90%% ceiling: %s — kasbah's limits are anti-takeover ceilings, and one project over them can take the host down", s.target, note)
	case verdict == "below":
		c.warnf("R04", "effective resource limits on %s are below the host's 90%% ceiling: %s — deliberately tighter is allowed, but every deploy rewrites the KASBAH_* block, so this is usually a stale .env", s.target, note)
	case note != "":
		c.warnf("R04", "effective resource limits on %s could not all be compared with the host's %s cpus / %s: %s", s.target, hostCPU, hostMem, note)
	default:
		var used []string
		if useCPU {
			used = append(used, cpu+" cpus")
		}
		if useMem {
			used = append(used, mem)
		}
		if len(own) > 0 {
			c.passf("R04", "effective resource limits on %s are within the host's 90%% ceiling (%s) — %s set by kasbah.yml's resources:", s.target, strings.Join(used, ", "), strings.Join(own, " and "))
			return
		}
		c.passf("R04", "effective resource limits on %s match the host's 90%% ceiling (%s)", s.target, strings.Join(used, ", "))
	}
}

// r06: the projects that set their own limits (below the ceiling) are shares,
// and their sum should fit the host. A project on the ceiling is a cap
// against takeover, not a share, and is left out.
func (c *checker) r06() {
	s := c.srv
	if s.r.HostCores <= 0 || s.r.HostMemKB <= 0 {
		return
	}
	cpuSum, memSum := new(big.Rat), int64(0)
	var cpus, mems []string
	for _, p := range s.r.Limits {
		if resources.CmpCPU(p.CPU, s.mk.CPULimit) == "below" {
			n, _ := resources.Cores(p.CPU)
			cpuSum.Add(cpuSum, n)
			cpus = append(cpus, p.Name+" "+p.CPU)
		}
		if resources.CmpMem(p.Mem, s.mk.MemLimit) == "below" {
			n, _ := resources.MemBytes(p.Mem)
			memSum += n
			mems = append(mems, p.Name+" "+p.Mem)
		}
	}
	if len(cpus) == 0 && len(mems) == 0 {
		return
	}
	hostMiB := s.r.HostMemKB / 1024
	over := false
	if cpuSum.Cmp(new(big.Rat).SetInt64(s.r.HostCores)) > 0 {
		over = true
		c.warnf("R06", "the projects on %s with their own cpus limit add up to %s cores, more than the host's %d: %s — each limit caps one container, so together they can still starve each other", s.target, cpuSum.FloatString(1), s.r.HostCores, strings.Join(cpus, ", "))
	}
	if memSum > s.r.HostMemKB*1024 {
		over = true
		c.warnf("R06", "the projects on %s with their own memory limit add up to %dm, more than the host's %dm: %s — each limit caps one container, so together they can still run the host out of memory", s.target, memSum>>20, hostMiB, strings.Join(mems, ", "))
	}
	if !over {
		var fit []string
		if len(cpus) > 0 {
			fit = append(fit, fmt.Sprintf("%s of %d cores", cpuSum.FloatString(1), s.r.HostCores))
		}
		if len(mems) > 0 {
			fit = append(fit, fmt.Sprintf("%dm of %dm", memSum>>20, hostMiB))
		}
		c.passf("R06", "the projects on %s with limits of their own fit the host together (%s)", s.target, strings.Join(fit, ", "))
	}
}

// memoryController: R04 and R06 judge limits the kernel may not enforce. A
// marker that does not record the probe says nothing.
func (c *checker) memoryController() {
	if c.srv.mk.MemoryController == "no" {
		w := marker.NoMemoryController(c.srv.target)
		c.warnf("", "%s", w[0])
		for _, l := range w[1:] {
			fmt.Fprintf(c.w, "      %s\n", l)
		}
	}
}

// r04Literals judges every literal limit in compose.prod.yml against the
// marker's ceiling, and says whether any service takes cpus / mem_limit from
// the .env — both do when the services cannot be read.
func (c *checker) r04Literals(hostCPU, hostMem string) (useCPU, useMem bool) {
	if !isFile(composeFile) || len(c.services) == 0 {
		return true, true
	}
	verdict, note, n := "same", "", 0
	add := func(n string) {
		if note != "" {
			note += "; "
		}
		note += n
	}
	for _, svc := range c.services {
		for _, k := range limitKeys {
			kind, v, _ := limitOf(c.svc(svc), k.key, k.deploy, k.ref)
			if kind == "ref" {
				useCPU, useMem = useCPU || k.key == "cpus", useMem || k.key == "mem_limit"
			}
			if kind != "literal" {
				continue
			}
			n++
			host, cmp := hostCPU, resources.CmpCPU(v, hostCPU)
			if k.key == "mem_limit" {
				host, cmp = hostMem, resources.CmpMem(v, hostMem)
			}
			switch cmp {
			case "above":
				add(svc + " " + k.key + " " + v + " > " + host)
				verdict = "above"
			case "below":
				add(svc + " " + k.key + " " + v + " < " + host)
				if verdict != "above" {
					verdict = "below"
				}
			case "unknown":
				add(svc + " " + k.key + " " + v + " against '" + or(host, "unset") + "'")
				if verdict == "same" {
					verdict = "unknown"
				}
			}
		}
	}
	s := c.srv
	switch {
	case verdict == "above":
		c.failf("R04", "literal resource limits in compose.prod.yml are above the 90%% ceiling of %s: %s — kasbah's limits are anti-takeover ceilings, and one service over them can take the host down", s.target, note)
	case verdict == "below":
		c.warnf("R04", "literal resource limits in compose.prod.yml are below the 90%% ceiling of %s: %s — a tighter per-service limit is allowed, but flagged", s.target, note)
	case verdict == "unknown":
		c.warnf("R04", "literal resource limits in compose.prod.yml could not all be compared with the %s cpus / %s ceiling of %s: %s", hostCPU, hostMem, s.target, note)
	case n > 0:
		c.passf("R04", "literal resource limits in compose.prod.yml match the 90%% ceiling of %s (%s cpus, %s)", s.target, hostCPU, hostMem)
	}
	return useCPU, useMem
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
		c.warnf("B01", "%s/.kasbah/server.json on %s records off-box backups and %s %s — nothing on this server would take one, and there is no record here to say when the last one ran; re-run: kasbah server init %s --with-backup", s.apps, s.target, dir, r.Reason, s.target)
	case backuprec.NoRecord:
		c.warnf("B01", "the backup scheduler on %s has written no record at %s — it writes one as its first act, so it has not started since backups were configured (its container is %s); bring it up: docker compose -p kasbah-backup up -d", s.target, rec, cstate)
	case backuprec.Unreadable:
		c.warnf("B01", "%s on %s %s, so nothing here says whether a backup has ever run — this is not the same fact as a backup that has stopped", rec, s.target, r.Reason)
	case backuprec.Unparsed:
		c.warnf("B01", "%s on %s is not a record this kasbah reads — it %s, so nothing here says whether a backup has ever run", rec, s.target, r.Reason)
	default:
		c.b01Verdict(r, b, clock)
	}

	missing, orphan := backuprec.Diff(b.Repos(), b.HasPass)
	if len(missing) > 0 {
		c.warnf("B01", "backup repositories on %s with no password: %s — a repository with no password is not backed up at all (docs/backup.md), and the run says so only in its own log; supply one with: kasbah server init %s --with-backup", s.target, strings.Join(missing, " "), s.target)
	}
	if len(orphan) > 0 {
		c.warnf("B01", "backup repository passwords on %s that no project files into any more: %s — the last project of that client was dropped and its password stayed behind at mode 600. Keep it: it is what decrypts the snapshots already off-box, and kasbah never deletes one. Take it off by hand once that repository has been handed over or emptied (docs/backup.md → Handover).", s.target, strings.Join(orphan, " "))
	}
}

// b02: what runs left in any project's directory that may hold .env, named
// path by path. Removing it is the operator's call, so it only warns.
func (c *checker) b02() {
	s := c.srv
	for _, p := range s.r.Leftovers {
		dir := s.apps + "/" + p.Name
		if p.Error != "" {
			c.warnf("B02", "whether %s on %s holds a leftover that may hold a copy of .env cannot be checked: %s", p.Name, s.target, p.Error)
		}
		if paths := p.Running().Paths(dir); len(paths) > 0 {
			c.warnf("B02", "%s on %s: a run holds the lock now (%s); a backup directory or extraction may be its own — each may hold a copy of .env:", p.Name, s.target, p.Holder)
			c.paths(paths)
		}
		if paths := p.Settled().Paths(dir); len(paths) > 0 {
			c.warnf("B02", "%s on %s holds %d leftover(s) a deploy or rollback did not finish with — a backup directory whose tarball was never written, a snapshot a backup could not take in, or a killed rollback's extraction — and each may hold a copy of .env; inspect each, then remove it by hand:", p.Name, s.target, len(paths))
			c.paths(paths)
		}
	}
}

// paths prints the first maxLeftovers of paths, then how many more.
func (c *checker) paths(paths []string) {
	for i, l := range paths {
		if i == maxLeftovers {
			fmt.Fprintf(c.w, "      and %d more\n", len(paths)-i)
			return
		}
		fmt.Fprintf(c.w, "      %s\n", l)
	}
}

// maxLeftovers is how many of a project's leftover paths B02 names.
const maxLeftovers = 20

func (c *checker) b01Verdict(r *backuprec.Record, b backuprec.Facts, clock string) {
	s := c.srv
	ago, due := backuprec.Ago(r.Age), backuprec.Ago(r.Overdue)
	repos := strings.TrimPrefix(r.Repos, " ")
	switch b.Container.State {
	case "running":
	case "nodocker":
		c.warnf("B01", "there is no docker on %s, so whether its backup scheduler is running cannot be read — the record says '%s'", s.target, r.Verdict)
		return
	case "nodaemon":
		c.warnf("B01", "the docker daemon on %s is not answering, so whether its backup scheduler is running cannot be read — nothing here says it is down (docker said: %s)", s.target, or(s.r.DockerError, "nothing"))
		return
	case "notours":
		c.failf("B01", "the container named kasbah-backup on %s was not started as the kasbah-backup compose project from %s/.kasbah/backup, so it is not kasbah's scheduler and nothing is shipping this server off-box", s.target, s.apps)
		return
	default:
		last := ""
		if r.Age >= 0 {
			last = ", last run " + ago + " ago"
		}
		c.failf("B01", "the backup scheduler on %s is %s, so nothing is being shipped off-box — its record still reads '%s'%s; bring it up: docker compose -p kasbah-backup up -d", s.target, b.Container.State, r.Verdict, last)
		return
	}
	switch r.Verdict {
	case backuprec.Failed:
		past := ""
		if r.Overdue != 0 {
			past = ", and the scheduler is " + due + " past its own deadline"
		}
		if why := r.Why(); len(why) > 0 {
			logs := "docker logs kasbah-backup says why"
			if r.Launcher == "" {
				logs = "docker logs kasbah-backup has each project's result and the last 64 KB of the backup hooks' stderr"
			}
			c.failf("B01", "the last backup on %s FAILED %s ago (repositories backed up: %s) — %s; %s%s%s", s.target, ago, or(repos, "-"), strings.Join(why, "; "), logs, past, clock)
			break
		}
		c.failf("B01", "the last backup on %s FAILED %s ago (repositories backed up: %s) — nothing new has been shipped off-box since; docker logs kasbah-backup says which repository and why%s%s", s.target, ago, or(repos, "-"), past, clock)
	case backuprec.Overdue:
		finished := ""
		if r.Age >= 0 {
			finished = " (the last run finished " + ago + " ago)"
		}
		c.failf("B01", "the backup scheduler on %s is %s past its own deadline in state '%s' — a run that never returned, or a sleep that never woke, so nothing is being shipped off-box%s; docker logs kasbah-backup%s", s.target, due, r.State, finished, clock)
	case backuprec.Never:
		c.warnf("B01", "backups are configured on %s and no run has finished yet — the scheduler is '%s' and inside its own deadline, so this is a stack that has not fired rather than one that has stopped%s", s.target, r.State, clock)
	case backuprec.OK:
		if repos == "" || repos == "none" {
			c.warnf("B01", "the last backup on %s finished %s ago and shipped nothing — no repository had anything to back up, so nothing of this server exists off-box yet%s", s.target, ago, clock)
		} else {
			c.passf("B01", "the last backup on %s finished %s ago and succeeded (repositories: %s)%s", s.target, ago, repos, clock)
		}
	}
}

// outsiders is C12 and C13: what a deploy's pre-flight would refuse, read
// from the same containers and judged by the same function.
func (c *checker) outsiders() {
	s := c.srv
	dir := s.apps + "/" + c.m.Name
	if s.r.OutsidersError != "" {
		c.warnf("C12,C13", "whether a container outside %s on %s publishes a port it publishes, or runs under its compose project name, cannot be checked: %s", dir, s.target, s.r.OutsidersError)
		return
	}
	binds, unsure := c.binds()
	cs := deploy.Collisions(c.m.Name, dir, binds, s.r.Outsiders)
	for _, col := range cs {
		if col.Kind == deploy.NameCollision {
			c.failf("C13", "on %s, %s — a deploy refuses this", s.target, col.Msg)
		} else {
			c.failf("C12", "on %s, %s — a deploy refuses this", s.target, col.Msg)
		}
	}
	for _, u := range unsure {
		c.warnf("C12", "whether a container outside %s on %s publishes %s cannot be checked: %s", dir, s.target, u.entry, u.why)
	}
	if len(cs) == 0 && len(unsure) == 0 {
		c.passf("C12,C13", "no container outside %s on %s publishes a port it publishes or runs under its compose project name", dir, s.target)
	}
}

type unsurePort struct{ entry, why string }

// binds is every host port compose.prod.yml publishes, by service, the
// server .env interpolated as compose would; unsure the entries that leaves
// unread: an unresolved interpolation, an .env line kasbah cannot read, or a
// host port that is not one.
func (c *checker) binds() (bs []deploy.Bind, unsure []unsurePort) {
	for _, svc := range c.services {
		for _, p := range asList(c.svc(svc, "ports")) {
			var b deploy.Bind
			var ok bool
			var err error
			entry := ""
			if m, isMap := p.(*tree.Map); isMap {
				var ip, pub, proto string
				pub = scalar(opt(m, "published"))
				entry = fmt.Sprintf("service %s's port published %q", svc, pub)
				if ip, err = c.interp(scalar(opt(m, "host_ip"))); err == nil {
					if pub, err = c.interp(pub); err == nil {
						proto, err = c.interp(scalar(opt(m, "protocol")))
					}
				}
				if err == nil && strings.TrimSpace(pub) != "" {
					if b, ok = deploy.ParseBind(ip, pub, proto); !ok {
						err = fmt.Errorf("%q is not a host port or range", pub)
					}
					b.Any = b.Lo < b.Hi
				}
			} else if str, isStr := p.(string); isStr {
				entry = fmt.Sprintf("service %s's port %q", svc, str)
				if str, err = c.interp(str); err == nil {
					b, ok, err = deploy.ParseShortPort(str)
				}
			}
			switch {
			case err != nil:
				unsure = append(unsure, unsurePort{entry, err.Error()})
			case ok:
				b.Svc = svc
				bs = append(bs, b)
			}
		}
	}
	return bs, unsure
}

// interp is s interpolated from the server's .env as compose would; a
// variable read from an .env kasbah cannot fully read leaves s unresolved.
func (c *checker) interp(s string) (string, error) {
	read := false
	v, err := envtpl.Interpolate(s, func(k string) (string, bool) {
		read = true
		v, ok := c.srv.envVals[k]
		return v, ok
	})
	if read && c.srv.envErr != nil {
		return "", fmt.Errorf("the server's .env has a line kasbah cannot read as compose does: %v", c.srv.envErr)
	}
	return v, err
}
