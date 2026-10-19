package serverinit

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
)

func errText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}

func TestParse(t *testing.T) {
	o, err := Parse([]string{"deploy@vps\r", "--no-mail", "--no-backup"})
	if err != nil || o.Target != "deploy@vps" || o.Apps != "/apps" || o.Data != "/apps/data" ||
		o.Mail != prompt.No || o.Backup != prompt.No || o.AcmeChoice != prompt.Unset {
		t.Fatalf("defaults: %+v %v", o, err)
	}
	o, err = Parse([]string{"d@h", "--apps-path=/srv/apps/", "--domain=example.com\r", "--email=a@b", "--reset-acme", "--reset-acme", "--yes", "--acme-staging"})
	if err != nil || o.Apps != "/srv/apps" || o.Data != "/srv/apps/data" || o.Domain != "example.com" ||
		o.AcmeChoice != prompt.Yes || !o.Yes || !o.Staging {
		t.Fatalf("flags: %+v %v", o, err)
	}
	for _, c := range []struct{ args, want string }{
		{"", "USER@HOST is required"},
		{"a@b|c@d", "unexpected argument 'c@d'"},
		{"a@b|--reset-acme|--keep-acme", "--reset-acme and --keep-acme cannot both be given"},
		{"a@b|--no-mail|--no-mail", ""},
		{"a@b|--apps-path=", "--apps-path= must not be empty"},
		{"a@b|--apps-path=srv", "must be an absolute path"},
		{"a@b|--apps-path=/srv/k/apps|--data-path=/srv/k", "--data-path=/srv/k must not be a directory above the apps path /srv/k/apps"},
		{"a@b|--apps-path=/srv/k/apps|--data-path=/", "must not be the filesystem root"},
		{"a@b|--apps-path=/srv/k|--data-path=/srv/k/", ""},
		{"a@b|--apps-path=/srv/k|--data-path=/srv/kk", ""},
		{"a@b|--apps-path=/srv/../x", "must be a normalised path"},
		{"a@b|--apps-path=/srv//x", "must be a normalised path"},
		{"a@b|--apps-path=/srv/.", "must be a normalised path"},
		{"a@b|--apps-path=/", "must not be the filesystem root"},
		{"a@b|--apps-path=/a$HOME", "must not contain '$'"},
		{"a@b|--data-path=/d:ata", "must not contain ':'"},
		{`a@b|--data-path=/d"x`, "double quote"},
		{"a@b|--domain=nodot", "is not a domain name"},
		{"a@b|--email=a b@c", "must not contain whitespace"},
		{"a@b|--email=ab", "is not an email address"},
		{"a@b|--traefik-auth=nocolon", "must be user:pass"},
		{"a@b|--traefik-auth=u:", "password must not be empty"},
		{"a@b|--traefik-auth=u s:p", "must not contain whitespace"},
		{"a@b|--acme-staging=1", "unknown flag '--acme-staging'"},
	} {
		_, err := Parse(strings.Split(c.args, "|"))
		if got := errText(err); (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%q: got %q, want %q", c.args, got, c.want)
		}
	}
	// A mistyped flag names the flag, never its value.
	_, err = Parse([]string{"a@b", "--traefik-auths=admin:hunter2"})
	if got := errText(err); !strings.Contains(got, "'--traefik-auths'") || strings.Contains(got, "hunter2") {
		t.Errorf("unknown flag leaked its value: %q", got)
	}
	_, err = Parse([]string{"a@b", "--email=a\u0085b@c"})
	if !strings.Contains(errText(err), "whitespace") && !strings.Contains(errText(err), "control") {
		t.Errorf("a C1 control passes the email check: %v", err)
	}
	if _, err := Parse([]string{"a@b", "--apps-path=/srv/café"}); err != nil {
		t.Errorf("a UTF-8 path is not a control character: %v", err)
	}
}

