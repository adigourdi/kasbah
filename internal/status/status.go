// Package status is `kasbah server status USER@HOST [--apps-path=<dir>]`:
// what a prepared server is running, read in one `kasbah remote status`
// round trip after the server binary is ensured. It reports; `check
// --server` judges. Nothing on the server is written but kasbah's own binary,
// under the same-build rule.
package status

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
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/vlog"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// ErrHelp is --help.
var ErrHelp = errors.New("help")

// Options is the parsed command line.
type Options struct {
	Target string
	// Apps is --apps-path, normalised; "" when not given.
	Apps string
}

// Usage is the --help text.
func Usage() string {
	return `Usage: kasbah server status USER@HOST [--apps-path=<dir>]

Prints what a prepared server is running: docker and compose versions, the
shared Traefik stack, and every project under the apps path with its last
versions.log entry. Read-only — it changes nothing on the server but kasbah's
own binary, which it installs when the server's is absent or older.

Flags:
  --apps-path=<dir>   where the server was prepared. Without it, status reads
                      ` + serverbin.Pointer + ` — the server's own record — and
                      falls back to ` + serverbin.DefaultApps + ` when there is none. The flag is
                      the escape hatch for a server whose pointer is gone.

It also prints the filesystem behind the apps and data paths, the mail stack,
the backup stack with its last run, each project's domain out of its Traefik
fragment, and what Traefik's ACME store says about every hostname on the server.
`
}

// Parse reads `server status`'s arguments.
func Parse(args []string) (Options, error) {
	var o Options
	apps, given := "", false
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--apps-path="):
			apps, given = strings.TrimPrefix(a, "--apps-path="), true
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "-"):
			flag, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("server status: unknown flag '%s' (expected --apps-path=)", flag)
		default:
			if o.Target != "" {
				return o, cli.Fail("server status: unexpected argument '%s' (USER@HOST is given once)", a)
			}
			o.Target = strings.TrimSuffix(a, "\r")
		}
	}
	if o.Target == "" {
		return o, cli.Fail("server status: USER@HOST is required (the user kasbah deploys as is not optional)")
	}
	if !given {
		return o, nil
	}
	v := strings.TrimSuffix(apps, "\r")
	switch {
	case v == "":
		return o, cli.Fail("server status: --apps-path= must not be empty")
	case !strings.HasPrefix(v, "/"):
		return o, cli.Fail("server status: --apps-path=%s must be an absolute path", v)
	case strings.Contains(v, "\n"):
		return o, cli.Fail("server status: --apps-path= must not contain a newline")
	case strings.Contains(v, "//"), strings.Contains(v, "/./"), strings.Contains(v, "/../"),
		strings.HasSuffix(v, "/.."), strings.HasSuffix(v, "/."):
		return o, cli.Fail("server status: --apps-path=%s must be a normalised path (no '.', '..' or empty segment)", v)
	}
	v = strings.TrimRight(v, "/")
	if v == "" {
		return o, cli.Fail("server status: --apps-path=/ must not be the filesystem root")
	}
	o.Apps = v
	return o, nil
}

// Session is one server's read.
type Session interface {
	// Read ensures the server binary under the apps path (apps when given,
	// else discovered) and returns its report, the apps path and how it was
	// found (flag, pointer or default).
	Read(apps string) (r *Report, path, source string, err error)
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out     *cli.Output
	Version string
	Dial    func(target string) (Session, error)
	Now     func() time.Time
}

// SSH is a Session over ssh.
type SSH struct {
	Conn  *ssh.Conn
	Self  remote.Info
	Local func(arch string) (string, error)
}

// Dial connects.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{Conn: c, Self: self, Local: local}, nil
	}
}

