package check

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/tree"
)

var testNow = time.Unix(2000000000, 0)

const secret = "THIS-IS-PRIVATE-KEY-MATERIAL"

func certPEM(t *testing.T, cn string, sans []string, notAfter time.Time) string {
	t.Helper()
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: cn, Organization: []string{"kasbah test fixture"}},
		NotBefore:    notAfter.Add(-90 * 24 * time.Hour),
		NotAfter:     notAfter,
		DNSNames:     sans,
	}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}

func b64s(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func store(main string, sans []string, cert string) string {
	m := tree.NewMap()
	d := tree.NewMap()
	d.Set("main", main)
	var sv []tree.Value
	for _, s := range sans {
		sv = append(sv, s)
	}
	d.Set("sans", sv)
	e := tree.NewMap()
	e.Set("domain", d)
	e.Set("certificate", cert)
	e.Set("key", secret)
	acct := tree.NewMap()
	acct.Set("PrivateKey", secret)
	le := tree.NewMap()
	le.Set("Account", acct)
	le.Set("Certificates", []tree.Value{e})
	m.Set("http", le)
	return tree.Compact(m)
}

const srvEnv = "DOMAIN=demo.example.com\n# >>> kasbah managed block >>>\nKASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54g\n# <<< kasbah managed block <<<\n"
const srvRegistry = "name: mail\nprimary_domain: rig.test\ndomains:\n  - rig.test\n  - shop.rig.test\n"
const srvShared = "http:\n  routers:\n    traefik-dashboard:\n      rule: \"Host(`traefik.rig.test`)\"\n      entryPoints: [websecure]\n"

var srvKeys = []string{"rsa-2048-mail-rig.test.private.txt", "ed25519-ed-rig.test.private.txt",
	"rsa-2048-mail-shop.rig.test.private.txt", "ed25519-ed-shop.rig.test.private.txt"}

// srvConf is the seeded override with the hand-added block for shop.rig.test.
const srvConf = `domain {
    rig.test { selectors [
        { path = "/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-rig.test.private.txt"; selector = "mail"; },
        { path = "/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-rig.test.private.txt"; selector = "ed"; } ] }
    shop.rig.test { selectors [
        { path = "/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-shop.rig.test.private.txt"; selector = "mail"; },
        { path = "/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-shop.rig.test.private.txt"; selector = "ed"; } ] }
}
`

type fakeSession struct{ sr *ServerRead }

func (f *fakeSession) Read(name, health string) (*ServerRead, error) { return f.sr, nil }

type srvCase struct {
	t      *testing.T
	marker string
	r      ServerReport
}

func newSrv(t *testing.T) *srvCase {
	acme := store("demo.example.com", []string{"www.demo.example.com"}, b64s(certPEM(t, "demo.example.com", nil, testNow.Add(400*24*time.Hour))))
	return &srvCase{t: t,
		marker: `{"kasbah_version":"0.1.0-dev","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}`,
		r: ServerReport{
			Project: "dir", EnvState: "file", Env: b64s(srvEnv),
			RegistryState: "file", Registry: b64s(srvRegistry),
			SharedState: "file", Shared: b64s(srvShared),
			AcmeState: "file", Acme: b64s(acme),
			HealthState: "running", HealthHealth: "healthy",
			DKIMState: "dir", DKIMKeys: srvKeys, DKIMConfState: "file", DKIMConf: b64s(srvConf),
			Backup: backuprec.Facts{Dir: "absent", Record: "absent", Now: "2000000000",
				Container: backuprec.Container{State: "absent", Health: "none"}},
		}}
}

// run checks the project in the cwd against the fake server.
func (s *srvCase) run() (string, int) {
	s.t.Helper()
	mk, err := marker.Validate([]byte(s.marker), "/apps/.kasbah/server.json", "deploy@vps", "kasbah server init deploy@vps")
	if err != nil {
		s.t.Fatal(err)
	}
	r := s.r
	var o, e bytes.Buffer
	code := Run(Env{Out: &cli.Output{Stdout: &o, Stderr: &e}, PWD: "/p", Version: "1", Server: "deploy@vps",
		Dial: func(string) (ServerSession, error) {
			return &fakeSession{&ServerRead{Target: "deploy@vps", Marker: mk, Report: &r}}, nil
		},
		Now: func() time.Time { return testNow }})
	return o.String() + e.String(), code
}

func srvProject(t *testing.T, extra string) {
	project(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nhealth:\n  container: demo-web\nmail:\n  domain: shop.rig.test\n" + extra})
}

func contains(t *testing.T, out string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(out, w) {
			t.Errorf("missing %q in:\n%s", w, out)
		}
	}
}

func hasNot(t *testing.T, out string, nots ...string) {
	t.Helper()
	for _, w := range nots {
		if strings.Contains(out, w) {
			t.Errorf("unexpected %q in:\n%s", w, out)
		}
	}
}

func TestServerGolden(t *testing.T) {
	srvProject(t, "")
	s := newSrv(t)
	out, code := s.run()
	if code != 0 {
		t.Fatalf("exit %d:\n%s", code, out)
	}
	contains(t, out,
		"Server (deploy@vps at /apps):",
		"  ✓ /apps/demo exists on deploy@vps",
		"  ✓ .env on deploy@vps has no missing keys vs .env.prod.example",
		"  ✓ .env on deploy@vps has no extra keys vs .env.prod.example",
		"  ✓ the mail stack on deploy@vps serves 'shop.rig.test' (listed under domains:)",
		"  ✓ manifest health.container 'demo-web' is running and healthy on deploy@vps",
		"  ✓ certificate for 'demo.example.com' valid for 400 more day(s) (until ",
		"O = kasbah test fixture, CN = demo.example.com)",
		"  ✓ effective resource limits on deploy@vps match the host's 90% ceiling (14.4 cpus, 54g)",
		"  ✓ No router claims a hostname kasbah owns on deploy@vps (traefik.rig.test mail.rig.test webmail.rig.test)",
		"  ✓ every mail domain on deploy@vps has both DKIM keys, listed in its signing override (rig.test shop.rig.test)")
	hasNot(t, out, secret, "backup on", "backup scheduler")
	if st, _ := os.ReadFile(".kasbah/state.json"); !strings.Contains(string(st), `"last_server": "deploy@vps"`) {
		t.Errorf("last_server not recorded: %s", st)
	}
}

func TestServerProjectAndEnv(t *testing.T) {
	for _, tc := range []struct {
		name string
		set  func(s *srvCase)
		want []string
		not  []string
		code int
	}{
		{"not deployed", func(s *srvCase) {
			s.r.Project, s.r.EnvState, s.r.Env, s.r.HealthState = "absent", "absent", "", "absent"
		},
			[]string{"⚠ /apps/demo does not exist on deploy@vps", "is not running on deploy@vps"},
			[]string{"missing keys", "effective resource limits"}, 0},
		{"not a directory", func(s *srvCase) { s.r.Project = "notdir" }, []string{"✗ /apps/demo on deploy@vps exists and is not a directory"}, nil, 6},
		{"drift", func(s *srvCase) {
			s.r.Env = b64s("OTHER=1\nexport DOMAIN=x\n" + "KASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54g\n")
		}, []string{"⚠ .env on deploy@vps has extra keys not in .env.prod.example: OTHER", "✓ .env on deploy@vps has no missing keys"}, nil, 0},
		{"env absent", func(s *srvCase) { s.r.EnvState, s.r.Env = "absent", "" }, []string{"/apps/demo/.env does not exist on deploy@vps — the next deploy"}, []string{"effective resource limits"}, 0},
		{"env unreadable", func(s *srvCase) { s.r.EnvState, s.r.Env = "unreadable", "" }, []string{"cannot be read by this user, so its keys cannot be compared"}, nil, 0},
		{"env a directory", func(s *srvCase) { s.r.EnvState, s.r.Env = "dir", "" }, []string{"✗ /apps/demo/.env on deploy@vps is not a regular file (it is dir)"}, nil, 6},
		{"env bytes lost", func(s *srvCase) { s.r.Env = "!!" }, []string{"did not come back as readable bytes"}, nil, 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srvProject(t, "")
			s := newSrv(t)
			tc.set(s)
			out, code := s.run()
			if code != tc.code {
				t.Errorf("exit %d, want %d", code, tc.code)
			}
			contains(t, out, tc.want...)
			hasNot(t, out, tc.not...)
		})
	}
	t.Run("no template", func(t *testing.T) {
		srvProject(t, "")
		os.Remove(".env.prod.example")
		out, _ := newSrv(t).run()
		contains(t, out, "⚠ no .env.prod.example in this checkout, so /apps/demo/.env on deploy@vps cannot be checked for drift")
	})
}