func TestParseMail(t *testing.T) {
	o, err := Parse([]string{"a@b", "--with-mail", "--postmaster-password=pw:x\r"})
	if err != nil || o.Mail != prompt.Yes || o.Postmaster != "pw:x" {
		t.Fatalf("%+v %v", o, err)
	}
	for _, c := range []struct{ args, want string }{
		{"a@b|--with-mail|--no-mail", "--with-mail and --no-mail cannot both be given"},
		{"a@b|--postmaster-password=", "--postmaster-password= must not be empty"},
		{"a@b|--postmaster-password=a\nb", "must not contain a newline"},
	} {
		if _, err := Parse(strings.Split(c.args, "|")); !strings.Contains(errText(err), c.want) {
			t.Errorf("%q: %v", c.args, err)
		}
	}
}

func TestLimits(t *testing.T) {
	for _, c := range []struct{ n, kb, cpu, mem string }{
		{"16", "65011712", "14.4", "55g"},
		{"1", "8388608", "0.9", "7g"},
		{"2", "524288", "1.8", "460m"},
		{"2", "1000", "1.8", "1m"},
		{"3", "1165085", "2.7", "1g"},
		{"3", "1165084", "2.7", "1023m"},
	} {
		cpu, mem, err := Limits(c.n, c.kb)
		if err != nil || cpu != c.cpu || mem != c.mem {
			t.Errorf("%s/%s: %s %s %v", c.n, c.kb, cpu, mem, err)
		}
	}
	if _, _, err := Limits("0", "1"); err == nil {
		t.Error("nproc 0 accepted")
	}
}

func goodFacts() Facts {
	return Facts{"user": "deploy", "group": "deploy", "have_docker": "yes", "docker_server": "27.1.0",
		"docker_error": "", "compose_version": "v2.29.7", "have_rsync": "yes", "have_openssl": "yes",
		"have_gzip": "yes", "sudo_nopasswd": "yes", "pointer_state": "absent",
		"pointer_value": "", "apps_state": "absent", "apps_owned": "no", "apps_writable": "no",
		"apps_owner": "", "apps_write_error": "", "apps_root_state": "absent", "apps_root_owner": "",
		"apps_base": "/", "apps_base_owner": "root:root", "apps_base_mode": "755", "data_state": "absent",
		"data_writable": "no", "data_owner": "", "data_scope": "inside", "data_base": "/",
		"data_base_writable": "no", "acme_store": "absent", "nproc": "4", "memtotal_kb": "8000000"}
}

func TestPreflight(t *testing.T) {
	if err := Preflight(goodFacts(), "d@h", "/apps", "/apps/data"); err != nil {
		t.Fatalf("a good host fails: %v", err)
	}
	for _, c := range []struct {
		set  Facts
		want string
	}{
		{Facts{"have_docker": "no"}, "no docker command"},
		{Facts{"docker_server": "", "docker_error": "permission denied"}, "usermod -aG docker deploy"},
		{Facts{"docker_server": "23.0.1"}, "the daemon reports 23.0.1"},
		{Facts{"compose_version": ""}, "produced nothing"},
		{Facts{"compose_version": "1.29.2"}, "the plugin reports 1.29.2"},
		{Facts{"compose_version": "5.2.0"}, ""},
		{Facts{"have_gzip": "no"}, "gzip is missing"},
		{Facts{"sudo_nopasswd": "no"}, "sudo mkdir -p /apps && sudo chown deploy:deploy /apps"},
		{Facts{"apps_state": "dangling"}, "symlink to nothing"},
		{Facts{"apps_state": "unreachable", "apps_root_state": "exists", "apps_root_owner": "root:root"}, "cannot see it"},
		{Facts{"apps_state": "dir", "apps_owned": "no", "apps_owner": "root:root"}, "sudo chown deploy:deploy /apps"},
		{Facts{"apps_state": "dir", "apps_owned": "yes", "apps_writable": "no", "apps_write_error": "touch: Read-only file system"}, "read-only filesystem"},
		{Facts{"data_state": "dir", "data_writable": "no"}, "is not writable by deploy"},
		{Facts{"data_scope": "outside", "data_base": "/srv"}, "/srv is not writable"},
		{Facts{"nproc": ""}, "nproc=''"},
	} {
		f := goodFacts()
		for k, v := range c.set {
			f[k] = v
		}
		got := errText(Preflight(f, "d@h", "/apps", "/apps/data"))
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%v: got %q, want %q", c.set, got, c.want)
		}
	}
}

