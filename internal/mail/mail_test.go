package mail

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/templates"
)

func repoTemplates(t *testing.T) fs.FS {
	return templates.FS
}

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

// Vectors from `openssl passwd -6 -salt …`.
func TestSHA512Crypt(t *testing.T) {
	for _, c := range []struct{ pass, salt, want string }{
		{"Hello world!", "saltstring", "$6$saltstring$svn8UoSVapNtMuq1ukKS4tPQd8iKwSMHWjl/O817G3uBnIFNjnQJuesI68u4OTLiBFdcbYEdFCoEOfaS35inz1"},
		{"péss word with a much longer body than sixty-four bytes so the loop runs twice ok", "ab./XY09",
			"$6$ab./XY09$q51xqEFpjKbXlwUJoDiMQ2I.9Ftw8Yv6AlvA60tgG1dRWQVfrxF/8678OdkDeeGMPyFmbmJEwwOXTgTKMhAQg/"},
	} {
		if got := SHA512Crypt(c.pass, c.salt); got != c.want {
			t.Errorf("%q: %s", c.salt, got)
		}
	}
	s, err := Salt()
	if err != nil || len(s) != 16 || strings.Trim(s, itoa64) != "" {
		t.Errorf("salt %q %v", s, err)
	}
}

func TestMergeEnv(t *testing.T) {
	rendered := "# MAIL_HOSTNAME=__x__\nMAIL_HOSTNAME=mail.a.com\nDOMAIN=a.com\nDATA_PATH=/d\n\nDEFAULT_RELAY_HOST=\n"
	for _, c := range []struct{ cur, want string }{
		{rendered, rendered},
		{"MAIL_HOSTNAME=old\r\nRELAY_USER=me\r\nDOMAIN=b.com", "MAIL_HOSTNAME=mail.a.com\nRELAY_USER=me\r\nDOMAIN=a.com\nDATA_PATH=/d\n"},
		{"", "MAIL_HOSTNAME=mail.a.com\nDOMAIN=a.com\nDATA_PATH=/d\n"},
	} {
		if got := MergeEnv(c.cur, rendered); got != c.want {
			t.Errorf("%q: %q", c.cur, got)
		}
	}
}

func run(t *testing.T, stdin string, args ...string) (string, string, int) {
	t.Helper()
	var o, e bytes.Buffer
	rc := Remote(args, strings.NewReader(stdin), &o, &e)
	return o.String(), e.String(), rc
}

func signed(body string, args ...string) []string {
	size, sum := remote.Digest([]byte(body))
	return append(args, size, sum)
}