func TestServerM03(t *testing.T) {
	for _, tc := range []struct {
		name, domain string
		set          func(s *srvCase)
		want         string
		code         int
	}{
		{"primary", "rig.test", nil, "✓ the mail stack on deploy@vps serves 'rig.test' (its primary_domain)", 0},
		{"unserved", "nowhere.rig.test", nil, "✗ the mail stack on deploy@vps does not serve 'nowhere.rig.test' — /apps/mail/kasbah.yml serves rig.test shop.rig.test; add it with: kasbah server add-mail-domain deploy@vps nowhere.rig.test", 6},
		{"no stack", "rig.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "absent", "" }, "✗ demo claims the mail domain 'rig.test', and there is no mail stack on deploy@vps", 6},
		{"unreadable", "rig.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "unreadable", "" }, "⚠ demo claims the mail domain 'rig.test', and /apps/mail/kasbah.yml on deploy@vps is unreadable", 0},
		{"not YAML", "rig.test", func(s *srvCase) { s.r.Registry = b64s("a: [\n") }, "does not parse as YAML", 0},
		{"no primary: the refusal is the finding", "rig.test", func(s *srvCase) { s.r.Registry = b64s("domains: [rig.test]\n") },
			"✗ demo claims the mail domain 'rig.test', and /apps/mail/kasbah.yml on deploy@vps has no primary_domain:", 6},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\ndomain: demo.example.com\nmail:\n  domain: " + tc.domain + "\n"})
			s := newSrv(t)
			if tc.set != nil {
				tc.set(s)
			}
			out, code := s.run()
			contains(t, out, tc.want)
			if code != tc.code {
				t.Errorf("exit %d, want %d", code, tc.code)
			}
		})
	}
	t.Run("no claim, no line", func(t *testing.T) {
		project(t, nil)
		out, _ := newSrv(t).run()
		hasNot(t, out, "mail stack on")
	})
}

