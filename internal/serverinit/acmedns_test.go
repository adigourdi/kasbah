package serverinit

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
)

const dnsToken = "CF_DNS_API_TOKEN=s3cr3t-token"

func envFile(t *testing.T, body string, mode os.FileMode) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "cf.env")
	if err := os.WriteFile(p, []byte(body), mode); err != nil {
		t.Fatal(err)
	}
	os.Chmod(p, mode)
	return p
}

func TestParseAcmeDNS(t *testing.T) {
	good := envFile(t, "# token\r\n"+dnsToken+"\r\n", 0o600)
	o, err := Parse([]string{"u@h", "--acme-dns=cloudflare:" + good, "--no-acme-dns=ovh"})
	if err != nil {
		t.Fatal(err)
	}
	if len(o.AcmeDNS) != 1 || o.AcmeDNS[0].Provider != "cloudflare" || string(o.AcmeDNS[0].Body) != "# token\n"+dnsToken+"\n" {
		t.Errorf("parsed %+v", o.AcmeDNS)
	}
	if len(o.NoAcmeDNS) != 1 || o.NoAcmeDNS[0] != "ovh" {
		t.Errorf("parsed %v", o.NoAcmeDNS)
	}
	dir := t.TempDir()
	for _, tc := range []struct {
		args []string
		want string
	}{
		{[]string{"--acme-dns=cloudflare"}, "must be <provider>:<env file>"},
		{[]string{"--acme-dns"}, "--acme-dns takes a value"},
		{[]string{"--acme-dns=http:" + good}, "'http' is the HTTP-01 resolver's name"},
		{[]string{"--acme-dns=Cloud-Flare:" + good}, "is not a provider name"},
		{[]string{"--acme-dns=:" + good}, "names no provider"},
		{[]string{"--acme-dns=cloudflare:"}, "names no env file"},
		{[]string{"--acme-dns=cloudflare:/nope/x.env"}, "no such file"},
		{[]string{"--acme-dns=cloudflare:" + dir}, "not a regular file"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, dnsToken+"\n", 0o640)}, "is open to its group or others (mode 0640)"},
		{[]string{"--acme-dns=letsencrypt:" + good}, "the HTTP-01 resolver's former name"},
		{[]string{"--acme-dns=yes:" + good}, "YAML reads 'yes' as a boolean"},
		{[]string{"--no-acme-dns=null"}, "YAML reads 'null'"},
		{[]string{"--acme-dns=1e3:" + good}, "opening with a letter"},
		{[]string{"--acme-dns=123:" + good}, "is not a provider name"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "# k\nCF_DNS_API_TOKEN=\"s3cr3tTOKENvalue\n", 0o600)}, "line 2 (CF_DNS_API_TOKEN): the value holds a quote"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=s3cr3t$HOME\n", 0o600)}, "line 1 (CF_DNS_API_TOKEN): the value holds a $"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=s3cr3t #x\n", 0o600)}, "the value holds a #"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=s3cr3t\\n\n", 0o600)}, "the value holds a backslash"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=s3cr3t \n", 0o600)}, "opens or ends with a space"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=\n", 0o600)}, "the value is empty"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=s3cr3t\x01\n", 0o600)}, "line 1 holds a control character"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "CF_DNS_API_TOKEN=s3cr3té\n", 0o600)}, "not printable ASCII"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "export CF_DNS_API_TOKEN=s3cr3t\n", 0o600)}, "line 1: the name before = is not"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "s3cr3t_lower=x\n", 0o600)}, "line 1: the name before = is not"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, "# only\n\n", 0o600)}, "it sets no key"},
		{[]string{"--acme-dns=cloudflare:" + envFile(t, dnsToken+"\nnot an assignment s3cr3t\n", 0o600)}, "line 2 is not KEY=value"},
		{[]string{"--acme-dns=cloudflare:" + good, "--acme-dns=cloudflare:" + good}, "is given twice"},
		{[]string{"--acme-dns=cloudflare:" + good, "--no-acme-dns=cloudflare"}, "contradict each other"},
		{[]string{"--no-acme-dns=ovh", "--no-acme-dns=ovh"}, "--no-acme-dns=ovh is given twice"},
		{[]string{"--no-acme-dns=http"}, "'http' is the HTTP-01 resolver's name"},
	} {
		_, err := Parse(append([]string{"u@h"}, tc.args...))
		if got := errText(err); !strings.Contains(got, tc.want) || strings.Contains(got, "s3cr3t") {
			t.Errorf("%v: %q", tc.args, got)
		}
	}
}

