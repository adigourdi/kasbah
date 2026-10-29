// Package mail is the shared mail stack (docs/mail.md): `server
// add-mail-domain`, `server mail-setup-guide`, `kasbah remote mail …`, and
// what `server init --with-mail` renders and prints.
package mail

import (
	"fmt"
	"io"
	"io/fs"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/tmpl"
)

// Project is the mail stack's compose project and directory under <apps>.
const Project = "mail"

// DKIMDir is where DMS's `setup config dkim` writes Rspamd's keys, on the
// host; DKIMContainerDir is the same directory as Rspamd's paths name it.
func DKIMDir(data string) string { return data + "/mail/dms/config/rspamd/dkim" }

const DKIMContainerDir = "/tmp/docker-mailserver/rspamd/dkim"

// DKIMConf is the Rspamd signing override kasbah seeds; Rspamd signs only
// with the key paths it lists.
func DKIMConf(data string) string {
	return data + "/mail/dms/config/rspamd/override.d/dkim_signing.conf"
}

// DKIMKeyNames is the pair of key files the signing override names for a
// domain, in DKIMKeygen's order: the helper's names for those two commands.
func DKIMKeyNames(domain string) [2]string {
	return [2]string{"rsa-2048-mail-" + domain + ".private.txt", "ed25519-ed-" + domain + ".private.txt"}
}

// DKIMKeygen is dual signing's two keygen commands for one domain, RSA first.
func DKIMKeygen(target, domain string) [2]string {
	return [2]string{
		fmt.Sprintf("ssh %s 'docker exec mail-dms setup config dkim keytype rsa     selector mail domain %s'", target, domain),
		fmt.Sprintf("ssh %s 'docker exec mail-dms setup config dkim keytype ed25519 selector ed   domain %s'", target, domain),
	}
}

// DKIMGaps is which of a domain's DKIMKeyNames are not among keys, the key
// directory's entries, and which conf (the signing override) does not list
// by path. Commented lines list nothing.
func DKIMGaps(domain string, keys []string, conf string) (absent, unlisted []string) {
	var live strings.Builder
	for _, l := range strings.Split(conf, "\n") {
		if t := strings.TrimSpace(strings.TrimRight(l, "\r")); !strings.HasPrefix(t, "#") {
			live.WriteString(t + "\n")
		}
	}
	for _, n := range DKIMKeyNames(domain) {
		if !slices.Contains(keys, n) {
			absent = append(absent, n)
		}
		if !strings.Contains(live.String(), DKIMContainerDir+"/"+n) {
			unlisted = append(unlisted, n)
		}
	}
	return absent, unlisted
}

// DomainsBlock is the YAML list the registry template's __MAIL_DOMAINS__
// stands for. Every entry has passed the FQDN check, so none can open a key.
func DomainsBlock(domains []string) string {
	lines := make([]string, len(domains))
	for i, d := range domains {
		lines[i] = "  - " + d
	}
	return strings.Join(lines, "\n")
}

// RenderRegistry renders templates/mail/kasbah.yml, the registry's one shape,
// for every writer of it.
func RenderRegistry(templates fs.FS, primary string, domains []string) (string, error) {
	b, err := fs.ReadFile(templates, "mail/kasbah.yml")
	if err != nil {
		return "", cli.Fail("internal: this kasbah build carries no mail/kasbah.yml template")
	}
	s, err := tmpl.Render(string(b), "mail kasbah.yml", map[string]string{
		"MAIL_PRIMARY_DOMAIN": primary,
		"MAIL_DOMAINS":        DomainsBlock(domains),
	})
	if err != nil {
		return "", err
	}
	if perr := tmpl.CheckYAML(s); perr != nil {
		return "", cli.Fail("the rendered mail registry is not valid YAML — refusing to ship it").Cont(
			perr.Error(),
			fmt.Sprintf("rendered with primary %s, domains %s", primary, strings.Join(domains, " ")))
	}
	return s, nil
}

// GuideData is what the walkthrough is rendered for.
type GuideData struct {
	Target, Apps, Data, Primary string
	Domains                     []string
	// HostAddr is the address the ssh session reached, "" when unknown.
	HostAddr string
}