// Read is the Session's read.
func (s *SSH) Read(apps string) (*Report, string, string, error) {
	target := s.Conn.Target.String()
	res, err := serverbin.Ensure(s.Conn, s.Self, s.Local, serverbin.Options{Apps: apps, Prepared: func(body []byte, apps string) error {
		return JudgeMarker(body, marker.Path(apps), target)
	}})
	if err != nil {
		return nil, "", "", err
	}
	out, err := s.Conn.Run(serverbin.Bounded(serverbin.Path(res.Apps), ReadTimeout, "status", res.Apps)...)
	if err != nil {
		return nil, "", "", cli.Fail("could not read the state of %s (%s, see above)", target, serverbin.ExitText(ssh.ExitCode(err), ReadTimeout))
	}
	r, err := Decode(out, target)
	if err != nil {
		return nil, "", "", err
	}
	source := res.Source
	if source == "explicit" {
		source = "flag"
	}
	return r, res.Apps, source, nil
}

// ReadTimeout bounds `remote status`: it asks docker about every container of
// every project, which a loaded host can take well past the usual 30 s over.
const ReadTimeout = 120

// Decode reads `remote status`'s answer. The report carries acme.json, so a
// bad one is described, never shown.
func Decode(out []byte, target string) (*Report, error) {
	if len(strings.TrimSpace(string(out))) == 0 {
		return nil, cli.Fail("the status probe on %s succeeded and reported nothing (its output was lost, or the login shell swallowed it)", target)
	}
	var r Report
	if err := json.Unmarshal(out, &r); err != nil {
		return nil, cli.Fail("the status probe on %s answered with %d bytes that are not a whole report — truncated, or not this kasbah's (not shown: they carry acme.json, which holds private key material)", target, len(out))
	}
	return &r, nil
}

// JudgeMarker is status's reading of a marker: there, and a JSON object.
func JudgeMarker(body []byte, path, target string) error {
	if len(body) == 0 {
		return cli.Fail("%s on %s is empty — kasbah server init did not finish, or something truncated it", path, target)
	}
	v, err := jv.ParseOne(body)
	if _, ok := v.(*jv.Map); err != nil || !ok {
		return cli.Fail("%s on %s is not a JSON object — look at it before running anything else against this server", path, target)
	}
	return nil
}

type run struct {
	w      io.Writer
	out    *cli.Output
	now    time.Time
	target string
	apps   string
	source string
	r      *Report

	mk                                      *jv.Map
	mkApps, mkData, mkVersion, mkCPU, mkMem string
	bkEnabled                               bool
	bkBase, bkAt, bkJitter                  string

	acme      []byte
	acmeReady bool
	dash      string
	trusted   bool
}

// Run is the command.
func Run(c Ctx, o Options) error {
	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	r, apps, source, err := s.Read(o.Apps)
	if err != nil {
		return err
	}
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	x := &run{w: c.Out.Stdout, out: c.Out, now: now(), target: o.Target, apps: apps, source: source, r: r}
	if err := x.readMarker(); err != nil {
		return err
	}
	x.decode()
	mm, _, _ := strings.Cut(x.mkVersion, ".")
	ours, _, _ := strings.Cut(c.Version, ".")
	if isDigits(mm) && isDigits(ours) && mm != ours {
		c.Out.Warn("the marker was written by kasbah %s and this is kasbah %s", x.mkVersion, c.Version)
		c.Out.Warn("different majors — fields this version does not know about are not shown")
	}
	x.print()
	return nil
}

var reDigits = regexp.MustCompile(`^[0-9]+$`)

func isDigits(s string) bool { return reDigits.MatchString(s) }

func b64(s string) []byte {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return nil
	}
	return b
}

// field is `jq -r '.k // "" | tostring'`.
func field(m *jv.Map, path ...any) string {
	v, ok := jv.Get(m, path...)
	if !ok {
		return ""
	}
	return strings.TrimRight(jv.ToString(jv.Alt(v, "")), "\n")
}