func mode(t *testing.T, p string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

func readOf(t *testing.T, apps, data string) ReadReport {
	t.Helper()
	out, e, rc := run(t, "", "read", apps, data)
	var r ReadReport
	if rc != 0 || json.Unmarshal([]byte(out), &r) != nil {
		t.Fatalf("read: %q %q %d", out, e, rc)
	}
	return r
}

func TestRemoteLayout(t *testing.T) {
	root := t.TempDir()
	apps, data := root+"/apps", root+"/apps/data"
	os.MkdirAll(apps+"/traefik/dynamic", 0o755)
	t.Setenv("SSH_CONNECTION", "198.51.100.1 5555 203.0.113.7 22")
	if r := readOf(t, apps, data); r.Dir != "absent" || r.Accounts != "absent" || r.Env || r.HostAddr != "203.0.113.7" {
		t.Fatalf("bare: %+v", r)
	}

	env := "MAIL_HOSTNAME=mail.a.com\nDOMAIN=a.com\nDATA_PATH=" + data + "\nRELAY_USER=\n"
	lb := func(account string) string {
		b, _ := json.Marshal(LayoutBody{Env: env, DKIM: "dkim\n", Account: account})
		return string(b)
	}
	body := lb("postmaster@a.com|{SHA512-CRYPT}$6$x$y")
	out, e, rc := run(t, body, signed(body, "layout", apps, data)...)
	if rc != 0 || out != "mail_env=created\nmail_account=seeded\nmail_dkim_seed=seeded\nmail_layout=done\n" {
		t.Fatalf("first layout: %q %q %d", out, e, rc)
	}
	acc := data + "/mail/dms/config/postfix-accounts.cf"
	if b, _ := os.ReadFile(acc); string(b) != "postmaster@a.com|{SHA512-CRYPT}$6$x$y\n" || mode(t, acc) != 0o600 {
		t.Errorf("accounts %q %o", b, mode(t, acc))
	}
	if mode(t, apps+"/mail/.env") != 0o600 || mode(t, data+"/mail/dms/config/rspamd/override.d/dkim_signing.conf") != 0o644 {
		t.Error("seed modes")
	}
	for _, d := range []string{"/mail/dms/mail-data", "/mail/dms/mail-state", "/mail/dms/mail-logs", "/mail/snappymail"} {
		if fi, err := os.Stat(data + d); err != nil || !fi.IsDir() {
			t.Errorf("%s not created", d)
		}
	}
	if r := readOf(t, apps, data); r.Dir != "dir" || r.Accounts != "present" || !r.Env {
		t.Errorf("after: %+v", r)
	}

	// The operator's relay survives, a hand-loosened mode does not, and an
	// account is never written over.
	os.WriteFile(apps+"/mail/.env", []byte(env+"RELAY_PASSWORD=s3cret\n"), 0o644)
	body = lb("postmaster@a.com|{SHA512-CRYPT}$6$new$z")
	out, _, rc = run(t, body, signed(body, "layout", apps, data)...)
	if rc != 0 || out != "mail_env=unchanged\nmail_account=kept\nmail_dkim_seed=kept\nmail_layout=done\n" || mode(t, apps+"/mail/.env") != 0o600 {
		t.Errorf("re-run: %q %o", out, mode(t, apps+"/mail/.env"))
	}
	if b, _ := os.ReadFile(acc); !strings.Contains(string(b), "$6$x$y") {
		t.Errorf("account rewritten: %q", b)
	}
	os.WriteFile(apps+"/mail/.env", []byte("DOMAIN=b.com\nRELAY_PASSWORD=s3cret\n"), 0o600)
	out, _, _ = run(t, body, signed(body, "layout", apps, data)...)
	b, _ := os.ReadFile(apps + "/mail/.env")
	if !strings.Contains(out, "mail_env=rewritten") || string(b) != "DOMAIN=a.com\nRELAY_PASSWORD=s3cret\nMAIL_HOSTNAME=mail.a.com\nDATA_PATH="+data+"\n" {
		t.Errorf("merge: %q %q", out, b)
	}

	// An account file this user cannot read (DMS leaves it root's 600 after
	// `setup email update`) is reported present, as layout keeps it.
	if os.Getuid() != 0 {
		os.Chmod(acc, 0o000)
		if r := readOf(t, apps, data); r.Accounts != "present" {
			t.Errorf("unreadable accounts read as %q", r.Accounts)
		}
		out, _, _ = run(t, body, signed(body, "layout", apps, data)...)
		if !strings.Contains(out, "mail_account=kept") {
			t.Errorf("unreadable accounts: %q", out)
		}
		os.Chmod(acc, 0o600)
	}

	// A file with no account in it is seeded.
	os.WriteFile(acc, []byte("# none\n\n"), 0o600)
	out, _, _ = run(t, body, signed(body, "layout", apps, data)...)
	if !strings.Contains(out, "mail_account=seeded") {
		t.Errorf("comment-only accounts: %q", out)
	}

	// Refusals: a cut payload, a directory where a file belongs.
	if _, e, rc := run(t, body[:10], signed(body, "layout", apps, data)...); rc != 1 || !strings.Contains(e, "nothing was installed") {
		t.Errorf("cut: %q", e)
	}
	os.Remove(apps + "/mail/.env")
	os.Mkdir(apps+"/mail/.env", 0o755)
	if _, e, rc := run(t, body, signed(body, "layout", apps, data)...); rc != 1 || !strings.Contains(e, ".env exists and is not a regular file") {
		t.Errorf("env dir: %q", e)
	}
	if left, _ := filepath.Glob(apps + "/mail/*.tmp.*"); len(left) != 0 {
		t.Errorf("temp left: %v", left)
	}
}

func TestRemoteWrite(t *testing.T) {
	root := t.TempDir()
	apps, data := root+"/apps", root+"/data"
	os.MkdirAll(apps+"/mail", 0o755)
	w := func(alias string) (string, string, int) {
		b, _ := json.Marshal(WriteBody{Registry: "name: mail\n", Alias: alias})
		return run(t, string(b), signed(string(b), "write", apps, data)...)
	}
	if out, e, rc := w("postmaster@b.com postmaster@a.com"); rc != 0 || out != "registry=written\nalias=noconfig\n" {
		t.Fatalf("noconfig: %q %q", out, e)
	}
	if mode(t, apps+"/mail/kasbah.yml") != 0o644 {
		t.Error("registry mode")
	}
	cfg := data + "/mail/dms/config"
	os.MkdirAll(cfg, 0o755)
	os.WriteFile(cfg+"/postfix-virtual.cf", []byte("x@a.com y@a.com"), 0o644)
	if out, _, _ := w("postmaster@b.com postmaster@a.com"); out != "registry=written\nalias=added\n" {
		t.Errorf("added: %q", out)
	}
	if b, _ := os.ReadFile(cfg + "/postfix-virtual.cf"); string(b) != "x@a.com y@a.com\npostmaster@b.com postmaster@a.com\n" {
		t.Errorf("append: %q", b)
	}
	if out, _, _ := w(""); out != "registry=written\nalias=skipped\n" {
		t.Errorf("skipped: %q", out)
	}
	os.Chmod(cfg+"/postfix-virtual.cf", 0o444)
	if os.Getuid() != 0 {
		if out, _, _ := w("p@c.com p@a.com"); out != "registry=written\nalias=failed\n" {
			t.Errorf("failed: %q", out)
		}
	}
	if r := readOf(t, apps, data); r.Registry != base64.StdEncoding.EncodeToString([]byte("name: mail\n")) || r.Aliases == "" {
		t.Errorf("read back: %+v", r)
	}
}

func TestParse(t *testing.T) {
	o, err := Parse("add-mail-domain", []string{"d@vps\r", "shop.test\r"})
	if err != nil || o.Target != "d@vps" || o.Domain != "shop.test" {
		t.Fatalf("%+v %v", o, err)
	}
	for _, c := range []struct{ cmd, args, want string }{
		{"add-mail-domain", "d@vps|not a domain", "'not a domain' is not a domain name"},
		{"add-mail-domain", "d@vps", "a domain is required"},
		{"add-mail-domain", "", "USER@HOST is required"},
		{"add-mail-domain", "d@vps|a.com|b.com", "unexpected argument 'b.com'"},
		{"add-mail-domain", "d@vps|--x=secret", "unknown flag '--x'"},
		{"mail-setup-guide", "d@vps|e@vps", "USER@HOST is given once"},
		{"mail-setup-guide", "", "the guide is rendered for one server's registry"},
	} {
		var args []string
		if c.args != "" {
			args = strings.Split(c.args, "|")
		}
		if _, err := Parse(c.cmd, args); !strings.Contains(errText(err), c.want) {
			t.Errorf("%s %q: %v", c.cmd, c.args, err)
		}
	}
	if _, err := Parse("mail-setup-guide", []string{"d@vps", "--help"}); err != ErrHelp {
		t.Error("--help")
	}
}

// fake is a server whose kasbah answers from memory.
type fake struct {
	r      ReadReport
	result string
	writes []WriteBody
	calls  int
}

func (f *fake) Paths() (string, string, error) { return "/apps", "/apps/data", nil }
func (f *fake) Close()                         {}
func (f *fake) Remote(stdin []byte, args ...string) ([]byte, int) {
	f.calls++
	switch args[1] {
	case "read":
		b, _ := json.Marshal(f.r)
		return b, 0
	case "write":
		var w WriteBody
		json.Unmarshal(stdin, &w)
		f.writes = append(f.writes, w)
		return []byte(f.result), 0
	}
	return nil, 1
}

func enc(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func runWith(t *testing.T, f *fake, cmd string, args ...string) (string, string, error) {
	t.Helper()
	var so, se bytes.Buffer
	o, err := Parse(cmd, append([]string{"deploy@vps"}, args...))
	if err != nil {
		t.Fatal(err)
	}
	err = Run(Ctx{Out: &cli.Output{Stdout: &so, Stderr: &se}, Templates: repoTemplates(t),
		Dial: func(string) (Session, error) { return f, nil }}, o)
	return so.String(), se.String(), err
}

func TestAddMailDomain(t *testing.T) {
	one := "name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n"
	two := one + "  - shop.test\n"
	f := &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(one)}, result: "registry=written\nalias=added\n"}
	so, se, err := runWith(t, f, "add-mail-domain", "shop.test")
	if err != nil || len(f.writes) != 1 || f.writes[0].Registry != mustRender(t, two) ||
		f.writes[0].Alias != "postmaster@shop.test postmaster@example.test" {
		t.Fatalf("add: %v %+v", err, f.writes)
	}
	if !strings.Contains(se, "Added shop.test") || !strings.Contains(so, "selector ed   domain shop.test") {
		t.Errorf("report: %q %q", se, so)
	}

	// Both halves there: nothing written. Listed without the alias: converges.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(two), Aliases: enc("postmaster@shop.test postmaster@example.test\r\n")}}
	if _, se, err := runWith(t, f, "add-mail-domain", "shop.test"); err != nil || len(f.writes) != 0 || !strings.Contains(se, "already served") {
		t.Errorf("idempotent: %v %q", err, se)
	}
	f = &fake{r: ReadReport{Dir: "dir", Env: false, Registry: enc(two)}, result: "registry=written\nalias=failed\n"}
	_, se, err = runWith(t, f, "add-mail-domain", "shop.test")
	if err != nil || len(f.writes) != 1 || strings.Count(f.writes[0].Registry, "- shop.test") != 1 ||
		!strings.Contains(se, "has no .env") || !strings.Contains(se, "setup alias add postmaster@shop.test postmaster@example.test") {
		t.Errorf("converge: %v %q %+v", err, se, f.writes)
	}

	// The primary itself: no self-alias, no DKIM block for a seeded domain.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(one)}, result: "registry=written\nalias=added\n"}
	so, se, err = runWith(t, f, "add-mail-domain", "example.test")
	if err != nil || len(f.writes) != 0 || !strings.Contains(se, "example.test is the primary domain of the mail stack") || so != "" {
		t.Errorf("primary: %v %q %q %+v", err, se, so, f.writes)
	}

	for _, c := range []struct {
		r    ReadReport
		res  string
		want string
	}{
		{ReadReport{Dir: "absent"}, "", "there is no mail stack at /apps/mail on deploy@vps"},
		{ReadReport{Dir: "dir", Env: true, Registry: enc("domains:\n  - [oops\n")}, "", "could not be read as YAML"},
		{ReadReport{Dir: "dir", Env: true}, "", "missing or empty"},
		{ReadReport{Dir: "dir", Env: true, Registry: enc("name: mail\ndomains: [a.com]\n")}, "", "has no primary_domain"},
		{ReadReport{Dir: "dir", Env: true, Registry: enc(one)}, "registry=half\nalias=added\n", "reported registry='half'"},
	} {
		f := &fake{r: c.r, result: c.res}
		if _, _, err := runWith(t, f, "add-mail-domain", "shop.test"); !strings.Contains(errText(err), c.want) {
			t.Errorf("%+v: %v", c.r, err)
		}
		if c.res == "" && len(f.writes) != 0 {
			t.Errorf("%+v wrote", c.r)
		}
	}
}