// Guide prints the walkthrough, ported from the original project's mail/SETUP.md, on w:
// it is the command's output, so `> mail-setup.txt` captures all of it.
func Guide(w io.Writer, g GuideData) {
	ip, note := g.HostAddr, ""
	if ip == "" {
		ip = "<VPS IP>"
	} else {
		note = " (the address this ssh session reached — substitute the public one if the server is behind NAT)"
	}
	r := strings.NewReplacer("{T}", g.Target, "{P}", g.Primary, "{A}", g.Apps, "{D}", g.Data,
		"{IP}", ip, "{NOTE}", note, "{DOMAINS}", strings.Join(g.Domains, " "), "{BT}", "`")
	var keys, dns strings.Builder
	for _, d := range g.Domains {
		for _, c := range DKIMKeygen(g.Target, d) {
			fmt.Fprintf(&keys, "    %s\n", c)
		}
	}
	p := g.Primary
	fmt.Fprintf(&dns, "; ---------- %s: the stack's own names ----------\n", p)
	fmt.Fprintf(&dns, "mail.%s.               IN A     %s\n", p, ip)
	fmt.Fprintf(&dns, "webmail.%s.            IN A     %s\n", p, ip)
	fmt.Fprintf(&dns, "mail.%s.               IN TXT   \"v=spf1 a -all\"\n", p)
	fmt.Fprintf(&dns, "_smtp._tls.%s.         IN TXT   \"v=TLSRPTv1; rua=mailto:postmaster@%s\"\n", p, p)
	fmt.Fprintf(&dns, "_imaps._tcp.%s.        IN SRV   0 1 993 mail.%s.\n", p, p)
	fmt.Fprintf(&dns, "_submissions._tcp.%s.  IN SRV   0 1 465 mail.%s.\n", p, p)
	fmt.Fprintf(&dns, "_submission._tcp.%s.   IN SRV   0 1 587 mail.%s.\n", p, p)
	for _, d := range g.Domains {
		fmt.Fprintf(&dns, "\n; ---------- %s ----------\n", d)
		fmt.Fprintf(&dns, "%s.                    IN MX    10 mail.%s.\n", d, p)
		fmt.Fprintf(&dns, "%s.                    IN TXT   \"v=spf1 mx ip4:%s ~all\"\n", d, ip)
		fmt.Fprintf(&dns, "_dmarc.%s.             IN TXT   \"v=DMARC1; p=none; rua=mailto:postmaster@%s; fo=1\"\n", d, p)
		fmt.Fprintf(&dns, "mail._domainkey.%s.    IN TXT   \"<rsa-2048-mail-%s.public.dns.txt>\"\n", d, d)
		fmt.Fprintf(&dns, "ed._domainkey.%s.      IN TXT   \"<ed25519-ed-%s.public.dns.txt>\"\n", d, d)
	}
	io.WriteString(w, r.Replace(guideHead))
	io.WriteString(w, keys.String())
	io.WriteString(w, r.Replace(guideKeys))
	io.WriteString(w, "\n"+dns.String())
	io.WriteString(w, r.Replace(guideTail))
}

const guideHead = `Mail setup — {T}
========================

Primary domain: {P}
Domains served: {DOMAINS}
VPS address:    {IP}{NOTE}
Stack:          {A}/mail   data: {D}/mail

Everything below runs on the VPS. docker-mailserver has no admin web UI; its
CLI is {BT}docker exec mail-dms setup …{BT}, and {BT}setup help{BT} lists all of it.

0. Prerequisites — kasbah cannot check either of these, and both are fatal
---------------------------------------------------------------------------
[ ] Reverse DNS (PTR) on the VPS IP is set to mail.{P}. It is set in
    the VPS provider's control panel, not in your zone, and receivers reject
    or spam-file mail from a host whose PTR does not match its HELO name.
[ ] Port 25 **outbound** is not blocked by the provider. Many block it by
    default (OVH, Hetzner, AWS, GCP) and will unblock on request. If they will
    not, use an outbound relay — step 6.
[ ] mail.{P} and webmail.{P} resolve to the VPS from the
    public internet. Traefik asks Let's Encrypt for both the moment it loads
    the fragment, and DMS will not boot without the first one's certificate.

1. Check the stack
---------------------------------------------------------------------------
    ssh {T} 'docker inspect -f "{{.State.Health.Status}}" mail-dms'
    ssh {T} 'docker logs --tail 40 mail-dms'

On a first run DMS may crashloop for 30-90 s with

    Unable to find key and/or cert for '{P}' in '/etc/letsencrypt/acme.json'

while Traefik finishes the HTTP-01 exchange. That is expected. If it never
settles, mail.{P} does not resolve to this host from the outside.

    https://webmail.{P} — webmail, and it should answer 200
    https://mail.{P} — answers 418 by design. Nothing is served there;
    the name exists so that Traefik asks for its certificate.

2. Generate DKIM keys — dual signing, Ed25519 primary with RSA fallback
---------------------------------------------------------------------------
Per domain. kasbah does not generate keys and never will: they are the one
thing here that cannot be regenerated without breaking every receiver holding
the old one.

`