func (x *run) readMarker() error {
	path := marker.Path(x.apps)
	switch x.r.AppsState {
	case "dir", "absent":
	case "notdir":
		return cli.Fail("%s on %s exists and is not a directory — point status elsewhere with --apps-path=<dir>", x.apps, x.target)
	default:
		return cli.Fail("%s on %s is in a state the probe called '%s', which this kasbah does not know", x.apps, x.target, x.r.AppsState)
	}
	switch x.r.MarkerState {
	case "ok":
	case "absent":
		return cli.Failf(cli.ExitNoRemoteState, "%s has no server marker at %s", x.target, path)
	case "notfile":
		return cli.Fail("%s on %s exists and is not a regular file", path, x.target)
	case "empty":
		return cli.Fail("%s on %s is empty — kasbah server init did not finish, or something truncated it", path, x.target)
	default:
		return cli.Fail("%s on %s could not be read", path, x.target)
	}
	body, err := base64.StdEncoding.DecodeString(x.r.Marker)
	if err != nil {
		return cli.Fail("the status probe on %s sent %s back as something that is not base64", x.target, path)
	}
	if err := JudgeMarker(body, path, x.target); err != nil {
		return err
	}
	v, _ := jv.ParseOne(body)
	m := v.(*jv.Map)
	x.mkApps, x.mkData, x.mkVersion = field(m, "apps_path"), field(m, "data_path"), field(m, "kasbah_version")
	x.mkCPU, x.mkMem = field(m, "cpu_limit"), field(m, "mem_limit")
	x.bkEnabled = field(m, "backup", "enabled") == "true"
	x.bkBase, x.bkAt, x.bkJitter = field(m, "backup", "repo_base"), field(m, "backup", "at"), field(m, "backup", "jitter")
	return nil
}

func (x *run) decode() {
	x.acme = b64(x.r.Acme)
	if apex, err := serverinit.DashboardApex(string(b64(x.r.Shared))); err == nil && apex != "" {
		x.dash = "traefik." + apex
	}
	x.trusted = x.mkData != "" && x.r.DataPath == x.mkData
	// A data path directly under <apps> is not a project.
	if rest, ok := strings.CutPrefix(x.mkData, x.apps+"/"); ok && rest != "" && !strings.Contains(rest, "/") {
		var ps []Project
		for _, p := range x.r.Projects {
			if p.Name != rest {
				ps = append(ps, p)
			}
		}
		x.r.Projects = ps
	}
}

func (x *run) p(format string, a ...any) { fmt.Fprintf(x.w, format, a...) }

func or(s, def string) string {
	if s == "" {
		return def
	}
	return s
}

func (x *run) print() {
	x.p("VPS: %s (connected)\n", x.target)
	if x.r.DockerServer != "" {
		x.p("Docker: %s, Compose: %s\n", x.r.DockerServer, or(x.r.ComposeVersion, "unknown"))
	} else {
		x.p("Docker: unavailable — %s\n", or(x.r.DockerError, "no docker command on the remote"))
	}
	x.p("Root: %s (%s)  Data: %s\n", x.apps, x.source, or(x.mkData, "unknown"))
	x.p("Marker: kasbah %s, cpu %s, mem %s\n", or(x.mkVersion, "unknown"), or(x.mkCPU, "unknown"), or(x.mkMem, "unknown"))
	x.printDisk()
	if x.mkApps != "" && x.mkApps != x.apps {
		x.out.Warn("the marker records apps_path=%s, and this status read %s", x.mkApps, x.apps)
	}
	x.p("\n")
	x.printTraefik()
	x.printCerts()
	if x.dash != "" {
		x.p("  Dashboard: %s\n", x.dash)
		x.certLine(x.dash, "      ")
	}
	x.p("\n")
	x.printMail()
	x.p("\n")
	x.printBackup()
	x.p("\n")
	x.printProjects()
}

// HumanKB is a df size in KiB, one decimal past K.
func HumanKB(v string) string {
	if !isDigits(v) {
		return "?"
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return "?"
	}
	unit, div := "K", int64(1)
	switch {
	case n >= 1073741824:
		unit, div = "T", 1073741824
	case n >= 1048576:
		unit, div = "G", 1048576
	case n >= 1024:
		unit, div = "M", 1024
	}
	if div == 1 {
		return v + unit
	}
	t := n * 10 / div
	return fmt.Sprintf("%d.%d%s", t/10, t%10, unit)
}