// M04 answers for every registry domain, whether or not the project claims
// mail, and warns rather than fails; no registry, no line.
func TestServerM04(t *testing.T) {
	const dir, conf = "/apps/data/mail/dms/config/rspamd/dkim", "/apps/data/mail/dms/config/rspamd/override.d/dkim_signing.conf"
	rsa := "\n      ssh deploy@vps 'docker exec mail-dms setup config dkim keytype rsa     selector mail domain shop.rig.test'"
	ed := "\n      ssh deploy@vps 'docker exec mail-dms setup config dkim keytype ed25519 selector ed   domain shop.rig.test'"
	tail := " — its mail leaves unsigned and receivers file it as spam (kasbah server mail-setup-guide deploy@vps, step 2):"
	cant := ", so whether the mail domains are DKIM-signed cannot be checked"
	for _, tc := range []struct {
		name string
		set  func(s *srvCase)
		want []string
		not  []string
	}{
		{"no keys for one domain", func(s *srvCase) { s.r.DKIMKeys = s.r.DKIMKeys[:2] },
			[]string{"⚠ mail domain 'shop.rig.test' on deploy@vps is not DKIM-signed: no rsa-2048-mail-shop.rig.test.private.txt or ed25519-ed-shop.rig.test.private.txt in " + dir + "/" + tail + rsa + ed + "\n"},
			[]string{"'rig.test' on deploy@vps is not", "every mail domain", "signing block"}},
		{"ed25519 only", func(s *srvCase) { s.r.DKIMKeys = []string{s.r.DKIMKeys[0], s.r.DKIMKeys[1], s.r.DKIMKeys[3]} },
			[]string{"is not DKIM-signed: no rsa-2048-mail-shop.rig.test.private.txt in " + dir + "/" + tail + rsa + "\n"}, []string{ed}},
		{"a hyphenated selector is not the domain's key", func(s *srvCase) {
			s.r.Registry = b64s("primary_domain: rig.test\ndomains: [rig.test, a.test]\n")
			s.r.DKIMKeys = append(s.r.DKIMKeys, "rsa-2048-mail-shop-a.test.private.txt", "ed25519-ed-shop-a.test.private.txt")
			s.r.DKIMConf = b64s(srvConf + strings.ReplaceAll(srvConf, "shop.rig.test", "shop-a.test"))
		}, []string{"⚠ mail domain 'a.test' on deploy@vps is not DKIM-signed: no rsa-2048-mail-a.test.private.txt or ed25519-ed-a.test.private.txt in " + dir + "/, and " +
			conf + " does not list rsa-2048-mail-a.test.private.txt or ed25519-ed-a.test.private.txt" + tail,
			"\n      add its signing block to " + conf + "\n"}, nil},
		{"keys, no signing block", func(s *srvCase) { s.r.DKIMConf = b64s(strings.ReplaceAll(srvConf, "shop.rig.test", "other.test")) },
			[]string{"⚠ mail domain 'shop.rig.test' on deploy@vps is not DKIM-signed: " + conf + " does not list rsa-2048-mail-shop.rig.test.private.txt or ed25519-ed-shop.rig.test.private.txt" + tail +
				"\n      add its signing block to " + conf + "\n"},
			[]string{"setup config dkim keytype", "'rig.test' on deploy@vps is not"}},
		{"no key directory yet", func(s *srvCase) { s.r.DKIMState, s.r.DKIMKeys = "absent", nil },
			[]string{"⚠ mail domain 'rig.test' on deploy@vps is not DKIM-signed", "⚠ mail domain 'shop.rig.test' on deploy@vps is not DKIM-signed"}, nil},
		{"an empty override lists nothing", func(s *srvCase) { s.r.DKIMConfState, s.r.DKIMConf = "empty", "" },
			[]string{"'rig.test' on deploy@vps is not DKIM-signed: " + conf + " does not list"}, nil},
		{"key directory unlistable", func(s *srvCase) { s.r.DKIMState, s.r.DKIMKeys = "unreadable", nil },
			[]string{"⚠ " + dir + " on deploy@vps cannot be listed by this user" + cant}, []string{"is not DKIM-signed"}},
		{"key directory a file", func(s *srvCase) { s.r.DKIMState, s.r.DKIMKeys = "notdir", nil },
			[]string{"⚠ " + dir + " on deploy@vps is not a directory (it is notdir)" + cant}, nil},
		{"override unreadable", func(s *srvCase) { s.r.DKIMConfState, s.r.DKIMConf = "unreadable", "" },
			[]string{"⚠ " + conf + " on deploy@vps is unreadable" + cant}, []string{"is not DKIM-signed"}},
		{"override absent", func(s *srvCase) { s.r.DKIMConfState, s.r.DKIMConf = "absent", "" },
			[]string{"⚠ " + conf + " on deploy@vps is absent" + cant}, nil},
		{"override bytes lost", func(s *srvCase) { s.r.DKIMConf = "!!" },
			[]string{"⚠ " + conf + " on deploy@vps did not come back as readable bytes" + cant}, nil},
		{"registry unreadable", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "unreadable", "" },
			[]string{"⚠ /apps/mail/kasbah.yml on deploy@vps is unreadable — so whether the mail domains are DKIM-signed cannot be checked"}, nil},
		{"registry refused", func(s *srvCase) { s.r.Registry = b64s("domains: [x.test]\n") },
			[]string{"has no primary_domain:", "— so whether the mail domains are DKIM-signed cannot be checked"}, nil},
		{"no mail stack", func(s *srvCase) {
			s.r.RegistryState, s.r.Registry, s.r.DKIMState, s.r.DKIMKeys, s.r.DKIMConfState, s.r.DKIMConf = "absent", "", "absent", nil, "absent", ""
		}, nil, []string{"DKIM"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, nil)
			s := newSrv(t)
			tc.set(s)
			out, code := s.run()
			if code != 0 {
				t.Errorf("exit %d, want 0:\n%s", code, out)
			}
			contains(t, out, tc.want...)
			hasNot(t, out, tc.not...)
		})
	}
}

// The key directory is listed, never read: private-key names only. The
// override comes back whole. A path this user cannot reach is unreadable,
// never absent.
func TestCollectServerDKIM(t *testing.T) {
	data := t.TempDir()
	cfg := data + "/mail/dms/config"
	dir, conf := cfg+"/rspamd/dkim", cfg+"/rspamd/override.d/dkim_signing.conf"
	if r := CollectServer(data, data, "demo", ""); r.DKIMState != "absent" || r.DKIMKeys != nil || r.DKIMConfState != "absent" || r.DKIMConf != "" {
		t.Errorf("absent: %+v", r)
	}
	os.MkdirAll(dir+"/sub.private.txt", 0o755)
	os.MkdirAll(cfg+"/rspamd/override.d", 0o755)
	os.WriteFile(conf, []byte("domain {}\n"), 0o644)
	for _, n := range []string{"rsa-2048-mail-a.com.private.txt", "rsa-2048-mail-a.com.public.txt", "rsa-2048-mail-a.com.public.dns.txt"} {
		os.WriteFile(dir+"/"+n, nil, 0o000)
	}
	r := CollectServer(data, data, "demo", "")
	if r.DKIMState != "dir" || strings.Join(r.DKIMKeys, " ") != "rsa-2048-mail-a.com.private.txt" || r.DKIMConfState != "file" || string(dec(r.DKIMConf)) != "domain {}\n" {
		t.Errorf("listed: %+v", r)
	}
	if os.Geteuid() != 0 {
		for _, p := range []string{dir, cfg} {
			os.Chmod(p, 0o000)
			r := CollectServer(data, data, "demo", "")
			os.Chmod(p, 0o755)
			if r.DKIMState != "unreadable" || (p == cfg && r.DKIMConfState != "unreadable") {
				t.Errorf("%s closed: %q %q", p, r.DKIMState, r.DKIMConfState)
			}
		}
	}
	os.RemoveAll(dir)
	os.WriteFile(dir, nil, 0o644)
	if r := CollectServer(data, data, "demo", ""); r.DKIMState != "notdir" {
		t.Errorf("a file: %q", r.DKIMState)
	}
}

