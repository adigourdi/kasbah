package status

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

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
)

func TestParse(t *testing.T) {
	for _, tc := range []struct {
		args       []string
		target     string
		apps, fail string
	}{
		{[]string{"deploy@vps"}, "deploy@vps", "", ""},
		{[]string{"deploy@vps", "--apps-path=/srv/apps"}, "deploy@vps", "/srv/apps", ""},
		{[]string{"--apps-path=/srv/apps/", "deploy@vps\r"}, "deploy@vps", "/srv/apps", ""},
		{nil, "", "", "USER@HOST is required"},
		{[]string{"deploy@vps", "other@vps"}, "", "", "given once"},
		{[]string{"deploy@vps", "--with-certs=x"}, "", "", "unknown flag '--with-certs'"},
		{[]string{"deploy@vps", "--apps-path="}, "", "", "must not be empty"},
		{[]string{"deploy@vps", "--apps-path=apps"}, "", "", "absolute path"},
		{[]string{"deploy@vps", "--apps-path=/"}, "", "", "filesystem root"},
		{[]string{"deploy@vps", "--apps-path=/srv/../apps"}, "", "", "normalised path"},
		{[]string{"deploy@vps", "--apps-path=/srv//apps"}, "", "", "normalised path"},
		{[]string{"deploy@vps", "--apps-path=/srv/apps/."}, "", "", "normalised path"},
	} {
		o, err := Parse(tc.args)
		switch {
		case tc.fail != "":
			if err == nil || !strings.Contains(err.Error(), tc.fail) {
				t.Errorf("%q: %v, want a refusal naming %q", tc.args, err, tc.fail)
			}
		case err != nil || o.Target != tc.target || o.Apps != tc.apps:
			t.Errorf("%q: %+v %v", tc.args, o, err)
		}
	}
	if _, err := Parse([]string{"x@y", "--help"}); err != ErrHelp {
		t.Errorf("--help: %v", err)
	}
}

func TestDisk(t *testing.T) {
	for v, want := range map[string]string{"": "?", "x": "?", "512": "512K", "1024": "1.0M", "1572864": "1.5G", "2147483648": "2.0T"} {
		if got := HumanKB(v); got != want {
			t.Errorf("HumanKB(%q) = %q, want %q", v, got, want)
		}
	}
	s, fs, ok := DiskSentence("/dev/sda1  61255492 30627746 27482990  53% /")
	if !ok || s != "29.2G of 58.4G used (53%), 26.2G free — /dev/sda1 on /" || fs != "/dev/sda1 on /" {
		t.Errorf("got %q %q %v", s, fs, ok)
	}
	if _, _, ok := DiskSentence("/dev/sda1 - - - - /"); ok {
		t.Error("a line with no numbers was read")
	}
	if s, _, _ := DiskSentence("tank 10 5 5 50% /mnt/with space"); !strings.HasSuffix(s, "tank on /mnt/with space") {
		t.Errorf("a mount point with a space: %q", s)
	}
}