// DiskSentence turns df's line into a sentence and the "fs on mount" it is.
func DiskSentence(line string) (sentence, fs string, ok bool) {
	f := strings.Fields(line)
	if len(f) < 4 || !isDigits(f[1]) || !isDigits(f[2]) || !isDigits(f[3]) {
		return "", "", false
	}
	cap, mount := "?", "?"
	if len(f) > 4 {
		cap = f[4]
	}
	if len(f) > 5 {
		mount = strings.Join(f[5:], " ")
	}
	return fmt.Sprintf("%s of %s used (%s), %s free — %s on %s", HumanKB(f[2]), HumanKB(f[1]), cap, HumanKB(f[3]), f[0], mount),
		f[0] + " on " + mount, true
}

func (x *run) printDisk() {
	appsFS := ""
	switch x.r.AppsDisk.State {
	case "ok":
		if s, fs, ok := DiskSentence(x.r.AppsDisk.Line); ok {
			x.p("Disk: %s  %s\n", x.apps, s)
			appsFS = fs
		} else {
			x.p("Disk: %s  unknown — df answered in a shape this kasbah does not read\n", x.apps)
		}
	case "absent":
		x.p("Disk: %s  unknown — the path is not there\n", x.apps)
	default:
		x.p("Disk: %s  unknown — df did not answer\n", x.apps)
	}
	if !x.trusted {
		x.p("      %s  not read — %s\n", or(x.mkData, "<no data path in the marker>"),
			"the probe and the marker disagree about where the data path is")
		return
	}
	switch x.r.DataDisk.State {
	case "ok":
		s, fs, ok := DiskSentence(x.r.DataDisk.Line)
		switch {
		case !ok:
			x.p("      %s  unknown — df answered in a shape this kasbah does not read\n", x.mkData)
		case appsFS != "" && fs == appsFS:
			x.p("      %s  the same filesystem\n", x.mkData)
		default:
			x.p("      %s  %s\n", x.mkData, s)
		}
	case "absent":
		x.p("      %s  unknown — the path is not there\n", x.mkData)
	default:
		x.p("      %s  unknown — df did not answer\n", x.mkData)
	}
}

func (x *run) printCerts() {
	path := or(x.mkData, "<data>") + "/traefik/letsencrypt/acme.json"
	x.acmeReady = false
	if !x.trusted {
		x.p("  Certificates: not read — the probe and the marker disagree about the data path\n")
		return
	}
	switch x.r.AcmeState {
	case "file":
	case "absent":
		x.p("  Certificates: no store at %s — this Traefik is not the one kasbah prepared\n", path)
		return
	case "empty":
		x.p("  Certificates: the store at %s is empty — nothing has been issued yet\n", path)
		return
	case "unreadable":
		x.p("  Certificates: %s cannot be read by %s — it is mode 600 and owned by the deploy user\n", path, x.target)
		return
	default:
		x.p("  Certificates: %s is %s, not a regular file\n", path, x.r.AcmeState)
		return
	}
	if len(x.acme) == 0 {
		x.p("  Certificates: %s did not come back as readable bytes\n", path)
		return
	}
	l := acme.Find(x.acme, "", x.now)
	switch l.State {
	case "notjson":
		x.p("  Certificates: %s does not parse as JSON (its bytes are not shown — it holds private key material)\n", path)
	case "noresolver":
		x.p("  Certificates: %s has no '%s' store — the schema has shifted, or this Traefik uses another resolver\n", path, acme.Resolver)
	case "notarray":
		x.p("  Certificates: %s holds a '%s' whose Certificates is a %s, not a list\n", path, acme.Resolver, l.Kind)
	case "empty":
		x.p("  Certificates: none issued yet (the store at %s is empty)\n", path)
	default:
		x.p("  Certificates: %d in %s\n", l.Count, path)
		x.acmeReady = true
	}
}

