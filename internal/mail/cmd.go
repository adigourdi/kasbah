package mail

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// ErrHelp is -h/--help: print the usage and leave 0.
var ErrHelp = errors.New("help")

const AddUsage = `Usage: kasbah server add-mail-domain USER@HOST <domain>

Joins <domain> to the VPS's shared mail stack (docs/mail.md → Multi-domain).
Two things change: the domain joins domains: in <apps>/mail/kasbah.yml — the
registry, and the only thing asked whether this stack serves a domain — and
postmaster@<domain> is aliased to the primary mailbox in docker-mailserver's
postfix-virtual.cf, which is also what makes Postfix accept mail for it.

Adding a domain twice is a no-op that says so.

No router is added: mail.<primary> and webmail.<primary> are the stack's
hostnames and an app domain needs no MX of its own — it needs an MX record
pointing at mail.<primary>. Run ` + "`kasbah server mail-setup-guide USER@HOST`" + `
for the records this domain needs, and generate its DKIM keys on the VPS.
`

const GuideUsage = `Usage: kasbah server mail-setup-guide USER@HOST

Prints the mail stack's post-install walkthrough, rendered for this server:
its primary domain, every domain in <apps>/mail/kasbah.yml, and the DNS
records each of them needs. Ported from the original project's mail/SETUP.md.

Read-only. It reads the registry and changes nothing on the server.
`

// Options is either command's command line; Domain is add-mail-domain's.
type Options struct {
	Cmd    string
	Target string
	Domain string
}

// Parse reads `server add-mail-domain` (cmd "add-mail-domain") or `server
// mail-setup-guide` arguments.
func Parse(cmd string, args []string) (Options, error) {
	o := Options{Cmd: cmd}
	add := cmd == "add-mail-domain"
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			takes := "USER@HOST"
			if add {
				takes = "USER@HOST and a domain"
			}
			return o, cli.Fail("server %s: unknown flag '%s' (this command takes %s)", cmd, name, takes)
		case o.Target == "":
			o.Target = strings.TrimSuffix(a, "\r")
		case add && o.Domain == "":
			o.Domain = strings.TrimSuffix(a, "\r")
		case add:
			return o, cli.Fail("server add-mail-domain: unexpected argument '%s' (USER@HOST and one domain)", a)
		default:
			return o, cli.Fail("server mail-setup-guide: unexpected argument '%s' (USER@HOST is given once)", a)
		}
	}
	if o.Target == "" {
		why := "the guide is rendered for one server's registry"
		if add {
			why = "the user kasbah deploys as is not optional"
		}
		return o, cli.Fail("server %s: USER@HOST is required (%s)", cmd, why)
	}
	if add {
		if o.Domain == "" {
			return o, cli.Fail("server add-mail-domain: a domain is required (kasbah server add-mail-domain %s example.com)", o.Target)
		}
		// The FQDN alphabet cannot carry a newline, quote or colon into YAML.
		if !initproject.IsFQDN(o.Domain) {
			return o, cli.Fail("server add-mail-domain: '%s' is not a domain name (it goes under domains: in the mail registry, and every entry there is one)", o.Domain)
		}
	}
	return o, nil
}

// Session is a connection to a prepared server whose kasbah answers.
type Session interface {
	// Paths is the marker's apps and data paths, the binary ensured first.
	Paths() (apps, data string, err error)
	// Remote runs `kasbah remote ARGS…` bounded, stdin the payload or nil.
	Remote(stdin []byte, args ...string) ([]byte, int)
	Close()
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out       *cli.Output
	Templates fs.FS
	Dial      func(target string) (Session, error)
}

// Facts is a step's key=value report, \r stripped.
func Facts(out string) map[string]string { return remote.KV([]byte(out)) }

// Read is the shared read, one round trip, nothing written.
func Read(s Session, target, apps, data string) (*ReadReport, error) {
	body, rc := s.Remote(nil, "mail", "read", apps, data)
	if rc != 0 {
		return nil, cli.Fail("could not read the mail stack on %s (the remote step exited %d, see above)", target, rc)
	}
	var r ReadReport
	if err := json.Unmarshal(body, &r); err != nil {
		return nil, cli.Fail("the mail read on %s reported nothing kasbah can use — the step was truncated, or the server's kasbah rejected it", target)
	}
	return &r, nil
}