func TestParseFragment(t *testing.T) {
	for in, want := range map[string]string{
		"http:\n  routers:\n    a: {rule: \"Host(`a.test`) || Host(`b.test`)\"}\n    b: {rule: \"Host(`a.test`)\"}\n": "a.test b.test",
		"http:\n  routers: {}\n": "",
		"http:\n  routers:\n    a: {rule: 'Host( \"a.test\" ) && !Host(`b.test`)'}\n": "a.test",
		"# only a comment\n":                    "",
		"http:\n  routers: [1]\n":               "",
		"http: x\n":                             "!",
		"a: [\n":                                "!",
		"http:\n  routers:\n    a: {rule: 5}\n": "",
	} {
		root, ok := ParseFragment([]byte(in))
		got := strings.Join(acme.Hosts(acme.Routes(root)), " ")
		if !ok {
			got = "!"
		}
		if got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

func TestRedact(t *testing.T) {
	for in, want := range map[string]string{
		"rest:https://u:p@h:8000/x/": "rest:https://u:***@h:8000/x/",
		"s3:https://s3.example/b/":   "s3:https://s3.example/b/",
		"rest:http://u@h/":           "rest:http://u@h/",
		"rest:http://u:p@x@h/a@b:c/": "rest:http://u:***@h/a@b:c/",
		"/local/path/":               "/local/path/",
	} {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
}

type fake struct {
	r      *Report
	apps   string
	source string
	err    error
}

func (f *fake) Read(string) (*Report, string, string, error) { return f.r, f.apps, f.source, f.err }

func b64s(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func base() *Report {
	return &Report{
		HaveDocker: true, DockerServer: "27.0.1", ComposeVersion: "2.29.0",
		AppsState: "dir", MarkerState: "ok", DataPath: "/apps/data",
		Marker:    b64s(`{"kasbah_version":"1.2.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"14.4","mem_limit":"54g"}`),
		AppsDisk:  Disk{State: "ok", Line: "/dev/sda1 61255492 30627746 27482990 53% /"},
		DataDisk:  Disk{State: "ok", Line: "/dev/sda1 61255492 30627746 27482990 53% /"},
		AcmeState: "empty", SharedState: "file",
		Shared:  b64s("http:\n  routers:\n    traefik-dashboard:\n      rule: \"Host(`traefik.rig.test`)\"\n"),
		MailDir: "absent", RegistryState: "absent",
		Backup:   backuprec.Facts{Dir: "absent", Record: "absent", Now: "2000000000", Container: backuprec.Container{State: "absent"}},
		Traefik:  Traefik{Present: true, State: "running", Health: "healthy", Image: "traefik:v3.1", ImageID: "sha256:0123456789abcdef0123", Container: "traefik"},
		Projects: []Project{},
	}
}

var now = time.Unix(2000000000, 0)

func runStatus(t *testing.T, r *Report) (string, string, int) {
	t.Helper()
	var o, e bytes.Buffer
	out := &cli.Output{Stdout: &o, Stderr: &e}
	err := Run(Ctx{Out: out, Version: "1.0.0", Now: func() time.Time { return now },
		Dial: func(string) (Session, error) { return &fake{r: r, apps: "/apps", source: "pointer"}, nil }},
		Options{Target: "deploy@vps"})
	code := out.Report(err)
	return o.String(), e.String(), code
}

func has(t *testing.T, s string, want ...string) {
	t.Helper()
	for _, w := range want {
		if !strings.Contains(s, w) {
			t.Errorf("missing %q in:\n%s", w, s)
		}
	}
}

func TestHeader(t *testing.T) {
	out, errs, code := runStatus(t, base())
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	want := `VPS: deploy@vps (connected)
Docker: 27.0.1, Compose: 2.29.0
Root: /apps (pointer)  Data: /apps/data
Marker: kasbah 1.2.0, cpu 14.4, mem 54g
Disk: /apps  29.2G of 58.4G used (53%), 26.2G free — /dev/sda1 on /
      /apps/data  the same filesystem

Traefik: running (healthy)
  Image: traefik:v3.1 (sha256:0123456789ab)
  Container: traefik
  Certificates: the store at /apps/data/traefik/letsencrypt/acme.json is empty — nothing has been issued yet
  Dashboard: traefik.rig.test

Mail: not installed — no /apps/mail (kasbah server init --with-mail scaffolds it)

Backup: not configured — the marker records none (kasbah server init --with-backup ships snapshots off-box)

Projects:
  none — no project directory under /apps
`
	if out != want {
		t.Errorf("got:\n%s\nwant:\n%s", out, want)
	}
	if errs != "" {
		t.Errorf("stderr: %s", errs)
	}
}

func TestMarkerStates(t *testing.T) {
	for _, tc := range []struct {
		set  func(r *Report)
		code int
		want string
	}{
		{func(r *Report) { r.MarkerState = "absent" }, cli.ExitNoRemoteState, "deploy@vps has no server marker at /apps/.kasbah/server.json"},
		{func(r *Report) { r.MarkerState = "empty" }, 1, "is empty — kasbah server init did not finish"},
		{func(r *Report) { r.MarkerState = "notfile" }, 1, "exists and is not a regular file"},
		{func(r *Report) { r.MarkerState = "unreadable" }, 1, "could not be read"},
		{func(r *Report) { r.Marker = b64s("[1]") }, 1, "is not a JSON object"},
		{func(r *Report) { r.AppsState = "notdir" }, 1, "exists and is not a directory"},
	} {
		r := base()
		tc.set(r)
		_, errs, code := runStatus(t, r)
		if code != tc.code || !strings.Contains(errs, tc.want) {
			t.Errorf("exit %d (%s), want %d naming %q", code, errs, tc.code, tc.want)
		}
	}
	r := base()
	r.Marker = b64s(`{"kasbah_version":"2.0.0","apps_path":"/srv/apps","data_path":"/apps/data"}`)
	out, errs, _ := runStatus(t, r)
	has(t, errs, "the marker records apps_path=/srv/apps, and this status read /apps",
		"the marker was written by kasbah 2.0.0 and this is kasbah 1.0.0", "different majors")
	has(t, out, "Marker: kasbah 2.0.0, cpu unknown, mem unknown")

}

func TestReadError(t *testing.T) {
	var o, e bytes.Buffer
	out := &cli.Output{Stdout: &o, Stderr: &e}
	err := Run(Ctx{Out: out, Dial: func(string) (Session, error) {
		return &fake{err: cli.Failf(cli.ExitNoRemoteState, "no marker")}, nil
	}}, Options{Target: "x@y"})
	var ce *cli.Error
	if !errors.As(err, &ce) || ce.Code != cli.ExitNoRemoteState || o.Len() != 0 {
		t.Errorf("got %v, stdout %q", err, o.String())
	}
}

func TestDocker(t *testing.T) {
	r := base()
	r.DockerServer, r.DockerError, r.Traefik = "", "Cannot connect to the Docker daemon", Traefik{}
	r.Projects = []Project{{Name: "demo", LogState: "missing", FragState: "absent"}}
	out, _, _ := runStatus(t, r)
	has(t, out, "Docker: unavailable — Cannot connect to the Docker daemon", "Traefik: unknown — docker did not answer",
		"  demo           ?              -          no versions.log")
	r = base()
	r.Traefik = Traefik{}
	out, _, _ = runStatus(t, r)
	has(t, out, "Traefik: absent — no container in compose project 'traefik'")
	r.Traefik = Traefik{Present: true, State: "running"}
	out, _, _ = runStatus(t, r)
	has(t, out, "Traefik: unknown — docker named a container and then did not describe it\n  state running / health <none> / image <none>")
	r.Traefik = Traefik{Present: true, State: "running", Health: "none", Image: "t"}
	out, _, _ = runStatus(t, r)
	has(t, out, "Traefik: running (no healthcheck)")
}

func TestDiskLines(t *testing.T) {
	r := base()
	r.DataDisk = Disk{State: "ok", Line: "/dev/sdb1 100 50 50 50% /data"}
	r.AppsDisk = Disk{State: "error"}
	out, _, _ := runStatus(t, r)
	has(t, out, "Disk: /apps  unknown — df did not answer\n      /apps/data  50K of 100K used (50%), 50K free — /dev/sdb1 on /data")
	r.AppsDisk, r.DataDisk = Disk{State: "absent"}, Disk{State: "ok", Line: "x y z"}
	out, _, _ = runStatus(t, r)
	has(t, out, "Disk: /apps  unknown — the path is not there\n      /apps/data  unknown — df answered in a shape this kasbah does not read")
	r.DataPath = "/elsewhere"
	out, _, _ = runStatus(t, r)
	has(t, out, "      /apps/data  not read — the probe and the marker disagree", "  Certificates: not read")
}

func pemCert(t *testing.T, cn string, notAfter time.Time) string {
	k, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	tpl := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: cn},
		NotBefore: notAfter.Add(-time.Hour * 2400), NotAfter: notAfter}
	der, err := x509.CreateCertificate(rand.Reader, tpl, tpl, &k.PublicKey, k)
	if err != nil {
		t.Fatal(err)
	}
	return b64s(string(pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})))
}