func mustRender(t *testing.T, reg string) string {
	t.Helper()
	s, err := RenderRegistry(repoTemplates(t), "example.test", []string{"example.test", "shop.test"})
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasSuffix(s, "domains:\n  - example.test\n  - shop.test\n") {
		t.Fatalf("render: %q", s)
	}
	return s
}

func TestGuide(t *testing.T) {
	two := "name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n  - shop.test\n"
	f := &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(two), HostAddr: "203.0.113.7"}}
	so, _, err := runWith(t, f, "mail-setup-guide")
	if err != nil || f.calls != 1 || len(f.writes) != 0 {
		t.Fatalf("%v %d", err, f.calls)
	}
	for _, want := range []string{
		"Primary domain: example.test\nDomains served: example.test shop.test\nVPS address:    203.0.113.7 (the address",
		"shop.test.                    IN MX    10 mail.example.test.",
		"mail.example.test.               IN A     203.0.113.7",
		"ip4:203.0.113.7", "Reverse DNS (PTR)", "Port 25 **outbound**", "_dmarc.shop.test.",
		"CLI is `docker exec mail-dms setup …`", "dms-config-$(date +%F).tar.gz",
		"selector ed   domain shop.test'\n\nThe keys land",
		"---------------------------------------------------------------------------\n\n; ---------- example.test: the stack's own names",
	} {
		if !strings.Contains(so, want) {
			t.Errorf("guide lacks %q", want)
		}
	}
	var b bytes.Buffer
	Guide(&b, GuideData{Target: "t", Primary: "p.com", Domains: []string{"p.com"}})
	if !strings.Contains(b.String(), "VPS address:    <VPS IP>\n") {
		t.Error("no placeholder")
	}
}

// The account ladder: blank and comment lines, CR-stripped, are no account;
// one line without its final newline is.
func TestAccountLadder(t *testing.T) {
	root := t.TempDir()
	apps, data := root+"/apps", root+"/apps/data"
	acc := data + "/mail/dms/config/postfix-accounts.cf"
	os.MkdirAll(filepath.Dir(acc), 0o755)
	for body, want := range map[string]string{
		"":                                 "empty",
		"# only a comment\n":               "empty",
		"\r\n# c\r\n\r\n":                  "empty",
		"postmaster@a.com|{SHA512-CRYPT}x": "present",
		"# c\r\npostmaster@a.com|x\r\n":    "present",
	} {
		os.WriteFile(acc, []byte(body), 0o600)
		if r := readOf(t, apps, data); r.Accounts != want {
			t.Errorf("%q: %s, want %s", body, r.Accounts, want)
		}
	}
}