// Decode is a read's file body.
func Decode(b64, what, target string) (string, error) {
	b, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return "", cli.Fail("the mail read on %s returned a %s that does not decode", target, what)
	}
	return string(b), nil
}

// stack is the registry of a stack that is there to act on.
func stack(out *cli.Output, s Session, target string) (apps, data string, r *ReadReport, reg *mailreg.Registry, err error) {
	if apps, data, err = s.Paths(); err != nil {
		return
	}
	if r, err = Read(s, target, apps, data); err != nil {
		return
	}
	switch r.Dir {
	case "dir":
	case "absent", "notdir":
		err = cli.Fail("there is no mail stack at %s/mail on %s", apps, target).Cont(
			"that directory is where the shared stack lives — its compose file, its .env",
			"and its registry. Install it with:",
			"  kasbah server init "+target+" --with-mail")
		return
	default:
		err = cli.Fail("the mail read on %s reported dir='%s', which this kasbah does not know", target, r.Dir)
		return
	}
	if !r.Env {
		out.Warn("%s/mail on %s has no .env, so that stack cannot start as it stands", apps, target)
		out.Warn("compose reads MAIL_HOSTNAME, DOMAIN and DATA_PATH out of it — re-run:")
		out.Warn("  kasbah server init %s --with-mail", target)
	}
	body, err := Decode(r.Registry, "registry", target)
	if err != nil {
		return
	}
	reg, err = ParseRegistry(body, apps, target)
	return
}

// ParseRegistry is mailreg.Parse with what each refusal means here.
func ParseRegistry(body, apps, target string) (*mailreg.Registry, error) {
	reg, err := mailreg.Parse([]byte(body), mailreg.Path(apps)+" on "+target)
	var e *cli.Error
	if err != nil && errors.As(err, &e) {
		switch {
		case errors.Is(err, mailreg.ErrUnparseable):
			e.Cont("kasbah reproduces what is in that file rather than regenerating it, so a",
				"file it cannot parse is one it will not rewrite. Fix it and re-run.")
		case strings.TrimSpace(body) == "":
			e.Cont("Re-run:  kasbah server init " + target + " --with-mail")
		}
	}
	return reg, err
}

// Run is either command.
func Run(c Ctx, o Options) error {
	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	defer s.Close()
	apps, data, r, reg, err := stack(c.Out, s, o.Target)
	if err != nil {
		return err
	}
	if o.Cmd != "add-mail-domain" {
		Guide(c.Out.Stdout, GuideData{Target: o.Target, Apps: apps, Data: data,
			Primary: reg.Primary, Domains: reg.Domains, HostAddr: r.HostAddr})
		return nil
	}
	return add(c, s, o, apps, data, r, reg)
}