func TestCertsAndMail(t *testing.T) {
	r := base()
	r.AcmeState = "file"
	r.Acme = b64s(`{"http":{"Account":{"PrivateKey":"SECRET-KEY"},"Certificates":[` +
		`{"domain":{"main":"mail.rig.test","sans":["webmail.rig.test"]},"certificate":"` + pemCert(t, "mail.rig.test", now.Add(50*24*time.Hour+time.Hour)) + `","key":"SECRET-KEY"},` +
		`{"domain":{"main":"traefik.rig.test"},"certificate":"` + pemCert(t, "traefik.rig.test", now.Add(-2*24*time.Hour-time.Hour)) + `"},` +
		`{"domain":{"main":"demo.test"},"certificate":"` + pemCert(t, "demo.test", now.Add(10*24*time.Hour+time.Hour)) + `"},` +
		`{"domain":{"main":"bad.test"},"certificate":"%%%"}]}}`)
	r.MailDir, r.RegistryState = "dir", "file"
	r.Registry = b64s("primary_domain: rig.test\ndomains: [rig.test, shop.test]\n")
	r.MailDMS = Stack{State: "running", Health: "healthy", Restarts: "3"}
	r.MailWeb = Stack{State: "absent"}
	r.Projects = []Project{{Name: "demo", LogState: "ok", Log: "2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0", FragState: "ok", Total: 1, Running: 1,
		Frag:       b64s("http:\n  routers:\n    a: {rule: \"Host(`demo.test`) || Host(`bad.test`) || Host(`none.test`)\"}\n    b: {rule: \"Host(`plain.test`) || Host(`demo.test`)\", entryPoints: [web]}\n"),
		Containers: []Container{{"demo-web", "running", "healthy"}}},
		{Name: "site", LogState: "ok", Log: "2026-08-13T22:30:37+00:00 deploy 1.0.0 no-backup kasbah=0.1.0", FragState: "ok", Total: 1, Running: 1,
			Frag:       b64s("http:\n  routers:\n    a: {rule: \"Host(`site.test`)\", entryPoints: [web]}\n"),
			Containers: []Container{{"site-web", "running", "healthy"}}}}
	out, _, _ := runStatus(t, r)
	has(t, out,
		"  Certificates: 4 in /apps/data/traefik/letsencrypt/acme.json\n  Dashboard: traefik.rig.test\n      certificate EXPIRED 2 day(s) ago (",
		"Mail: /apps/mail\n  mail-dms         running (healthy), 3 restart(s)\n  mail-cypht       absent — the stack is scaffolded and not running\n  Primary: rig.test   Domains: rig.test shop.test\n  mail.rig.test\n      certificate valid for 50 more day(s) (until ",
		"  webmail.rig.test\n      certificate (as a SAN of mail.rig.test) valid for 50 more day(s)",
		"  demo           1/1 running    1.0.0      deploy 2026-08-13T22:30:37+00:00 (kasbah 0.1.0)\n      demo.test\n          certificate expires in 10 day(s) (",
		"Traefik renews at 30, so renewal has missed its window",
		"      bad.test\n          the store entry is not base64\n      none.test\n          no certificate — Traefik issues one when the hostname resolves here\n      plain.test\n          no certificate — Traefik issues one when the hostname resolves here\n      1 container(s), all running and none unhealthy",
		"      site.test\n          plain HTTP — its fragment has no HTTPS router, so no certificate is expected\n      1 container(s), all running and none unhealthy")
	if strings.Contains(out, "SECRET-KEY") {
		t.Error("the store's key material was printed")
	}
	// A host is looked up under the resolver its router names.
	dns := r
	dns.Acme = b64s(`{"http":{"Certificates":[]},"cloudflare":{"Certificates":[{"domain":{"main":"demo.test"},"certificate":"` + pemCert(t, "demo.test", now.Add(80*24*time.Hour+time.Hour)) + `"}]}}`)
	dns.Projects = []Project{{Name: "demo", LogState: "ok", Log: r.Projects[0].Log, FragState: "ok", Total: 1, Running: 1,
		Frag: b64s("http:\n  routers:\n    a: {rule: \"Host(`demo.test`)\", tls: {certResolver: cloudflare}}\n    b: {rule: \"Host(`other.test`)\", tls: {certResolver: ovh}}\n")}}
	out, _, _ = runStatus(t, dns)
	has(t, out, "  Certificates: 1 in /apps/data/traefik/letsencrypt/acme.json",
		"      demo.test\n          certificate valid for 80 more day(s)",
		"      other.test\n          no certificate — nothing in the store under its resolver 'ovh' yet")
	if strings.Contains(out, "former name") {
		t.Error("a store with an http entry got the rename hint")
	}
	// A store filled under the former name says so.
	dns.Acme = b64s(`{"letsencrypt":{"Certificates":[{"domain":{"main":"demo.test"},"certificate":"` + pemCert(t, "demo.test", now.Add(80*24*time.Hour)) + `"}]}}`)
	dns.Projects[0].Frag = b64s("http:\n  routers:\n    a: {rule: \"Host(`demo.test`)\", tls: {certResolver: http}}\n")
	out, _, _ = runStatus(t, dns)
	has(t, out, "  Certificates: 1 in /apps/data/traefik/letsencrypt/acme.json\n    filled under the resolver's former name 'letsencrypt', with nothing under 'http' yet",
		"      demo.test\n          no certificate — nothing under 'http' yet; the store's 'letsencrypt' entry is the resolver's former name")
	for reg, want := range map[string]string{
		"domains: [x.test]\n": "  registry /apps/mail/kasbah.yml has no primary_domain:",
		"a: [\n":              "  registry /apps/mail/kasbah.yml could not be read as YAML",
	} {
		r.Registry = b64s(reg)
		out, _, _ = runStatus(t, r)
		has(t, out, want)
	}
	r.RegistryState = "unreadable"
	out, _, _ = runStatus(t, r)
	has(t, out, "  registry /apps/mail/kasbah.yml: unreadable — the one record of which domains this stack serves")
	for st, want := range map[string]string{
		"absent":     "  Certificates: no store at /apps/data/traefik/letsencrypt/acme.json",
		"unreadable": "cannot be read by deploy@vps — it is mode 600",
		"dir":        "is dir, not a regular file",
	} {
		r.AcmeState = st
		out, _, _ = runStatus(t, r)
		has(t, out, want)
	}
	r.AcmeState = "file"
	for body, want := range map[string]string{
		"{x":                            "does not parse as JSON (its bytes are not shown",
		`{"a":1}`:                       "holds no resolver's store",
		`{"http":{"Certificates":"x"}}`: "whose Certificates is a string, not a list",
		`{"http":{}}`:                   "none issued yet",
	} {
		r.Acme = b64s(body)
		out, _, _ = runStatus(t, r)
		has(t, out, want)
	}
}