func TestRenderDNS(t *testing.T) {
	o := Options{Apps: "/srv/apps", Data: "/data"}
	v := Values{Image: TraefikImage, Email: "ops@example.com", Acme: Acme{CA: CAStaging}}
	plain, err := Render(repoTemplates(t), o, v)
	if err != nil {
		t.Fatal(err)
	}
	// Without a provider, nothing of the feature shows.
	if !strings.Contains(plain["traefik.yml"], "entryPoint: web\n\napi:") || strings.Contains(plain["traefik.yml"], "dnsChallenge") ||
		!strings.Contains(plain["compose.yml"], "acme.json\"\n    networks:") || strings.Contains(plain["compose.yml"], "env_file") {
		t.Errorf("a render without DNS resolvers changed:\n%s\n%s", plain["traefik.yml"], plain["compose.yml"])
	}
	v.DNS = []string{"cloudflare", "ovh"}
	r, err := Render(repoTemplates(t), o, v)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := Render(repoTemplates(t), o, v)
	if again["traefik.yml"] != r["traefik.yml"] || again["compose.yml"] != r["compose.yml"] {
		t.Error("re-render is not byte-stable")
	}
	st := r["traefik.yml"]
	if strings.Count(st, `caServer: "`+CAStaging+`"`) != 3 || strings.Count(st, "storage: /letsencrypt/acme.json") != 3 || strings.Count(st, `email: "ops@example.com"`) != 3 {
		t.Errorf("every resolver shares address, endpoint and store:\n%s", st)
	}
	for _, want := range []string{"  cloudflare:\n    acme:", "        provider: cloudflare\n        resolvers:\n          - \"1.1.1.1:53\"\n          - \"8.8.8.8:53\"\n", "        provider: ovh\n"} {
		if !strings.Contains(st, want) {
			t.Errorf("traefik.yml lacks %q:\n%s", want, st)
		}
	}
	if !strings.Contains(r["compose.yml"], "    env_file:\n      - acme-dns/cloudflare.env\n      - acme-dns/ovh.env\n    networks:") {
		t.Errorf("compose.yml env_file:\n%s", r["compose.yml"])
	}
	if got, err := DNSResolvers(st); err != nil || strings.Join(got, " ") != "cloudflare ovh" {
		t.Errorf("read back %v %v", got, err)
	}
	if got, _ := DNSResolvers(plain["traefik.yml"]); len(got) != 0 {
		t.Errorf("plain declares %v", got)
	}
	if _, err := DNSResolvers("{nope"); !Unparsed(err) {
		t.Errorf("unparsed: %v", err)
	}
}