func add(c Ctx, s Session, o Options, apps, data string, r *ReadReport, reg *mailreg.Registry) error {
	out, d := c.Out, o.Domain
	if d == reg.Primary {
		out.Info("%s is the primary domain of the mail stack on %s — nothing to do", d, o.Target)
		out.Info("  it is the MX target every other domain points at, served since `server init --with-mail`,")
		out.Info("  and postmaster@%s is the mailbox the other domains' postmaster aliases deliver to", d)
		return nil
	}
	known := reg.Serves(d)
	// The alias is what makes Postfix accept mail for d: DMS builds its
	// accepted domains out of postfix-accounts.cf and postfix-virtual.cf.
	alias := "postmaster@" + d + " postmaster@" + reg.Primary
	aliases, err := Decode(r.Aliases, "postfix-virtual.cf", o.Target)
	if err != nil {
		return err
	}
	aliased := false
	for _, l := range strings.Split(aliases, "\n") {
		if strings.TrimSuffix(l, "\r") == alias {
			aliased = true
			break
		}
	}
	if known && aliased {
		out.Info("%s is already served by the mail stack on %s — nothing to do", d, o.Target)
		out.Info("  registry: %s lists it under domains:", mailreg.Path(apps))
		out.Info("  alias:    %s", alias)
		return nil
	}
	domains := reg.Domains
	if !known {
		domains = append(append([]string{}, domains...), d)
	}
	send := alias
	if aliased {
		send = ""
	}
	registry, err := RenderRegistry(c.Templates, reg.Primary, domains)
	if err != nil {
		return err
	}
	body, _ := json.Marshal(WriteBody{Registry: registry, Alias: send})
	size, sum := remote.Digest(body)
	res, rc := s.Remote(body, "mail", "write", apps, data, size, sum)
	if rc != 0 {
		return cli.Fail("could not write the mail registry on %s (the remote step exited %d, see above) — nothing else was changed", o.Target, rc)
	}
	f := Facts(string(res))
	if f["registry"] != "written" {
		return cli.Fail("the registry write on %s reported registry='%s', which this kasbah does not know — %s may be half-written", o.Target, f["registry"], mailreg.Path(apps))
	}
	if _, ok := f["alias"]; !ok {
		return cli.Fail("the mail write on %s reported no alias — the step was truncated, or the server's kasbah rejected it", o.Target)
	}

	out.Info("Added %s to the mail stack on %s", d, o.Target)
	out.Info("  registry: %s — domains: %s", mailreg.Path(apps), strings.Join(domains, " "))
	fix := fmt.Sprintf("  ssh %s 'docker exec mail-dms setup alias add postmaster@%s postmaster@%s'", o.Target, d, reg.Primary)
	switch f["alias"] {
	case "added":
		out.Info("  alias:    %s (docker-mailserver reloads on its own)", alias)
	case "skipped":
		out.Info("  alias:    postmaster@%s was already aliased", d)
	case "noconfig":
		out.Warn("docker-mailserver's config directory is not at %s/mail/dms/config yet, so", data)
		out.Warn("postmaster@%s has no alias. The stack has to have run once. Then:", d)
		out.Warn("%s", fix)
	default:
		out.Warn("could not append to %s/mail/dms/config/postfix-virtual.cf, so", data)
		out.Warn("postmaster@%s has no alias and Postfix will not accept mail for it.", d)
		out.Warn("docker-mailserver rewrites that file as root once its own helper has been used;")
		out.Warn("let it do this one too:")
		out.Warn("%s", fix)
	}
	followup(out.Stdout, o.Target, d, reg.Primary, data)
	return nil
}

// followup is what is left that is not kasbah's: DKIM keys, the signing
// block, DNS.
func followup(w io.Writer, target, d, primary, data string) {
	fmt.Fprintf(w, "\nStill to do for %s — none of it is kasbah's to do:\n\n", d)
	fmt.Fprintf(w, "1. Generate its DKIM keys, on the VPS:\n")
	fmt.Fprintf(w, "     ssh %s 'docker exec mail-dms setup config dkim keytype rsa     selector mail domain %s'\n", target, d)
	fmt.Fprintf(w, "     ssh %s 'docker exec mail-dms setup config dkim keytype ed25519 selector ed   domain %s'\n", target, d)
	fmt.Fprintf(w, "\n2. Add a block for it to the Rspamd signing override, which kasbah wrote\n")
	fmt.Fprintf(w, "   once for %s and never rewrites:\n", primary)
	fmt.Fprintf(w, "     %s/mail/dms/config/rspamd/override.d/dkim_signing.conf\n\n", data)
	fmt.Fprintf(w, "     domain {\n")
	fmt.Fprintf(w, "         %s {\n", d)
	fmt.Fprintf(w, "             selectors [\n")
	fmt.Fprintf(w, "                 { path = \"/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-%s.private.txt\"; selector = \"mail\"; },\n", d)
	fmt.Fprintf(w, "                 { path = \"/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-%s.private.txt\"; selector = \"ed\"; }\n", d)
	fmt.Fprintf(w, "             ]\n")
	fmt.Fprintf(w, "         }\n")
	fmt.Fprintf(w, "     }\n\n")
	fmt.Fprintf(w, "3. Publish its DNS records — MX, SPF, DMARC and the two DKIM keys:\n")
	fmt.Fprintf(w, "     kasbah server mail-setup-guide %s\n", target)
}

// SSH is the Session a real run uses: env's, whose Marker ensures the
// server binary before reading the marker.
type SSH struct{ *env.SSH }

// DialSSH connects; nothing runs until Paths.
func DialSSH(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

func (s SSH) Paths() (string, string, error) {
	m, err := s.SSH.Marker()
	if err != nil {
		return "", "", err
	}
	return m.AppsPath, m.DataPath, nil
}

func (s SSH) Remote(stdin []byte, args ...string) ([]byte, int) {
	cmd := s.Conn.Command(s.Bounded(args...)...)
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.Bytes(), ssh.ExitCode(err)
}

func (s SSH) Close() { s.Conn.Close() }