func TestProjects(t *testing.T) {
	r := base()
	r.Marker = b64s(`{"apps_path":"/apps","data_path":"/apps/store"}`)
	r.DataPath = "/apps/store"
	r.Projects = []Project{
		{Name: "a-very-long-project-name", LogState: "empty", FragState: "absent"},
		{Name: "store", LogState: "missing", FragState: "absent"},
		{Name: "odd", LogState: "ok", Log: "just a note", FragState: "empty", Total: 2, Running: 1,
			Containers: []Container{{"odd-web", "running", "unhealthy"}, {"odd-db", "exited", "none"}}},
		{Name: "file", LogState: "notdir", FragState: "notfile"},
		{Name: "locked", LogState: "noaccess", FragState: "unreadable", Total: 1},
		{Name: "stopped", LogState: "unreadable", FragState: "absent", Total: 2},
		{Name: "weird", LogState: "notfile", FragState: "ok", Frag: b64s("a: [\n")},
		{Name: "nohost", LogState: "missing", FragState: "ok", Frag: b64s("http: {}\n")},
	}
	out, _, _ := runStatus(t, r)
	has(t, out,
		"  a-very-long-project-name no containers  -          versions.log is empty\n",
		"  odd                      1/2 partial    ?          versions.log's last line is not a kasbah entry: just a note\n      /apps/traefik/dynamic/odd.yml is empty — nothing routes to this project\n      odd-web                  running (unhealthy)\n      odd-db                   exited (none)\n",
		"  file                     -              -          not a directory — kasbah deploys into directories only\n      /apps/traefik/dynamic/file.yml exists and is not a regular file\n",
		"  locked                   0/1 stopped    -          the directory cannot be read by the ssh user",
		"      /apps/traefik/dynamic/locked.yml cannot be read by the ssh user",
		"  stopped                  0/2 stopped    -          versions.log cannot be read by the ssh user\n      no Traefik fragment at /apps/traefik/dynamic/stopped.yml — nothing routes to this project\n",
		"  weird                    no containers  -          versions.log exists and is not a regular file\n      /apps/traefik/dynamic/weird.yml does not parse as YAML",
		"      /apps/traefik/dynamic/nohost.yml declares no Host() rule, so this project claims no domain")
	if strings.Contains(out, "  store ") {
		t.Errorf("the data directory under <apps> was listed as a project:\n%s", out)
	}
}