func TestServerHealth(t *testing.T) {
	for _, tc := range []struct {
		state, health, derr, want string
		code                      int
	}{
		{"running", "unhealthy", "", "✗ manifest health.container 'demo-web' is running and UNHEALTHY on deploy@vps — Traefik keeps routing to it", 6},
		{"running", "starting", "", "⚠ manifest health.container 'demo-web' is running and still starting", 0},
		{"running", "none", "", "declares no healthcheck, so nothing there reports health (H01)", 0},
		{"exited", "weird", "", "is exited on deploy@vps and reports health 'weird'", 0},
		{"absent", "none", "", "⚠ manifest health.container 'demo-web' is not running on deploy@vps — the project is deployed", 0},
		{"nodocker", "nodocker", "", "⚠ no docker on deploy@vps, so the health of 'demo-web' cannot be read", 0},
		{"nodaemon", "none", "Cannot connect to the Docker daemon", "the docker daemon on deploy@vps is not answering, so the health of 'demo-web' cannot be read — nothing here says the container is down (docker said: Cannot connect to the Docker daemon)", 0},
	} {
		t.Run(tc.state+"/"+tc.health, func(t *testing.T) {
			srvProject(t, "")
			s := newSrv(t)
			s.r.HealthState, s.r.HealthHealth, s.r.DockerError = tc.state, tc.health, tc.derr
			out, code := s.run()
			contains(t, out, tc.want)
			if code != tc.code {
				t.Errorf("exit %d, want %d", code, tc.code)
			}
		})
	}
}

func TestServerCert(t *testing.T) {
	soon := b64s(certPEM(t, "demo.example.com", nil, testNow.Add(7*24*time.Hour+time.Hour)))
	expired := b64s(certPEM(t, "demo.example.com", nil, testNow.Add(-3*24*time.Hour-time.Hour)))
	justExpired := b64s(certPEM(t, "demo.example.com", nil, testNow.Add(-time.Hour)))
	san := b64s(certPEM(t, "other.example.com", nil, testNow.Add(100*24*time.Hour+time.Hour)))
	for _, tc := range []struct {
		name, state, acme, want string
		code                    int
	}{
		{"soon", "file", store("demo.example.com", nil, soon), "⚠ certificate for 'demo.example.com' expires in 7 day(s) (", 0},
		{"expired", "file", store("demo.example.com", nil, expired), "✗ certificate for 'demo.example.com' EXPIRED 3 day(s) ago (", 6},
		{"expired within the day", "file", store("demo.example.com", nil, justExpired), "✗ certificate for 'demo.example.com' EXPIRED 0 day(s) ago (", 6},
		{"as a SAN", "file", store("other.example.com", []string{"demo.example.com"}, san), "✓ certificate for 'demo.example.com' (as a SAN of other.example.com) valid for 100 more day(s)", 0},
		{"a SAN with a space is not a match", "file", store("other.example.com", []string{"demo.example.com x"}, san), "no certificate for 'demo.example.com' in /apps/data/traefik/letsencrypt/acme.json on deploy@vps (1 in the store)", 0},
		{"nomatch", "file", store("other.example.com", nil, san), "(1 in the store) — Traefik issues one when a router claims the hostname", 0},
		{"notjson", "file", "{nope", "does not parse as JSON, so the certificate for 'demo.example.com' cannot be read (its bytes are not shown", 0},
		{"noresolver", "file", `{"other":{}}`, "has no 'http' store — a store filled under the resolver's former name 'letsencrypt'", 0},
		{"notarray", "file", `{"http":{"Certificates":{"a":1}}}`, "holds a 'http' whose Certificates is a object, not a list", 0},
		{"empty list", "file", `{"http":{"Certificates":[]}}`, "holds no certificates — nothing has been issued for 'demo.example.com' yet", 0},
		{"null list", "file", `{"http":{"Certificates":null}}`, "holds no certificates", 0},
		{"nocert", "file", `{"http":{"Certificates":[{"domain":{"main":"demo.example.com"}}]}}`, "carries no certificate field", 0},
		{"notbase64", "file", `{"http":{"Certificates":[{"domain":{"main":"demo.example.com"},"certificate":"%%%"}]}}`, "is not base64 — the store's schema", 0},
		{"nopem", "file", `{"http":{"Certificates":[{"domain":{"main":"demo.example.com"},"certificate":"` + b64s("hello") + `"}]}}`, "is not a certificate openssl reads", 0},
		{"absent", "absent", "", "⚠ no certificate store at /apps/data/traefik/letsencrypt/acme.json on deploy@vps", 0},
		{"empty", "empty", "", "is empty — Traefik has not issued anything yet, so 'demo.example.com' is served with its self-signed default", 0},
		{"unreadable", "unreadable", "", "cannot be read by this user, so the certificate for 'demo.example.com' cannot be checked", 0},
		{"a directory", "dir", "", "is dir, not a regular file — Traefik bind-mounts that path", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srvProject(t, "")
			s := newSrv(t)
			s.r.AcmeState, s.r.Acme = tc.state, ""
			if tc.acme != "" {
				s.r.Acme = b64s(tc.acme)
			}
			out, code := s.run()
			contains(t, out, tc.want)
			hasNot(t, out, secret)
			if code != tc.code {
				t.Errorf("exit %d, want %d:\n%s", code, tc.code, out)
			}
		})
	}
}

func TestServerCertPlainHTTP(t *testing.T) {
	webOnly := "http:\n  routers:\n" +
		"    demo: {rule: \"Host(`demo.example.com`)\", entryPoints: [web], service: demo}\n" +
		"  services:\n    demo: {loadBalancer: {servers: [{url: \"http://demo-web:80\"}]}}\n"
	other := "    other: {rule: \"Host(`other.example.com`)\", entryPoints: [websecure], tls: {certResolver: http}, service: demo}\n  services:"
	for _, tc := range []struct {
		name, frag, want, not string
		code                  int
	}{
		{"web only", webOnly, "✓ this checkout's fragment has no HTTPS router, so 'demo.example.com' is served over plain HTTP and no certificate is expected", "no certificate for", 0},
		// Any router that could serve HTTPS, for whichever host, sends the domain to the store.
		{"https for another host", strings.Replace(webOnly, "  services:", other, 1), "⚠ no certificate for 'demo.example.com'", "plain HTTP", 0},
		{"tcp router", webOnly + "tcp:\n  routers:\n    t: {rule: \"HostSNI(`demo.example.com`)\", entryPoints: [websecure], tls: {}, service: t}\n", "⚠ no certificate for 'demo.example.com'", "plain HTTP", 0},
		{"websecure too", goodFragment, "⚠ no certificate for 'demo.example.com' in /apps/data/traefik/letsencrypt/acme.json on deploy@vps (1 in the store)", "plain HTTP", 0},
		// T03 fails it; Traefik puts such a router on every entrypoint.
		{"no entryPoints", strings.ReplaceAll(goodFragment, "entryPoints: [websecure], ", ""), "⚠ no certificate for 'demo.example.com'", "plain HTTP", 6},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srvProject(t, "")
			if err := os.WriteFile("traefik-dynamic.yml", []byte(tc.frag), 0o644); err != nil {
				t.Fatal(err)
			}
			s := newSrv(t)
			s.r.AcmeState, s.r.Acme = "file", b64s(store("other.example.com", nil, b64s(certPEM(t, "other.example.com", nil, testNow.Add(100*24*time.Hour)))))
			out, code := s.run()
			contains(t, out, tc.want)
			hasNot(t, out, tc.not)
			if code != tc.code {
				t.Errorf("exit %d, want %d:\n%s", code, tc.code, out)
			}
		})
	}
}