func TestSettleDNS(t *testing.T) {
	static := "certificatesResolvers:\n  http: {acme: {httpChallenge: {entryPoint: web}}}\n  cloudflare: {acme: {dnsChallenge: {provider: cloudflare}}}\n  ovh: {acme: {dnsChallenge: {provider: ovh}}}\n"
	o := Options{Target: "u@h", Apps: "/apps"}
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	pl, err := SettleDNS(out, o, static, []string{"cloudflare", "ovh"}, nil)
	if err != nil || strings.Join(pl.List, " ") != "cloudflare ovh" || strings.Join(pl.Kept, " ") != "cloudflare ovh" || len(pl.Remove) != 0 {
		t.Errorf("a plain re-run keeps them: %+v %v", pl, err)
	}
	_, err = SettleDNS(out, o, static, []string{"cloudflare"}, nil)
	if got := errText(err); !strings.Contains(got, "declares the DNS resolver 'ovh'") || !strings.Contains(got, "--acme-dns=ovh:<env file>") || !strings.Contains(got, "--no-acme-dns=ovh") {
		t.Errorf("missing env file: %q", got)
	}
	o.NoAcmeDNS = []string{"ovh"}
	named := map[string][]string{"shop.toml": {"ovh"}, "_mail.yml": {"ovh"}, "blog.yml": {"cloudflare"}}
	_, err = SettleDNS(out, o, static, []string{"cloudflare", "ovh"}, named)
	if got := errText(err); !strings.Contains(got, "--no-acme-dns=ovh refused") || !strings.Contains(got, "dynamic/_mail.yml dynamic/shop.toml") || strings.Contains(got, "blog.yml") {
		t.Errorf("removal in use: %q", got)
	}
	delete(named, "shop.toml")
	delete(named, "_mail.yml")
	o.AcmeDNS = []AcmeDNS{{Provider: "gandiv5", Body: []byte("X=1\n")}}
	pl, err = SettleDNS(out, o, static, []string{"cloudflare", "ovh", "stale"}, named)
	if err != nil || strings.Join(pl.List, " ") != "cloudflare gandiv5" || strings.Join(pl.Remove, " ") != "ovh stale" || len(pl.Install) != 1 {
		t.Errorf("add and remove: %+v %v", pl, err)
	}
	// An unreadable traefik.yml keeps what has credentials.
	o = Options{Target: "u@h", Apps: "/apps", NoAcmeDNS: []string{"route53"}}
	buf.Reset()
	pl, err = SettleDNS(out, o, "{nope", []string{"ovh"}, nil)
	if err != nil || strings.Join(pl.List, " ") != "ovh" || !strings.Contains(buf.String(), "--no-acme-dns=route53 had no effect") {
		t.Errorf("unreadable: %+v %v %s", pl, err, buf.String())
	}
	// So does an absent one, which the server reads back as "".
	pl, err = SettleDNS(out, Options{Target: "u@h", Apps: "/apps"}, "", []string{"cloudflare", "ovh"}, nil)
	if err != nil || strings.Join(pl.List, " ") != "cloudflare ovh" || len(pl.Remove) != 0 {
		t.Errorf("absent traefik.yml: %+v %v", pl, err)
	}
}

func TestDNSNamed(t *testing.T) {
	dir := t.TempDir()
	files := map[string]string{
		"shop.yml":        "http:\n  routers:\n    a: {tls: {CertResolver: '{{ \"CloudFlare\" }}'}}\n",
		"blog.toml":       "[http.routers.b.tls]\ncertResolver = \"ovh\"\n",
		"notes.txt":       "# ovh-backup\n",
		"word.yml":        "rule: Host(`ovhcloud.example.com`) # cloudflare2\n",
		"_shared.yml":     "certResolver: ovh\n",
		"sub/deep.yml":    "x: cloudflare\n",
		"_mail.yml":       "tcp: {routers: {m: {tls: {certResolver: http}}}}\n",
		"sub/_shared.yml": "y: ovh\n",
	}
	files["esc.yml"] = "certResolver: \"\\x63loudflare\"\n"
	// Anything but plain ASCII without backslash, '!' or a template names all.
	files["cr.yml"] = "certResolver: \"cloud\\\rflare\"\n"
	files["nel.yml"] = "a: \"x\u0085y\"\n"
	files["tag.yml"] = "certResolver: !<tag:yaml.org,2002:binary> Y2xvdWRmbGFyZQ==\n"
	files["neg.yml"] = "rule: \"!Host(`a.test`)\"\n"
	files["utf16.yml"] = "\xff\xfec\x00f\x00"
	files["lonecr.yml"] = "a: b\rc: d\n"
	files["dash.yml"] = "# a comment — with arrows → and an em-dash\nx: ovh\n"
	files["ls.yml"] = "a: \"x\u2028y\"\n"
	for f, b := range files {
		os.MkdirAll(filepath.Dir(filepath.Join(dir, f)), 0o755)
		os.WriteFile(filepath.Join(dir, f), []byte(b), 0o644)
	}
	// Neither a link nor a FIFO is opened: each names every candidate.
	outside := filepath.Join(t.TempDir(), "x.yml")
	os.WriteFile(outside, []byte("nothing\n"), 0o644)
	os.Symlink(outside, filepath.Join(dir, "link.yml"))
	if err := syscall.Mkfifo(filepath.Join(dir, "pipe.yml"), 0o644); err != nil {
		t.Fatal(err)
	}
	got := DNSNamed(dir, []string{"cloudflare", "ovh"})
	all := "cloudflare ovh"
	want := map[string]string{"shop.yml": all, "esc.yml": all, "link.yml": all, "pipe.yml": all,
		"cr.yml": all, "nel.yml": all, "tag.yml": all, "neg.yml": all, "utf16.yml": all, "lonecr.yml": all,
		"ls.yml": all, "dash.yml": "ovh",
		"blog.toml": "ovh", "notes.txt": "ovh", "sub/deep.yml": "cloudflare", "sub/_shared.yml": "ovh"}
	if len(got) != len(want) {
		t.Errorf("DNSNamed: %v", got)
	}
	for f, w := range want {
		if strings.Join(got[f], " ") != w {
			t.Errorf("%s: %v, want %s", f, got[f], w)
		}
	}
	if got := DNSNamed(dir+"/nope", []string{"ovh"}); len(got) != 0 {
		t.Errorf("absent dir: %v", got)
	}
}