func TestCheckPointer(t *testing.T) {
	for _, c := range []struct{ state, value, apps, want string }{
		{"absent", "", "/apps", ""},
		{"present", "/apps", "/apps", ""},
		{"present", "/srv/apps", "/srv/apps", ""},
		{"present", "/srv/apps", "/apps", "already prepared at /srv/apps"},
		{"present", "/apps", "/srv/apps", "Nothing has been changed"},
		{"present", "/srv/x/..", "/apps", "resolves to"},
		{"present", "srv/apps", "/apps", "not an absolute path"},
		{"present", "", "/apps", "not an absolute path"},
		{"notfile", "", "/apps", "not a regular file"},
		{"unreachable", "", "/apps", "chmod 755 /etc/kasbah"},
		{"unreadable", "", "/apps", "cannot be read"},
	} {
		got := errText(CheckPointer(Facts{"pointer_state": c.state, "pointer_value": c.value, "user": "u"}, "d@h", c.apps))
		if (c.want == "") != (got == "") || !strings.Contains(got, c.want) {
			t.Errorf("%s %q at %s: got %q, want %q", c.state, c.value, c.apps, got, c.want)
		}
		if strings.Contains(got, "--apps-path=/srv/x/..") {
			t.Errorf("prescribes a flag its own parser rejects: %q", got)
		}
	}
}

func newOut() (*cli.Output, *bytes.Buffer) {
	var b bytes.Buffer
	return &cli.Output{Stdout: &b, Stderr: &b}, &b
}

func TestPointerVerdict(t *testing.T) {
	out, b := newOut()
	for _, s := range []string{"written", "unchanged"} {
		if err := PointerVerdict(out, s, "d@h", "/srv/apps", "u"); err != nil || b.Len() != 0 {
			t.Errorf("%s: %v %q", s, err, b.String())
		}
	}
	if err := PointerVerdict(out, "nosudo", "d@h", "/apps", "u"); err != nil || !strings.Contains(b.String(), "warning:") {
		t.Errorf("nosudo at /apps is a warning: %v %q", err, b.String())
	}
	err := PointerVerdict(out, "nosudo", "d@h", "/srv/apps", "u")
	if got := errText(err); !strings.Contains(got, "exit 4") || !strings.Contains(got, "sudo tee /etc/kasbah/apps-path") {
		t.Errorf("nosudo elsewhere: %q", got)
	}
	if PointerVerdict(out, "other", "d@h", "/apps", "u") == nil {
		t.Error("an unknown report passes")
	}
}

const sharedDoc = "http:\n  middlewares:\n    admin-area-auth:\n      basicAuth:\n        users:\n          - \"them:$2y$05$THEIRS\"\n    traefik-dashboard-auth:\n      basicAuth:\n        users:\n          - \"dash:$2y$05$OURS\"\n  routers:\n    traefik-dashboard:\n      rule: \"Host(`traefik.example.com`)\"\n"

func TestExtract(t *testing.T) {
	if a, err := ExtractAuth(sharedDoc); err != nil || a != "dash:$2y$05$OURS" {
		t.Errorf("auth: %q %v", a, err)
	}
	inline := "http:\n  middlewares:\n    traefik-dashboard-auth:\n      basicAuth:\n        users: [\"bob:$2y$05$x\"]\n"
	if a, err := ExtractAuth(inline); err != nil || a != "bob:$2y$05$x" {
		t.Errorf("inline: %q %v", a, err)
	}
	if a, err := ExtractAuth("http:\n  middlewares: {}\n"); err != nil || a != "" {
		t.Errorf("none: %q %v", a, err)
	}
	if _, err := ExtractAuth("no hash here"); err == nil {
		t.Error("a scalar document is read as YAML with no query error")
	}
	junk := "http:\n  middlewares:\n    traefik-dashboard-auth:\n      basicAuth:\n        users:\n          - notanentry\n"
	if _, err := ExtractAuth(junk); !strings.Contains(errText(err), "not an htpasswd entry") {
		t.Errorf("junk: %v", err)
	}
	if d, err := DashboardApex(sharedDoc); err != nil || d != "example.com" {
		t.Errorf("domain: %q %v", d, err)
	}
	if _, err := DashboardApex("http: [1\n"); err == nil {
		t.Error("broken YAML parses")
	}
	for _, c := range []struct{ doc, want string }{
		{"services:\n  traefik:\n    image: traefik:v3.8.0\n", "traefik:v3.8.0"},
		{"services:\n  traefik:\n    image: mirror.example/traefik:v3\n", ""},
		{"services:\n  traefik:\n    image: traefik@sha256:abc\n", ""},
	} {
		if got, _ := ExtractImage(c.doc); got != c.want {
			t.Errorf("image %q: %q", c.doc, got)
		}
	}
}

