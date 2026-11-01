// Package upgrade is `kasbah server upgrade-traefik`: a managed Traefik
// version bump — re-render the three kasbah-owned files with the values
// already in effect, dry-run the target version against every fragment on
// the server, back up, ship, recreate; a start that does not come up healthy
// is rolled back on the server.
package upgrade

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are the command's arguments.
type Options struct {
	Target, Version string
}

const (
	// DryLabel is what the next run sweeps a leftover throwaway by.
	DryLabel = "kasbah.role=traefik-dry-run"
	// DryCA refuses at once on every host, and no genuine error can name it.
	DryCA = "https://127.0.0.1:1/kasbah-dry-run-no-ca"
	// DryACMEError is the one error family the throwaway's CA produces. The
	// classifier depends on Traefik printing it and the CA on one line
	// (v3.5–v3.7): every error line naming DryCA means that broke.
	DryACMEError = "Unable to obtain ACME certificate for domains"
	// DryAnchor proves the file provider ran: a TLS router the dry run adds
	// to its own overlay of _shared.yml, never shipped, there with the
	// dashboard on or off.
	DryAnchor = "kasbah-dry-run-anchor@file"
	// DryTimeout bounds the throwaway's verdict; StartTimeout the health wait.
	DryTimeout   = 120
	StartTimeout = 180
)

// SharedRouters are the routers the overlay can contribute: _shared.yml's
// own, and the anchor.
var SharedRouters = []string{"traefik-dashboard@file", "traefik-dashboard-http@file", DryAnchor}

// Usage is the command's --help.
const Usage = `Usage: kasbah server upgrade-traefik USER@HOST --version=<tag>

Moves the shared Traefik proxy to another image tag. Two halves:

  * the three kasbah-owned files — compose.yml, traefik.yml and
    dynamic/_shared.yml — are re-rendered from this kasbah's templates and
    the bytes already on the server are copied to
    <apps>/traefik/backups/<UTC stamp>/ before anything is overwritten.
    They are kasbah's outright (docs/traefik.md), so nothing is asked;
    the backup is what ` + "`server init`" + ` does not do.

  * a throwaway Traefik of the target version is booted first, with the
    live dynamic directory mounted read-only, and the upgrade fails on a
    config error in its log. It validates every fragment in that
    directory — _shared.yml, _mail.yml and every project's own — before
    the live proxy is touched.

Flags:
  --version=<tag>   the Traefik image tag to move to, e.g. v3.7.10

The dashboard apex, its basic-auth entry, the ACME address and the ACME
endpoint are read back off the server and reproduced — a server without a
dashboard keeps it off. A stack that will not yield them is refused:
repairing one is ` + "`kasbah server init`" + `'s job, and
this command must not move a server's CA or its dashboard credentials as a
side effect of a version bump. acme.json is never written.

There is no --apps-path: where the server was prepared is the server's own
answer (/etc/kasbah/apps-path, falling back to /apps).
`