func (x *run) certLine(host, indent string) {
	if !x.acmeReady {
		return
	}
	l := acme.Find(x.acme, host, x.now)
	via := ""
	if l.Main != host {
		via = " (as a SAN of " + l.Main + ")"
	}
	switch l.State {
	case "found":
	case "nomatch":
		x.p("%sno certificate — Traefik issues one when the hostname resolves here\n", indent)
		return
	case "nocert":
		x.p("%sthe store entry carries no certificate field\n", indent)
		return
	case "notbase64":
		x.p("%sthe store entry is not base64\n", indent)
		return
	case "nopem":
		x.p("%sthe store entry is not a certificate openssl reads\n", indent)
		return
	default:
		x.p("%sno certificate (%s)\n", indent, l.State)
		return
	}
	issuer := or(l.Issuer, "unknown issuer")
	switch {
	case l.Expired:
		x.p("%scertificate%s EXPIRED %d day(s) ago (%s, %s) — renewal has been failing\n", indent, via, l.Days, l.NotAfter, issuer)
	case l.Days <= 14:
		x.p("%scertificate%s expires in %d day(s) (%s, %s) — Traefik renews at 30, so renewal has missed its window\n", indent, via, l.Days, l.NotAfter, issuer)
	default:
		x.p("%scertificate%s valid for %d more day(s) (until %s, %s)\n", indent, via, l.Days, l.NotAfter, issuer)
	}
}

func restartsClause(r string) string {
	if r == "" || r == "0" {
		return ""
	}
	return ", " + r + " restart(s)"
}

func (x *run) printMail() {
	switch x.r.MailDir {
	case "absent":
		x.p("Mail: not installed — no %s/mail (kasbah server init --with-mail scaffolds it)\n", x.apps)
		return
	case "notdir":
		x.p("Mail: %s/mail exists and is not a directory\n", x.apps)
		return
	}
	x.p("Mail: %s/mail\n", x.apps)
	for _, s := range []struct {
		name string
		st   Stack
	}{{"mail-dms", x.r.MailDMS}, {"mail-cypht", x.r.MailWeb}} {
		switch s.st.State {
		case "absent":
			x.p("  %-16s absent — the stack is scaffolded and not running\n", s.name)
		case "nodocker":
			x.p("  %-16s unknown — docker did not answer\n", s.name)
		default:
			x.p("  %-16s %s (%s)%s\n", s.name, s.st.State, or(s.st.Health, "none"), restartsClause(s.st.Restarts))
		}
	}
	path := mailreg.Path(x.apps)
	if x.r.RegistryState != "file" {
		x.p("  registry %s: %s — the one record of which domains this stack serves\n", path, x.r.RegistryState)
		return
	}
	reg, err := mailreg.Parse(b64(x.r.Registry), path)
	if err != nil {
		x.p("  registry %s\n", strings.ReplaceAll(err.Error(), "\n", "; "))
		return
	}
	x.p("  Primary: %s   Domains: %s\n", reg.Primary, strings.Join(reg.Domains, " "))
	for _, d := range []string{"mail." + reg.Primary, "webmail." + reg.Primary} {
		x.p("  %s\n", d)
		x.certLine(d, "      ")
	}
}