// acmeRun settles one ACME case and returns the decision and the output.
func acmeRun(t *testing.T, store, stored string, staticErr error, o Options, answer string, tty bool) (Acme, string, error) {
	t.Helper()
	out, b := newOut()
	p := &prompt.Prompter{In: strings.NewReader(answer), Out: out, TTY: tty}
	o.Target, o.Apps = "d@h", "/apps"
	static := "x"
	if strings.HasPrefix(answer, "nocontent") {
		static, answer = "", strings.TrimPrefix(answer, "nocontent")
	}
	a, err := SettleAcme(out, p, o, store, static, stored, staticErr)
	return a, b.String(), err
}

func TestSettleAcme(t *testing.T) {
	staging := Options{Staging: true}
	// Nothing to lose: silent, whatever the CA.
	for _, store := range []string{"absent", "empty", "notfile"} {
		a, said, err := acmeRun(t, store, CAProduction, nil, staging, "", false)
		if err != nil || a.Reset || said != "" {
			t.Errorf("%s store: %+v %q %v", store, a, said, err)
		}
	}
	// The idempotent re-run.
	if a, said, err := acmeRun(t, "nonempty", CAProduction, nil, Options{}, "", false); err != nil || a.Reset || said != "" {
		t.Errorf("same CA: %+v %q %v", a, said, err)
	}
	// The switch: a confirmation --yes answers; declining aborts.
	if a, _, err := acmeRun(t, "nonempty", CAProduction, nil, staging, "", false); err == nil || a.Reset || !strings.Contains(errText(err), "--yes") {
		t.Errorf("switch without --yes or a terminal: %+v %v", a, err)
	}
	if a, _, err := acmeRun(t, "nonempty", CAProduction, nil, Options{Staging: true, Yes: true}, "", false); err != nil || !a.Reset {
		t.Errorf("switch with --yes: %+v %v", a, err)
	}
	if _, _, err := acmeRun(t, "nonempty", CAStaging, nil, Options{}, "n\n", true); !strings.Contains(errText(err), "re-run with --acme-staging") {
		t.Errorf("declined switch: %v", err)
	}
	if _, said, _ := acmeRun(t, "nonempty", "https://ca.example/dir", nil, Options{Yes: true}, "", false); strings.Contains(said, "--acme-staging") || !strings.Contains(said, "does not render") {
		t.Errorf("a foreign CA is offered a flag that cannot reproduce it: %q", said)
	}
	// --keep-acme meeting a switch refuses, --yes or not: the store is never archived.
	for _, yes := range []bool{false, true} {
		a, _, err := acmeRun(t, "nonempty", CAProduction, nil, Options{Staging: true, Yes: yes, AcmeChoice: prompt.No}, "y\n", true)
		if err == nil || a.Reset || !strings.Contains(errText(err), "--keep-acme cannot be honoured") {
			t.Errorf("--keep-acme yes=%v on a switch: %+v %v", yes, a, err)
		}
	}
	// --reset-acme on a switch is spare, and does not answer it.
	if a, said, err := acmeRun(t, "nonempty", CAProduction, nil, Options{Staging: true, AcmeChoice: prompt.Yes}, "", false); err == nil || a.Reset || !strings.Contains(said, "--reset-acme had no effect") {
		t.Errorf("--reset-acme on a switch: %+v %q %v", a, said, err)
	}
	// The unknown store: a choice --yes does not answer.
	for _, origin := range []struct {
		stored string
		err    error
		said   string
	}{{"", nil, "names no caServer"}, {"", errUnparsed{}, "does not parse"}} {
		_, said, err := acmeRun(t, "nonempty", origin.stored, origin.err, Options{Yes: true}, "", false)
		if !strings.Contains(errText(err), "--reset-acme or --keep-acme") || !strings.Contains(said, origin.said) {
			t.Errorf("unknown store with only --yes: %q %v", said, err)
		}
	}
	if a, said, err := acmeRun(t, "nonempty", "", nil, Options{Yes: true, AcmeChoice: prompt.No}, "", false); err != nil || a.Reset || !a.KeptUnknown || !strings.Contains(said, "keeping acme.json") {
		t.Errorf("--keep-acme --yes on an unknown store keeps it: %+v %v", a, err)
	}
	if a, _, err := acmeRun(t, "nonempty", "", nil, Options{AcmeChoice: prompt.Yes}, "", false); err != nil || !a.Reset {
		t.Errorf("--reset-acme on an unknown store resets: %+v %v", a, err)
	}
	if a, _, err := acmeRun(t, "nonempty", "", nil, Options{}, "n\n", true); err != nil || a.Reset || !a.KeptUnknown {
		t.Errorf("answering keep at the terminal: %+v %v", a, err)
	}
	// A choice flag on a run that never reaches the choice warns and changes nothing.
	for _, c := range []Options{{AcmeChoice: prompt.Yes}, {AcmeChoice: prompt.No}, {AcmeChoice: prompt.No, Yes: true}} {
		a, said, err := acmeRun(t, "empty", "", nil, c, "", false)
		if err != nil || a.Reset || !strings.Contains(said, "had no effect") {
			t.Errorf("spare %+v: %+v %q %v", c, a, said, err)
		}
	}
}

