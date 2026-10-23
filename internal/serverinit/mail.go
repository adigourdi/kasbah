package serverinit

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/initproject"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/tmpl"
)

// MailFiles are the kasbah-owned mail files compared and shipped, in order.
var MailFiles = []string{"compose.yml", "kasbah.yml", "_mail.yml", "cypht-nginx.conf", "fail2ban-jail.cf"}

// MailDest is where a mail file lands: _mail.yml in Traefik's watch directory,
// the jail in DMS's config mount, which DMS copies into Fail2ban at start.
func MailDest(o Options, rel string) string {
	switch rel {
	case "_mail.yml":
		return o.Apps + "/traefik/dynamic/_mail.yml"
	case "fail2ban-jail.cf":
		return o.Data + "/mail/dms/config/fail2ban-jail.cf"
	}
	return o.Apps + "/mail/" + rel
}

var reCrypt = regexp.MustCompile(`^\$6\$[^$]+\$[./A-Za-z0-9]+$`)

// MailTimeout is how long the start step waits for Cypht's healthcheck, which
// passes ~5 s after start on a workstation; the slack is for a slow VPS.
const MailTimeout = 180

// MailValues are what the mail stack is rendered and seeded with.
type MailValues struct {
	Primary string
	// Origin is "reused" (the registry's) or "domain" (--domain's apex).
	Origin  string
	Domains []string
	// Account is the postmaster line to seed, "" when the server has one.
	Account string
}

// Crypter hashes the postmaster password into a `$6$` SHA512-CRYPT string.
type Crypter func(pass string) (string, error)

// Crypt is a SHA512-CRYPT hash under a fresh salt.
func Crypt(pass string) (string, error) {
	salt, err := mail.Salt()
	if err != nil {
		return "", cli.Fail("could not draw a salt for the postmaster password: %v", err)
	}
	return mail.SHA512Crypt(pass, salt), nil
}

// CheckPostmaster refuses what cannot be hashed whole.
func CheckPostmaster(p string) error {
	switch {
	case p == "":
		return cli.Fail("server init: --postmaster-password= must not be empty")
	case strings.Contains(p, "\n"):
		return cli.Fail("server init: --postmaster-password= must not contain a newline — only the first line would be hashed")
	}
	return nil
}

// freshMail is a server with nothing of mail on it: an apps path not yet made.
var freshMail = mail.ReadReport{Dir: "absent", Accounts: "absent"}

// MailCurrent is the shipped files' bytes off the read, by name.
func MailCurrent(r *mail.ReadReport, target string) (map[string]string, error) {
	cur := map[string]string{}
	for rel, enc := range map[string]string{"compose.yml": r.Compose, "kasbah.yml": r.Registry, "_mail.yml": r.Fragment,
		"cypht-nginx.conf": r.Nginx, "fail2ban-jail.cf": r.Jail} {
		b, err := base64.StdEncoding.DecodeString(enc)
		if err != nil {
			return nil, cli.Fail("the mail stack read on %s returned a %s that does not decode", target, rel)
		}
		cur[rel] = string(b)
	}
	return cur, nil
}

// MailResolve reproduces the registry's two values, inventing the primary
// only for a server with no registry, and asks for the postmaster password
// only when no account is there to keep.
func MailResolve(out *cli.Output, p *prompt.Prompter, o Options, r *mail.ReadReport, registry, dashboard string, crypt Crypter) (MailValues, error) {
	var v MailValues
	switch r.Accounts {
	case "absent", "empty", "present":
	default:
		return v, cli.Fail("the mail stack read on %s reported accounts='%s', which this kasbah does not know", o.Target, r.Accounts)
	}
	switch r.Dir {
	case "absent", "dir":
	case "notdir":
		return v, cli.Fail("%s/mail on %s exists and is not a directory", o.Apps, o.Target).Cont(
			"that is where the shared mail stack lives — its compose file, its .env and",
			"its registry. Look at it, remove it, and re-run. Nothing has been changed.")
	default:
		return v, cli.Fail("the mail stack read on %s reported dir='%s', which this kasbah does not know", o.Target, r.Dir)
	}

	if strings.TrimSpace(registry) == "" {
		v.Primary, v.Origin = dashboard, "domain"
		if !initproject.IsFQDN(v.Primary) {
			return v, cli.Fail("server init: the mail stack's primary domain is '%s', which is not a domain name (it is the MX target, and mail.<domain> is what DMS's certificate is issued for)", v.Primary)
		}
		v.Domains = []string{v.Primary}
	} else {
		reg, err := mailreg.Parse([]byte(registry), mailreg.Path(o.Apps)+" on "+o.Target)
		var e *cli.Error
		if errors.Is(err, mailreg.ErrUnparseable) && errors.As(err, &e) {
			e.Cont("that file is the mail stack's registry — the one thing that says which",
				"domains this server's mail handles — and kasbah reproduces what is in it",
				"rather than regenerating it. Guessing past a file it cannot parse would",
				"move the MX hostname and abandon two certificates. Fix it, or remove it to",
				"start the registry over from --domain.")
		}
		if err != nil {
			return v, err
		}
		v.Primary, v.Origin, v.Domains = reg.Primary, "reused", reg.Domains
	}

	if r.Accounts == "present" {
		// Never a rotation: the file holds every mailbox on the server.
		if o.Postmaster != "" {
			out.Warn("--postmaster-password had no effect: postmaster is already in")
			out.Warn("%s/mail/dms/config/postfix-accounts.cf on %s, and init never rewrites that file", o.Data, o.Target)
			out.Warn("to change the password: ssh %s 'docker exec -it mail-dms setup email update postmaster@%s'", o.Target, v.Primary)
		}
		return v, nil
	}
	pass, err := p.Secret("postmaster-password",
		fmt.Sprintf("Password for postmaster@%s (seeded before DMS starts; DMS will not boot without an account)", v.Primary), o.Postmaster)
	if err != nil {
		return v, err
	}
	if err := CheckPostmaster(pass); err != nil {
		return v, err
	}
	hash, err := crypt(pass)
	if err != nil {
		return v, err
	}
	if !reCrypt.MatchString(hash) {
		return v, cli.Fail("could not produce a SHA512-CRYPT hash for the postmaster password").Cont(
			"expected one line of '$6$<salt>$<hash>'")
	}
	// The line docker-mailserver's own file provisioner writes.
	v.Account = "postmaster@" + v.Primary + "|{SHA512-CRYPT}" + hash
	return v, nil
}

