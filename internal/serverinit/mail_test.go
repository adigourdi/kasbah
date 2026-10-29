package serverinit

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/prompt"
)

func TestMailResolve(t *testing.T) {
	o := Options{Target: "deploy@vps", Apps: "/apps", Data: "/apps/data", Mail: prompt.Yes}
	crypt := func(p string) (string, error) { return "$6$salt$" + map[string]string{"pw": "HASH"}[p], nil }
	ask := func(in string) *prompt.Prompter {
		out, _ := newOut()
		return &prompt.Prompter{In: strings.NewReader(in), Out: out, TTY: in != ""}
	}
	r := mail.ReadReport{Dir: "absent", Accounts: "absent"}

	// Fresh: --domain's apex, and the password asked for.
	out, b := newOut()
	v, err := MailResolve(out, ask("pw\n"), o, &r, "", "example.com", crypt)
	if err != nil || v.Primary != "example.com" || v.Origin != "domain" || strings.Join(v.Domains, " ") != "example.com" ||
		v.Account != "postmaster@example.com|{SHA512-CRYPT}$6$salt$HASH" {
		t.Fatalf("fresh: %+v %v %s", v, err, b)
	}
	// No terminal, no flag: refused naming the flag.
	if _, err := MailResolve(out, ask(""), o, &r, "", "example.com", crypt); !strings.Contains(errText(err), "--postmaster-password=<value>") {
		t.Errorf("unanswered: %v", err)
	}

	// Reused, in mailreg's order, and an account never re-asked.
	r = mail.ReadReport{Dir: "dir", Accounts: "present"}
	o.Postmaster = "pw"
	b.Reset()
	v, err = MailResolve(out, ask(""), o, &r, "primary_domain: mx.example.com\ndomains:\n  - a.com\n  - mx.example.com\n", "example.com", crypt)
	if err != nil || v.Primary != "mx.example.com" || v.Origin != "reused" || strings.Join(v.Domains, " ") != "mx.example.com a.com" || v.Account != "" {
		t.Fatalf("reused: %+v %v", v, err)
	}
	if !strings.Contains(b.String(), "--postmaster-password had no effect") || strings.Contains(b.String(), "pw\n") {
		t.Errorf("unused flag: %s", b)
	}

	for _, c := range []struct {
		r        mail.ReadReport
		registry string
		want     string
	}{
		{mail.ReadReport{Dir: "notdir", Accounts: "absent"}, "", "/apps/mail on deploy@vps exists and is not a directory"},
		{mail.ReadReport{Dir: "dir", Accounts: "bogus"}, "", "accounts='bogus'"},
		{mail.ReadReport{Dir: "dir", Accounts: "present"}, "domains: [a.com]\n", "has no primary_domain"},
		{mail.ReadReport{Dir: "dir", Accounts: "present"}, "domains: [oops\n", "start the registry over from --domain"},
		{mail.ReadReport{Dir: "dir", Accounts: "present"}, "primary_domain: a.com\ndomains:\n  - not_a domain\n", "which is not a domain name"},
	} {
		if _, err := MailResolve(out, ask(""), o, &c.r, c.registry, "example.com", crypt); !strings.Contains(errText(err), c.want) {
			t.Errorf("%+v %q: %v", c.r, c.registry, err)
		}
	}
}

