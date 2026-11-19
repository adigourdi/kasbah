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
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/deploy"
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
		"  ✓ E02 .env on deploy@vps has no missing keys vs .env.prod.example",
		"  ✓ E03 .env on deploy@vps has no extra keys vs .env.prod.example",
		"  ✓ M03 the mail stack on deploy@vps serves 'shop.rig.test' (listed under domains:)",
		"  ✓ manifest health.container 'demo-web' is running and healthy on deploy@vps",
		"  ✓ certificate for 'demo.example.com' valid for 400 more day(s) (until ",
		"O = kasbah test fixture, CN = demo.example.com)",
		"  ✓ R04 effective resource limits on deploy@vps match the host's 90% ceiling (14.4 cpus, 54g)",
		"  ✓ T05 No router claims a hostname kasbah owns on deploy@vps (traefik.rig.test mail.rig.test webmail.rig.test)",
		"  ✓ M04 every mail domain on deploy@vps has both DKIM keys, listed in its signing override (rig.test shop.rig.test)")
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
		}, []string{"⚠ E03 .env on deploy@vps has extra keys not in .env.prod.example: OTHER", "✓ E02 .env on deploy@vps has no missing keys"}, nil, 0},
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
		contains(t, out, "⚠ E02,E03 no .env.prod.example in this checkout, so /apps/demo/.env on deploy@vps cannot be checked for drift")
	})
}