// MailRender renders the shipped files (the YAML ones parsed: _mail.yml lands
// where Traefik watches) and the two seeds, "env" and "dkim".
func MailRender(fsys fs.FS, o Options, v MailValues) (map[string]string, error) {
	subst := map[string]string{
		"APPS_PATH":           o.Apps,
		"DATA_PATH":           o.Data,
		"MAIL_PRIMARY_DOMAIN": v.Primary,
		"MAIL_HOSTNAME":       "mail." + v.Primary,
		"MAIL_DOMAINS":        mail.DomainsBlock(v.Domains),
	}
	out := map[string]string{}
	for _, f := range [][2]string{{"compose.yml", "compose.yml"}, {"kasbah.yml", "kasbah.yml"}, {"_mail.yml", "_mail.yml"},
		{"cypht-nginx.conf", "cypht-nginx.conf"}, {"fail2ban-jail.cf", "fail2ban-jail.cf"},
		{"env", "env"}, {"rspamd-dkim-signing.conf", "dkim"}} {
		b, err := fs.ReadFile(fsys, "mail/"+f[0])
		if err != nil {
			return nil, cli.Fail("internal: this kasbah build carries no mail/%s template", f[0])
		}
		s, err := tmpl.Render(string(b), "mail "+f[0], subst)
		if err != nil {
			return nil, err
		}
		if strings.HasSuffix(f[0], ".yml") {
			if perr := tmpl.CheckYAML(s); perr != nil {
				return nil, cli.Fail("the rendered mail %s is not valid YAML — refusing to ship it", f[0]).Cont(
					perr.Error(),
					"a substituted value is the likely cause; this run rendered it with:",
					"  primary domain  "+v.Primary,
					"  domains         "+strings.Join(v.Domains, " "),
					fmt.Sprintf("  apps / data     %s, %s", o.Apps, o.Data))
			}
		}
		out[f[1]] = s
	}
	return out, nil
}

// mailCall is `kasbah remote mail ARGS…` on the server.
func (s *session) mailCall(stdin []byte, bounded bool, args ...string) (string, int) {
	return s.remote(stdin, bounded, append([]string{"mail"}, args...)...)
}

// mailLayout ships the tree, .env and seeds in one checked payload.
func (s *session) mailLayout(o Options, rendered map[string]string, v MailValues) (Facts, error) {
	body, _ := json.Marshal(mail.LayoutBody{Env: rendered["env"], DKIM: rendered["dkim"], Account: v.Account})
	size, sum := remote.Digest(body)
	res, rc := s.mailCall(body, true, "layout", o.Apps, o.Data, size, sum)
	if rc != 0 {
		return nil, stepFailed("lay out the mail stack", s.target, rc)
	}
	return checked("the mail layout step", s.target, res, "mail_layout", "mail_env", "mail_account", "mail_dkim_seed")
}

// MailChanged is the files whose rendered bytes differ from the server's.
func MailChanged(rendered, cur map[string]string) []string {
	var changed []string
	for _, rel := range MailFiles {
		if rendered[rel] != cur[rel] {
			changed = append(changed, rel)
		}
	}
	return changed
}

