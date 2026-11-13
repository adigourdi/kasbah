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
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
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
		{"RELAY_KEY=\"-----BEGIN\r\nDOMAIN=x\r\n-----END\"\r\nDOMAIN='b\nc'\nMAIL_HOSTNAME=m\nDATA_PATH=/d\n",
			"RELAY_KEY=\"-----BEGIN\r\nDOMAIN=x\r\n-----END\"\r\nDOMAIN=a.com\nMAIL_HOSTNAME=mail.a.com\nDATA_PATH=/d\n"},
	} {
		if got := MergeEnv(c.cur, rendered); got != c.want {
			t.Errorf("%q: %q", c.cur, got)
		}
	}
}

func run(t *testing.T, stdin string, args ...string) (string, string, int) {
	t.Helper()
	var o, e bytes.Buffer
	rc := Remote(repoTemplates(t), args, strings.NewReader(stdin), &o, &e)
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
	os.MkdirAll(apps+"/mail", 0o755)
	os.MkdirAll(data+"/mail/dms/config", 0o755)
	os.WriteFile(apps+"/mail/cypht-nginx.conf", []byte("nginx"), 0o644)
	os.WriteFile(data+"/mail/dms/config/fail2ban-jail.cf", []byte("jail"), 0o644)
	if r := readOf(t, apps, data); r.Nginx != enc("nginx") || r.Jail != enc("jail") {
		t.Errorf("shipped files read as %q %q", r.Nginx, r.Jail)
	}
	os.RemoveAll(apps + "/mail")
	os.RemoveAll(data)

	env := "MAIL_HOSTNAME=mail.a.com\nDOMAIN=a.com\nDATA_PATH=" + data + "\nRELAY_USER=\n"
	lb := func(account string) string {
		b, _ := json.Marshal(LayoutBody{Env: env, Account: account})
		return string(b)
	}
	body := lb("postmaster@a.com|{SHA512-CRYPT}$6$x$y")
	out, e, rc := run(t, body, signed(body, "layout", apps, data)...)
	if rc != 0 || out != "mail_env=created\nmail_account=seeded\nmail_layout=done\n" {
		t.Fatalf("first layout: %q %q %d", out, e, rc)
	}
	acc := data + "/mail/dms/config/postfix-accounts.cf"
	if b, _ := os.ReadFile(acc); string(b) != "postmaster@a.com|{SHA512-CRYPT}$6$x$y\n" || mode(t, acc) != 0o600 {
		t.Errorf("accounts %q %o", b, mode(t, acc))
	}
	if mode(t, apps+"/mail/.env") != 0o600 {
		t.Error("seed modes")
	}
	if fi, err := os.Stat(data + "/mail/dms/config/rspamd/override.d"); err != nil || !fi.IsDir() || func() bool { _, err := os.Lstat(DKIMConf(data)); return err == nil }() {
		t.Error("layout makes override.d and leaves the signing override to the dkim step")
	}
	for _, d := range []string{"/mail/dms/mail-data", "/mail/dms/mail-state", "/mail/dms/mail-logs", "/mail/cypht"} {
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
	os.Chmod(data+"/mail/cypht", 0o700)
	body = lb("postmaster@a.com|{SHA512-CRYPT}$6$new$z")
	out, _, rc = run(t, body, signed(body, "layout", apps, data)...)
	if rc != 0 || out != "mail_env=unchanged\nmail_account=kept\nmail_layout=done\n" || mode(t, apps+"/mail/.env") != 0o600 {
		t.Errorf("re-run: %q %o", out, mode(t, apps+"/mail/.env"))
	}
	if b, _ := os.ReadFile(acc); !strings.Contains(string(b), "$6$x$y") {
		t.Errorf("account rewritten: %q", b)
	}
	if mode(t, data+"/mail/cypht") != 0o755 {
		t.Errorf("cypht/ left at %o, which www-data cannot traverse", mode(t, data+"/mail/cypht"))
	}
	os.WriteFile(apps+"/mail/.env", []byte("DOMAIN=b.com\nRELAY_PASSWORD=s3cret\n"), 0o600)
	out, _, _ = run(t, body, signed(body, "layout", apps, data)...)
	b, _ := os.ReadFile(apps + "/mail/.env")
	if !strings.Contains(out, "mail_env=rewritten") || string(b) != "DOMAIN=a.com\nRELAY_PASSWORD=s3cret\nMAIL_HOSTNAME=mail.a.com\nDATA_PATH="+data+"\n" {
		t.Errorf("merge: %q %q", out, b)
	}
	// A .env kasbah cannot read as compose does is refused, left as it is.
	bad := "DOMAIN=b.com\nRELAY_PASSWORD=\"s3cret\n"
	os.WriteFile(apps+"/mail/.env", []byte(bad), 0o600)
	_, errs, rc := run(t, body, signed(body, "layout", apps, data)...)
	if b, _ := os.ReadFile(apps + "/mail/.env"); rc == 0 || string(b) != bad || !strings.Contains(errs, "line 2 (RELAY_PASSWORD)") || strings.Contains(errs, "s3cret") {
		t.Errorf("unclosed quote: rc %d %q %q", rc, errs, b)
	}
	os.WriteFile(apps+"/mail/.env", b, 0o600)

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
		{"mail-dkim", "d@vps", "server mail-dkim: a domain is required"},
		{"mail-dkim", "d@vps|a.com|--replace-keys|--keep-keys", "--replace-keys and --keep-keys cannot both be given"},
		{"mail-dkim", "d@vps|a.com|--replace", "unknown flag '--replace' (this command takes USER@HOST, a domain and --replace-keys/--keep-keys)"},
		{"add-mail-domain", "d@vps|a.com|--keep-keys", "unknown flag '--keep-keys'"},
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
	if o, err := Parse("mail-dkim", []string{"d@vps", "--replace-keys\r", "a.com", "--replace-keys"}); err != nil || o.Domain != "a.com" || o.Replace != prompt.Yes {
		t.Errorf("mail-dkim: %+v %v", o, err)
	}
}

func TestMailDKIM(t *testing.T) {
	reg := "name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n  - shop.test\n"
	rsaV := "v=DKIM1; k=rsa; p=" + strings.Repeat("A", 380)
	full := []string{"rsa-2048-mail-shop.test.private.txt", "rsa-2048-mail-shop.test.public.txt", "rsa-2048-mail-shop.test.public.dns.txt",
		"ed25519-ed-shop.test.private.txt", "ed25519-ed-shop.test.public.txt", "ed25519-ed-shop.test.public.dns.txt"}
	kept := "mail_dkim_shop.test=kept kept\nmail_dkim_txt_mail._domainkey.shop.test=" + rsaV + "\nmail_dkim_txt_ed._domainkey.shop.test=v=DKIM1; k=ed25519; p=ED\n" +
		"mail_dkim_conf=unchanged\nmail_dkim_unsigned=\nmail_dkim_rspamd=unchanged\nmail_dkim=done\n"
	dkim := func(f *fake, stdin string, args ...string) (string, string, error) {
		t.Helper()
		var so, se bytes.Buffer
		o, err := Parse("mail-dkim", append([]string{"deploy@vps", "shop.test"}, args...))
		if err != nil {
			t.Fatal(err)
		}
		out := &cli.Output{Stdout: &so, Stderr: &se}
		err = Run(Ctx{Out: out, Templates: repoTemplates(t), Dial: func(string) (Session, error) { return f, nil },
			Prompter: &prompt.Prompter{In: strings.NewReader(stdin), Out: out, TTY: stdin != ""},
			Now:      func() time.Time { return time.Date(2026, 11, 12, 18, 4, 5, 0, time.FixedZone("x", 3600)) }}, o)
		return so.String(), se.String(), err
	}

	// No key there: nothing asked, the step makes them.
	f := &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg)}}
	if _, se, err := dkim(f, ""); err != nil || len(f.dkimArgs) != 5 || f.held != 1 || f.lock != "server mail-dkim" ||
		!strings.Contains(se, "keys generated, override updated, rspamd restarted") {
		t.Errorf("missing keys: %v %v %q", err, f.dkimArgs, se)
	}
	// Keys there, no terminal, no flag: refused naming both, nothing run.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg), DKIMFiles: full}}
	if _, _, err := dkim(f, ""); !strings.Contains(errText(err), "cannot ask: replace shop.test's DKIM keys? DNS must then carry the new public keys before mail signed with them is trusted") ||
		!strings.Contains(errText(err), "pass --replace-keys or --keep-keys instead") || len(f.dkims) != 0 {
		t.Errorf("no tty: %v %v", err, f.dkims)
	}
	// --keep-keys: the repair alone, and the records to publish, the RSA one split.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg), DKIMFiles: full}, dkim: kept}
	so, se, err := dkim(f, "", "--keep-keys")
	if err != nil || len(f.dkimArgs) != 5 || strings.Contains(se, "old keys") ||
		!strings.Contains(so, "    mail._domainkey.shop.test.  IN TXT  \""+rsaV[:255]+"\" \""+rsaV[255:]+"\"\n") ||
		!strings.Contains(so, "    ed._domainkey.shop.test.  IN TXT  \"v=DKIM1; k=ed25519; p=ED\"\n") || strings.Contains(so, "Until DNS") {
		t.Errorf("keep: %v %v\n%s%s", err, f.dkimArgs, se, so)
	}
	// Answered on a terminal, yes: the keys are rotated under a UTC stamp.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg), DKIMFiles: full},
		dkim: "mail_dkim_old_shop.test=rsa-2048-mail-shop.test.private.txt.kasbah-old-20261112T170405Z\n" + strings.Replace(kept, "kept kept", "replaced replaced", 1)}
	so, se, err = dkim(f, "maybe\ny\n")
	if err != nil || len(f.dkimArgs) != 6 || f.dkimArgs[4] != "--replace=20261112T170405Z" || !strings.Contains(se, "answer y or n") ||
		!strings.Contains(se, "keys replaced, override unchanged") ||
		!strings.Contains(se, "old keys: kept beside the new ones, Rspamd no longer signs with them: rsa-2048-mail-shop.test.private.txt.kasbah-old-20261112T170405Z") ||
		!strings.Contains(so, "Until DNS carries the new records") || !strings.Contains(so, "mail._domainkey.shop.test.  IN TXT") {
		t.Errorf("replace: %v %v\n%s%s", err, f.dkimArgs, se, so)
	}
	// A replace whose step reports no old keys is truncated.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg), DKIMFiles: full}, dkim: kept}
	if _, _, err := dkim(f, "", "--replace-keys"); !strings.Contains(errText(err), "reported no mail_dkim_old_shop.test") {
		t.Errorf("truncated replace: %v", err)
	}
	// A rotation that failed before any swap says the keys are as they were.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg), DKIMFiles: full}, dkim: "mail_dkim_image=dms:9\nmail_dkim_old_shop.test=\n", dkimRC: 1}
	if _, se, err := dkim(f, "", "--replace-keys"); !strings.Contains(errText(err), "could not make the DKIM keys of shop.test") ||
		!strings.Contains(errText(err), "--replace-keys rotates") || !strings.Contains(se, "no key file of shop.test was swapped: its keys are as they were") ||
		strings.Contains(se, "way back") {
		t.Errorf("failed replace: %v %q", err, se)
	}
	// One that failed partway names exactly what it swapped, which key is
	// rotated and which is not, and the way back for each swapped file.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(reg), DKIMFiles: full}, dkimRC: 1, dkim: "mail_dkim_image=dms:9\n" +
		"mail_dkim_swapped_rsa-2048-mail-shop.test.public.dns.txt=rsa-2048-mail-shop.test.public.dns.txt.kasbah-old-20261112T170405Z\n" +
		"mail_dkim_swapped_rsa-2048-mail-shop.test.public.txt=rsa-2048-mail-shop.test.public.txt.kasbah-old-20261112T170405Z\n" +
		"mail_dkim_swapped_rsa-2048-mail-shop.test.private.txt=rsa-2048-mail-shop.test.private.txt.kasbah-old-20261112T170405Z\n" +
		"mail_dkim_swapped_ed25519-ed-shop.test.public.dns.txt=ed25519-ed-shop.test.public.dns.txt.kasbah-old-20261112T170405Z\n" +
		"mail_dkim_rspamd=restarted\n"}
	_, se, err = dkim(f, "", "--replace-keys")
	dir := "/apps/data/mail/dms/config/rspamd/dkim"
	for _, w := range []string{
		"swapped in " + dir + " before the step failed: rsa-2048-mail-shop.test.private.txt rsa-2048-mail-shop.test.public.txt rsa-2048-mail-shop.test.public.dns.txt ed25519-ed-shop.test.public.dns.txt\n",
		"rotated: shop.test's mail key(s) — Rspamd signs with the new ones, so DNS must carry their new",
		"not rotated: shop.test's ed key(s) — Rspamd still signs with the old one",
		"shop.test's ed public file(s) were swapped and no longer match the old private key beside them",
		"  ssh deploy@vps 'docker run --rm --network none --user _rspamd -v " + dir + ":" + DKIMContainerDir + " --entrypoint sh dms:9 -c \"cd " + DKIMContainerDir +
			" && ln -fT rsa-2048-mail-shop.test.private.txt.kasbah-old-20261112T170405Z rsa-2048-mail-shop.test.private.txt && ln -fT rsa-2048-mail-shop.test.public.txt.kasbah-old-20261112T170405Z rsa-2048-mail-shop.test.public.txt" +
			" && ln -fT rsa-2048-mail-shop.test.public.dns.txt.kasbah-old-20261112T170405Z rsa-2048-mail-shop.test.public.dns.txt && ln -fT ed25519-ed-shop.test.public.dns.txt.kasbah-old-20261112T170405Z ed25519-ed-shop.test.public.dns.txt\"'\n",
		"supervisorctl restart rspamd"} {
		if !strings.Contains(se, w) {
			t.Errorf("partial replace: no %q in\n%s", w, se)
		}
	}
	if !strings.Contains(errText(err), "no old key was deleted") || strings.Contains(se, "NOT restarted") {
		t.Errorf("partial replace: %v", err)
	}
	// Its Rspamd sentence follows the reload, and the step's warnings follow:
	// an override kept aside, a domain unsigned, an Rspamd not restarted.
	f.dkim = "mail_dkim_swapped_rsa-2048-mail-shop.test.private.txt=\nmail_dkim_rspamd=failed\nmail_dkim_unsettled=yes\n" +
		"mail_dkim_prev=/p/dkim_signing.conf.kasbah-prev\nmail_dkim_unsigned=other.test\n"
	_, se, _ = dkim(f, "", "--replace-keys")
	for _, w := range []string{
		"the rotation's container may still be running",
		"rotated: shop.test's mail key(s) — Rspamd, NOT restarted (see below), signs with the new ones once it restarts",
		"the file it was is kept as /p/dkim_signing.conf.kasbah-prev",
		"no DKIM key for other.test",
		"Rspamd in mail-dms did not restart onto the new keys"} {
		if !strings.Contains(se, w) {
			t.Errorf("failed reload: no %q in\n%s", w, se)
		}
	}
	if strings.Contains(se, "no longer match") || strings.Contains(se, "Rspamd signs with the new ones,") {
		t.Errorf("failed reload:\n%s", se)
	}
	// A domain the registry lacks is refused before any step.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc("name: mail\nprimary_domain: example.test\ndomains:\n  - example.test\n")}}
	if _, _, err := dkim(f, "", "--replace-keys"); !strings.Contains(errText(err), "shop.test is not served by the mail stack on deploy@vps") ||
		!strings.Contains(errText(err), "kasbah server add-mail-domain deploy@vps shop.test") || len(f.dkims) != 0 {
		t.Errorf("unlisted: %v", err)
	}
}