func (x *run) printBackup() {
	dir := x.apps + "/.kasbah/backup"
	rec := dir + "/state/status"
	b := x.r.Backup
	if !x.bkEnabled {
		x.p("Backup: not configured — the marker records none (kasbah server init --with-backup ships snapshots off-box)\n")
		if b.Dir != "absent" {
			x.p("  %-16s %s is %s, and no marker entry describes it\n", "stack", dir, b.Dir)
		}
		return
	}
	r := backuprec.Read(b.Dir, b.Record, b.Content(), b.Now)
	ago, due := backuprec.Ago(r.Age), backuprec.Ago(r.Overdue)
	since, nextin := "", ""
	if r.Since >= 0 {
		since = backuprec.Ago(max(r.Now-r.Since, 0))
	}
	if r.NextRun > 0 {
		nextin = backuprec.Ago(max(r.NextRun-r.Now, 0))
	}
	clock := ""
	if r.Clock == "local" {
		clock = " (judged against this machine's clock: the probe did not report the server's)"
	}
	ran := strings.TrimPrefix(r.Repos, " ")
	if x.bkBase != "" {
		x.p("Backup: %s  daily at %s plus %ss jitter%s\n", Redact(x.bkBase), or(x.bkAt, "unknown"), or(x.bkJitter, "?"), clock)
	} else {
		x.p("Backup: enabled, and the marker records no repository base — nothing on this server says where the snapshots go%s\n", clock)
	}
	st := b.Container
	switch st.State {
	case "absent":
		x.p("  %-16s absent — the stack is scaffolded and no container is running it\n", "kasbah-backup")
	case "nodocker":
		x.p("  %-16s unknown — there is no docker on this server\n", "kasbah-backup")
	case "nodaemon":
		x.p("  %-16s unknown — the docker daemon did not answer\n", "kasbah-backup")
	case "notours":
		x.p("  %-16s a container of that name is running here and is not in the kasbah-backup\n", "kasbah-backup")
		x.p("  %-16s compose project — kasbah's scheduler cannot take a name something else\n", "")
		x.p("  %-16s already holds, so nothing is being shipped off-box\n", "")
	default:
		x.p("  %-16s %s (%s)%s\n", "kasbah-backup", st.State, or(st.Health, "none"), restartsClause(st.Restarts))
	}

	switch r.Verdict {
	case backuprec.NoStack:
		x.p("  %-16s none — %s %s, so nothing here says whether a backup has ever run\n", "last run", dir, r.Reason)
	case backuprec.NoRecord:
		x.p("  %-16s none — %s is not there, and the scheduler writes it as its first act\n", "last run", rec)
	case backuprec.Unreadable:
		x.p("  %-16s unknown — %s %s\n", "last run", rec, r.Reason)
	case backuprec.Unparsed:
		reason := ""
		if r.Reason != "" {
			reason = " (it " + r.Reason + ")"
		}
		x.p("  %-16s unknown — %s is not a record this kasbah reads%s\n", "last run", rec, reason)
	case backuprec.Never:
		going := ""
		if r.State == "running" && since != "" {
			going = ", and a run has been going for " + since
		}
		x.p("  %-16s none yet — the scheduler is %s%s\n", "last run", r.State, going)
		if nextin != "" {
			x.p("  %-16s in %s\n", "next run", nextin)
		}
	case backuprec.Failed:
		x.p("  %-16s FAILED %s ago — repositories backed up: %s (docker logs %s says why)\n", "last run", ago, or(ran, "-"), "kasbah-backup")
		if r.Overdue != 0 {
			x.p("  %-16s %s past its own deadline in state '%s' — nothing has run since\n", "scheduler", due, r.State)
		}
		if nextin != "" {
			x.p("  %-16s in %s\n", "next run", nextin)
		}
	case backuprec.Overdue:
		forClause := ""
		if since != "" {
			forClause = " (for " + since + ")"
		}
		if st.State == "running" {
			x.p("  %-16s %s past its own deadline in state '%s'%s — a run that never returned, or a sleep that never woke\n", "scheduler", due, r.State, forClause)
		} else {
			x.p("  %-16s %s past its own deadline in state '%s'%s — the container is %s, so nothing has moved it on\n", "scheduler", due, r.State, forClause, st.State)
		}
		if r.Age >= 0 {
			x.p("  %-16s %s %s ago — repositories: %s\n", "last run", r.Status, ago, or(ran, "-"))
		} else {
			x.p("  %-16s none yet\n", "last run")
		}
	case backuprec.OK:
		if ran == "" || ran == "none" {
			x.p("  %-16s ok %s ago, and shipped nothing — no repository had anything to back up\n", "last run", ago)
		} else {
			x.p("  %-16s ok %s ago — repositories: %s\n", "last run", ago, ran)
		}
		if nextin != "" {
			x.p("  %-16s in %s\n", "next run", nextin)
		}
	}

	repos := backuprec.RepoSet(b.Projects, x.r.MailDir == "dir")
	missing, orphan := backuprec.Diff(repos, b.HasPass)
	if len(repos) == 0 {
		x.p("  %-16s none — nothing under %s to back up yet\n", "repositories", x.apps)
	} else {
		x.p("  %-16s %s\n", "repositories", strings.Join(repos, " "))
	}
	if len(missing) > 0 {
		x.p("  %-16s %s — not backed up until kasbah server init %s --with-backup supplies one\n", "no password", strings.Join(missing, " "), x.target)
	}
	if len(orphan) > 0 {
		x.p("  %-16s %s — a password for a repository no project files into any more; kasbah keeps it, because it is what decrypts the snapshots already off-box\n", "orphan password", strings.Join(orphan, " "))
	}
}