func TestResolveReuses(t *testing.T) {
	out, _ := newOut()
	p := &prompt.Prompter{In: strings.NewReader(""), Out: out}
	o := Options{Target: "d@h", Apps: "/apps", Data: "/apps/data"}
	cur := map[string]string{
		"dynamic/_shared.yml": sharedDoc,
		"traefik.yml":         "certificatesResolvers:\n  letsencrypt:\n    acme:\n      email: \"ops@example.com\"\n      caServer: \"" + CAProduction + "\"\n",
		"compose.yml":         "services:\n  traefik:\n    image: traefik:v3.8.1\n",
	}
	never := func(string, string) (string, error) { t.Fatal("hashed on a re-run"); return "", nil }
	v, err := Resolve(out, p, o, cur, "nonempty", never)
	if err != nil || v.Domain != "example.com" || v.Email != "ops@example.com" || v.AuthEntry != "dash:$2y$05$OURS" ||
		v.AuthOrigin != "reused" || v.Image != "traefik:v3.8.1" || v.Acme.Reset {
		t.Fatalf("re-run: %+v %v", v, err)
	}
	// A broken entry is no reason to refuse a run that sets the credentials.
	cur["dynamic/_shared.yml"] = "http:\n  middlewares:\n    traefik-dashboard-auth:\n      basicAuth:\n        users: [junk]\n"
	o.Domain, o.Auth = "example.org", "admin:pw"
	v, err = Resolve(out, p, o, cur, "nonempty", func(u, pw string) (string, error) { return u + ":$2y$05$h", nil })
	if err != nil || v.AuthOrigin != "flag" || v.Domain != "example.org" {
		t.Fatalf("flags over a broken entry: %+v %v", v, err)
	}
	// Without the flag, an unparseable file is not guessed past.
	o.Domain, o.Auth = "", ""
	cur["dynamic/_shared.yml"] = "http: [1\n"
	if _, err := Resolve(out, p, o, cur, "empty", never); !strings.Contains(errText(err), "could not be read as YAML") {
		t.Errorf("unparseable _shared.yml: %v", err)
	}
	// Nothing on the server and no terminal: the flag is named.
	if _, err := Resolve(out, p, o, map[string]string{}, "absent", never); !strings.Contains(errText(err), "--domain=<value>") {
		t.Errorf("fresh server, no terminal: %v", err)
	}
}