func TestMailRender(t *testing.T) {
	o := Options{Apps: "/srv/apps", Data: "/srv/data"}
	r, err := MailRender(repoTemplates(t), o, MailValues{Primary: "example.com", Domains: []string{"example.com", "shop.test"}})
	if err != nil {
		t.Fatal(err)
	}
	for k, want := range map[string]string{
		"kasbah.yml":       "primary_domain: example.com\ndomains:\n  - example.com\n  - shop.test\n",
		"_mail.yml":        "Host(`webmail.example.com`)",
		"compose.yml":      "name: mail",
		"env":              "MAIL_HOSTNAME=mail.example.com\nDOMAIN=example.com\nDATA_PATH=/srv/data\n",
		"dkim":             "rsa-2048-mail-example.com.private.txt",
		"compose.yml#":     "./cypht-nginx.conf:/etc/nginx/nginx.conf:ro",
		"cypht-nginx.conf": "\treal_ip_header X-Forwarded-For;\n\treal_ip_recursive on;\n",
		"fail2ban-jail.cf": "[DEFAULT]\nignoreip = 127.0.0.1/8 mail-cypht\n",
	} {
		k, _, _ = strings.Cut(k, "#")
		if !strings.Contains(r[k], want) {
			t.Errorf("%s lacks %q", k, want)
		}
	}
	// The registry has one renderer: init's and add-mail-domain's agree.
	if reg, _ := mail.RenderRegistry(repoTemplates(t), "example.com", []string{"example.com", "shop.test"}); reg != r["kasbah.yml"] {
		t.Error("two registry shapes")
	}
}

// An accounts file with no account line (DMS would boot accountless) is
// seeded, never reused.
func TestMailResolveEmptyAccounts(t *testing.T) {
	o := Options{Target: "deploy@vps", Apps: "/apps", Data: "/apps/data", Mail: prompt.Yes, Postmaster: "pw"}
	out, _ := newOut()
	r := mail.ReadReport{Dir: "dir", Accounts: "empty"}
	v, err := MailResolve(out, &prompt.Prompter{In: strings.NewReader(""), Out: out}, o, &r,
		"primary_domain: a.com\ndomains:\n  - a.com\n", "example.com",
		func(string) (string, error) { return "$6$salt$HASH", nil })
	if err != nil || v.Account != "postmaster@a.com|{SHA512-CRYPT}$6$salt$HASH" {
		t.Errorf("%+v %v", v, err)
	}
}

// Each file lands where its consumer reads it, and only a file whose bytes
// differ from the server's is shipped again.
func TestMailChanged(t *testing.T) {
	o := Options{Apps: "/srv/apps", Data: "/srv/data"}
	for rel, want := range map[string]string{
		"compose.yml":      "/srv/apps/mail/compose.yml",
		"kasbah.yml":       "/srv/apps/mail/kasbah.yml",
		"_mail.yml":        "/srv/apps/traefik/dynamic/_mail.yml",
		"cypht-nginx.conf": "/srv/apps/mail/cypht-nginx.conf",
		"fail2ban-jail.cf": "/srv/data/mail/dms/config/fail2ban-jail.cf",
	} {
		if got := MailDest(o, rel); got != want {
			t.Errorf("%s lands at %s", rel, got)
		}
	}
	r, err := MailRender(repoTemplates(t), o, MailValues{Primary: "example.com", Domains: []string{"example.com"}})
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(MailChanged(r, map[string]string{}), " "); got != strings.Join(MailFiles, " ") {
		t.Errorf("fresh server: %s", got)
	}
	// What the read returns is what the comparison sees.
	rd := mail.ReadReport{}
	for rel, f := range map[string]*string{"compose.yml": &rd.Compose, "kasbah.yml": &rd.Registry, "_mail.yml": &rd.Fragment,
		"cypht-nginx.conf": &rd.Nginx, "fail2ban-jail.cf": &rd.Jail} {
		*f = base64.StdEncoding.EncodeToString([]byte(r[rel]))
	}
	cur, err := MailCurrent(&rd, "deploy@vps")
	if err != nil {
		t.Fatal(err)
	}
	if got := MailChanged(r, cur); len(got) != 0 {
		t.Errorf("current server: %v", got)
	}
	for _, rel := range []string{"fail2ban-jail.cf", "cypht-nginx.conf"} {
		was := cur[rel]
		cur[rel] = strings.Replace(was, "\n", "\r\n", 1)
		if got := strings.Join(MailChanged(r, cur), " "); got != rel {
			t.Errorf("%s edited on the server: %s", rel, got)
		}
		cur[rel] = was
	}
}