// mailSync ships the files whose bytes differ.
func (s *session) mailSync(o Options, rendered, cur map[string]string) ([]string, error) {
	changed := MailChanged(rendered, cur)
	for _, rel := range changed {
		dest := MailDest(o, rel)
		if _, rc := s.send([]byte(rendered[rel]), "write", dest); rc != 0 {
			return nil, cli.Fail("could not ship the mail %s to %s:%s", rel, s.target, dest)
		}
	}
	return changed, nil
}

// mailStart is unbounded by RunTimeout: a first start pulls ~1.6 GB, and the
// Cypht wait is bounded on the server.
func (s *session) mailStart(o Options) (Facts, error) {
	res, rc := s.mailCall(nil, false, "start", o.Apps, strconv.Itoa(MailTimeout))
	if rc != 0 {
		return nil, cli.Fail("could not start the mail stack on %s (the remote step exited %d, see above)", s.target, rc)
	}
	return checked("the mail start", s.target, res, "mail_cypht_health", "mail_cypht_nginx", "mail_dms_state",
		"mail_dms_health", "mail_dms_restarts", "mail_dms_image", "mail_jail")
}

// jailWords and nginxWords are the start step's mail_jail and
// mail_cypht_nginx states, as the summary says them.
var (
	jailWords = map[string]string{
		"unchanged": "fail2ban ignores mail-cypht",
		"reloaded":  "fail2ban reloaded, ignores mail-cypht",
		"atstart":   "fail2ban ignores mail-cypht once it starts",
		"failed":    "fail2ban jail NOT applied, mail-cypht can be banned",
	}
	nginxWords = map[string]string{
		"mounted":   "cypht nginx.conf live",
		"remounted": "cypht recreated onto its new nginx.conf",
		"unchecked": "cypht nginx.conf not checked (could not compare the shipped and served copies)",
	}
)

// reportMail is the stack's summary and, when DMS is not healthy yet, what
// that most likely means; the walkthrough follows on the run that made it.
func reportMail(out *cli.Output, o Options, v MailValues, r *mail.ReadReport, changed []string, lay, st Facts) {
	shipped := "nothing re-rendered"
	if len(changed) > 0 {
		shipped = "shipped " + strings.Join(changed, " ")
	}
	p := v.Primary
	out.Info("  mail: %s/mail (%s)", o.Apps, shipped)
	out.Info("        domains: %s (primary %s, %s)", strings.Join(v.Domains, " "), p, v.Origin)
	out.Info("        routers: mail.%s (cert-trigger, no backend), https://webmail.%s", p, p)
	out.Info("        .env %s, postmaster %s, dkim override %s", lay["mail_env"], lay["mail_account"], lay["mail_dkim_seed"])
	out.Info("        cypht %s, dms %s (%s, %s restarts)", st["mail_cypht_health"], st["mail_dms_state"], st["mail_dms_health"], st["mail_dms_restarts"])
	out.Info("        %s; %s", jailWords[st["mail_jail"]], nginxWords[st["mail_cypht_nginx"]])
	out.Info("        setup guide: kasbah server mail-setup-guide %s", o.Target)
	if st["mail_jail"] == "failed" {
		// Mail still flows; only the webmail exemption is missing.
		out.Warn("mail-dms's Fail2ban did not take the new jail (see above); until it does,")
		out.Warn("a few wrong webmail passwords can ban mail-cypht and cut webmail off from IMAP.")
		out.Warn("re-run init once mail-dms is running, or retry by hand:")
		out.Warn("  ssh %s 'docker exec mail-dms cp %s %s && docker exec mail-dms fail2ban-client reload'", o.Target, mail.JailSource, mail.JailLive)
	}
	if st["mail_dms_health"] != "healthy" {
		// Inside the 60 s start_period and crashlooping on a missing
		// certificate look alike here; restarts tell them apart only later.
		out.Warn("mail-dms is %s and its healthcheck says '%s' (%s restarts so far).", st["mail_dms_state"], st["mail_dms_health"], st["mail_dms_restarts"])
		out.Warn("that is expected right after a start: the healthcheck has a 60 s start_period.")
		out.Warn("if it does not settle, the reason is almost always the certificate.")
		out.Warn("  SSL_TYPE=letsencrypt makes one for mail.%s a *boot* requirement, so", p)
		out.Warn("  DMS restarts until Traefik has finished the HTTP-01 exchange and written it into")
		out.Warn("  acme.json — 30-90 s on a first run, and forever if that hostname does not resolve")
		out.Warn("  to this host from the public internet. Check in a minute:")
		out.Warn("  ssh %s 'docker inspect -f \"{{.State.Health.Status}}\" mail-dms'", o.Target)
		out.Warn("  ssh %s 'docker logs --tail 40 mail-dms'", o.Target)
	}
	if r.Dir == "absent" {
		fmt.Fprintln(out.Stdout)
		mail.Guide(out.Stdout, mail.GuideData{Target: o.Target, Apps: o.Apps, Data: o.Data, Primary: p, Domains: v.Domains})
	}
}