func repoTemplates(t *testing.T) string {
	t.Helper()
	dir, err := filepath.Abs("../../templates")
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

func TestRender(t *testing.T) {
	o := Options{Apps: "/srv/apps", Data: "/data"}
	v := Values{Image: TraefikImage, Domain: "example.com", Email: "ops@example.com", AuthEntry: "admin:$2y$05$abc", Acme: Acme{CA: CAStaging}}
	r, err := Render(repoTemplates(t), o, v)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []struct{ rel, s string }{
		{"compose.yml", "image: " + TraefikImage},
		{"compose.yml", `"/srv/apps/traefik/traefik.yml:/etc/traefik/traefik.yml:ro"`},
		{"compose.yml", `"/data/traefik/letsencrypt/acme.json:/letsencrypt/acme.json"`},
		{"traefik.yml", `caServer: "` + CAStaging + `"`},
		{"traefik.yml", `email: "ops@example.com"`},
		{"dynamic/_shared.yml", `"admin:$2y$05$abc"`},
		{"dynamic/_shared.yml", "Host(`traefik.example.com`)"},
	} {
		if !strings.Contains(r[want.rel], want.s) {
			t.Errorf("%s lacks %q", want.rel, want.s)
		}
	}
	if strings.Contains(r["compose.yml"]+r["traefik.yml"]+r["dynamic/_shared.yml"], "__") {
		t.Error("a token survived")
	}
	// A value carrying a token is not rescanned.
	o.Apps = "/srv/__STAGE__"
	if _, err := Render(repoTemplates(t), o, v); err != nil {
		t.Errorf("a substituted token is rescanned: %v", err)
	}

	dir := t.TempDir()
	os.MkdirAll(filepath.Join(dir, "traefik/dynamic"), 0o755)
	for _, rel := range Files {
		os.WriteFile(filepath.Join(dir, "traefik", rel), []byte("a: __NOPE__\n"), 0o644)
	}
	if _, err := Render(dir, o, v); !strings.Contains(errText(err), "__NOPE__") {
		t.Errorf("an unknown token: %v", err)
	}
	for _, rel := range Files {
		os.WriteFile(filepath.Join(dir, "traefik", rel), []byte("a: \"__ACME_EMAIL__\"\n"), 0o644)
	}
	v.Email = `x"y: [`
	if _, err := Render(dir, o, v); !strings.Contains(errText(err), "not valid YAML") {
		t.Errorf("unparseable render ships: %v", err)
	}
	if _, err := Render(t.TempDir(), o, v); !strings.Contains(errText(err), "templates are missing") {
		t.Errorf("missing templates: %v", err)
	}
}

// signed appends the payload's size and sha256, as the workstation does.
func signed(body string, args ...string) []string {
	size, sum := remote.Digest([]byte(body))
	return append(args, size, sum)
}

func remoteRun(t *testing.T, stdin string, args ...string) (string, string, int) {
	t.Helper()
	var o, e bytes.Buffer
	rc := Remote(args, strings.NewReader(stdin), &o, &e)
	return o.String(), e.String(), rc
}

func mode(t *testing.T, p string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

func TestRemoteSteps(t *testing.T) {
	root := t.TempDir()
	apps, data := root+"/apps", root+"/apps/data"
	os.Mkdir(apps, 0o755)
	acme := data + "/traefik/letsencrypt/acme.json"

	if out, e, rc := remoteRun(t, "", "layout", apps, data); rc != 0 || out != "acme=created\n" {
		t.Fatalf("layout: %q %q %d", out, e, rc)
	}
	for _, d := range []string{"/.kasbah", "/backups", "/traefik/dynamic"} {
		if fi, err := os.Stat(apps + d); err != nil || !fi.IsDir() {
			t.Errorf("%s not created", d)
		}
	}
	if mode(t, acme) != 0o600 {
		t.Errorf("acme.json mode %o", mode(t, acme))
	}
	os.Chmod(acme, 0o644)
	if out, _, rc := remoteRun(t, "", "layout", apps, data); rc != 0 || out != "acme=existed\n" || mode(t, acme) != 0o600 {
		t.Errorf("re-run: %q %d %o", out, rc, mode(t, acme))
	}

	// read: absent marker, files as they are.
	os.WriteFile(apps+"/traefik/traefik.yml", []byte("x: 1\n\n"), 0o644)
	out, _, rc := remoteRun(t, "", "read", apps)
	var r ReadReport
	if rc != 0 || json.Unmarshal([]byte(out), &r) != nil || r.Marker != "absent" || r.Traefik["compose.yml"] != "" {
		t.Fatalf("read: %q %d", out, rc)
	}
	if b, _ := base64.StdEncoding.DecodeString(r.Traefik["traefik.yml"]); string(b) != "x: 1\n\n" {
		t.Errorf("trailing newlines lost: %q", b)
	}

	// marker: written, then unchanged, mode 644 whatever the umask.
	if out, _, rc := remoteRun(t, "{\n  \"a\": 1\n}\n", signed("{\n  \"a\": 1\n}\n", "marker", apps)...); rc != 0 || out != "marker=written\n" {
		t.Errorf("marker: %q %d", out, rc)
	}
	if out, _, _ := remoteRun(t, "{\n  \"a\": 1\n}\n", signed("{\n  \"a\": 1\n}\n", "marker", apps)...); out != "marker=unchanged\n" {
		t.Errorf("marker re-run: %q", out)
	}
	if mode(t, apps+"/.kasbah/server.json") != 0o644 {
		t.Errorf("marker mode %o", mode(t, apps+"/.kasbah/server.json"))
	}
	if out, _, _ := remoteRun(t, "", "read", apps); !strings.Contains(out, `"marker":"present"`) {
		t.Errorf("read after marker: %q", out)
	}

	// write: atomic, 644, no temp left behind.
	dest := apps + "/traefik/dynamic/_shared.yml"
	if _, _, rc := remoteRun(t, "a: 1\n", signed("a: 1\n", "write", dest)...); rc != 0 {
		t.Fatal("write failed")
	}
	if b, _ := os.ReadFile(dest); string(b) != "a: 1\n" || mode(t, dest) != 0o644 {
		t.Errorf("write: %q %o", b, mode(t, dest))
	}
	if left, _ := filepath.Glob(dest + ".tmp.*"); len(left) != 0 {
		t.Errorf("temp left: %v", left)
	}

	// acme-reset: archived, never deleted, never overwritten.
	os.WriteFile(acme, []byte("{certs}"), 0o600)
	out, _, rc = remoteRun(t, "", "acme-reset", acme, "20261019T000000Z")
	if rc != 0 || !strings.Contains(out, "acme_reset=done") || !strings.Contains(out, "acme_archive="+acme+".20261019T000000Z") {
		t.Fatalf("reset: %q %d", out, rc)
	}
	if b, _ := os.ReadFile(acme + ".20261019T000000Z"); string(b) != "{certs}" {
		t.Errorf("archive: %q", b)
	}
	if fi, _ := os.Stat(acme); fi.Size() != 0 || mode(t, acme) != 0o600 {
		t.Errorf("fresh store: %d %o", fi.Size(), mode(t, acme))
	}
	os.WriteFile(acme, []byte("{more}"), 0o600)
	if _, e, rc := remoteRun(t, "", "acme-reset", acme, "20261019T000000Z"); rc == 0 || !strings.Contains(e, "will not write over") {
		t.Errorf("archive overwritten: %q %d", e, rc)
	}

	// A directory where acme.json belongs is refused, not worked around.
	os.Remove(acme)
	os.Mkdir(acme, 0o755)
	if _, e, rc := remoteRun(t, "", "layout", apps, data); rc != 1 || !strings.Contains(e, "remote: "+acme+" exists and is not a regular file") {
		t.Errorf("acme dir: %q %d", e, rc)
	}
	if _, e, rc := remoteRun(t, "", "bogus"); rc != 1 || !strings.Contains(e, "usage") {
		t.Errorf("bogus: %q %d", e, rc)
	}
}