// Redact hides the password in a URL's userinfo: `rest:https://u:p@h/` is
// shown `rest:https://u:***@h/`. A string with no `://` or no `@` is itself.
func Redact(in string) string {
	i := strings.Index(in, "://")
	if i < 0 {
		return in
	}
	scheme, auth := in[:i+3], in[i+3:]
	tail := ""
	if j := strings.Index(auth, "/"); j >= 0 {
		auth, tail = auth[:j], auth[j:]
	}
	if at := strings.LastIndex(auth, "@"); at >= 0 {
		if user, _, found := strings.Cut(auth[:at], ":"); found {
			auth = user + ":***@" + auth[at+1:]
		}
	}
	return scheme + auth + tail
}

func (x *run) printTraefik() {
	t := x.r.Traefik
	if !t.Present {
		if !x.r.HaveDocker || x.r.DockerError != "" || x.r.DockerServer == "" {
			x.p("Traefik: unknown — docker did not answer\n")
		} else {
			x.p("Traefik: absent — no container in compose project 'traefik'\n")
		}
		return
	}
	if t.State == "" || t.Health == "" || t.Image == "" {
		x.p("Traefik: unknown — docker named a container and then did not describe it\n")
		x.p("  state %s / health %s / image %s\n", or(t.State, "<none>"), or(t.Health, "<none>"), or(t.Image, "<none>"))
		return
	}
	if t.Health == "none" {
		x.p("Traefik: %s (no healthcheck)\n", t.State)
	} else {
		x.p("Traefik: %s (%s)\n", t.State, t.Health)
	}
	id := t.ImageID
	if len(id) > 19 {
		id = id[:19]
	}
	x.p("  Image: %s (%s)\n", t.Image, id)
	x.p("  Container: %s\n", t.Container)
}

func (x *run) dockerOK() bool {
	return x.r.HaveDocker && x.r.DockerError == "" && x.r.DockerServer != ""
}