func TestServerR04(t *testing.T) {
	for _, tc := range []struct {
		env, want string
		code      int
	}{
		{"KASBAH_CPU_LIMIT=999\nKASBAH_MEM_LIMIT=54g\n", "✗ effective resource limits on deploy@vps are above the host's 90% ceiling: cpus 999 > 14.4", 6},
		{"KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=1g\n", "⚠ effective resource limits on deploy@vps are below the host's 90% ceiling: cpus 2 < 14.4; mem_limit 1g < 54g", 0},
		{"KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=99g\n", "✗ effective resource limits on deploy@vps are above the host's 90% ceiling: cpus 2 < 14.4; mem_limit 99g > 54g", 6},
		{"KASBAH_CPU_LIMIT=14.40\nKASBAH_MEM_LIMIT=55296m\n", "✓ effective resource limits on deploy@vps match the host's 90% ceiling (14.40 cpus, 55296m)", 0},
		{"KASBAH_CPU_LIMIT=1\nexport KASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54G\n", "✓ effective resource limits on deploy@vps match", 0},
		{"KASBAH_CPU_LIMIT=lots\nKASBAH_MEM_LIMIT=54g\n", "⚠ effective resource limits on deploy@vps could not all be compared with the host's 14.4 cpus / 54g: cpus 'lots' is not a number", 0},
		{"KASBAH_CPU_LIMIT=14.4\n", "mem_limit 'unset' is not a size", 0},
		{"DOMAIN=x\n", "carries no KASBAH_CPU_LIMIT or KASBAH_MEM_LIMIT, so there is no effective limit to compare with the host's 14.4 cpus / 54g", 0},
	} {
		srvProject(t, "")
		s := newSrv(t)
		s.r.Env = b64s("DOMAIN=demo.example.com\n" + tc.env)
		out, code := s.run()
		contains(t, out, tc.want)
		if code != tc.code {
			t.Errorf("%q: exit %d, want %d", tc.env, code, tc.code)
		}
	}
}

// A literal is compared as written; the .env is asked only for the keys a
// service takes from it.
func TestServerR04Literals(t *testing.T) {
	compose := func(cpus, mem string) string {
		return strings.Replace(strings.Replace(goodCompose, "${KASBAH_CPU_LIMIT}", cpus, 1), "${KASBAH_MEM_LIMIT}", mem, 1)
	}
	for _, tc := range []struct {
		compose, env string
		want, not    []string
		code         int
	}{
		{compose("16", "2g"), "KASBAH_CPU_LIMIT=999\n",
			[]string{"  ✓ All services set cpus/mem_limit, some as literals: demo-web(cpus=16,mem_limit=2g) — compared with the host's ceiling under Server (R04)",
				"  ✗ literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web cpus 16 > 14.4; demo-web mem_limit 2g < 54g — kasbah's limits are anti-takeover ceilings"},
			[]string{"Services with literal resource limits", "effective resource limits on"}, 6},
		{compose("0.5", "${KASBAH_MEM_LIMIT}"), "KASBAH_CPU_LIMIT=lots\nKASBAH_MEM_LIMIT=54g\n",
			[]string{"  ⚠ literal resource limits in compose.prod.yml are below the 90% ceiling of deploy@vps: demo-web cpus 0.5 < 14.4 — a tighter per-service limit is allowed, but flagged",
				"  ✓ effective resource limits on deploy@vps match the host's 90% ceiling (54g)"},
			nil, 0},
		{compose("14.40", "55296m"), "",
			[]string{"  ✓ literal resource limits in compose.prod.yml match the 90% ceiling of deploy@vps (14.4 cpus, 54g)"},
			[]string{"effective resource limits on", "carries no KASBAH_CPU_LIMIT"}, 0},
		{strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "    deploy: {resources: {limits: {cpus: 16}}}\n", 1), "KASBAH_MEM_LIMIT=54g\n",
			[]string{"  ✗ literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web cpus 16 > 14.4",
				"  ✓ effective resource limits on deploy@vps match the host's 90% ceiling (54g)"},
			nil, 6},
		{compose("${KASBAH_CPU_LIMIT}", "99g"), "KASBAH_CPU_LIMIT=14.4\n",
			[]string{"  ✗ literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web mem_limit 99g > 54g",
				"  ✓ effective resource limits on deploy@vps match"},
			[]string{"is not a size"}, 6},
	} {
		srvProject(t, "")
		os.WriteFile(composeFile, []byte(tc.compose), 0o644)
		s := newSrv(t)
		s.r.Env = b64s("DOMAIN=demo.example.com\n" + tc.env)
		out, code := s.run()
		contains(t, out, tc.want...)
		hasNot(t, out, tc.not...)
		if code != tc.code {
			t.Errorf("%q: exit %d, want %d:\n%s", tc.compose, code, tc.code, out)
		}
	}
	t.Run("a literal is compared before the project is deployed", func(t *testing.T) {
		srvProject(t, "")
		os.WriteFile(composeFile, []byte(compose("32", "${KASBAH_MEM_LIMIT}")), 0o644)
		s := newSrv(t)
		s.r.Project, s.r.EnvState, s.r.Env, s.r.HealthState = "absent", "absent", "", "absent"
		out, code := s.run()
		contains(t, out, "  ✗ literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web cpus 32 > 14.4")
		if code != 6 {
			t.Errorf("exit %d, want 6", code)
		}
	})
}

func TestMemBytes(t *testing.T) {
	for in, want := range map[string]int64{
		"512m": 512 << 20, "1.5g": 1610612736, "2GiB": 2 << 30, "1t": 1 << 40, "512 MB": 512 << 20,
		".5k": 512, "536870912": 536870912, "1b": 1, "54G": 54 << 30, "8191p": 8191 << 50,
	} {
		if got, ok := MemBytes(in); !ok || got != want {
			t.Errorf("MemBytes(%q) = %d, %v; want %d", in, got, ok, want)
		}
	}
	for _, in := range []string{"512mi", "1ib", "8192p", "99999999999t", "5.5.5m", "1e3", "-1m", "512  m", "1,5g", ""} {
		if got, ok := MemBytes(in); ok {
			t.Errorf("MemBytes(%q) = %d, want not a size", in, got)
		}
	}
}

