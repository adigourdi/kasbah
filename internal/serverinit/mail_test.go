package serverinit

import (
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
		"kasbah.yml":  "primary_domain: example.com\ndomains:\n  - example.com\n  - shop.test\n",
		"_mail.yml":   "Host(`webmail.example.com`)",
		"compose.yml": "name: mail",
		"env":         "MAIL_HOSTNAME=mail.example.com\nDOMAIN=example.com\nDATA_PATH=/srv/data\n",
		"dkim":        "rsa-2048-mail-example.com.private.txt",
	} {
		if !strings.Contains(r[k], want) {
			t.Errorf("%s lacks %q", k, want)
		}
	}
	// The registry has one renderer: init's and add-mail-domain's agree.
	if reg, _ := mail.RenderRegistry(repoTemplates(t), "example.com", []string{"example.com", "shop.test"}); reg != r["kasbah.yml"] {
		t.Error("two registry shapes")
	}
}