func TestRemoteAcmeDNS(t *testing.T) {
	apps := t.TempDir()
	os.MkdirAll(apps+"/traefik/dynamic", 0o755)
	body := []byte(dnsToken + "\n")
	size, sum := remote.Digest(body)
	run := func(stdin []byte, args ...string) (string, string, int) {
		var o, e bytes.Buffer
		rc := Remote(args, bytes.NewReader(stdin), &o, &e)
		return o.String(), e.String(), rc
	}
	if out, e, rc := run(body, "acme-dns", apps, "cloudflare", size, sum); rc != 0 || !strings.Contains(out, "acme_dns=written") {
		t.Fatalf("install: %d %s %s", rc, out, e)
	}
	path := apps + "/traefik/acme-dns/cloudflare.env"
	if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != 0o640 {
		t.Errorf("mode: %v %v", fi, err)
	}
	if out, _, _ := run(body, "acme-dns", apps, "cloudflare", size, sum); !strings.Contains(out, "acme_dns=unchanged") {
		t.Errorf("same bytes rewritten: %s", out)
	}
	if _, e, rc := run(body[:3], "acme-dns", apps, "cloudflare", size, sum); rc == 0 || strings.Contains(e, "s3cr3t") {
		t.Errorf("a cut stream: %d %s", rc, e)
	}
	if _, _, rc := run(body, "acme-dns", apps, "http", size, sum); rc == 0 {
		t.Error("http accepted as a provider")
	}
	os.WriteFile(apps+"/traefik/dynamic/shop.yml", []byte("http:\r\n  routers:\r\n    a: {tls: {certResolver: cloudflare}}\r\n"), 0o644)
	os.WriteFile(apps+"/traefik/dynamic/_mail.yml", []byte("tcp:\n  routers:\n    m: {tls: {certResolver: http}}\n"), 0o644)
	os.WriteFile(apps+"/traefik/traefik.yml", []byte("certificatesResolvers:\n  ovh: {acme: {dnsChallenge: {provider: ovh}}}\n"), 0o644)
	os.WriteFile(apps+"/traefik/dynamic/blog.yml", []byte("# was ovh\n"), 0o644)
	out, _, rc := run(nil, "read", apps)
	if rc != 0 || !strings.Contains(out, `"acme_dns":["cloudflare"]`) || !strings.Contains(out, `"dns_named":{"blog.yml":["ovh"],"shop.yml":["cloudflare"]}`) {
		t.Errorf("read: %s", out)
	}
	// The sweep keeps credentials a file still names.
	if out, _, rc := run(nil, "acme-dns-rm", apps, "cloudflare", "ovh"); rc != 0 || !strings.Contains(out, "acme_dns_kept_cloudflare=dynamic/shop.yml\n") || !strings.Contains(out, "acme_dns_removed=yes") {
		t.Errorf("remove in use: %d %s", rc, out)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("removed while named: %v", err)
	}
	os.Remove(apps + "/traefik/dynamic/shop.yml")
	if out, _, rc := run(nil, "acme-dns-rm", apps, "cloudflare", "ovh"); rc != 0 || strings.Contains(out, "kept_cloudflare") || !strings.Contains(out, "acme_dns_kept_ovh=dynamic/blog.yml") || !strings.Contains(out, "acme_dns_removed=yes") {
		t.Errorf("remove: %d %s", rc, out)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("still there: %v", err)
	}
}