func TestBackupLines(t *testing.T) {
	enabled := b64s(`{"apps_path":"/apps","data_path":"/apps/data","backup":{"enabled":true,"repo_base":"rest:https://u:pw@h/r/","at":"04:17","jitter":42}}`)
	rec := func(lines ...string) string { return b64s(strings.Join(lines, "\n") + "\n") }
	for _, tc := range []struct {
		name  string
		facts backuprec.Facts
		want  []string
	}{
		{"fresh", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=sleeping", "deadline=2000086400", "next_run=2000003600", "last_run_status=-"),
			Container: backuprec.Container{State: "running", Health: "healthy"}, HasPass: []string{"demo"}, Projects: []backuprec.Project{{Name: "demo"}}},
			[]string{"Backup: rest:https://u:***@h/r/  daily at 04:17 plus 42s jitter\n  kasbah-backup    running (healthy)\n  last run         none yet — the scheduler is sleeping\n  next run         in 1h\n  repositories     demo\n"}},
		{"running for a while", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=running", "since=1999999000", "deadline=2000086400"),
			Container: backuprec.Container{State: "running", Restarts: "2"}},
			[]string{"  kasbah-backup    running (none), 2 restart(s)\n  last run         none yet — the scheduler is running, and a run has been going for 16m\n  repositories     none — nothing under /apps to back up yet"}},
		{"failed and overdue", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=sleeping", "deadline=1999990000", "last_run_finished=1999980000", "last_run_status=failed", "last_run_repos= demo"),
			Container: backuprec.Container{State: "running"}, HasPass: []string{"demo", "old"}, Projects: []backuprec.Project{{Name: "demo"}, {Name: "new"}}},
			[]string{"  last run         FAILED 5h ago — repositories backed up: demo (docker logs kasbah-backup says why)\n  scheduler        2h past its own deadline in state 'sleeping' — nothing has run since\n",
				"  no password      new — not backed up until kasbah server init deploy@vps --with-backup supplies one\n",
				"  orphan password  old — a password for a repository no project files into any more"}},
		{"overdue, stopped", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=sleeping", "since=1999000000", "deadline=1999990000"),
			Container: backuprec.Container{State: "exited"}},
			[]string{"  scheduler        2h past its own deadline in state 'sleeping' (for 11 day(s)) — the container is exited, so nothing has moved it on\n  last run         none yet\n"}},
		{"overdue, running", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=running", "deadline=1999990000", "last_run_finished=1999980000", "last_run_status=ok"),
			Container: backuprec.Container{State: "running"}},
			[]string{"a run that never returned, or a sleep that never woke\n  last run         ok 5h ago — repositories: -\n"}},
		{"ok, shipped nothing", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=sleeping", "deadline=2000086400", "last_run_finished=1999999990", "last_run_status=ok", "last_run_repos=none"),
			Container: backuprec.Container{State: "running"}},
			[]string{"  last run         ok 10s ago, and shipped nothing — no repository had anything to back up\n"}},
		{"no stack", backuprec.Facts{Dir: "absent", Record: "absent", Container: backuprec.Container{State: "absent"}},
			[]string{"  kasbah-backup    absent — the stack is scaffolded and no container is running it\n  last run         none — /apps/.kasbah/backup is not there, so nothing here says whether a backup has ever run\n"}},
		{"no record", backuprec.Facts{Dir: "dir", Record: "absent", Container: backuprec.Container{State: "nodaemon"}},
			[]string{"  kasbah-backup    unknown — the docker daemon did not answer\n  last run         none — /apps/.kasbah/backup/state/status is not there, and the scheduler writes it as its first act\n"}},
		{"unreadable", backuprec.Facts{Dir: "dir", Record: "unreadable", Container: backuprec.Container{State: "nodocker"}},
			[]string{"  kasbah-backup    unknown — there is no docker on this server\n  last run         unknown — /apps/.kasbah/backup/state/status cannot be read by the ssh user\n"}},
		{"unparsed", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("deadline=1"), Container: backuprec.Container{State: "notours"}},
			[]string{"  kasbah-backup    a container of that name is running here and is not in the kasbah-backup\n                   compose project — kasbah's scheduler cannot take a name something else\n                   already holds, so nothing is being shipped off-box\n",
				"  last run         unknown — /apps/.kasbah/backup/state/status is not a record this kasbah reads (it carries no scheduler state)\n"}},
		{"another clock", backuprec.Facts{Dir: "dir", Record: "file", RecordB64: rec("state=sleeping", "deadline=99999999999"), Now: "x", Container: backuprec.Container{State: "running"}},
			[]string{"plus 42s jitter (judged against this machine's clock: the probe did not report the server's)\n"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := base()
			r.Marker = enabled
			if tc.facts.Now == "" {
				tc.facts.Now = "2000000000"
			}
			r.Backup = tc.facts
			out, _, _ := runStatus(t, r)
			has(t, out, tc.want...)
			if strings.Contains(out, "pw@") {
				t.Error("the repository password was printed")
			}
		})
	}
	r := base()
	r.Backup.Dir = "dir"
	out, _, _ := runStatus(t, r)
	has(t, out, "Backup: not configured — the marker records none (kasbah server init --with-backup ships snapshots off-box)\n  stack            /apps/.kasbah/backup is dir, and no marker entry describes it\n")
	r.Marker = b64s(`{"backup":{"enabled":true}}`)
	out, _, _ = runStatus(t, r)
	has(t, out, "Backup: enabled, and the marker records no repository base")
}