func TestServerT05(t *testing.T) {
	fragOf := func(host string) map[string]string {
		i := strings.Index(goodFragment, "  services:")
		f := goodFragment[:i] + "    x: {rule: \"Host(`" + host + "`)\", entryPoints: [web], service: demo}\n" + goodFragment[i:]
		return map[string]string{"traefik-dynamic.yml": f}
	}
	for _, tc := range []struct {
		name, host string
		set        func(s *srvCase)
		want       string
		code       int
	}{
		{"mail of another apex is not reserved here", "mail.demo.example.com", nil, "✓ No router claims a hostname kasbah owns on deploy@vps (traefik.rig.test mail.rig.test webmail.rig.test)", 0},
		{"webmail of the primary is", "webmail.rig.test", nil, "✗ Routers claim hostnames kasbah owns on deploy@vps: x→webmail.rig.test (traefik.rig.test mail.rig.test webmail.rig.test)", 6},
		{"no registry: the apex", "mail.rig.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "absent", "" }, "✗ Routers claim hostnames kasbah owns on deploy@vps: x→mail.rig.test", 6},
		{"dashboard off: traefik.* is nobody's", "traefik.rig.test", func(s *srvCase) { s.r.Shared = b64s("http: {}\n") },
			"✓ No router claims a hostname kasbah owns on deploy@vps (mail.rig.test webmail.rig.test; dashboard off, traefik.* not reserved)", 0},
		{"dashboard off, registry refused", "traefik.rig.test", func(s *srvCase) {
			s.r.Shared = b64s("http:\n  middlewares: {}\n")
			s.r.Registry = b64s("domains: [x.test]\n")
		}, "✓ No router claims reserved hostnames (mail.*, webmail.*) — heuristic: deploy@vps was asked and its mail registry could not be read — the dashboard is off on deploy@vps, so traefik.* is not reserved", 0},
		{"dashboard off, no registry", "traefik.rig.test", func(s *srvCase) {
			s.r.Shared = b64s("http: {}\n")
			s.r.RegistryState, s.r.Registry = "absent", ""
		}, "✓ No router claims reserved hostnames (mail.*, webmail.*) — heuristic: deploy@vps has no mail registry, and no dashboard apex to name mail.* from — the dashboard is off", 0},
		{"an unparseable _shared.yml: traefik keeps the heuristic", "traefik.elsewhere.test", func(s *srvCase) { s.r.Shared = b64s("http: [1\n") },
			"✗ Routers claim hostnames kasbah owns on deploy@vps: x→traefik.elsewhere.test (mail.rig.test webmail.rig.test; traefik.* by heuristic)", 6},
		{"a refused registry: mail keeps the heuristic", "mail.anything.test", func(s *srvCase) { s.r.Registry = b64s("domains: [x.test]\n") },
			"✗ Routers claim hostnames kasbah owns on deploy@vps: x→mail.anything.test (traefik.rig.test; mail.* by heuristic; webmail.* by heuristic)", 6},
		{"an unreadable registry: mail keeps the heuristic", "webmail.x.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "unreadable", "" },
			"(traefik.rig.test; mail.* by heuristic; webmail.* by heuristic)", 6},
		{"neither read", "mail.x.test", func(s *srvCase) {
			s.r.Shared = ""
			s.r.RegistryState, s.r.Registry = "unreadable", ""
		}, "✗ Routers claim reserved hostnames: x→mail.x.test — heuristic: deploy@vps was asked and neither its dashboard fragment nor a mail registry could be read", 6},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, fragOf(tc.host))
			s := newSrv(t)
			if tc.set != nil {
				tc.set(s)
			}
			out, code := s.run()
			contains(t, out, tc.want)
			if code != tc.code {
				t.Errorf("exit %d, want %d:\n%s", code, tc.code, out)
			}
		})
	}
}

// T09 holds under --server as it does locally, the dashboard off included:
// --no-dashboard is the promise a project fragment would otherwise break.
func TestServerT09(t *testing.T) {
	project(t, map[string]string{"traefik-dynamic.yml": strings.Replace(goodFragment, "service: demo}", "service: api@internal}", 1)})
	s := newSrv(t)
	s.r.Shared = b64s("http: {}\n")
	out, code := s.run()
	contains(t, out, "✗ Fragment routes to Traefik's internal services (only noop@internal is allowed): demo→api@internal")
	if code != 6 {
		t.Errorf("exit %d, want 6:\n%s", code, out)
	}
}