const guideKeys = `
The keys land in {D}/mail/dms/config/rspamd/dkim/. The flat,
one-line public forms are the ones to paste into DNS:

    ssh {T} 'cat {D}/mail/dms/config/rspamd/dkim/*.public.dns.txt'

kasbah seeded the signing override for {P} before DMS first started —
which is what stops DMS's helper writing its own single-selector default over
it — and never rewrites it. **A domain added later needs its own block added by
hand** to

    {D}/mail/dms/config/rspamd/override.d/dkim_signing.conf

Rspamd reloads on its own; no restart. {BT}kasbah check --server{BT} warns for
every domain in the registry that lacks either key or its block in that file.

3. Publish DNS, for this server's registry
---------------------------------------------------------------------------
`

const guideTail = `
The two DKIM lines are placeholders — paste the matching .public.dns.txt
contents from step 2. Apex A records are not listed: those belong to whatever
serves each site.

Start DMARC at p=none, read the rua reports for a few days, then tighten to
p=quarantine and only later to p=reject. Tighten SPF's ~all to -all once every
sender is listed.

    dig +short MX {P}
    dig +short TXT mail._domainkey.{P}
    dig +short TXT _dmarc.{P}

4. Mailboxes
---------------------------------------------------------------------------
postmaster@{P} already exists — {BT}server init --with-mail{BT} seeded it,
because Dovecot panics within 120 s if the account file is empty. Every other
address is created out of band, deliberately: deploys do not touch user data
(docs/mail.md → Account management).

    ssh -t {T} 'docker exec -it mail-dms setup email add noreply@{P}'
    ssh -t {T} 'docker exec -it mail-dms setup email update postmaster@{P}'
    ssh    {T} 'docker exec mail-dms setup email list'
    ssh    {T} 'docker exec mail-dms setup alias add hello@{P} noreply@{P}'

Each additional domain already has postmaster@<domain> aliased to
postmaster@{P} — that is what {BT}kasbah server add-mail-domain{BT} writes,
and what makes Postfix accept mail for the domain at all.

5. Webmail
---------------------------------------------------------------------------
Users log in at https://webmail.{P} with their full address and
mailbox password; there is no separate webmail admin. Further accounts, on
this server or elsewhere, are added in Cypht's settings, and its combined
views (Everything, Unread, Flagged…) span all of them. Cypht keeps a
settings change only once it is saved with the login password, under
Settings → Save ("Save" or "Save and Logout"); "Just Logout" discards it.

6. Outbound relay, if the IP is blocked or has poor reputation
---------------------------------------------------------------------------
Fill these three in {A}/mail/.env — they are the operator's half of
that file, and kasbah copies them through untouched on every re-run:

    DEFAULT_RELAY_HOST=[smtp-relay.brevo.com]:587
    RELAY_USER=<smtp-login>
    RELAY_PASSWORD=<smtp-key>

    ssh {T} 'cd {A}/mail && docker compose -p mail up -d'

7. Prove it end to end
---------------------------------------------------------------------------
[ ] Send from an outside account to postmaster@{P}, read it in webmail.
[ ] Reply, and confirm it arrives and is not in spam.
[ ] https://www.mail-tester.com/ — aim for 10/10, from each domain that sends.
[ ] https://mxtoolbox.com/SuperTool.aspx on each domain: MX, SPF, DKIM, DMARC.
[ ] ssh {T} 'docker logs mail-dms 2>&1 | grep -i rspamd | tail -20'

8. Back up the DKIM keys
---------------------------------------------------------------------------
{D}/mail/dms/config/rspamd/dkim/ is the one directory here that
cannot be rebuilt. A regenerated key is a different key, and every receiver
holding the old one fails verification until its cache expires.

    ssh {T} 'tar czf - -C {D}/mail dms/config' > dms-config-$(date +%F).tar.gz

Mailboxes live in {D}/mail/dms/mail-data/, webmail settings in
{D}/mail/cypht/.
`