func TestServerM03(t *testing.T) {
	for _, tc := range []struct {
		name, domain string
		set          func(s *srvCase)
		want         string
		code         int
	}{
		{"primary", "rig.test", nil, "✓ M03 the mail stack on deploy@vps serves 'rig.test' (its primary_domain)", 0},
		{"unserved", "nowhere.rig.test", nil, "✗ M03 the mail stack on deploy@vps does not serve 'nowhere.rig.test' — /apps/mail/kasbah.yml serves rig.test shop.rig.test; add it with: kasbah server add-mail-domain deploy@vps nowhere.rig.test", 6},
		{"no stack", "rig.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "absent", "" }, "✗ M03 demo claims the mail domain 'rig.test', and there is no mail stack on deploy@vps", 6},
		{"unreadable", "rig.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "unreadable", "" }, "⚠ M03 demo claims the mail domain 'rig.test', and /apps/mail/kasbah.yml on deploy@vps is unreadable", 0},
		{"not YAML", "rig.test", func(s *srvCase) { s.r.Registry = b64s("a: [\n") }, "does not parse as YAML", 0},
		{"no primary: the refusal is the finding", "rig.test", func(s *srvCase) { s.r.Registry = b64s("domains: [rig.test]\n") },
			"✗ M03 demo claims the mail domain 'rig.test', and /apps/mail/kasbah.yml on deploy@vps has no primary_domain:", 6},
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
	fix := "\n      kasbah server mail-dkim deploy@vps shop.rig.test --keep-keys\n"
	tail := " — its mail leaves unsigned and receivers file it as spam; this makes its missing keys and renders the override:"
	cant := ", so whether the mail domains are DKIM-signed cannot be checked"
	for _, tc := range []struct {
		name string
		set  func(s *srvCase)
		want []string
		not  []string
	}{
		{"no keys for one domain", func(s *srvCase) { s.r.DKIMKeys = s.r.DKIMKeys[:2] },
			[]string{"⚠ M04 mail domain 'shop.rig.test' on deploy@vps is not DKIM-signed: no rsa-2048-mail-shop.rig.test.private.txt or ed25519-ed-shop.rig.test.private.txt in " + dir + "/" + tail + fix},
			[]string{"'rig.test' on deploy@vps is not", "every mail domain", "signing block", "setup config dkim"}},
		{"ed25519 only", func(s *srvCase) { s.r.DKIMKeys = []string{s.r.DKIMKeys[0], s.r.DKIMKeys[1], s.r.DKIMKeys[3]} },
			[]string{"is not DKIM-signed: no rsa-2048-mail-shop.rig.test.private.txt in " + dir + "/" + tail + fix}, []string{"ed25519-ed-shop.rig.test.private.txt in"}},
		{"a hyphenated selector is not the domain's key", func(s *srvCase) {
			s.r.Registry = b64s("primary_domain: rig.test\ndomains: [rig.test, a.test]\n")
			s.r.DKIMKeys = append(s.r.DKIMKeys, "rsa-2048-mail-shop-a.test.private.txt", "ed25519-ed-shop-a.test.private.txt")
			s.r.DKIMConf = b64s(srvConf + strings.ReplaceAll(srvConf, "shop.rig.test", "shop-a.test"))
		}, []string{"⚠ M04 mail domain 'a.test' on deploy@vps is not DKIM-signed: no rsa-2048-mail-a.test.private.txt or ed25519-ed-a.test.private.txt in " + dir + "/, and " +
			conf + " does not list rsa-2048-mail-a.test.private.txt or ed25519-ed-a.test.private.txt" + tail +
			"\n      kasbah server mail-dkim deploy@vps a.test --keep-keys\n"}, nil},
		{"keys, no signing block", func(s *srvCase) { s.r.DKIMConf = b64s(strings.ReplaceAll(srvConf, "shop.rig.test", "other.test")) },
			[]string{"⚠ M04 mail domain 'shop.rig.test' on deploy@vps is not DKIM-signed: " + conf + " does not list rsa-2048-mail-shop.rig.test.private.txt or ed25519-ed-shop.rig.test.private.txt" + tail + fix},
			[]string{"setup config dkim keytype", "signing block", "'rig.test' on deploy@vps is not"}},
		{"no key directory yet", func(s *srvCase) { s.r.DKIMState, s.r.DKIMKeys = "absent", nil },
			[]string{"⚠ M04 mail domain 'rig.test' on deploy@vps is not DKIM-signed", "⚠ M04 mail domain 'shop.rig.test' on deploy@vps is not DKIM-signed"}, nil},
		{"an empty override lists nothing", func(s *srvCase) { s.r.DKIMConfState, s.r.DKIMConf = "empty", "" },
			[]string{"'rig.test' on deploy@vps is not DKIM-signed: " + conf + " does not list"}, nil},
		{"key directory unlistable", func(s *srvCase) { s.r.DKIMState, s.r.DKIMKeys = "unreadable", nil },
			[]string{"⚠ M04 " + dir + " on deploy@vps cannot be listed by this user" + cant}, []string{"is not DKIM-signed"}},
		{"key directory a file", func(s *srvCase) { s.r.DKIMState, s.r.DKIMKeys = "notdir", nil },
			[]string{"⚠ M04 " + dir + " on deploy@vps is not a directory (it is notdir)" + cant}, nil},
		{"override unreadable", func(s *srvCase) { s.r.DKIMConfState, s.r.DKIMConf = "unreadable", "" },
			[]string{"⚠ M04 " + conf + " on deploy@vps is unreadable" + cant}, []string{"is not DKIM-signed"}},
		{"override absent", func(s *srvCase) { s.r.DKIMConfState, s.r.DKIMConf = "absent", "" },
			[]string{"⚠ M04 " + conf + " on deploy@vps is absent" + cant}, nil},
		{"override bytes lost", func(s *srvCase) { s.r.DKIMConf = "!!" },
			[]string{"⚠ M04 " + conf + " on deploy@vps did not come back as readable bytes" + cant}, nil},
		{"registry unreadable", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "unreadable", "" },
			[]string{"⚠ M04 /apps/mail/kasbah.yml on deploy@vps is unreadable — so whether the mail domains are DKIM-signed cannot be checked"}, nil},
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
		target                    string
	}{
		{"running", "healthy", "", "✓ manifest health.container 'demo-web' is running and healthy on deploy@vps", 0, "demo-web"},
		{"running", "healthy", "", "✓ manifest health.container 'demo-web' (demo-demo-web-3) is running and healthy on deploy@vps", 0, "demo-demo-web-3"},
		{"running", "unhealthy", "", "✗ manifest health.container 'demo-web' (demo-demo-web-3) is running and UNHEALTHY", 6, "demo-demo-web-3"},
		{"running", "unhealthy", "", "✗ manifest health.container 'demo-web' is running and UNHEALTHY on deploy@vps — Traefik keeps routing to it", 6, ""},
		{"running", "starting", "", "⚠ manifest health.container 'demo-web' is running and still starting", 0, ""},
		{"running", "none", "", "declares no healthcheck, so nothing there reports health (H01)", 0, ""},
		{"exited", "weird", "", "is exited on deploy@vps and reports health 'weird'", 0, ""},
		{"absent", "none", "", "⚠ manifest health.container 'demo-web' is not running on deploy@vps — the project is deployed", 0, ""},
		{"nodocker", "nodocker", "", "⚠ no docker on deploy@vps, so the health of 'demo-web' cannot be read", 0, ""},
		{"nodaemon", "none", "Cannot connect to the Docker daemon", "the docker daemon on deploy@vps is not answering, so the health of 'demo-web' cannot be read — nothing here says the container is down (docker said: Cannot connect to the Docker daemon)", 0, ""},
	} {
		t.Run(tc.state+"/"+tc.health+"/"+tc.target, func(t *testing.T) {
			srvProject(t, "")
			s := newSrv(t)
			s.r.HealthTarget, s.r.HealthState, s.r.HealthHealth, s.r.DockerError = tc.target, tc.state, tc.health, tc.derr
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
		{"by a wildcard main", "file", store("*.example.com", nil, san), "✓ certificate for 'demo.example.com' (by the wildcard *.example.com) valid for 100 more day(s)", 0},
		{"by a wildcard SAN", "file", store("example.com", []string{"*.example.com"}, expired), "✗ certificate for 'demo.example.com' (by the wildcard *.example.com, a SAN of example.com) EXPIRED 3 day(s) ago (", 6},
		{"a wildcard covers one label", "file", store("*.com", nil, san), "no certificate for 'demo.example.com' in /apps/data/traefik/letsencrypt/acme.json on deploy@vps (1 in the store)", 0},
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

// An unrouted project has no certificate to look for, and says nothing of one.
func TestServerCertUnrouted(t *testing.T) {
	for _, extra := range []string{"routed: false\n", "routed: false\ndomain: \"\"\n"} {
		project(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nhealth:\n  container: demo-web\n" + extra, "traefik-dynamic.yml": ""})
		s := newSrv(t)
		s.r.AcmeState, s.r.Acme = "unreadable", ""
		out, _ := s.run()
		contains(t, out, "Server (deploy@vps at /apps):")
		hasNot(t, out, "certificate", "acme.json", "names no domain")
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
		{"KASBAH_CPU_LIMIT=999\nKASBAH_MEM_LIMIT=54g\n", "✗ R04 effective resource limits on deploy@vps are above the host's 90% ceiling: cpus 999 > 14.4", 6},
		{"KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=1g\n", "⚠ R04 effective resource limits on deploy@vps are below the host's 90% ceiling: cpus 2 < 14.4; mem_limit 1g < 54g", 0},
		{"KASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=99g\n", "✗ R04 effective resource limits on deploy@vps are above the host's 90% ceiling: cpus 2 < 14.4; mem_limit 99g > 54g", 6},
		{"KASBAH_CPU_LIMIT=14.40\nKASBAH_MEM_LIMIT=55296m\n", "✓ R04 effective resource limits on deploy@vps match the host's 90% ceiling (14.40 cpus, 55296m)", 0},
		{"KASBAH_CPU_LIMIT=1\nexport KASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54G\n", "✓ R04 effective resource limits on deploy@vps match", 0},
		{"KASBAH_CPU_LIMIT=lots\nKASBAH_MEM_LIMIT=54g\n", "⚠ R04 effective resource limits on deploy@vps could not all be compared with the host's 14.4 cpus / 54g: cpus 'lots' is not a number", 0},
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

// Below the ceiling is deliberate when kasbah.yml's resources: sets that half.
func TestServerR04Resources(t *testing.T) {
	srvProject(t, "resources:\n  cpus: 2\n")
	s := newSrv(t)
	s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=2.0\nKASBAH_MEM_LIMIT=54g\n")
	out, _ := s.run()
	contains(t, out, "  ✓ R04 effective resource limits on deploy@vps are within the host's 90% ceiling (2.0 cpus, 54g) — cpus set by kasbah.yml's resources:")

	srvProject(t, "resources:\n  cpus: 2\n")
	s = newSrv(t)
	s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=2.0\nKASBAH_MEM_LIMIT=1g\n")
	out, _ = s.run()
	contains(t, out, "  ⚠ R04 effective resource limits on deploy@vps are below the host's 90% ceiling: mem_limit 1g < 54g")

	srvProject(t, "resources:\n  memory: 25%\n")
	s = newSrv(t)
	s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=15g\n")
	out, _ = s.run()
	contains(t, out, "  ✓ R04 effective resource limits on deploy@vps are within the host's 90% ceiling (14.4 cpus, 15g) — memory set by kasbah.yml's resources:")
	hasNot(t, out, "are below the host's 90% ceiling")

	srvProject(t, "resources:\n  memory: 25%\n")
	s = newSrv(t)
	s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=2.0\nKASBAH_MEM_LIMIT=15g\n")
	out, _ = s.run()
	contains(t, out, "  ⚠ R04 effective resource limits on deploy@vps are below the host's 90% ceiling: cpus 2.0 < 14.4")
	hasNot(t, out, "mem_limit 15g < 54g")
}

// A host without the memory controller warns beside R04/R06; a marker that
// records it, or one too old to record anything, says nothing.
func TestServerMemoryController(t *testing.T) {
	for _, tc := range []struct {
		key  string
		warn bool
	}{{`,"memory_controller":false`, true}, {`,"memory_controller":true`, false}, {"", false}} {
		srvProject(t, "")
		s := newSrv(t)
		s.marker = strings.Replace(s.marker, "}", tc.key+"}", 1)
		s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54g\n")
		out, code := s.run()
		want := "  ⚠ deploy@vps has no memory cgroup controller, so Docker discards every mem_limit: the limits are written but not enforced\n" +
			"      on Raspberry Pi OS: append cgroup_enable=memory to the single line of /boot/firmware/cmdline.txt (/boot/cmdline.txt before Bookworm)\n      elsewhere: remove cgroup_disable=memory"
		if tc.warn {
			contains(t, out, "✓ R04 effective resource limits on deploy@vps match", want, "      then reboot and re-run `kasbah server init deploy@vps` to record it\n")
		} else {
			hasNot(t, out, "memory cgroup controller")
		}
		if code != 0 {
			t.Errorf("%q: exit %d", tc.key, code)
		}
	}
}

// Projects below the ceiling are shares and are summed; one on the ceiling is
// a cap and is not.
func TestServerR06(t *testing.T) {
	for _, tc := range []struct {
		limits []ProjectLimits
		want   []string
		not    []string
	}{
		{nil, nil, []string{"fit the host", "add up to"}},
		{[]ProjectLimits{{"demo", "14.4", "54g"}, {"shop", "14.4", "54g"}}, nil, []string{"fit the host", "add up to"}},
		{[]ProjectLimits{{"demo", "8.0", "30g"}, {"shop", "4.0", "54g"}, {"blog", "14.4", "20g"}},
			[]string{"  ✓ R06 the projects on deploy@vps with limits of their own fit the host together (12.0 of 16 cores, 51200m of 61440m)"}, []string{"add up to"}},
		{[]ProjectLimits{{"demo", "8.0", "40g"}, {"shop", "9.0", "30g"}, {"blog", "14.4", "54g"}},
			[]string{"  ⚠ R06 the projects on deploy@vps with their own cpus limit add up to 17.0 cores, more than the host's 16: demo 8.0, shop 9.0",
				"  ⚠ R06 the projects on deploy@vps with their own memory limit add up to 71680m, more than the host's 61440m: demo 40g, shop 30g"},
			[]string{"fit the host"}},
		{[]ProjectLimits{{"demo", "14.4", "20g"}},
			[]string{"  ✓ R06 the projects on deploy@vps with limits of their own fit the host together (20480m of 61440m)"}, []string{"cores", "add up to"}},
	} {
		srvProject(t, "")
		s := newSrv(t)
		s.r.Limits, s.r.HostCores, s.r.HostMemKB = tc.limits, 16, 62914560
		out, code := s.run()
		contains(t, out, tc.want...)
		hasNot(t, out, tc.not...)
		if code != 0 {
			t.Errorf("%v: exit %d", tc.limits, code)
		}
	}
}

// The server reads each project's managed block, and no other line of its .env.
func TestCollectServerLimits(t *testing.T) {
	apps := t.TempDir()
	for name, body := range map[string]string{
		"demo":    "SECRET=hunter2\n# >>> kasbah managed block - do not edit, rewritten on every deploy >>>\nKASBAH_CPU_LIMIT=2.0\nKASBAH_MEM_LIMIT=1g\n# <<< kasbah managed block <<<\n",
		"shop":    "KASBAH_CPU_LIMIT=9\n",
		"traefik": "# >>> kasbah managed block - do not edit, rewritten on every deploy >>>\nKASBAH_CPU_LIMIT=1.0\n# <<< kasbah managed block <<<\n",
	} {
		os.MkdirAll(filepath.Join(apps, name), 0o755)
		os.WriteFile(filepath.Join(apps, name, ".env"), []byte(body), 0o600)
	}
	os.MkdirAll(filepath.Join(apps, "empty"), 0o755)
	r := CollectServer(apps, apps+"/data", "demo", "")
	if len(r.Limits) != 1 || r.Limits[0] != (ProjectLimits{"demo", "2.0", "1g"}) || r.HostCores < 1 || r.HostMemKB < 1 {
		t.Errorf("limits: %+v %d %d", r.Limits, r.HostCores, r.HostMemKB)
	}
	b, _ := json.Marshal(r.Limits)
	if strings.Contains(string(b), "hunter2") {
		t.Errorf("a secret crossed: %s", b)
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
			[]string{"  ✓ R01,R02 All services set cpus/mem_limit, some as literals: demo-web(cpus=16,mem_limit=2g) — compared with the host's ceiling under Server (R04)",
				"  ✗ R04 literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web cpus 16 > 14.4; demo-web mem_limit 2g < 54g — kasbah's limits are anti-takeover ceilings"},
			[]string{"Services with literal resource limits", "effective resource limits on"}, 6},
		{compose("0.5", "${KASBAH_MEM_LIMIT}"), "KASBAH_CPU_LIMIT=lots\nKASBAH_MEM_LIMIT=54g\n",
			[]string{"  ⚠ R04 literal resource limits in compose.prod.yml are below the 90% ceiling of deploy@vps: demo-web cpus 0.5 < 14.4 — a tighter per-service limit is allowed, but flagged",
				"  ✓ R04 effective resource limits on deploy@vps match the host's 90% ceiling (54g)"},
			nil, 0},
		{compose("14.40", "55296m"), "",
			[]string{"  ✓ R04 literal resource limits in compose.prod.yml match the 90% ceiling of deploy@vps (14.4 cpus, 54g)"},
			[]string{"effective resource limits on", "carries no KASBAH_CPU_LIMIT"}, 0},
		{strings.Replace(goodCompose, "    cpus: ${KASBAH_CPU_LIMIT}\n", "    deploy: {resources: {limits: {cpus: 16}}}\n", 1), "KASBAH_MEM_LIMIT=54g\n",
			[]string{"  ✗ R04 literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web cpus 16 > 14.4",
				"  ✓ R04 effective resource limits on deploy@vps match the host's 90% ceiling (54g)"},
			nil, 6},
		{compose("${KASBAH_CPU_LIMIT}", "99g"), "KASBAH_CPU_LIMIT=14.4\n",
			[]string{"  ✗ R04 literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web mem_limit 99g > 54g",
				"  ✓ R04 effective resource limits on deploy@vps match"},
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
		contains(t, out, "  ✗ R04 literal resource limits in compose.prod.yml are above the 90% ceiling of deploy@vps: demo-web cpus 32 > 14.4")
		if code != 6 {
			t.Errorf("exit %d, want 6", code)
		}
	})
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
		{"mail of another apex is not reserved here", "mail.demo.example.com", nil, "✓ T05 No router claims a hostname kasbah owns on deploy@vps (traefik.rig.test mail.rig.test webmail.rig.test)", 0},
		{"webmail of the primary is", "webmail.rig.test", nil, "✗ T05 Routers claim hostnames kasbah owns on deploy@vps: x→webmail.rig.test (traefik.rig.test mail.rig.test webmail.rig.test)", 6},
		{"no registry: the apex", "mail.rig.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "absent", "" }, "✗ T05 Routers claim hostnames kasbah owns on deploy@vps: x→mail.rig.test", 6},
		{"dashboard off: traefik.* is nobody's", "traefik.rig.test", func(s *srvCase) { s.r.Shared = b64s("http: {}\n") },
			"✓ T05 No router claims a hostname kasbah owns on deploy@vps (mail.rig.test webmail.rig.test; dashboard off, traefik.* not reserved)", 0},
		{"dashboard off, registry refused", "traefik.rig.test", func(s *srvCase) {
			s.r.Shared = b64s("http:\n  middlewares: {}\n")
			s.r.Registry = b64s("domains: [x.test]\n")
		}, "✓ T05 No router claims reserved hostnames (mail.*, webmail.*) — heuristic: deploy@vps was asked and its mail registry could not be read — the dashboard is off on deploy@vps, so traefik.* is not reserved", 0},
		{"dashboard off, no registry", "traefik.rig.test", func(s *srvCase) {
			s.r.Shared = b64s("http: {}\n")
			s.r.RegistryState, s.r.Registry = "absent", ""
		}, "✓ T05 No router claims reserved hostnames (mail.*, webmail.*) — heuristic: deploy@vps has no mail registry, and no dashboard apex to name mail.* from — the dashboard is off", 0},
		{"an unparseable _shared.yml: traefik keeps the heuristic", "traefik.elsewhere.test", func(s *srvCase) { s.r.Shared = b64s("http: [1\n") },
			"✗ T05 Routers claim hostnames kasbah owns on deploy@vps: x→traefik.elsewhere.test (mail.rig.test webmail.rig.test; traefik.* by heuristic)", 6},
		{"a refused registry: mail keeps the heuristic", "mail.anything.test", func(s *srvCase) { s.r.Registry = b64s("domains: [x.test]\n") },
			"✗ T05 Routers claim hostnames kasbah owns on deploy@vps: x→mail.anything.test (traefik.rig.test; mail.* by heuristic; webmail.* by heuristic)", 6},
		{"an unreadable registry: mail keeps the heuristic", "webmail.x.test", func(s *srvCase) { s.r.RegistryState, s.r.Registry = "unreadable", "" },
			"(traefik.rig.test; mail.* by heuristic; webmail.* by heuristic)", 6},
		{"neither read", "mail.x.test", func(s *srvCase) {
			s.r.Shared = ""
			s.r.RegistryState, s.r.Registry = "unreadable", ""
		}, "✗ T05 Routers claim reserved hostnames: x→mail.x.test — heuristic: deploy@vps was asked and neither its dashboard fragment nor a mail registry could be read", 6},
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
	contains(t, out, "✗ T09 Fragment routes to Traefik's internal services (only noop@internal is allowed): demo→api@internal")
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
		{"ok", "dir", "file", ok, "running", "✓ B01 the last backup on deploy@vps finished 4h ago and succeeded (repositories: demo)", 0},
		{"nostack", "absent", "absent", "", "running", "⚠ B01 /apps/.kasbah/server.json on deploy@vps records off-box backups and /apps/.kasbah/backup is not there", 0},
		{"norecord", "dir", "absent", "", "exited", "⚠ B01 the backup scheduler on deploy@vps has written no record at /apps/.kasbah/backup/state/status — it writes one as its first act, so it has not started since backups were configured (its container is exited)", 0},
		{"unreadable", "dir", "unreadable", "", "running", "⚠ B01 /apps/.kasbah/backup/state/status on deploy@vps cannot be read by the ssh user, so nothing here says whether a backup has ever run", 0},
		{"empty", "dir", "empty", "", "running", "status on deploy@vps is empty, so nothing here", 0},
		{"unparsed", "dir", "file", rec("deadline=2000086400"), "running", "is not a record this kasbah reads — it carries no scheduler state", 0},
		{"octal deadline", "dir", "file", rec("state=sleeping", "deadline=01999000009"), "running", "records deadline='01999000009', which is not a unix time this kasbah can compare", 0},
		{"huge deadline", "dir", "file", rec("state=sleeping", "deadline=999999999999999999999999"), "running", "which is not a unix time this kasbah can compare", 0},
		{"never", "dir", "file", rec("state=starting", "deadline=2000000600", "last_run_status=-"), "running", "⚠ B01 backups are configured on deploy@vps and no run has finished yet — the scheduler is 'starting'", 0},
		{"shipped nothing", "dir", "file", strings.Replace(ok, "repos= demo", "repos= none", 1), "running", "⚠ B01 the last backup on deploy@vps finished 4h ago and shipped nothing", 0},
		{"failed", "dir", "file", strings.Replace(ok, "status=ok", "status=failed", 1), "running", "✗ B01 the last backup on deploy@vps FAILED 4h ago (repositories backed up: demo)", 6},
		{"failed hooks", "dir", "file", strings.Replace(ok, "status=ok", "status=failed", 1) + "last_run_failed=demo the backup hook failed (exit 3): pg_dump\nlast_run_failed=web remove /apps/web/.kasbah-prev by hand\n", "running",
			"✗ B01 the last backup on deploy@vps FAILED 4h ago (repositories backed up: demo) — demo's backup failed: the backup hook failed (exit 3): pg_dump; web's backup failed: remove /apps/web/.kasbah-prev by hand; docker logs kasbah-backup has each project's result and the last 64 KB of the backup hooks' stderr", 6},
		{"no launcher", "dir", "file", strings.Replace(ok, "status=ok", "status=failed", 1) + "last_run_launcher=no Docker socket at /var/run/docker.sock\n", "running",
			"FAILED 4h ago (repositories backed up: demo) — the nightly backup job failed: no Docker socket at /var/run/docker.sock; docker logs kasbah-backup says why", 6},
		{"overdue", "dir", "file", rec("state=running", "deadline=1999999000", "last_run_finished=1999983600", "last_run_status=ok"), "running", "✗ B01 the backup scheduler on deploy@vps is 16m past its own deadline in state 'running' — a run that never returned, or a sleep that never woke, so nothing is being shipped off-box (the last run finished 4h ago)", 6},
		{"stopped scheduler is asked first", "dir", "file", ok, "exited", "✗ B01 the backup scheduler on deploy@vps is exited, so nothing is being shipped off-box — its record still reads 'ok', last run 4h ago", 6},
		{"notours", "dir", "file", ok, "notours", "✗ B01 the container named kasbah-backup on deploy@vps was not started as the kasbah-backup compose project from /apps/.kasbah/backup", 6},
		{"nodaemon", "dir", "file", ok, "nodaemon", "⚠ B01 the docker daemon on deploy@vps is not answering, so whether its backup scheduler is running cannot be read", 0},
		{"nodocker", "dir", "file", ok, "nodocker", "⚠ B01 there is no docker on deploy@vps, so whether its backup scheduler is running cannot be read — the record says 'ok'", 0},
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
			"⚠ B01 backup repositories on deploy@vps with no password: acme x mail — a repository with no password is not backed up at all",
			"⚠ B01 backup repository passwords on deploy@vps that no project files into any more: gone — the last project of that client was dropped",
			"✓ B01 the last backup on deploy@vps finished 4h ago and succeeded")
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
		"--bogus":               "error: check: unknown argument '--bogus' (expected --server [[USER@]HOST], --fix, --yes)",
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
for last; do :; done
case "$1" in
    version) [ -z "$DAEMON_DOWN" ] && { echo 27.0; exit 0; }
             printf 'Cannot connect to the Docker daemon\r\nat unix:///var/run/docker.sock \n' >&2; exit 1 ;;
    ps) [ -z "$DAEMON_DOWN$PS_FAIL" ] || exit 1
        case "$*" in *com.docker.compose.project=demo*) printf '%s' "$PS" ;; esac; exit 0 ;;
    inspect) case "$last" in demo-demo-web-3|web)
        case "$*" in *Health*) echo healthy ;; *) echo running ;; esac; exit 0 ;; esac ;;
esac
exit 1
`), 0o755)
	t.Setenv("PATH", dir)
	apps := t.TempDir()
	r := CollectServer(apps, apps+"/data", "demo", "demo-web")
	if r.HealthState != "absent" || r.HealthHealth != "none" || r.DockerError != "" || r.Project != "absent" || r.HealthTarget != "demo-web" {
		t.Errorf("absent: %+v", r)
	}
	// A service name reads off the replica deploy would wait on, and an
	// exact container name off itself.
	t.Setenv("PS", "a\tdemo-demo-web-2\tdemo-web\t2\texited\nb\tdemo-demo-web-3\tdemo-web\t3\trunning\nc\tweb\tother\t1\trunning\n")
	for name, want := range map[string]string{"demo-web": "demo-demo-web-3", "web": "web"} {
		r = CollectServer(apps, apps+"/data", "demo", name)
		if r.HealthTarget != want || r.HealthState != "running" || r.HealthHealth != "healthy" {
			t.Errorf("%s: %q %q %q, want %s running healthy", name, r.HealthTarget, r.HealthState, r.HealthHealth, want)
		}
	}
	// A service with no container is the name as written, absent.
	t.Setenv("PS", "c\tweb\tother\t1\trunning\n")
	if r = CollectServer(apps, apps+"/data", "demo", "demo-web"); r.HealthTarget != "demo-web" || r.HealthState != "absent" {
		t.Errorf("no container: %+v", r)
	}
	// A failed ps leaves the name as written for inspect to judge, though the
	// replica list would resolve demo-web to demo-demo-web-3.
	t.Setenv("PS", "b\tdemo-demo-web-3\tdemo-web\t3\trunning\n")
	t.Setenv("PS_FAIL", "1")
	for name, want := range map[string]string{"web": "running", "demo-web": "absent"} {
		if r = CollectServer(apps, apps+"/data", "demo", name); r.HealthTarget != name || r.HealthState != want {
			t.Errorf("ps failing, %s: %q %q, want %s", name, r.HealthTarget, r.HealthState, want)
		}
	}
	t.Setenv("PS_FAIL", "")
	t.Setenv("PS", "")
	t.Setenv("DAEMON_DOWN", "1")
	r = CollectServer(apps, apps+"/data", "demo", "demo-web")
	if r.HealthState != "nodaemon" || r.HealthTarget != "demo-web" || r.DockerError != "Cannot connect to the Docker daemon at unix:///var/run/docker.sock" {
		t.Errorf("nodaemon: %q %q %q", r.HealthState, r.HealthTarget, r.DockerError)
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

func TestServerT04T10(t *testing.T) {
	static := "certificatesResolvers:\n  http:\n    acme: {httpChallenge: {entryPoint: web}}\n" +
		"  cloudflare:\n    acme: {dnsChallenge: {provider: cloudflare}}\n  plain:\n    acme: {httpChallenge: {entryPoint: web}}\n"
	wild := func(resolver string) string {
		return strings.Replace(goodFragment, "tls: {certResolver: http}", "tls: {certResolver: "+resolver+", domains: [{main: demo.example.com, sans: [\"*.demo.example.com\"]}]}", 1)
	}
	for _, tc := range []struct {
		name, frag, static, want, not string
		code                          int
	}{
		{"declared DNS resolver", wild("cloudflare"), static, "✓ T04 Secure routers name a cert resolver", "Routers name a cert resolver", 0},
		{"undeclared resolver", wild("ovh"), static, "✗ T04 Routers name a cert resolver deploy@vps does not declare: demo→ovh", "wildcard certificate from a resolver", 6},
		{"declared without dnsChallenge", wild("plain"), static, "✗ T10 Routers ask for a wildcard certificate from a resolver without dnsChallenge (HTTP-01 cannot issue one): demo→plain (*.demo.example.com)", "does not declare", 6},
		{"a Host() wildcard on http", strings.Replace(goodFragment, "demo: {rule: \"Host(`demo.example.com`)", "demo: {rule: \"Host(`*.demo.example.com`)", 1), static, "demo→http (*.demo.example.com)", "does not declare", 6},
		{"unreadable traefik.yml warns", wild("cloudflare"), "{nope", "traefik.yml on deploy@vps could not be read, so whether it declares them is unknown", "does not declare", 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srvProject(t, "")
			if err := os.WriteFile("traefik-dynamic.yml", []byte(tc.frag), 0o644); err != nil {
				t.Fatal(err)
			}
			s := newSrv(t)
			s.r.StaticState, s.r.Static = "file", b64s(tc.static)
			out, code := s.run()
			contains(t, out, tc.want)
			hasNot(t, out, tc.not)
			if code != tc.code {
				t.Errorf("exit %d, want %d:\n%s", code, tc.code, out)
			}
		})
	}
}

func TestServerCertResolver(t *testing.T) {
	srvProject(t, "")
	frag := strings.Replace(goodFragment, "certResolver: http", "certResolver: cloudflare", 1)
	if err := os.WriteFile("traefik-dynamic.yml", []byte(frag), 0o644); err != nil {
		t.Fatal(err)
	}
	cert := b64s(certPEM(t, "demo.example.com", nil, testNow.Add(100*24*time.Hour+time.Hour)))
	s := newSrv(t)
	// The http store has nothing for the host; the resolver its router names does.
	s.r.Acme = b64s(`{"http":{"Certificates":[]},"cloudflare":` + strings.TrimPrefix(strings.TrimSuffix(store("demo.example.com", nil, cert), "}"), `{"http":`) + `}`)
	out, _ := s.run()
	contains(t, out, "✓ certificate for 'demo.example.com' valid for 100 more day(s)")
	s.r.Acme = b64s(store("demo.example.com", nil, cert))
	out, _ = s.run()
	contains(t, out, "has no 'cloudflare' store — the resolver this checkout's router names for 'demo.example.com' has issued nothing yet")
}

func TestCollectServerStatic(t *testing.T) {
	apps := t.TempDir()
	os.MkdirAll(apps+"/traefik", 0o755)
	os.WriteFile(apps+"/traefik/traefik.yml", []byte("certificatesResolvers: {}\n"), 0o644)
	r := CollectServer(apps, apps+"/data", "demo", "")
	if r.StaticState != "file" || string(dec(r.Static)) != "certificatesResolvers: {}\n" {
		t.Errorf("traefik.yml not collected: %q %q", r.StaticState, r.Static)
	}
}

func TestServerB02(t *testing.T) {
	t.Run("none: silent", func(t *testing.T) {
		srvProject(t, "")
		out, code := newSrv(t).run()
		hasNot(t, out, "leftover")
		if code != 0 {
			t.Errorf("exit %d", code)
		}
	})
	t.Run("several projects, each kind", func(t *testing.T) {
		srvProject(t, "")
		s := newSrv(t)
		var many []string
		for i := range 22 {
			many = append(many, fmt.Sprintf("1.0.%d-20261102-1000%02d", i, i))
		}
		s.r.Leftovers = []ProjectLeftovers{
			{Name: "demo", Leftovers: deploy.Leftovers{Backups: []string{"1.2.0-20261102-100000"},
				Kept: []string{deploy.KeptPrefix + "1.1.0-20261101-090000"}, Unpacked: []string{deploy.UnpackedPrefix + "4242"}}},
			{Name: "blog", Leftovers: deploy.Leftovers{Backups: many}},
			{Name: "empty"},
		}
		out, code := s.run()
		if code != 0 {
			t.Errorf("B02 failed the run, exit %d:\n%s", code, out)
		}
		contains(t, out,
			"  ⚠ B02 demo on deploy@vps holds 3 leftover(s) a deploy or rollback did not finish with — a backup directory whose tarball was never written, a snapshot a backup could not take in, or a killed rollback's extraction — and each may hold a copy of .env; inspect each, then remove it by hand:\n"+
				"      /apps/demo/backups/1.2.0-20261102-100000\n      /apps/demo/.kasbah-prev.kept-1.1.0-20261101-090000\n      /apps/demo/.kasbah-unpacked.4242\n",
			"  ⚠ B02 blog on deploy@vps holds 22 leftover(s)",
			"      /apps/blog/backups/1.0.19-20261102-100019\n      and 2 more\n")
		hasNot(t, out, "1.0.20-", "empty on deploy@vps", "holds the lock")
	})
	t.Run("a run holds the lock", func(t *testing.T) {
		srvProject(t, "")
		s := newSrv(t)
		s.r.Leftovers = []ProjectLeftovers{
			{Name: "demo", Leftovers: deploy.Leftovers{Backups: []string{"1.2.0-20261102-100000"},
				Kept: []string{deploy.KeptPrefix + "1.1.0-20261101-090000"}, Unpacked: []string{deploy.UnpackedPrefix + "77"},
				Holder: "a deploy or rollback by alice (pid 4242)"}},
			{Name: "blog", Leftovers: deploy.Leftovers{Backups: []string{"1.0.0-20261102-100000"}, Holder: "a deploy or rollback by bob (pid 9)"}},
		}
		out, code := s.run()
		if code != 0 {
			t.Errorf("exit %d:\n%s", code, out)
		}
		contains(t, out,
			"  ⚠ B02 demo on deploy@vps: a run holds the lock now (a deploy or rollback by alice (pid 4242)); a backup directory or extraction may be its own — each may hold a copy of .env:\n"+
				"      /apps/demo/backups/1.2.0-20261102-100000\n      /apps/demo/.kasbah-unpacked.77\n"+
				"  ⚠ B02 demo on deploy@vps holds 1 leftover(s) a deploy or rollback did not finish with",
			"inspect each, then remove it by hand:\n      /apps/demo/.kasbah-prev.kept-1.1.0-20261101-090000\n",
			"  ⚠ B02 blog on deploy@vps: a run holds the lock now (a deploy or rollback by bob (pid 9))")
		hasNot(t, out, "blog on deploy@vps holds")
	})
	t.Run("cannot be checked", func(t *testing.T) {
		srvProject(t, "")
		s := newSrv(t)
		s.r.Leftovers = []ProjectLeftovers{{Name: "demo", Leftovers: deploy.Leftovers{Error: "backups/ could not be listed: permission denied"}}}
		out, code := s.run()
		contains(t, out, "  ⚠ B02 whether demo on deploy@vps holds a leftover that may hold a copy of .env cannot be checked: backups/ could not be listed: permission denied\n")
		hasNot(t, out, "leftover(s)", "✓ demo")
		if code != 0 {
			t.Errorf("exit %d", code)
		}
	})
}

func TestCollectServerLeftovers(t *testing.T) {
	apps := t.TempDir()
	for _, d := range []string{"demo/backups/1.0.0-20261102-100000", "demo/" + deploy.UnpackedPrefix + "7", "tidy/backups",
		"traefik/backups/20261102-100000", ".hidden/" + deploy.UnpackedPrefix + "1", "Caps/" + deploy.UnpackedPrefix + "2"} {
		os.MkdirAll(filepath.Join(apps, d), 0o755)
	}
	os.WriteFile(filepath.Join(apps, "demo/backups/1.0.0-20261101-100000.tar.gz"), nil, 0o644)
	// A project directory symlinked elsewhere is a project, as status and destroy see it.
	elsewhere := t.TempDir()
	os.Mkdir(filepath.Join(elsewhere, deploy.KeptPrefix+"1.0.0-20261102-100000"), 0o755)
	os.Symlink(elsewhere, filepath.Join(apps, "linked"))
	r := CollectServer(apps, apps+"/data", "demo", "")
	if len(r.Leftovers) != 2 || r.Leftovers[0].Name != "demo" || r.Leftovers[1].Name != "linked" ||
		strings.Join(r.Leftovers[0].Paths(apps+"/demo"), " ") != apps+"/demo/backups/1.0.0-20261102-100000 "+apps+"/demo/"+deploy.UnpackedPrefix+"7" {
		t.Errorf("leftovers: %+v", r.Leftovers)
	}
	if b, _ := json.Marshal(r); !strings.Contains(string(b), `"leftovers":[{"name":"demo","backups":["1.0.0-20261102-100000"],"kept":[],"unpacked":[".kasbah-unpacked.7"],"holder":"","error":""},`) {
		t.Errorf("wire form: %s", b)
	}
}

func TestServerOutsiders(t *testing.T) {
	ports := strings.Replace(goodCompose, "    networks: [kasbah]\n", "    networks: [kasbah]\n    ports: [\"${WEB_PORT:-8080}:80\", {target: 53, published: 5353, protocol: udp, host_ip: 127.0.0.1}, \"9000\"]\n", 1)
	other := deploy.Holder{Name: "other-web-1", Project: "other", Dir: "/home/u/other", Config: "/home/u/other/compose.yml",
		Ports: []deploy.Bind{{Lo: 8080, Hi: 8080, Proto: "tcp"}}}
	dns := deploy.Holder{Name: "dns", Ports: []deploy.Bind{{Lo: 5353, Hi: 5353, Proto: "udp"}}}
	named := deploy.Holder{Name: "demo-web-1", Project: "demo", Dir: "/home/u/demo", Config: "/home/u/demo/compose.yml"}
	for _, tc := range []struct {
		env       string
		hs        []deploy.Holder
		err       string
		want, not []string
		code      int
	}{
		{"", nil, "", []string{"  ✓ C12,C13,C17 no container outside /apps/demo on deploy@vps publishes a port it publishes, holds a container_name it sets, or runs under its compose project name"}, nil, 0},
		{"", []deploy.Holder{dns, other}, "", []string{
			"  ✗ C12 on deploy@vps, container other-web-1 (compose project other) publishes 8080/tcp, which service demo-web of this project publishes too — stop or move that container, or change the port demo-web publishes — a deploy refuses this",
			"  ✗ C12 on deploy@vps, container dns (not a compose container) publishes 5353/udp, which service demo-web of this project publishes too"}, nil, 6},
		{"WEB_PORT=8081\n", []deploy.Holder{other}, "", []string{"  ✓ C12,C13,C17 no container outside"}, nil, 0},
		// The .env as compose reads it: an inline comment and quotes are not the value.
		{"WEB_PORT=8080 # dev\n", []deploy.Holder{other}, "", []string{"  ✗ C12 on deploy@vps, container other-web-1 (compose project other) publishes 8080/tcp"}, nil, 6},
		{"WEB_PORT=\"8080\"\n", []deploy.Holder{other}, "", []string{"  ✗ C12 on deploy@vps, container other-web-1 (compose project other) publishes 8080/tcp"}, nil, 6},
		{"WEB_PORT=${OTHER:-8081}\n", []deploy.Holder{other}, "", []string{"  ✓ C12,C13,C17 no container outside"}, nil, 0},
		// `KEY = v` and `KEY: v` set the port, as compose reads them.
		{"WEB_PORT = 8080\n", []deploy.Holder{other}, "", []string{"  ✗ C12 on deploy@vps, container other-web-1 (compose project other) publishes 8080/tcp"}, nil, 6},
		{"\u00a0\nWEB_PORT: 8080 # dev\n", []deploy.Holder{other}, "", []string{"  ✗ C12 on deploy@vps, container other-web-1 (compose project other) publishes 8080/tcp"}, nil, 6},
		// A key compose would take with other characters: unread, so the port cannot pass on its default.
		{"WEB.PORT=1\n", []deploy.Holder{other}, "", []string{"cannot be checked: the server's .env has a line kasbah cannot read as compose does: line 4 is not an assignment kasbah reads"}, []string{"✓ C12,C13,C17 no container outside"}, 0},
		{"", []deploy.Holder{named}, "", []string{
			"  ✗ C13 on deploy@vps, a compose project named demo already exists outside /apps/demo: demo-web-1, started from /home/u/demo (/home/u/demo/compose.yml) — Docker keys compose projects by name, so this project's up would take its containers for its own; run `docker compose -p demo down` in /home/u/demo, or rename this project — a deploy refuses this"}, nil, 6},
		{"", nil, "there is no docker on the server", []string{
			"  ⚠ C12,C13,C17 whether a container outside /apps/demo on deploy@vps publishes a port it publishes, holds a container_name it sets, or runs under its compose project name, cannot be checked: there is no docker on the server"}, []string{"✓ C12,C13,C17 no container outside"}, 0},
	} {
		srvProject(t, "")
		os.WriteFile(composeFile, []byte(ports), 0o644)
		s := newSrv(t)
		s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54g\n" + tc.env)
		s.r.Outsiders, s.r.OutsidersError = tc.hs, tc.err
		out, code := s.run()
		contains(t, out, tc.want...)
		hasNot(t, out, tc.not...)
		if code != tc.code {
			t.Errorf("%v: exit %d, want %d:\n%s", tc.hs, code, tc.code, out)
		}
	}
}

// A container_name an outside container holds, read from the server's .env
// as compose interpolates it; one left unread warns.
func TestServerOutsidersContainerName(t *testing.T) {
	named := strings.Replace(goodCompose, "networks:\n  kasbah: {}\n", `  db:
    image: postgres:alpine
    container_name: "${CN:-db}"
    restart: unless-stopped
    cpus: ${KASBAH_CPU_LIMIT}
    mem_limit: ${KASBAH_MEM_LIMIT}
    logging: {driver: json-file, options: {max-size: 10m, max-file: "3"}}
networks:
  kasbah: {}
`, 1)
	holder := deploy.Holder{Name: "demo-web", Project: "other", Dir: "/o"}
	for _, tc := range []struct {
		env       string
		hs        []deploy.Holder
		want, not []string
		code      int
	}{
		{"", []deploy.Holder{holder}, []string{
			"  ✗ C17 on deploy@vps, container demo-web (compose project other) already holds demo-web, the container_name service demo-web of this project sets — Docker gives a name to one container per host, running or stopped; remove or rename that container, or change the container_name demo-web sets — a deploy refuses this"},
			[]string{"✓ C12,C13,C17"}, 6},
		{"", []deploy.Holder{{Name: "db", Project: "other", Dir: "/o"}, {Name: "Db"}}, []string{"  ✗ C17 on deploy@vps, container db (compose project other) already holds db, the container_name service db of this project sets"}, []string{"Db"}, 6},
		{"CN=store\n", []deploy.Holder{{Name: "db"}}, []string{"  ✓ C12,C13,C17 no container outside"}, []string{"C17 on"}, 0},
		{"CN=store\n", []deploy.Holder{{Name: "store"}}, []string{"  ✗ C17 on deploy@vps, container store (not a compose container) already holds store, the container_name service db"}, nil, 6},
		{"X='unclosed\n", []deploy.Holder{{Name: "db"}}, []string{
			"  ⚠ C17 whether a container outside /apps/demo on deploy@vps holds service db's container_name \"${CN:-db}\" cannot be checked: the server's .env has a line kasbah cannot read as compose does"},
			[]string{"✓ C12,C13,C17", "✗ C17"}, 0},
	} {
		srvProject(t, "")
		os.WriteFile(composeFile, []byte(named), 0o644)
		s := newSrv(t)
		s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54g\n" + tc.env)
		s.r.Outsiders = tc.hs
		out, code := s.run()
		contains(t, out, tc.want...)
		hasNot(t, out, tc.not...)
		if code != tc.code {
			t.Errorf("%q %v: exit %d, want %d:\n%s", tc.env, tc.hs, code, tc.code, out)
		}
	}
}

// Interpolated as compose does, nested and with ?, and a range for one
// container port taken only when all of it is; what stays unread warns.
func TestServerOutsidersPorts(t *testing.T) {
	ports := strings.Replace(goodCompose, "    networks: [kasbah]\n", "    networks: [kasbah]\n    ports: [\"${A:-${B}}:80\", \"${C:?set C}:81\", \"18000-18001:82\", {target: 83, published: \"${D:+7000}\"}, \"$$x:84\"]\n", 1)
	held := func(ps ...int) []deploy.Holder {
		var hs []deploy.Holder
		for _, p := range ps {
			hs = append(hs, deploy.Holder{Name: fmt.Sprintf("h%d", p), Ports: []deploy.Bind{{Lo: p, Hi: p, Proto: "tcp"}}})
		}
		return hs
	}
	for _, tc := range []struct {
		env       string
		hs        []deploy.Holder
		want, not []string
	}{
		{"B=9000\nC=9001\nD=1\n", held(9000, 7000, 18000), []string{
			"  ✗ C12 on deploy@vps, container h9000 (not a compose container) publishes 9000/tcp, which service demo-web",
			"  ✗ C12 on deploy@vps, container h7000 (not a compose container) publishes 7000/tcp",
			"  ⚠ C12 whether a container outside /apps/demo on deploy@vps publishes service demo-web's port \"$$x:84\" cannot be checked: \"$x\" is not a host port or range"},
			[]string{"h18000", "✓ C12,C13,C17 no container outside"}},
		{"B=9000\n", held(18000, 18001), []string{
			"  ⚠ C12 whether a container outside /apps/demo on deploy@vps publishes service demo-web's port \"${C:?set C}:81\" cannot be checked: required variable C is missing a value: set C",
			"every port of 18000-18001/tcp, the range service demo-web of this project publishes one port from, is taken: container h18000 (not a compose container) publishes 18000/tcp, container h18001 (not a compose container) publishes 18001/tcp"},
			[]string{"✓ C12,C13,C17 no container outside", "h9000"}},
		{"B='unclosed\n", nil, []string{
			"  ⚠ C12 whether a container outside /apps/demo on deploy@vps publishes service demo-web's port \"${A:-${B}}:80\" cannot be checked: the server's .env has a line kasbah cannot read as compose does: line 4 (B): the single quote is not closed",
			"service demo-web's port \"$$x:84\" cannot be checked: \"$x\" is not a host port or range"},
			[]string{"✓ C12,C13,C17 no container outside"}},
	} {
		srvProject(t, "")
		os.WriteFile(composeFile, []byte(ports), 0o644)
		s := newSrv(t)
		s.r.Env = b64s("DOMAIN=demo.example.com\nKASBAH_CPU_LIMIT=14.4\nKASBAH_MEM_LIMIT=54g\n" + tc.env)
		s.r.Outsiders = tc.hs
		out, _ := s.run()
		contains(t, out, tc.want...)
		hasNot(t, out, tc.not...)
	}
}

func TestCollectServerOutsiders(t *testing.T) {
	dir := t.TempDir()
	os.WriteFile(filepath.Join(dir, "docker"), []byte("#!/bin/sh\n[ \"$1\" = ps ] || exit 1\nprintf 'demo-web-1\\trunning\\tdemo\\t/home/u/demo\\tc\\t0.0.0.0:80->80/tcp\\n'\n"), 0o755)
	t.Setenv("PATH", dir)
	apps := t.TempDir()
	r := CollectServer(apps, apps+"/data", "demo", "")
	if len(r.Outsiders) != 1 || r.Outsiders[0].Dir != "/home/u/demo" || r.OutsidersError != "" {
		t.Errorf("outsiders: %+v %q", r.Outsiders, r.OutsidersError)
	}
	t.Setenv("PATH", t.TempDir())
	if r := CollectServer(apps, apps+"/data", "demo", ""); r.OutsidersError != "there is no docker on the server" {
		t.Errorf("no docker: %q", r.OutsidersError)
	}
}