func TestServerB01(t *testing.T) {
	rec := func(lines ...string) string { return strings.Join(lines, "\n") + "\n" }
	ok := rec("state=sleeping", "since=1999990000", "deadline=2000086400", "next_run=2000082800",
		"last_run_started=1999980000", "last_run_finished=1999983600", "last_run_status=ok", "last_run_repos= demo")
	for _, tc := range []struct {
		name               string
		dir, file, content string
		cstate             string
		want               string
		code               int
	}{
		{"ok", "dir", "file", ok, "running", "✓ the last backup on deploy@vps finished 4h ago and succeeded (repositories: demo)", 0},
		{"nostack", "absent", "absent", "", "running", "⚠ /apps/.kasbah/server.json on deploy@vps records off-box backups and /apps/.kasbah/backup is not there", 0},
		{"norecord", "dir", "absent", "", "exited", "⚠ the backup scheduler on deploy@vps has written no record at /apps/.kasbah/backup/state/status — it writes one as its first act, so it has not started since backups were configured (its container is exited)", 0},
		{"unreadable", "dir", "unreadable", "", "running", "⚠ /apps/.kasbah/backup/state/status on deploy@vps cannot be read by the ssh user, so nothing here says whether a backup has ever run", 0},
		{"empty", "dir", "empty", "", "running", "status on deploy@vps is empty, so nothing here", 0},
		{"unparsed", "dir", "file", rec("deadline=2000086400"), "running", "is not a record this kasbah reads — it carries no scheduler state", 0},
		{"octal deadline", "dir", "file", rec("state=sleeping", "deadline=01999000009"), "running", "records deadline='01999000009', which is not a unix time this kasbah can compare", 0},
		{"huge deadline", "dir", "file", rec("state=sleeping", "deadline=999999999999999999999999"), "running", "which is not a unix time this kasbah can compare", 0},
		{"never", "dir", "file", rec("state=starting", "deadline=2000000600", "last_run_status=-"), "running", "⚠ backups are configured on deploy@vps and no run has finished yet — the scheduler is 'starting'", 0},
		{"shipped nothing", "dir", "file", strings.Replace(ok, "repos= demo", "repos= none", 1), "running", "⚠ the last backup on deploy@vps finished 4h ago and shipped nothing", 0},
		{"failed", "dir", "file", strings.Replace(ok, "status=ok", "status=failed", 1), "running", "✗ the last backup on deploy@vps FAILED 4h ago (repositories backed up: demo)", 6},
		{"overdue", "dir", "file", rec("state=running", "deadline=1999999000", "last_run_finished=1999983600", "last_run_status=ok"), "running", "✗ the backup scheduler on deploy@vps is 16m past its own deadline in state 'running' — a run that never returned, or a sleep that never woke, so nothing is being shipped off-box (the last run finished 4h ago)", 6},
		{"stopped scheduler is asked first", "dir", "file", ok, "exited", "✗ the backup scheduler on deploy@vps is exited, so nothing is being shipped off-box — its record still reads 'ok', last run 4h ago", 6},
		{"notours", "dir", "file", ok, "notours", "✗ the container named kasbah-backup on deploy@vps is not in the kasbah-backup compose project", 6},
		{"nodaemon", "dir", "file", ok, "nodaemon", "⚠ the docker daemon on deploy@vps is not answering, so whether its backup scheduler is running cannot be read", 0},
		{"nodocker", "dir", "file", ok, "nodocker", "⚠ there is no docker on deploy@vps, so whether its backup scheduler is running cannot be read — the record says 'ok'", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srvProject(t, "")
			s := newSrv(t)
			s.marker = strings.Replace(s.marker, "}", `,"backup":{"enabled":true}}`, 1)
			s.r.Backup = backuprec.Facts{Dir: tc.dir, Record: tc.file, RecordB64: b64s(tc.content), Now: "2000000000",
				Container: backuprec.Container{State: tc.cstate, Health: "healthy"},
				HasPass:   []string{"demo"}, Projects: []backuprec.Project{{Name: "demo"}}}
			out, code := s.run()
			contains(t, out, tc.want)
			if code != tc.code {
				t.Errorf("exit %d, want %d:\n%s", code, tc.code, out)
			}
		})
	}
	t.Run("not configured: not asked", func(t *testing.T) {
		srvProject(t, "")
		out, _ := newSrv(t).run()
		hasNot(t, out, "backup on", "backup scheduler", "backups are configured")
	})
	t.Run("the server's clock, or this one's said out loud", func(t *testing.T) {
		srvProject(t, "")
		s := newSrv(t)
		s.marker = strings.Replace(s.marker, "}", `,"backup":{"enabled":true}}`, 1)
		s.r.Backup = backuprec.Facts{Dir: "dir", Record: "file", RecordB64: b64s(ok), Now: "soon",
			Container: backuprec.Container{State: "running"}, HasPass: []string{"demo"}, Projects: []backuprec.Project{{Name: "demo"}}}
		out, _ := s.run()
		contains(t, out, "(judged against this machine's clock: the probe did not report the server's)")
	})
	t.Run("missing and orphaned passwords", func(t *testing.T) {
		srvProject(t, "")
		s := newSrv(t)
		s.marker = strings.Replace(s.marker, "}", `,"backup":{"enabled":true}}`, 1)
		s.r.Backup = backuprec.Facts{Dir: "dir", Record: "file", RecordB64: b64s(ok), Now: "2000000000", Mail: true,
			Container: backuprec.Container{State: "running"}, HasPass: []string{"demo", "gone"},
			Projects: []backuprec.Project{{Name: "demo"}, {Name: "shop", Client: "acme"}, {Name: "blog", Client: "acme"}, {Name: "x", Client: "?"}}}
		out, _ := s.run()
		contains(t, out,
			"⚠ backup repositories on deploy@vps with no password: acme x mail — a repository with no password is not backed up at all",
			"⚠ backup repository passwords on deploy@vps that no project files into any more: gone — the last project of that client was dropped",
			"✓ the last backup on deploy@vps finished 4h ago and succeeded")
	})
}

func TestParse(t *testing.T) {
	for in, want := range map[string]string{
		"":                      "",
		"--fix --yes":           "fix yes",
		"--server":              "given",
		"--server a@b":          "given a@b",
		"--server --fix":        "given fix",
		"--server=a@b --fix":    "given a@b fix",
		"--server a@b\r":        "given a@b",
		"--yes":                 "error: check: --yes answers --fix's prompt",
		"--server=":             "error: check: --server= must name the server",
		"--bogus":               "error: check: unknown argument '--bogus' (expected --server [USER@HOST], --fix, --yes)",
		"--fix --help":          "help",
		"--fix\r":               "error: check: unknown argument",
		"--server a@b extra@vp": "error: check: unknown argument 'extra@vp'",
	} {
		var args []string
		if in != "" {
			args = strings.Split(in, " ")
		}
		o, err := Parse(args)
		var got []string
		switch {
		case err == ErrHelp:
			got = []string{"help"}
		case err != nil:
			got = []string{"error: " + err.Error()}
		default:
			if o.ServerGiven {
				got = append(got, "given")
			}
			if o.Server != "" {
				got = append(got, o.Server)
			}
			if o.Fix {
				got = append(got, "fix")
			}
			if o.Yes {
				got = append(got, "yes")
			}
		}
		if g := strings.Join(got, " "); !strings.HasPrefix(g, want) || (want == "" && g != "") {
			t.Errorf("check %q: %q, want %q", in, g, want)
		}
	}
}

func TestTarget(t *testing.T) {
	t.Chdir(t.TempDir())
	if _, err := Target(Options{ServerGiven: true}); err == nil || !strings.Contains(err.Error(), "has never talked to one") || !strings.Contains(err.Error(), "last_server") {
		t.Errorf("a bare --server with no last_server: %v", err)
	}
	os.MkdirAll(".kasbah", 0o755)
	os.WriteFile(".kasbah/state.json", []byte(`{"last_server": "deploy@vps"}`), 0o644)
	if got, err := Target(Options{ServerGiven: true}); got != "deploy@vps" || err != nil {
		t.Errorf("got %q, %v", got, err)
	}
	if got, _ := Target(Options{ServerGiven: true, Server: "x@y"}); got != "x@y" {
		t.Errorf("the given server wins: %q", got)
	}
}