func (x *run) printProjects() {
	x.p("Projects:\n")
	if len(x.r.Projects) == 0 {
		x.p("  none — no project directory under %s\n", x.apps)
		return
	}
	width := 14
	for _, p := range x.r.Projects {
		width = max(width, len(p.Name))
	}
	for _, p := range x.r.Projects {
		version, deployed, note := "-", "", ""
		switch p.LogState {
		case "ok":
			if e := vlog.Parse(p.Log); e.OK {
				version, deployed = e.Version, e.Action+" "+e.Time
				if e.Kasbah != "" {
					deployed += " (kasbah " + e.Kasbah + ")"
				}
			} else {
				version, note = "?", "versions.log's last line is not a kasbah entry: "+p.Log
			}
		case "missing":
			note = "no versions.log — never deployed by kasbah, or dropped"
		case "empty":
			note = "versions.log is empty"
		case "notfile":
			note = "versions.log exists and is not a regular file"
		case "unreadable":
			note = "versions.log cannot be read by the ssh user"
		case "noaccess":
			note = "the directory cannot be read by the ssh user — a deploy that ran as root leaves this"
		case "notdir":
			note = "not a directory — kasbah deploys into directories only"
		default:
			note = "unknown versions.log state '" + p.LogState + "'"
		}
		var state string
		switch {
		case p.LogState == "notdir":
			state = "-"
		case !x.dockerOK():
			state = "?"
		case p.Total == 0:
			state = "no containers"
		case p.Running == p.Total:
			state = fmt.Sprintf("%d/%d running", p.Running, p.Total)
		case p.Running == 0:
			state = fmt.Sprintf("0/%d stopped", p.Total)
		default:
			state = fmt.Sprintf("%d/%d partial", p.Running, p.Total)
		}
		x.p("  %-*s %-14s %-10s %s\n", width, p.Name, state, version, or(deployed, note))
		x.printHosts(p)
		x.printContainers(p)
	}
}

var reHost = regexp.MustCompile("Host\\(`([^`]+)`\\)")

// FragmentHosts is every Host() a fragment's routers claim, each once, in
// router order; ok is false when the fragment does not parse.
func FragmentHosts(content []byte) (hosts []string, ok bool) {
	docs, err := yamlx.Load(content)
	if err != nil || len(docs) > 1 {
		return nil, false
	}
	var doc jv.Value
	if len(docs) == 1 {
		doc = docs[0]
	}
	rv, ok := jv.Get(doc, "http", "routers")
	if !ok {
		return nil, false
	}
	routers, isMap := rv.(*jv.Map)
	if _, isBool := rv.(bool); isBool {
		return nil, false
	}
	if !isMap {
		return nil, true
	}
	seen := map[string]bool{}
	for _, k := range routers.Keys() {
		v, _ := routers.Get(k)
		rule, ok := jv.Get(v, "rule")
		if !ok {
			continue
		}
		for _, m := range reHost.FindAllStringSubmatch(jv.ToString(jv.Alt(rule, "")), -1) {
			if !seen[m[1]] {
				seen[m[1]] = true
				hosts = append(hosts, m[1])
			}
		}
	}
	return hosts, true
}

func (x *run) printHosts(p Project) {
	path := x.apps + "/traefik/dynamic/" + p.Name + ".yml"
	switch p.FragState {
	case "ok":
	case "absent":
		if p.LogState == "ok" || p.Total != 0 {
			x.p("      no Traefik fragment at %s — nothing routes to this project\n", path)
		}
		return
	case "empty":
		x.p("      %s is empty — nothing routes to this project\n", path)
		return
	case "unreadable":
		x.p("      %s cannot be read by the ssh user\n", path)
		return
	case "notfile":
		x.p("      %s exists and is not a regular file\n", path)
		return
	default:
		x.p("      unknown fragment state %s\n", p.FragState)
		return
	}
	hosts, ok := FragmentHosts(b64(p.Frag))
	if !ok {
		x.p("      %s does not parse as YAML, so this project's domain cannot be read\n", path)
		return
	}
	if len(hosts) == 0 {
		x.p("      %s declares no Host() rule, so this project claims no domain\n", path)
		return
	}
	for _, h := range hosts {
		x.p("      %s\n", h)
		x.certLine(h, "          ")
	}
}

func (x *run) printContainers(p Project) {
	if len(p.Containers) == 0 {
		return
	}
	odd := false
	for _, c := range p.Containers {
		if c.State != "running" || (c.Health != "" && c.Health != "none" && c.Health != "healthy") {
			odd = true
		}
	}
	if !odd {
		x.p("      %d container(s), all running and none unhealthy\n", len(p.Containers))
		return
	}
	for _, c := range p.Containers {
		x.p("      %-24s %s (%s)\n", c.Name, c.State, or(c.Health, "none"))
	}
}