// Collect, run here against a scratch tree, with no docker to ask.
func TestCollect(t *testing.T) {
	apps := t.TempDir()
	w := func(p, s string) {
		os.MkdirAll(filepath.Dir(filepath.Join(apps, p)), 0o755)
		os.WriteFile(filepath.Join(apps, p), []byte(s), 0o644)
	}
	w(".kasbah/server.json", `{"apps_path":"`+apps+`","data_path":"`+apps+`/data"}`)
	w("data/traefik/letsencrypt/acme.json", "")
	w("traefik/dynamic/_shared.yml", "http: {}\n")
	w("traefik/dynamic/demo.yml", "x: 1\n")
	w("traefik/dynamic/empty.yml", "")
	w("demo/versions.log", "2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup\n\n  \r\n")
	w("blank/versions.log", " \n")
	w("empty/.keep", "")
	w("afile", "x")
	w(".dot/versions.log", "a b c d\n")
	os.MkdirAll(filepath.Join(apps, "mail"), 0o755)
	os.MkdirAll(filepath.Join(apps, "logdir/versions.log"), 0o755)
	t.Setenv("PATH", t.TempDir())
	r := Collect(apps)
	if r.HaveDocker || r.MarkerState != "ok" || r.DataPath != apps+"/data" || r.AcmeState != "empty" ||
		r.SharedState != "file" || r.MailDir != "dir" || r.RegistryState != "absent" || r.MailDMS.State != "nodocker" ||
		r.Traefik.Present {
		t.Errorf("report: %+v", r)
	}
	got := map[string]string{}
	var names []string
	for _, p := range r.Projects {
		names = append(names, p.Name)
		got[p.Name] = p.LogState + "/" + p.FragState + "/" + p.Log
	}
	if strings.Join(names, " ") != ".dot afile blank demo empty logdir" {
		t.Errorf("projects %v", names)
	}
	for n, want := range map[string]string{
		"demo":   "ok/ok/2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup",
		"blank":  "empty/absent/",
		"empty":  "missing/empty/",
		"afile":  "notdir/absent/",
		"logdir": "notfile/absent/",
		".dot":   "ok/absent/a b c d",
	} {
		if got[n] != want {
			t.Errorf("%s: %q, want %q", n, got[n], want)
		}
	}
}