// fake is a server whose kasbah answers from memory.
type fake struct {
	r      ReadReport
	result string
	writes []WriteBody
	calls  int
	// dkim answers the dkim step, "" for the report of a domain whose keys
	// were made; dkims are the domains it was asked for.
	dkim   string
	dkimRC int
	dkims  []string
	// held counts the server lock's takings, lock the last one's command.
	held int
	lock string
	// dkimArgs is the dkim step's last argument list.
	dkimArgs []string
}

func (f *fake) Unbounded(args ...string) ([]byte, int) {
	f.calls++
	if len(args) < 5 || args[1] != "dkim" {
		return nil, 1
	}
	f.dkimArgs = args
	d := args[len(args)-1]
	f.dkims = append(f.dkims, d)
	if f.dkim == "" {
		return []byte("mail_dkim_" + d + "=generated generated\nmail_dkim_conf=updated\n" +
			"mail_dkim_unsigned=\nmail_dkim_rspamd=restarted\nmail_dkim=done\n"), f.dkimRC
	}
	return []byte(f.dkim), f.dkimRC
}

func (f *fake) Paths() (string, string, error) { return "/apps", "/apps/data", nil }
func (f *fake) Hold(_, cmd string) (func(), error) {
	f.held++
	f.lock = cmd
	return func() {}, nil
}
func (f *fake) Close() {}
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
	if !strings.Contains(se, "Added shop.test") || !strings.Contains(se, "dkim:     keys generated, override updated, rspamd restarted") ||
		strings.Contains(se, "kasbah-prev") || f.held != 1 || f.lock != "server add-mail-domain" ||
		!strings.Contains(so, "kasbah server mail-setup-guide deploy@vps") || strings.Contains(so, "setup config dkim") ||
		len(f.dkims) != 1 || f.dkims[0] != "shop.test" {
		t.Errorf("report: %q %q %v", se, so, f.dkims)
	}

	// Both halves there: nothing written, the keys still seen to.
	// Listed without the alias: converges.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(two), Aliases: enc("postmaster@shop.test postmaster@example.test\r\n")},
		dkim: "mail_dkim_shop.test=kept kept\nmail_dkim_conf=unchanged\nmail_dkim_unsigned=\nmail_dkim_rspamd=unchanged\nmail_dkim=done\n"}
	if _, se, err := runWith(t, f, "add-mail-domain", "shop.test"); err != nil || len(f.writes) != 0 || !strings.Contains(se, "already served") ||
		!strings.Contains(se, "keys kept, override unchanged") || strings.Contains(se, "warning:") || len(f.dkims) != 1 {
		t.Errorf("idempotent: %v %q", err, se)
	}
	// A failed or truncated dkim step fails the command, after the registry.
	for _, c := range []struct {
		res  string
		rc   int
		want string
	}{
		{"x=1\n", 1, "could not make the DKIM keys of shop.test on deploy@vps (it exited 1"},
		{"mail_dkim_shop.test=kept kept\n", 0, "reported no mail_dkim "},
	} {
		f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(one)}, result: "registry=written\nalias=added\n", dkim: c.res, dkimRC: c.rc}
		if _, _, err := runWith(t, f, "add-mail-domain", "shop.test"); !strings.Contains(errText(err), c.want) || len(f.writes) != 1 {
			t.Errorf("dkim %q: %v", c.res, err)
		}
	}
	f = &fake{r: ReadReport{Dir: "dir", Env: false, Registry: enc(two)}, result: "registry=written\nalias=failed\n"}
	_, se, err = runWith(t, f, "add-mail-domain", "shop.test")
	if err != nil || len(f.writes) != 1 || strings.Count(f.writes[0].Registry, "- shop.test") != 1 ||
		!strings.Contains(se, "has no .env") || !strings.Contains(se, "setup alias add postmaster@shop.test postmaster@example.test") {
		t.Errorf("converge: %v %q %+v", err, se, f.writes)
	}

	// The primary itself: no self-alias; its keys are init's.
	f = &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(one)}, result: "registry=written\nalias=added\n"}
	so, se, err = runWith(t, f, "add-mail-domain", "example.test")
	if err != nil || len(f.writes) != 0 || len(f.dkims) != 0 || !strings.Contains(se, "example.test is the primary domain of the mail stack") || so != "" {
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
	f := &fake{r: ReadReport{Dir: "dir", Env: true, Registry: enc(two), HostAddr: "203.0.113.7",
		DKIMFiles: []string{"rsa-2048-mail-example.test.public.dns.txt", "ed25519-ed-example.test.public.dns.txt"},
		DKIMTXT:   map[string]string{"mail._domainkey.example.test": "v=DKIM1; k=rsa; p=" + strings.Repeat("B", 300)}}}
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
		"log in at https://webmail.example.test with their full address", "\"Just Logout\" discards it",
		"webmail settings in\n/apps/data/mail/cypht/.",
		"mail._domainkey.example.test.    IN TXT   \"v=DKIM1; k=rsa; p=" + strings.Repeat("B", 237) + "\" \"" + strings.Repeat("B", 63) + "\"\n",
		"ed._domainkey.example.test.      IN TXT   \"<ed25519-ed-example.test.public.dns.txt>\"\n;   ed25519-ed-example.test.public.dns.txt holds no TXT value kasbah can print",
		"mail._domainkey.shop.test.    IN TXT   \"<rsa-2048-mail-shop.test.public.dns.txt>\"\n;   no mail key yet: kasbah server mail-dkim deploy@vps shop.test --keep-keys\n",
		"step 3. The keys live in /apps/data/mail/dms/config/rspamd/dkim/.\n\nA domain without both keys sends unsigned or half-signed mail. Make them with:\n\n    kasbah server mail-dkim deploy@vps shop.test --keep-keys\n\n`kasbah server mail-dkim",
		"`kasbah check --server` warns for every domain in the registry\nthat lacks either key or its block in that file.",
		"---------------------------------------------------------------------------\n\n; ---------- example.test: the stack's own names",
	} {
		if !strings.Contains(so, want) {
			t.Errorf("guide lacks %q", want)
		}
	}
	if strings.Contains(so, "mail-dkim deploy@vps example.test") || strings.Contains(so, "docker exec mail-dms setup config dkim") {
		t.Error("guide tells the operator to make keys by hand, or for a domain that has them")
	}
	var b bytes.Buffer
	Guide(&b, GuideData{Target: "t", Primary: "p.com", Domains: []string{"p.com"},
		TXT: map[string]string{"mail._domainkey.p.com": "v=DKIM1; k=rsa; p=R", "ed._domainkey.p.com": "v=DKIM1; k=ed25519; p=E"}})
	if !strings.Contains(b.String(), "VPS address:    <VPS IP>\n") || strings.Contains(b.String(), "<rsa-") || strings.Contains(b.String(), "Make them with") {
		t.Error("no placeholder, or a key placeholder for a domain with both")
	}
}