// A lifted ban is a warning, naming the addresses; none, or a Fail2ban not
// yet answering, says nothing; a failure says which step failed and how to
// do it by hand.
func TestReportMailUnban(t *testing.T) {
	o := Options{Target: "deploy@vps", Apps: "/apps", Data: "/apps/data"}
	v := MailValues{Primary: "a.com", Origin: "reused", Domains: []string{"a.com"}}
	both := "fd70::5 172.18.0.5"
	for _, c := range []struct{ n, addr, want string }{
		{"1", both, "lifted 1 Fail2ban ban(s) on mail-cypht (fd70::5 172.18.0.5)"},
		{"0", both, ""},
		{"skipped", "", ""},
		{"failed", both, "could not unban mail-cypht (fd70::5 172.18.0.5)"},
		{"failed", both, "docker exec mail-dms fail2ban-client unban fd70::5 172.18.0.5'"},
		{"failed", "", "cannot resolve mail-cypht, so no Fail2ban ban on it was looked for"},
		{"failed", "", "fail2ban-client unban <mail-cypht address>'"},
	} {
		// The start step's own lines, an empty address included, through checked().
		res := "mail_cypht_health=healthy\nmail_cypht_nginx=mounted\nmail_dms_state=running\nmail_dms_health=healthy\n" +
			"mail_dms_restarts=0\nmail_dms_image=img\nmail_jail=unchanged\nmail_cypht_unbanned=" + c.n + "\nmail_cypht_addr=" + c.addr + "\n"
		st, err := checked("the mail start", "deploy@vps", res, "mail_cypht_health", "mail_cypht_nginx", "mail_dms_state",
			"mail_dms_health", "mail_dms_restarts", "mail_dms_image", "mail_jail", "mail_cypht_unbanned", "mail_cypht_addr")
		if err != nil || st["mail_cypht_addr"] != c.addr {
			t.Fatalf("%s %q: %v %v", c.n, c.addr, st, err)
		}
		out, b := newOut()
		reportMail(out, o, v, &mail.ReadReport{Dir: "dir"}, nil, Facts{}, st)
		got := b.String()
		if c.want != "" && !strings.Contains(got, c.want) {
			t.Errorf("%s %q: no %q in\n%s", c.n, c.addr, c.want, got)
		}
		if c.want == "" && (strings.Contains(got, "mail-cypht (") || strings.Contains(got, "unban")) {
			t.Errorf("%s %q: says something:\n%s", c.n, c.addr, got)
		}
	}
}

// The summary ends with the guide pointer and the deliverability checklist,
// whatever else it says.
func TestReportMailChecklist(t *testing.T) {
	o := Options{Target: "deploy@vps", Apps: "/apps", Data: "/apps/data"}
	v := MailValues{Primary: "a.com", Origin: "reused", Domains: []string{"a.com", "b.com"}}
	out, b := newOut()
	// Every warning the summary can raise, so the checklist is shown to follow them.
	reportMail(out, o, v, &mail.ReadReport{Dir: "dir"}, nil, Facts{},
		Facts{"mail_dms_health": "starting", "mail_cypht_unbanned": "failed", "mail_jail": "failed", "mail_cypht_addr": "172.18.0.5"})
	want := "        setup guide: kasbah server mail-setup-guide deploy@vps\n" +
		"        before the first real send (each one a step of the guide):\n" +
		"          DKIM  keys per domain: docker exec mail-dms setup config dkim ... (step 2)\n" +
		"          PTR   the VPS IP's reverse DNS names mail.a.com, set at the provider (step 0)\n" +
		"          SPF   a TXT record on each domain (step 3)\n"
	if got := b.String(); !strings.HasSuffix(got, want) || !strings.Contains(got, "could not unban") || !strings.Contains(got, "healthcheck says 'starting'") {
		t.Errorf("summary does not end with the checklist:\n%s", got)
	}
}