func fakeSSH(t *testing.T, self remote.Info, markerJSON string, report any) (log string) {
	t.Helper()
	dir := t.TempDir()
	probe := "apps=/apps\nsource=default\napps_dir=yes\nmarker=yes\nmarker_hex=" + hex.EncodeToString([]byte(markerJSON)) +
		"\nmachine=x86_64\nbin=present\nbin_regular=yes\nbin_exec=yes\nbin_head=7f454c4602010100000000000000000002003e00\nversion_rc=0\nversion=" +
		self.Line() + "\n"
	body, _ := json.Marshal(report)
	os.WriteFile(filepath.Join(dir, "probe.out"), []byte(probe), 0o644)
	os.WriteFile(filepath.Join(dir, "report.json"), body, 0o644)
	os.WriteFile(filepath.Join(dir, "ssh"), []byte(`#!/bin/sh
d=$(dirname "$0")
for last; do :; done
case "$*" in *" -O "*) exit 0 ;; esac
[ "$last" = true ] && exit 0
printf '%s\n' "$last" >> "$d/calls.log"
case "$last" in
    "'sh' '-s' "*) cat >/dev/null; cat "$d/probe.out" ;;
    *"'remote' 'status' "*) cat "$d/report.json" ;;
    *) exit 99 ;;
esac
`), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("TMPDIR", t.TempDir())
	return filepath.Join(dir, "calls.log")
}

func TestRoundTrips(t *testing.T) {
	self := remote.Self("0.1.0-dev.1.1")
	r := base()
	log := fakeSSH(t, self, `{"apps_path":"/apps"}`, r)
	var o, e bytes.Buffer
	out := &cli.Output{Stdout: &o, Stderr: &e}
	code := out.Report(Run(Ctx{Out: out, Version: "1.0.0", Dial: Dial(self, func(string) (string, error) { return "", errors.New("no ship") })},
		Options{Target: "deploy@vps"}))
	calls, _ := os.ReadFile(log)
	lines := strings.Split(strings.TrimSpace(string(calls)), "\n")
	if code != 0 || len(lines) != 2 || !strings.Contains(lines[1], "'120' '/apps/.kasbah/bin/kasbah' 'remote' 'status' '/apps'") ||
		!strings.Contains(o.String(), "Root: /apps (default)") {
		t.Errorf("exit %d, calls:\n%s%s%s", code, calls, o.String(), e.String())
	}
}

func TestBrokenMarkerShipsNothing(t *testing.T) {
	for mk, want := range map[string]string{"": "is empty", "[1]": "is not a JSON object"} {
		log := fakeSSH(t, remote.Self("0.0.1"), mk, base())
		var o, e bytes.Buffer
		out := &cli.Output{Stdout: &o, Stderr: &e}
		shipped := false
		code := out.Report(Run(Ctx{Out: out, Version: "1.0.0", Dial: Dial(remote.Self("0.1.0-dev.1.1"), func(string) (string, error) {
			shipped = true
			return "", errors.New("shipping")
		})}, Options{Target: "deploy@vps"}))
		calls, _ := os.ReadFile(log)
		if code != 1 || shipped || strings.Count(string(calls), "\n") != 1 || !strings.Contains(e.String(), want) {
			t.Errorf("marker %q: exit %d, shipped %v\n%s%s", mk, code, shipped, calls, e.String())
		}
	}
}

func TestDecodeShowsNothing(t *testing.T) {
	r := base()
	r.Acme = b64s(`{"http":{"Account":{"PrivateKey":"SECRET-KEY"}}}`)
	full, _ := json.Marshal(r)
	for _, out := range [][]byte{full[:len(full)-30], []byte("PrivateKey: SECRET-KEY")} {
		_, err := Decode(out, "deploy@vps")
		if err == nil || strings.Contains(err.Error(), "SECRET") || strings.Contains(err.Error(), r.Acme[:16]) || !strings.Contains(err.Error(), "not shown") {
			t.Errorf("got %v", err)
		}
	}
	if _, err := Decode([]byte("\n"), "deploy@vps"); err == nil || !strings.Contains(err.Error(), "reported nothing") {
		t.Errorf("empty: %v", err)
	}
}

// versions.log this user cannot read, and a directory it cannot enter.
func TestCollectAccess(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads every mode")
	}
	apps := t.TempDir()
	os.MkdirAll(filepath.Join(apps, "locked"), 0o755)
	os.MkdirAll(filepath.Join(apps, "secret"), 0o755)
	os.WriteFile(filepath.Join(apps, "secret", "versions.log"), []byte("x\n"), 0o000)
	os.Chmod(filepath.Join(apps, "locked"), 0o000)
	t.Cleanup(func() { os.Chmod(filepath.Join(apps, "locked"), 0o755) })
	t.Setenv("PATH", t.TempDir())
	got := map[string]string{}
	for _, p := range Collect(apps).Projects {
		got[p.Name] = p.LogState
	}
	if got["locked"] != "noaccess" || got["secret"] != "unreadable" {
		t.Errorf("got %v", got)
	}
}

func TestDashboardOff(t *testing.T) {
	r := base()
	r.Shared = b64s("http:\n  middlewares:\n    gzip-compression: {compress: {}}\n")
	out, errs, code := runStatus(t, r)
	if code != 0 {
		t.Fatalf("exit %d: %s", code, errs)
	}
	has(t, out, "  Dashboard: off (no dashboard router in dynamic/_shared.yml)\n")
	// Nothing read is not "off".
	for _, shared := range []string{"", b64s("http: [1\n")} {
		r.Shared = shared
		if out, _, _ := runStatus(t, r); strings.Contains(out, "Dashboard:") {
			t.Errorf("an unread _shared.yml reports a dashboard state:\n%s", out)
		}
	}
}