var reTag = regexp.MustCompile(`^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)

// CheckVersion is Docker's tag grammar: the value reaches a YAML scalar and
// a `docker run` argument, so a whole image reference is refused.
func CheckVersion(tag string) error {
	if tag == "" {
		return cli.Fail("server upgrade-traefik: --version= must not be empty")
	}
	if strings.ContainsAny(tag, "/:") {
		return cli.Fail("server upgrade-traefik: --version=%s looks like an image reference — give the tag alone (the repository is always 'traefik')", tag)
	}
	if !reTag.MatchString(tag) {
		return cli.Fail("server upgrade-traefik: --version=%s is not a Docker tag (letters, digits, '_', '.' and '-', up to 128 characters, not starting with '.' or '-')", tag)
	}
	return nil
}

// Parse reads the command line.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--version="):
			o.Version = strings.TrimSuffix(strings.TrimPrefix(a, "--version="), "\r")
			if err := CheckVersion(o.Version); err != nil {
				return o, err
			}
		case a == "--version":
			return o, cli.Fail("server upgrade-traefik: --version needs a value (--version=v3.7.10)")
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("server upgrade-traefik: unknown flag '%s' (expected --version=<tag>)", name)
		default:
			if o.Target != "" {
				return o, cli.Fail("server upgrade-traefik: unexpected argument '%s' (USER@HOST is given once)", a)
			}
			o.Target = strings.TrimSuffix(a, "\r")
		}
	}
	if o.Target == "" {
		return o, cli.Fail("server upgrade-traefik: USER@HOST is required (the user kasbah deploys as is not optional)")
	}
	if o.Version == "" {
		return o, cli.Fail("server upgrade-traefik: --version=<tag> is required — this command exists to change it, and there is no default to fall back on")
	}
	return o, nil
}

// Session is what the command needs from a server; each call returns the
// remote step's stdout and its exit status.
type Session interface {
	Marker() (*marker.Marker, error)
	Call(stdin []byte, bounded bool, args ...string) ([]byte, int)
	// Lock holds the server lock exclusive until release.
	Lock(apps string) (release func(), err error)
	Close()
}

// SSH is the real Session.
type SSH struct{ *env.SSH }

// Dial connects; Marker ensures the server's binary.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

// Lock is serverlock.Hold: no deploy, rollback or drop runs under the upgrade.
func (s *SSH) Lock(apps string) (func(), error) {
	return serverlock.Hold(s.Conn, s.Bin(), apps, serverlock.Exclusive, "server upgrade-traefik")
}

// Call is `kasbah remote ARGS…`, bounded unless the step bounds itself.
func (s *SSH) Call(stdin []byte, bounded bool, args ...string) ([]byte, int) {
	words := append([]string{s.Bin(), "remote"}, args...)
	if bounded {
		words = s.Bounded(args...)
	}
	cmd := s.Conn.Command(words...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.Bytes(), ssh.ExitCode(err)
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out       *cli.Output
	Templates fs.FS
	Dial      func(target string) (Session, error)
	Now       func() time.Time
}

type run struct {
	c                  Ctx
	o                  Options
	s                  Session
	apps, data         string
	stack              Stack
	cur                map[string]string
	imageNow, imageNew string
	rendered           map[string]string
	dryStatic          string
	dryShared          string
	changed            []string
	stamp, backupDir   string
	routers            string
}

// Run is the command.
func Run(c Ctx, o Options) error {
	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return err
	}
	release, err := s.Lock(mk.AppsPath)
	if err != nil {
		return err
	}
	defer release()
	x := &run{c: c, o: o, s: s, apps: mk.AppsPath, data: mk.DataPath,
		stamp: c.Now().UTC().Format("20060102T150405Z"), imageNew: "traefik:" + o.Version}
	if err := x.readStack(); err != nil {
		return err
	}
	v, err := x.recover()
	if err != nil {
		return err
	}
	if err := x.render(v); err != nil {
		return err
	}
	c.Out.Info("Upgrading Traefik on %s: %s -> %s", o.Target, x.imageNow, x.imageNew)
	if err := x.dryRun(); err != nil {
		return err
	}
	// Byte-identical files are not a proxy on the target version: a container
	// never recreated after a hand edit is recreated here.
	if len(x.changed) == 0 && x.stack.RunningImage == x.imageNew {
		c.Out.Info("  nothing to ship: %s/traefik already renders byte-for-byte to %s", x.apps, x.imageNew)
		c.Out.Info("  the proxy was not restarted (%s, %s)", x.stack.RunningImage, x.stack.Health)
		return nil
	}
	if len(x.changed) == 0 {
		running := x.stack.RunningImage
		if running == "" {
			running = "nothing"
		}
		c.Out.Warn("%s/traefik already renders byte-for-byte to %s, but the container is running %s — recreating it", x.apps, x.imageNew, running)
	}
	if err := x.backup(); err != nil {
		return err
	}
	c.Out.Info("  backed up compose.yml, traefik.yml and dynamic/_shared.yml to %s", x.backupDir)
	if err := x.ship(); err != nil {
		return err
	}
	up, err := x.start()
	if err != nil {
		return err
	}
	c.Out.Info("Upgraded Traefik on %s", o.Target)
	c.Out.Info("  image: %s -> %s (%s)", x.imageNow, up.Image, up.Health)
	shipped := "nothing re-rendered"
	if len(x.changed) > 0 {
		shipped = "shipped " + strings.Join(x.changed, " ")
	}
	c.Out.Info("  %s, previous bytes at %s", shipped, x.backupDir)
	c.Out.Info("  validated %d fragment(s): %s", len(x.stack.Fragments), strings.Join(x.stack.Fragments, " "))
	if nets := strings.Fields(up.Networks); len(nets) > 0 {
		c.Out.Info("  rejoined %d project network(s): %s", len(nets), strings.Join(nets, " "))
	}
	if x.stack.AcmeState == "nonempty" {
		if up.AcmeDigest == x.stack.AcmeDigest {
			c.Out.Info("  acme.json: unchanged (kasbah never writes it; the certificates carried over)")
		} else {
			c.Out.Info("  acme.json: written by the new Traefik — normal when a certificate came up for renewal")
		}
	} else {
		c.Out.Info("  acme.json: %s, nothing to carry over", x.stack.AcmeState)
	}
	return nil
}

func (x *run) noStack(rel string) error {
	return cli.Fail("%s/traefik/%s is missing or unreadable on %s", x.apps, rel, x.o.Target).Cont(
		"upgrade-traefik re-renders the three kasbah-owned files and needs the ones",
		"already there to recover the dashboard apex, its credentials, the ACME",
		"address and the endpoint in effect. It will not invent any of them.",
		"Run `kasbah server init "+x.o.Target+"` to lay the stack down first.")
}

func (x *run) readStack() error {
	out, rc := x.s.Call(nil, true, "traefik", "read", x.apps, x.data)
	if rc != 0 {
		return cli.Fail("could not read the Traefik stack on %s (the remote step exited %d, see above)", x.o.Target, rc)
	}
	if err := remote.DecodeHidden(out, &x.stack,
		[]string{"compose_b64", "static_b64", "shared_b64", "fragments", "acme_state", "acme_digest", "docker",
			"traefik_state", "traefik_health", "traefik_running_image"}, "the Traefik stack read", x.o.Target); err != nil {
		return err
	}
	if !x.stack.Docker {
		return cli.Fail("docker is not on %s's PATH — this host is not running a kasbah Traefik stack", x.o.Target)
	}
	x.cur = map[string]string{
		"compose.yml":         decodeB64(x.stack.Compose),
		"traefik.yml":         decodeB64(x.stack.Static),
		"dynamic/_shared.yml": decodeB64(x.stack.Shared),
	}
	for _, rel := range serverinit.Files {
		if strings.TrimSpace(x.cur[rel]) == "" {
			return x.noStack(rel)
		}
	}
	return nil
}

func (x *run) unreadable(rel string) error {
	return cli.Fail("%s/traefik/%s on %s is not valid YAML", x.apps, rel, x.o.Target).Cont(
		"kasbah reproduces the values already in effect rather than regenerating them,",
		"and it cannot read them out of this file. Fix it, or re-render the stack with",
		"`kasbah server init "+x.o.Target+"`, which owns that file and will replace it.")
}

func (x *run) missing(what, file, flag string) error {
	return cli.Fail("%s on %s does not say what %s is", file, x.o.Target, what).Cont(
		"upgrade-traefik reproduces it verbatim and will not invent one — a bump that",
		"changed it would be a side effect nobody asked for.",
		"`kasbah server init "+x.o.Target+" "+flag+"` sets it; this command only moves the version.")
}

// recover reads the four values back, and the image in effect. The endpoint
// is reproduced, never decided: a bump must not move a server's CA.
func (x *run) recover() (serverinit.Values, error) {
	var v serverinit.Values
	shared, static, compose := x.cur["dynamic/_shared.yml"], x.cur["traefik.yml"], x.cur["compose.yml"]
	var err error
	if v.Dashboard, err = serverinit.DashboardOn(shared); err != nil {
		return v, x.unreadable("dynamic/_shared.yml")
	}
	if v.Domain, err = serverinit.DashboardApex(shared); err != nil {
		return v, x.unreadable("dynamic/_shared.yml")
	}
	if v.Dashboard && v.Domain == "" {
		return v, x.missing("the dashboard router's rule", "dynamic/_shared.yml", "--domain=")
	}
	if v.Dashboard {
		if v.AuthEntry, err = serverinit.ExtractAuth(shared); err != nil {
			if serverinit.Unparsed(err) {
				return v, x.unreadable("dynamic/_shared.yml")
			}
			return v, err
		}
		if v.AuthEntry == "" {
			return v, x.missing("the dashboard's basic-auth entry", "dynamic/_shared.yml", "--traefik-auth=user:pass")
		}
	}
	if v.Email, err = serverinit.StaticField(static, "email"); err != nil {
		return v, x.unreadable("traefik.yml")
	}
	if v.Email == "" {
		return v, x.missing("the ACME registration address", "traefik.yml", "--email=")
	}
	if v.Acme.CA, err = serverinit.StaticField(static, "caServer"); err != nil {
		return v, x.unreadable("traefik.yml")
	}
	if v.Acme.CA == "" {
		return v, x.missing("the ACME endpoint (caServer)", "traefik.yml", "--acme-staging (or without it for production)")
	}
	if x.imageNow, err = serverinit.ExtractImage(compose); err != nil {
		return v, x.unreadable("compose.yml")
	}
	if x.imageNow == "" {
		return v, x.missing("the traefik service's image", "compose.yml", "--version=")
	}
	v.Image = x.imageNew
	return v, nil
}

// DryStatic is the rendered traefik.yml isolated for the throwaway: its
// entrypoints off :80/:443, a CA that refuses on the loopback, a store that
// is not the real acme.json. JSON is YAML, and Traefik reads it as such.
func DryStatic(static string) (string, error) {
	docs, err := yamlx.Load([]byte(static))
	if err != nil || len(docs) != 1 {
		return "", errors.New("the rendered traefik.yml is not one YAML document")
	}
	root, ok := docs[0].(*tree.Map)
	if !ok {
		return "", errors.New("the rendered traefik.yml is not a mapping")
	}
	set := func(val string, path ...string) error {
		m := root
		for _, k := range path[:len(path)-1] {
			next, _ := m.Get(k)
			switch n := next.(type) {
			case *tree.Map:
				m = n
			case nil:
				n2 := tree.NewMap()
				m.Set(k, n2)
				m = n2
			default:
				return fmt.Errorf("%s is not a mapping", strings.Join(path, "."))
			}
		}
		m.Set(path[len(path)-1], val)
		return nil
	}
	for _, a := range [][]string{
		{":8080", "entryPoints", "web", "address"},
		{":8443", "entryPoints", "websecure", "address"},
		{DryCA, "certificatesResolvers", acme.Resolver, "acme", "caServer"},
		{"/tmp/kasbah-dry-run-acme.json", "certificatesResolvers", acme.Resolver, "acme", "storage"},
		{"INFO", "log", "level"},
	} {
		if err := set(a[0], a[1:]...); err != nil {
			return "", err
		}
	}
	return tree.Indent(root) + "\n", nil
}

// DryShared is the rendered _shared.yml with the anchor router added: the
// throwaway's overlay, never shipped.
func DryShared(shared string) (string, error) {
	docs, err := yamlx.Load([]byte(shared))
	if err != nil || len(docs) != 1 {
		return "", errors.New("the rendered _shared.yml is not one YAML document")
	}
	root, ok := docs[0].(*tree.Map)
	if !ok {
		return "", errors.New("the rendered _shared.yml is not a mapping")
	}
	m := root
	for _, k := range []string{"http", "routers"} {
		next, _ := m.Get(k)
		switch n := next.(type) {
		case *tree.Map:
			m = n
		case nil:
			n2 := tree.NewMap()
			m.Set(k, n2)
			m = n2
		default:
			return "", fmt.Errorf("the rendered _shared.yml's %s is not a mapping", k)
		}
	}
	tls := tree.NewMap()
	tls.Set("certResolver", acme.Resolver)
	r := tree.NewMap()
	r.Set("rule", "Host(`kasbah-dry-run.example.com`)")
	r.Set("entryPoints", []tree.Value{"websecure"})
	r.Set("tls", tls)
	r.Set("service", "noop@internal")
	m.Set(strings.TrimSuffix(DryAnchor, "@file"), r)
	return tree.Indent(root) + "\n", nil
}

func (x *run) render(v serverinit.Values) error {
	var err error
	x.rendered, err = serverinit.Render(x.c.Templates, serverinit.Options{Apps: x.apps, Data: x.data, Target: x.o.Target}, v)
	if err != nil {
		return err
	}
	if x.dryStatic, err = DryStatic(x.rendered["traefik.yml"]); err != nil {
		return cli.Fail("could not build the dry-run static configuration from the rendered traefik.yml: %v", err)
	}
	if x.dryShared, err = DryShared(x.rendered["dynamic/_shared.yml"]); err != nil {
		return cli.Fail("could not build the dry-run overlay from the rendered dynamic/_shared.yml: %v", err)
	}
	for _, rel := range serverinit.Files {
		if x.rendered[rel] != x.cur[rel] {
			x.changed = append(x.changed, rel)
		}
	}
	return nil
}

func (x *run) dryRun() error {
	t := x.o.Target
	x.c.Out.Info("Dry run: booting %s against %d fragment(s) in %s/traefik/dynamic (read-only)", x.imageNew, len(x.stack.Fragments), x.apps)
	body, _ := json.Marshal(DryPayload{Shared: x.dryShared, Static: x.dryStatic})
	size, sum := remote.Digest(body)
	out, rc := x.s.Call(body, false, "traefik", "dry-run", x.apps, x.imageNew, DryLabel, x.stamp,
		DryACMEError, DryCA, strconv.Itoa(DryTimeout), size, sum)
	if rc != 0 {
		return cli.Fail("the dry run of %s on %s could not be carried out (the remote step exited %d, see above) — nothing was changed", x.imageNew, t, rc)
	}
	var d Dry
	if err := remote.Decode(out, &d,
		[]string{"dry_swept", "dry_verdict", "dry_exitcode", "dry_errors", "dry_warns", "dry_routers", "dry_log"}, "the dry run", t); err != nil {
		return err
	}
	if d.Swept != 0 {
		x.c.Out.Warn("swept %d throwaway container(s) a previous dry run left behind", d.Swept)
	}
	x.routers = d.Routers
	withLog := func(e *cli.Error) error {
		e.Cont("nothing was backed up, shipped or restarted; "+x.stack.RunningImage+" is still serving.",
			"the throwaway's log, last lines:")
		for _, l := range strings.Split(strings.TrimRight(d.Log, "\n"), "\n") {
			e.Cont("| " + l)
		}
		return e
	}
	switch d.Verdict {
	case "spoke":
	case "exited":
		return withLog(cli.Fail("the throwaway %s exited (code %s) instead of loading the configuration", x.imageNew, d.ExitCode))
	default:
		return withLog(cli.Fail("the throwaway %s said nothing in %ds — the dry run reached no verdict", x.imageNew, DryTimeout).Cont(
			"a dry run that reads nothing must not be read as a pass."))
	}
	if d.Errors != "" {
		e := cli.Fail("%s rejects the configuration already on %s — the upgrade is off", x.imageNew, t).Cont(
			"nothing was backed up, shipped or restarted; "+x.stack.RunningImage+" is still serving.",
			"the throwaway logged, against "+x.apps+"/traefik/dynamic:")
		for _, l := range strings.Split(d.Errors, "\n") {
			e.Cont("| " + l)
		}
		return e.Cont("fix the fragment it names and run this again.")
	}

	// A conjunction: the anchor proves the file provider ran, and a router not
	// out of _shared.yml proves the server's directory was read.
	serverFrags := 0
	for _, f := range x.stack.Fragments {
		if f != "_shared.yml" {
			serverFrags++
		}
	}
	routers := strings.Fields(d.Routers)
	shown := d.Routers
	if shown == "" {
		shown = "<none>"
	}
	anchor, offServer := false, false
	for _, r := range routers {
		if r == DryAnchor {
			anchor = true
		}
		shared := false
		for _, sr := range SharedRouters {
			if r == sr {
				shared = true
			}
		}
		if !shared {
			offServer = true
		}
	}
	if !anchor {
		return withLog(cli.Fail("the dry run of %s loaded no %s router — it validated nothing", x.imageNew, DryAnchor).Cont(
			"every TLS router the file provider builds asks this run's own unreachable CA",
			"for a certificate and names itself doing it, and that router is in the",
			"dynamic/_shared.yml overlay this run rendered and mounted over the directory.",
			"Seeing not even that one means the file provider read nothing at all, so the",
			"verdict is not evidence.",
			"routers seen: "+shown))
	}
	if serverFrags > 0 && !offServer {
		return withLog(cli.Fail("the dry run of %s loaded no router out of %s/traefik/dynamic — it validated nothing", x.imageNew, x.apps).Cont(
			fmt.Sprintf("that directory holds %d fragment(s) besides _shared.yml —", serverFrags),
			strings.Join(x.stack.Fragments, " ")+" — and not one router came out of them.",
			DryAnchor+" is in kasbah's own _shared.yml, rendered here and mounted over",
			"the directory, so it answers the same whether that directory was read or not.",
			"Either the read-only mount of it did not apply, or nothing in it declares a",
			"router on websecure with certResolver: "+acme.Resolver+".",
			"routers seen: "+shown))
	}
	if d.Warns != "" {
		x.c.Out.Warn("%s logged warnings against the current configuration (not fatal):", x.imageNew)
		for _, l := range strings.Split(d.Warns, "\n") {
			x.c.Out.ErrCont("| %s", l)
		}
	}
	var built []string
	for _, r := range routers {
		if r != DryAnchor {
			built = append(built, r)
		}
	}
	x.c.Out.Info("  dry run passed: %s built %s out of %d fragment(s)", x.imageNew, or(strings.Join(built, " "), "no router but its own anchor"), len(x.stack.Fragments))
	if serverFrags == 0 {
		x.c.Out.Info("  (that directory holds only kasbah's own _shared.yml — there were no project fragments to validate)")
	}
	return nil
}

func (x *run) backup() error {
	out, rc := x.s.Call(nil, true, "traefik", "backup", x.apps, x.stamp, x.imageNow, x.imageNew)
	if rc != 0 {
		return cli.Fail("could not back up the Traefik stack on %s (the remote step exited %d, see above) — nothing was changed", x.o.Target, rc)
	}
	var b struct {
		Dir string `json:"backup_dir"`
	}
	if err := remote.Decode(out, &b, []string{"backup_dir"}, "the backup", x.o.Target); err != nil {
		return err
	}
	x.backupDir = b.Dir
	return nil
}

// ship overwrites through the payload-checked write; _shared.yml last, as
// the one file the running Traefik picks up without a restart.
func (x *run) ship() error {
	for _, rel := range serverinit.Files {
		if !contains(x.changed, rel) {
			continue
		}
		dest := x.apps + "/traefik/" + rel
		body := []byte(x.rendered[rel])
		size, sum := remote.Digest(body)
		out, rc := x.s.Call(body, true, "init", "write", dest, size, sum)
		if rc != 0 || !strings.Contains(string(out), "written=yes") {
			return cli.Fail("could not ship the Traefik %s to %s:%s — the backup is at %s", rel, x.o.Target, dest, x.backupDir)
		}
	}
	return nil
}

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func contains(l []string, s string) bool {
	for _, v := range l {
		if v == s {
			return true
		}
	}
	return false
}

func (x *run) start() (Up, error) {
	var up Up
	t := x.o.Target
	// Held: a signal here must not tear the master down mid-switch. The
	// server finishes the start, and its rollback, either way.
	release := atexit.Hold(func(os.Signal) {})
	out, rc := x.s.Call(nil, false, "traefik", "start", x.apps, x.backupDir,
		x.data+"/traefik/letsencrypt/acme.json", strconv.Itoa(StartTimeout))
	release()
	if c := atexit.Interrupted(); c != 0 && rc != 0 && rc != 3 {
		return up, cli.Failf(c, "interrupted while Traefik was being started on %s", t).Cont(
			"the server carries on without this end: it finishes the start, and puts the",
			"backup at "+x.backupDir+" back on its own if the new version does not come up.",
			"`kasbah server status "+t+"` shows where it ended.")
	}
	if rc != 0 && rc != 3 {
		return up, cli.Fail("could not bring Traefik up on %s (the remote step exited %d, see above)", t, rc).Cont(
			"the previous stack is backed up at "+x.backupDir+" — restore it with:",
			"  cp -p "+x.backupDir+"/compose.yml "+x.apps+"/traefik/compose.yml",
			"  cp -p "+x.backupDir+"/traefik.yml "+x.apps+"/traefik/traefik.yml",
			"  cp -p "+x.backupDir+"/_shared.yml "+x.apps+"/traefik/dynamic/_shared.yml",
			"  cd "+x.apps+"/traefik && docker compose -p "+Project+" up -d",
			"a recreated Traefik is on kasbah-net alone: `kasbah server init "+t+"` rejoins it to the project networks.")
	}
	if err := remote.Decode(out, &up,
		[]string{"up_rolled_back", "up_health", "up_state", "up_image", "up_started_at", "up_acme_digest", "up_networks"}, "the Traefik start", t); err != nil {
		return up, err
	}
	rejoin := []string{
		"every site whose network it is not on answers 502 until it is connected:",
		"  docker network ls --filter label=com.docker.compose.network=kasbah",
		"  docker network connect <network> traefik",
		"or re-run `kasbah server init " + t + "`, whose Traefik start rejoins them."}
	switch {
	case up.RolledBack == "no" && up.JoinErr == "":
		return up, nil
	case up.RolledBack == "no":
		return up, cli.Fail("Traefik is up on %s (%s) and could not rejoin the project networks: %s", t, up.Image, up.JoinErr).Cont(rejoin...)
	case up.RolledBack == "yes":
		e := cli.Fail("%s did not come up healthy on %s — rolled back to %s", x.imageNew, t, x.imageNow).Cont(
			"the proxy is serving again on "+up.Image+" ("+up.Health+");",
			"the backup it was restored from is at "+x.backupDir+".",
			"the failing stack's log is above.")
		if up.JoinErr != "" {
			e.Cont("and the restored Traefik could not rejoin the project networks: " + up.JoinErr)
			e.Cont(rejoin...)
		}
		return up, e
	}
	state := up.State
	if state == "" {
		state = "gone"
	}
	return up, cli.Fail("%s did not come up on %s and the rollback did not come up either", x.imageNew, t).Cont(
		"the proxy is "+state+" ("+up.Health+") — every site on this host is down.",
		"the previous stack's files are at "+x.backupDir+"; restore them and run:",
		"  cd "+x.apps+"/traefik && docker compose -p "+Project+" up -d",
		"then `kasbah server init "+t+"`, which rejoins Traefik to the project networks.")
}