// fakeSSH puts on PATH an ssh that answers the bootstrap probe as a prepared
// server whose binary is self, and `remote check` with report; every call it
// takes is logged, one per line.
func fakeSSH(t *testing.T, self remote.Info, markerJSON string, report any) (log string) {
	t.Helper()
	dir := t.TempDir()
	probe := "apps=/apps\nsource=default\napps_dir=yes\nmarker=yes\nmarker_hex=" + hex.EncodeToString([]byte(markerJSON)) +
		"\nmachine=x86_64\nbin=present\nbin_regular=yes\nbin_exec=yes\nbin_head=7f454c4602010100000000000000000002003e00\nversion_rc=0\nversion=" +
		self.Line() + "\n"
	body, _ := json.Marshal(report)
	os.WriteFile(filepath.Join(dir, "probe.out"), []byte(probe), 0o644)
	os.WriteFile(filepath.Join(dir, "report.json"), body, 0o644)
	script := `#!/bin/sh
d=$(dirname "$0")
for last; do :; done
case "$*" in *" -O "*) exit 0 ;; esac
[ "$last" = true ] && exit 0
printf '%s\n' "$last" >> "$d/calls.log"
case "$last" in
    "'sh' '-s' "*) cat >/dev/null; cat "$d/probe.out" ;;
    *"'remote' 'check' "*|*"'remote' 'status' "*) cat "$d/report.json" ;;
    *) exit 99 ;;
esac
`
	os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("TMPDIR", t.TempDir())
	return filepath.Join(dir, "calls.log")
}

// One bootstrap probe and one read: the marker rides on the probe.
func TestServerRoundTrips(t *testing.T) {
	srvProject(t, "")
	s := newSrv(t)
	self := remote.Self("0.1.0-dev.1.1")
	log := fakeSSH(t, self, s.marker, s.r)
	var o, e bytes.Buffer
	code := Run(Env{Out: &cli.Output{Stdout: &o, Stderr: &e}, PWD: "/p", Version: "1", Server: "deploy@vps",
		Dial: Dial(self, func(string) (string, error) { return "", errors.New("nothing to ship") }),
		Now:  func() time.Time { return testNow }})
	calls, _ := os.ReadFile(log)
	lines := strings.Split(strings.TrimSpace(string(calls)), "\n")
	if code != 0 || len(lines) != 2 || !strings.HasPrefix(lines[0], "'sh' '-s'") || !strings.Contains(lines[1], "'remote' 'check' '/apps' '/apps/data' 'demo' 'demo-web'") {
		t.Errorf("exit %d, %d remote calls:\n%s\n%s%s", code, len(lines), calls, o.String(), e.String())
	}
}

// A marker the read would refuse stops the run at the probe: nothing ships.
func TestServerBrokenMarkerShipsNothing(t *testing.T) {
	for _, mk := range []string{"", "not json", `{"apps_path":"/apps"}`} {
		srvProject(t, "")
		self := remote.Self("0.1.0-dev.1.1")
		log := fakeSSH(t, remote.Self("0.0.1"), mk, newSrv(t).r)
		var o, e bytes.Buffer
		shipped := false
		code := Run(Env{Out: &cli.Output{Stdout: &o, Stderr: &e}, PWD: "/p", Version: "1", Server: "deploy@vps",
			Dial: Dial(self, func(string) (string, error) { shipped = true; return "", errors.New("shipping") })})
		calls, _ := os.ReadFile(log)
		if code != 1 || shipped || strings.Count(string(calls), "\n") != 1 || !strings.Contains(e.String(), "server.json on deploy@vps") {
			t.Errorf("marker %q: exit %d, shipped %v, calls:\n%s%s", mk, code, shipped, calls, e.String())
		}
	}
}

func TestDecodeServerShowsNothing(t *testing.T) {
	full, _ := json.Marshal(newSrv(t).r)
	for _, out := range [][]byte{full[:len(full)/2], []byte("-----BEGIN EC PRIVATE KEY----- " + secret)} {
		_, err := DecodeServer(out, "deploy@vps")
		if err == nil || strings.Contains(err.Error(), secret) || strings.Contains(err.Error(), "PRIVATE KEY") ||
			strings.Contains(err.Error(), string(full[20:40])) || !strings.Contains(err.Error(), "not shown") {
			t.Errorf("got %v", err)
		}
	}
}

// The health container: absent and a daemon not answering are two facts,
// and docker's complaint arrives as one line.
func TestCollectServerHealth(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "docker"), []byte(`#!/bin/sh
case "$1" in
    version) [ -z "$DAEMON_DOWN" ] && { echo 27.0; exit 0; }
             printf 'Cannot connect to the Docker daemon\r\nat unix:///var/run/docker.sock \n' >&2; exit 1 ;;
esac
exit 1
`), 0o755)
	t.Setenv("PATH", dir)
	apps := t.TempDir()
	r := CollectServer(apps, apps+"/data", "demo", "demo-web")
	if r.HealthState != "absent" || r.HealthHealth != "none" || r.DockerError != "" || r.Project != "absent" {
		t.Errorf("absent: %+v", r)
	}
	t.Setenv("DAEMON_DOWN", "1")
	r = CollectServer(apps, apps+"/data", "demo", "demo-web")
	if r.HealthState != "nodaemon" || r.DockerError != "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" {
		t.Errorf("nodaemon: %q %q", r.HealthState, r.DockerError)
	}
	if r := CollectServer(apps, apps+"/data", "demo", ""); r.HealthState != "skipped" {
		t.Errorf("no health container: %+v", r.HealthState)
	}
	t.Setenv("PATH", t.TempDir())
	if r := CollectServer(apps, apps+"/data", "demo", "demo-web"); r.HealthState != "nodocker" || r.Backup.Container.State != "nodocker" {
		t.Errorf("no docker: %+v", r)
	}
}

func TestServerB01BackupNotAnObject(t *testing.T) {
	for _, b := range []string{`"backup":"yes"`, `"backup":[true]`, `"backup":{"enabled":false}`, `"backup":{"enabled":"no"}`, `"backup":{"enabled":"true"}`} {
		srvProject(t, "")
		s := newSrv(t)
		s.marker = strings.Replace(s.marker, "}", ","+b+"}", 1)
		s.r.Backup.Dir = "dir"
		out, code := s.run()
		if code != 0 || strings.Contains(out, "backup on") || strings.Contains(out, "backup scheduler") || strings.Contains(out, "off-box") {
			t.Errorf("%s: exit %d\n%s", b, code, out)
		}
	}
}