// Both of the names the override signs with, by equality, and listed on a
// live line of the override; the rendered override lists both for a domain
// with its keys.
func TestDKIMGaps(t *testing.T) {
	tpl, err := RenderDKIM(templates.FS, []string{"a.com"}, map[string][]DKIMKey{"a.com": DKIMKeys[:]})
	if err != nil {
		t.Fatal(err)
	}
	seeded := strings.ReplaceAll(tpl, "\n", "\r\n")
	both := []string{"rsa-2048-mail-a.com.private.txt", "ed25519-ed-a.com.private.txt"}
	for _, c := range []struct {
		name           string
		keys           []string
		conf           string
		absent, unlist string
	}{
		{"both, seeded", both, seeded, "", ""},
		{"ed25519 only", both[1:], seeded, "rsa-2048-mail-a.com.private.txt", ""},
		{"rsa only", both[:1], seeded, "ed25519-ed-a.com.private.txt", ""},
		{"a hyphenated selector is another domain's key",
			[]string{"rsa-2048-mail-shop-a.com.private.txt", "ed25519-ed-shop-a.com.private.txt", "rsa-4096-mail-a.com.private.txt", "ed25519-ed-a.com.public.txt"},
			seeded, strings.Join(both, " "), ""},
		{"keys, no block (a domain added later)", both, strings.ReplaceAll(seeded, "a.com", "b.com"), "", strings.Join(both, " ")},
		{"a commented-out block", both, "# path = \"/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-a.com.private.txt\";\n" +
			"  #path = \"/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-a.com.private.txt\";\n", "", strings.Join(both, " ")},
		{"a longer domain's path", both, strings.ReplaceAll(seeded, "a.com", "xa.com"), "", strings.Join(both, " ")},
	} {
		absent, unlisted := DKIMGaps("a.com", c.keys, c.conf)
		if strings.Join(absent, " ") != c.absent || strings.Join(unlisted, " ") != c.unlist {
			t.Errorf("%s: absent %q unlisted %q", c.name, absent, unlisted)
		}
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

// fakeDocker answers the start step from files in dir: dms_id is mail-dms's
// container (absent: none until up), cypht_nginx what mail-cypht shows at
// /etc/nginx/nginx.conf, f2b_live whether Fail2ban's ignoreip has mail-cypht,
// banned whether mail-cypht's IPv4 address (172.18.0.5) is banned;
// the other flag files fail or change one step. Every call lands in dir/log.
func fakeDocker(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	script := `#!/bin/sh
s=` + dir + `
printf '%s\n' "$*" >> "$s/log"
case "$1" in
compose)
	case "$*" in
	*" ps -a -q mail-dms") cat "$s/dms_id" 2>/dev/null ;;
	*" ps -a -q mail-cypht") echo web1 ;;
	*" up -d --remove-orphans")
		if [ ! -f "$s/dms_id" ] || [ -f "$s/up_recreates" ]; then
			n=$(( $(cat "$s/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$s/n"; echo "dms$n" > "$s/dms_id"
		fi ;;
	esac ;;
inspect)
	case "$3" in
	*Mounts*) echo /data/mail/dms/config ;;
	*Health*) echo healthy ;;
	*State.Running*) if [ "$4" = web1 ] || [ ! -f "$s/dms_stopped" ]; then echo true; else echo false; fi ;;
	*State.Status*) echo running ;;
	*RestartCount*) echo 0 ;;
	*Config.Image*) echo img ;;
	esac ;;
cp) touch "$s/jail_live" ;;
exec)
	[ "$2" = web1 ] || [ ! -f "$s/dms_stopped" ] || exit 1
	shift 2
	case "$*" in
	cat*) cat "$s/cypht_nginx" ;;
	cmp*) [ -f "$s/jail_live" ] ;;
	cp*) touch "$s/jail_live" ;;
	"fail2ban-client ping") [ ! -f "$s/ping_fails" ] ;;
	"fail2ban-client get dovecot ignoreip")
		echo 'These IP addresses/networks are ignored:'
		if [ -f "$s/f2b_live" ]; then printf '|- 127.0.0.0/8\n%s- mail-cypht\n' '` + "`" + `'; else echo '` + "`" + `- 127.0.0.0/8'; fi ;;
	"getent ahosts mail-cypht")
		[ ! -f "$s/getent_fails" ] || exit 2
		printf '%s\n' 'fd70::5         STREAM mail-cypht' 'fd70::5         DGRAM' 'fd70::5         RAW' \
			'172.18.0.5      STREAM' '172.18.0.5      DGRAM' '172.18.0.5      RAW' ;;
	"fail2ban-client unban "*)
		[ ! -f "$s/unban_fails" ] || { echo 'ERROR  NOK: (boom)'; exit 255; }
		case " $* " in
		*" 172.18.0.5 "*) if [ -f "$s/banned" ]; then rm "$s/banned"; echo 1; else echo 0; fi ;;
		*) echo 0 ;;
		esac ;;
	"fail2ban-client reload")
		[ ! -f "$s/reload_fails" ] || { echo 'ERROR  NOK: (boom)'; exit 255; }
		touch "$s/f2b_live" ;;
	esac ;;
esac
`
	if err := os.WriteFile(dir+"/docker", []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return dir
}

// The start step brings Fail2ban to the jail in every container DMS's own
// setup will not copy it into, judged by Fail2ban's live ignoreip; and it
// recreates Cypht onto a replaced nginx.conf.
func TestRemoteStartJailAndNginx(t *testing.T) {
	apps := t.TempDir()
	os.MkdirAll(apps+"/mail", 0o755)
	os.WriteFile(apps+"/mail/cypht-nginx.conf", []byte("new\n"), 0o644)
	d := fakeDocker(t)
	os.WriteFile(d+"/cypht_nginx", []byte("new\n"), 0o644)
	flag := func(name string, on bool) {
		if on {
			os.WriteFile(d+"/"+name, nil, 0o644)
		} else {
			os.Remove(d + "/" + name)
		}
	}
	start := func(what, jail string, in, out []string) map[string]string {
		t.Helper()
		os.Remove(d + "/log")
		o, e, rc := run(t, "", "start", apps, "5")
		b, _ := os.ReadFile(d + "/log")
		log, kv := string(b), remote.KV([]byte(o))
		if rc != 0 || kv["mail_jail"] != jail {
			t.Errorf("%s: rc %d, mail_jail=%s, want %s\n%s%s", what, rc, kv["mail_jail"], jail, e, log)
		}
		for _, w := range in {
			if !strings.Contains(log, w) && !strings.Contains(e, w) {
				t.Errorf("%s: no %q in\n%s%s", what, w, log, e)
			}
		}
		for _, w := range out {
			if strings.Contains(log, w) {
				t.Errorf("%s: %q in\n%s", what, w, log)
			}
		}
		return kv
	}
	cp := "exec dms1 cp " + JailSource + " " + JailLive + "\n"
	reload := "exec dms1 fail2ban-client reload\n"

	// A new container: DMS's own setup copies the jail.
	kv := start("first start", "atstart", nil, []string{"cmp", "cp /data"})
	if kv["mail_cypht_nginx"] != "mounted" {
		t.Errorf("first start: nginx %s", kv["mail_cypht_nginx"])
	}
	start("jail differs", "reloaded", []string{cp, reload}, nil)
	start("jail live", "unchanged", nil, []string{"fail2ban-client reload", " cp "})

	// A failed reload is reported, the step still succeeds, and the re-run
	// reloads although the copy already matches.
	flag("jail_live", false)
	flag("f2b_live", false)
	flag("reload_fails", true)
	start("failed reload", "failed", []string{cp, "fail2ban-client reload on mail-dms failed: ERROR  NOK: (boom)"}, nil)
	flag("reload_fails", false)
	start("after a failed reload", "reloaded", []string{reload}, []string{cp})

	// Fail2ban not up yet: the copy is made, and read when it starts.
	flag("jail_live", false)
	flag("ping_fails", true)
	start("fail2ban down", "atstart", []string{cp}, []string{"fail2ban-client reload"})
	flag("ping_fails", false)

	// The same container stopped, or restarted by its policy: setup is
	// skipped on its next start, so the jail is copied in from the mount.
	flag("jail_live", false)
	flag("dms_stopped", true)
	start("same container stopped", "atstart", []string{"cp /data/mail/dms/config/fail2ban-jail.cf dms1:" + JailLive + "\n"}, []string{"exec dms1 cp", "getent"})
	flag("dms_stopped", false)

	// Recreated by up: the new container's setup copies it.
	flag("up_recreates", true)
	start("recreated", "atstart", nil, []string{"cmp", "cp /data"})
	flag("up_recreates", false)

	// A ban made before the exemption is lifted on any run that finds Fail2ban
	// answering, and only reported when there was one.
	both := "fd70::5 172.18.0.5"
	unban := func(what, jail, want, addr string, in []string) string {
		t.Helper()
		kv := start(what, jail, in, nil)
		if kv["mail_cypht_unbanned"] != want || kv["mail_cypht_addr"] != addr {
			t.Errorf("%s: unbanned=%s addr=%q, want %s %q", what, kv["mail_cypht_unbanned"], kv["mail_cypht_addr"], want, addr)
		}
		b, _ := os.ReadFile(d + "/log")
		return string(b)
	}
	// Every address of a dual-stack mail-cypht, in one call.
	flag("banned", true)
	unban("banned", "unchanged", "1", both, []string{"fail2ban-client unban " + both + "\n"})
	unban("no ban", "unchanged", "0", both, nil)
	flag("unban_fails", true)
	unban("unban fails", "unchanged", "failed", both, []string{"fail2ban-client unban " + both + " on mail-dms failed: ERROR  NOK: (boom)"})
	flag("unban_fails", false)
	flag("getent_fails", true)
	unban("unresolved", "unchanged", "failed", "", []string{"mail-dms cannot resolve mail-cypht"})
	flag("getent_fails", false)
	// The unban follows the reload, or the old jail could ban again.
	flag("jail_live", false)
	flag("f2b_live", false)
	flag("banned", true)
	if log := unban("reload and unban", "reloaded", "1", both, nil); !(strings.Index(log, "fail2ban-client reload") < strings.Index(log, "fail2ban-client unban")) {
		t.Errorf("unban before reload:\n%s", log)
	}
	flag("jail_live", false)
	flag("ping_fails", true)
	unban("fail2ban down", "atstart", "skipped", "", nil)
	flag("ping_fails", false)
	unban("fail2ban back", "unchanged", "0", both, nil)

	// Cypht showing other bytes than the file is recreated onto it; one whose
	// file cannot be read is reported unchecked.
	os.WriteFile(d+"/cypht_nginx", []byte("old\n"), 0o644)
	if kv := start("nginx replaced", "unchanged", []string{"compose -p mail up -d --no-deps --force-recreate mail-cypht\n"}, nil); kv["mail_cypht_nginx"] != "remounted" {
		t.Errorf("replaced nginx.conf: %s", kv["mail_cypht_nginx"])
	}
	os.Remove(d + "/cypht_nginx")
	if kv := start("nginx unreadable", "unchanged", nil, []string{"force-recreate"}); kv["mail_cypht_nginx"] != "unchecked" {
		t.Errorf("unreadable nginx.conf: %s", kv["mail_cypht_nginx"])
	}
}

// The format fail2ban-client 1.1.0.1 prints in DMS 15.1.0.
func TestIgnoresCypht(t *testing.T) {
	live := "These IP addresses/networks are ignored:\n|- 127.0.0.0/8\n`- mail-cypht\n"
	if !ignoresCypht(live) || !ignoresCypht(strings.ReplaceAll(live, "\n", "\r\n")) {
		t.Error("mail-cypht not found")
	}
	if ignoresCypht("These IP addresses/networks are ignored:\n`- 127.0.0.0/8\n") || ignoresCypht("`- mail-cyphtx\n") {
		t.Error("found where it is not")
	}
}
