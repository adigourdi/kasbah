package upgrade

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
	"github.com/adigourdi/kasbah/templates"
)

func TestParse(t *testing.T) {
	o, err := Parse([]string{"deploy@vps", "--version=v3.7.11\r"})
	if err != nil || o.Target != "deploy@vps" || o.Version != "v3.7.11" {
		t.Fatalf("%+v %v", o, err)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"deploy@vps"}, "--version=<tag> is required"},
		{[]string{"--version=v3"}, "USER@HOST is required"},
		{[]string{"a@b", "c@d", "--version=v3"}, "unexpected argument 'c@d'"},
		{[]string{"a@b", "--version"}, "needs a value"},
		{[]string{"a@b", "--version="}, "must not be empty"},
		{[]string{"a@b", "--version=reg/traefik"}, "looks like an image reference"},
		{[]string{"a@b", "--version=traefik:v3"}, "looks like an image reference"},
		{[]string{"a@b", "--version=.v3"}, "is not a Docker tag"},
		{[]string{"a@b", "--version=v3\nx"}, "is not a Docker tag"},
		{[]string{"a@b", "--version=" + strings.Repeat("a", 129)}, "is not a Docker tag"},
		{[]string{"a@b", "--version=v3", "--apps-path=/x"}, "unknown flag '--apps-path'"},
	} {
		if _, err := Parse(c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%q: %v", c.args, err)
		}
	}
	if err := CheckVersion(strings.Repeat("a", 128)); err != nil {
		t.Errorf("128 characters is a tag: %v", err)
	}
}

func acmeLine(router, host string) string {
	return fmt.Sprintf("\033[90m2026-08-25T19:44:21Z\033[0m \033[31mERR\033[0m \033[1m%s\033[0m error=\"cannot get ACME client get directory at %s: connection refused\" acmeCA=%s domains=[\"%s\"] providerName=http.acme routerName=%s rule=Host(`%s`)\n",
		DryACMEError, DryCA, DryCA, host, router, host)
}

func cleanLog() string {
	return "2026-08-25T19:44:21Z WRN Traefik can reject some encoded characters in the request path.\n" +
		"2026-08-25T19:44:21Z INF Traefik version 3.7.10 built on 2026-07-31T12:42:19Z\n" +
		"2026-08-25T19:44:21Z INF Starting provider *file.Provider\n" +
		acmeLine("traefik-dashboard@file", "traefik.example.com") +
		acmeLine("gallery@file", "gallery.example.com") +
		acmeLine("mail-cert@file", "mail.example.com") +
		acmeLine("gallery@file", "gallery.example.com")
}

// Every shape traefik:v3.7.10 produced on the rig for a broken fragment.
var broken = map[string]string{
	"unparseable-yaml":   "2026-08-25T19:44:15Z ERR Cannot start the provider *file.Provider error=\"collecting file configs: /etc/traefik/dynamic/p.yml: yaml: line 2: did not find expected ',' or ']'\"",
	"unknown-field":      "2026-08-25T19:44:27Z ERR Cannot start the provider *file.Provider error=\"collecting file configs: /etc/traefik/dynamic/p.yml: field not found, node: nosuchfield\"",
	"missing-middleware": "2026-08-25T19:44:21Z ERR error=\"middleware \\\"nope@file\\\" does not exist\" entryPointName=websecure routerName=a@file",
	"unparseable-rule":   "2026-08-25T19:44:34Z ERR error=\"invalid rule Hostx(`a.test`, error: missing ',' before newline\" entryPointName=websecure routerName=a@file",
	"unknown-resolver":   "2026-08-25T19:44:40Z ERR Router uses a nonexistent certificate resolver certificateResolver=nosuch routerName=a@file",
	"unknown-entrypoint": "2026-08-25T19:44:46Z ERR EntryPoint doesn't exist entryPointName=nosuchep routerName=a@file",
}

func TestClassify(t *testing.T) {
	text := reColour.ReplaceAllString(cleanLog(), "")
	errs, warns, routers := Classify(text, DryACMEError, DryCA)
	if len(errs) != 0 || len(warns) != 1 || strings.Join(routers, " ") != "traefik-dashboard@file gallery@file mail-cert@file" {
		t.Fatalf("clean: errs=%q warns=%q routers=%q", errs, warns, routers)
	}
	for name, line := range broken {
		errs, _, _ := Classify(text+line+"\n", DryACMEError, DryCA)
		if len(errs) != 1 || errs[0] != line {
			t.Errorf("%s: %q", name, errs)
		}
	}
	// The exemption is the message AND this run's CA on one line.
	other := "2026-08-25T19:44:21Z ERR " + DryACMEError + " error=\"urn:acme:rateLimited\" acmeCA=https://acme-v02.api.letsencrypt.org/directory routerName=x@file"
	errs, _, routers = Classify(text+other+"\n", DryACMEError, DryCA)
	if len(errs) != 1 || strings.Contains(strings.Join(routers, " "), "x@file") {
		t.Errorf("another CA's error: errs=%q routers=%q", errs, routers)
	}
}

func TestDryStatic(t *testing.T) {
	out, err := DryStatic("entryPoints:\n  web:\n    address: \":80\"\n  websecure:\n    address: \":443\"\ncertificatesResolvers:\n  http:\n    acme:\n      email: a@b.c\n      storage: /letsencrypt/acme.json\n      caServer: https://acme-v02.api.letsencrypt.org/directory\nping: {}\n")
	if err != nil {
		t.Fatal(err)
	}
	docs, err := yamlx.Load([]byte(out))
	if err != nil || len(docs) != 1 {
		t.Fatalf("not YAML: %v\n%s", err, out)
	}
	for _, want := range []string{`":8080"`, `":8443"`, `"` + DryCA + `"`, `"/tmp/kasbah-dry-run-acme.json"`, `"level": "INFO"`, `"email": "a@b.c"`, `"ping": {}`} {
		if !strings.Contains(out, want) {
			t.Errorf("no %s in\n%s", want, out)
		}
	}
	if strings.Contains(out, "acme-v02") || strings.Contains(out, "/letsencrypt/acme.json") {
		t.Errorf("the real CA or store survived:\n%s", out)
	}
	if _, err := DryStatic("entryPoints: [1]\n"); err == nil {
		t.Error("a static config kasbah did not render is refused")
	}
}

func TestDryRunRemote(t *testing.T) {
	var calls []string
	var log string
	running := "true"
	oDocker, oLogs, oSleep := dockerCmd, dockerLogs, sleep
	defer func() { dockerCmd, dockerLogs, sleep = oDocker, oLogs, oSleep }()
	sleep = func(time.Duration) {}
	dockerLogs = func(string) string { return log }
	dockerCmd = func(dir string, args ...string) (string, error) {
		calls = append(calls, strings.Join(args, " "))
		switch args[0] {
		case "ps":
			return "old-a\nold-b", nil
		case "inspect":
			if strings.Contains(args[2], "Running") {
				return running, nil
			}
			return "1", nil
		}
		return "", nil
	}
	p := DryPayload{Shared: "http: {}\n", Static: "{}\n"}
	log = cleanLog()
	d, err := dryRun("/apps", "traefik:v3.7.10", DryLabel, "20260825T000000Z", DryACMEError, DryCA, time.Second, p)
	if err != nil || d.Verdict != "spoke" || d.Errors != "" || d.Swept != 2 || d.Routers != "traefik-dashboard@file gallery@file mail-cert@file " || d.Warns == "" {
		t.Fatalf("%+v %v", d, err)
	}
	var run string
	for _, c := range calls {
		if strings.HasPrefix(c, "run ") {
			run = c
		}
	}
	for _, want := range []string{"--network none", "/apps/traefik/dynamic:/etc/traefik/dynamic:ro", "--label " + DryLabel, "--name kasbah-traefik-dry-run-20260825T000000Z", "--restart no"} {
		if !strings.Contains(run, want) {
			t.Errorf("no %q in %q", want, run)
		}
	}
	if strings.Contains(run, " -p ") || strings.Contains(run, "acme.json") {
		t.Errorf("a port or the store in %q", run)
	}
	if calls[len(calls)-1] != "rm -f kasbah-traefik-dry-run-20260825T000000Z" {
		t.Errorf("the throwaway is removed last: %q", calls)
	}
	pulled := false
	for _, c := range calls {
		pulled = pulled || c == "pull traefik:v3.7.10"
	}
	if !pulled {
		t.Error("the target is pulled during the dry run")
	}

	log = "2026-08-25T19:44:21Z INF Starting provider *file.Provider\n"
	d, _ = dryRun("/apps", "traefik:v3.7.10", DryLabel, "s", DryACMEError, DryCA, 0, p)
	if d.Verdict != "timeout" || d.Routers != "" {
		t.Errorf("a throwaway that never speaks: %+v", d)
	}
	running = "false"
	d, _ = dryRun("/apps", "traefik:v3.7.10", DryLabel, "s", DryACMEError, DryCA, time.Second, p)
	if d.Verdict != "exited" || d.ExitCode != "1" {
		t.Errorf("a throwaway that died: %+v", d)
	}
	log = strings.Repeat("x", 9000)
	d, _ = dryRun("/apps", "traefik:v3.7.10", DryLabel, "s", DryACMEError, DryCA, 0, p)
	if len(d.Log) != 8000 {
		t.Errorf("the log is clipped to its tail: %d", len(d.Log))
	}
}

func TestBackupAndStartRemote(t *testing.T) {
	apps := t.TempDir()
	os.MkdirAll(apps+"/traefik/dynamic", 0o755)
	for _, f := range []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml"} {
		os.WriteFile(apps+"/traefik/"+f, []byte("old "+f), 0o640)
	}
	dest, err := backup(apps, "S", "traefik:a", "traefik:b")
	if err != nil || dest != apps+"/traefik/backups/S" {
		t.Fatal(dest, err)
	}
	for _, f := range []string{"compose.yml", "traefik.yml", "_shared.yml"} {
		fi, err := os.Stat(dest + "/" + f)
		if err != nil || fi.Mode().Perm() != 0o640 {
			t.Errorf("%s: %v", f, err)
		}
	}
	if b, _ := os.ReadFile(dest + "/kasbah-upgrade"); string(b) != "traefik:a -> traefik:b\n" {
		t.Errorf("kasbah-upgrade: %q", b)
	}
	if _, err := backup(apps, "S", "a", "b"); err == nil {
		t.Error("an existing backup is never written over")
	}
}

type fake struct {
	stack     Stack
	dry       Dry
	overlay   string
	dryStatic string
	up        Up
	upRC      int
	calls     []string
	written   map[string]string
}

func (f *fake) Marker() (*marker.Marker, error) {
	return &marker.Marker{AppsPath: "/apps", DataPath: "/apps/data"}, nil
}
func (f *fake) Close() {}
func (f *fake) Lock(apps string) (func(), error) {
	return func() {}, nil
}
func (f *fake) Call(stdin []byte, bounded bool, args ...string) ([]byte, int) {
	f.calls = append(f.calls, args[0]+" "+args[1])
	j := func(v any) []byte { b, _ := json.Marshal(v); return b }
	switch args[0] + " " + args[1] {
	case "traefik read":
		return j(f.stack), 0
	case "traefik dry-run":
		var p DryPayload
		if json.Unmarshal(stdin, &p) != nil || !strings.Contains(p.Static, DryCA) {
			return nil, 1
		}
		f.overlay, f.dryStatic = p.Shared, p.Static
		return j(f.dry), 0
	case "traefik backup":
		return j(map[string]string{"backup_dir": "/apps/traefik/backups/S"}), 0
	case "init write":
		f.written[args[2]] = string(stdin)
		return []byte("written=yes\n"), 0
	case "traefik start":
		return j(f.up), f.upRC
	}
	return nil, 1
}

func enc(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }

func newFake(t *testing.T, image string) *fake {
	tpl := templates.FS
	o := serverinit.Options{Apps: "/apps", Data: "/apps/data", Target: "deploy@vps"}
	v := serverinit.Values{Image: image, Domain: "example.com", Email: "ops@example.com",
		AuthEntry: "admin:$2y$05$abcdefghijklmnopqrstuuOKS6tiVYGv2Cm5Q4PJBTzH9xvOGHT6e", Dashboard: true}
	v.Acme.CA = serverinit.CAStaging
	cur, err := serverinit.Render(tpl, o, v)
	if err != nil {
		t.Fatal(err)
	}
	return &fake{
		stack: Stack{Compose: enc(cur["compose.yml"]), Static: enc(cur["traefik.yml"]), Shared: enc(cur["dynamic/_shared.yml"]),
			Fragments: []string{"_mail.yml", "_shared.yml", "gallery.yml"}, AcmeState: "nonempty", AcmeDigest: "d1", Docker: true,
			State: "running", Health: "healthy", RunningImage: image},
		dry:     Dry{Verdict: "spoke", Routers: "kasbah-dry-run-anchor@file traefik-dashboard@file gallery@file "},
		up:      Up{RolledBack: "no", Health: "healthy", State: "running", Image: "traefik:v3.7.11", AcmeDigest: "d1"},
		written: map[string]string{},
	}
}

func runUp(t *testing.T, f *fake, version string) (string, int) {
	t.Helper()
	tpl := templates.FS
	var se bytes.Buffer
	out := &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &se}
	err := Run(Ctx{Out: out, Templates: tpl, Dial: func(string) (Session, error) { return f, nil },
		Now: func() time.Time { return time.Date(2026, 8, 25, 1, 2, 3, 0, time.UTC) }},
		Options{Target: "deploy@vps", Version: version})
	code := out.Report(err)
	return se.String(), code
}

func TestRun(t *testing.T) {
	f := newFake(t, "traefik:v3.7.10")
	se, code := runUp(t, f, "v3.7.11")
	if code != 0 {
		t.Fatalf("%d\n%s", code, se)
	}
	if want := "traefik read|traefik dry-run|traefik backup|init write|traefik start"; strings.Join(f.calls, "|") != want {
		t.Errorf("order: %q", f.calls)
	}
	if len(f.written) != 1 || !strings.Contains(f.written["/apps/traefik/compose.yml"], "image: traefik:v3.7.11") {
		t.Errorf("only compose.yml differs: %v", f.written)
	}
	for _, want := range []string{"Upgrading Traefik on deploy@vps: traefik:v3.7.10 -> traefik:v3.7.11", "dry run passed: traefik:v3.7.11 built traefik-dashboard@file gallery@file out of 3 fragment(s)",
		"backed up compose.yml, traefik.yml and dynamic/_shared.yml to /apps/traefik/backups/S", "shipped compose.yml, previous bytes", "acme.json: unchanged"} {
		if !strings.Contains(se, want) {
			t.Errorf("no %q in\n%s", want, se)
		}
	}

	// A dry run that says no: nothing backed up, shipped or restarted.
	f = newFake(t, "traefik:v3.7.10")
	f.dry = Dry{Verdict: "spoke", Errors: broken["missing-middleware"], Routers: "kasbah-dry-run-anchor@file traefik-dashboard@file gallery@file "}
	se, code = runUp(t, f, "v3.7.11")
	if code != 1 || len(f.calls) != 2 || !strings.Contains(se, "rejects the configuration already on deploy@vps") || !strings.Contains(se, "nope@file") {
		t.Errorf("refused: %d %q\n%s", code, f.calls, se)
	}
	for _, c := range []struct {
		dry  Dry
		want string
	}{
		{Dry{Verdict: "spoke", Routers: "traefik-dashboard@file gallery@file "}, "loaded no kasbah-dry-run-anchor@file router"},
		{Dry{Verdict: "spoke", Routers: "kasbah-dry-run-anchor@file traefik-dashboard@file traefik-dashboard-http@file "}, "loaded no router out of /apps/traefik/dynamic"},
		{Dry{Verdict: "exited", ExitCode: "1", Log: "boom"}, "exited (code 1)"},
		{Dry{Verdict: "timeout"}, "said nothing in 120s"},
	} {
		f = newFake(t, "traefik:v3.7.10")
		f.dry = c.dry
		se, code = runUp(t, f, "v3.7.11")
		if code != 1 || len(f.calls) != 2 || !strings.Contains(se, c.want) || !strings.Contains(se, "traefik:v3.7.10 is still serving") {
			t.Errorf("%s: %d %q\n%s", c.want, code, f.calls, se)
		}
	}
	// Only kasbah's overlay on the server: the anchor alone passes, and says so.
	f = newFake(t, "traefik:v3.7.10")
	f.stack.Fragments = []string{"_shared.yml"}
	f.dry = Dry{Verdict: "spoke", Routers: "kasbah-dry-run-anchor@file traefik-dashboard@file "}
	if se, code = runUp(t, f, "v3.7.11"); code != 0 || !strings.Contains(se, "no project fragments to validate") {
		t.Errorf("overlay only: %d\n%s", code, se)
	}

	// Already there, files and container both: nothing shipped, nothing restarted.
	f = newFake(t, "traefik:v3.7.11")
	if se, code = runUp(t, f, "v3.7.11"); code != 0 || len(f.calls) != 2 || !strings.Contains(se, "nothing to ship") {
		t.Errorf("no-op: %d %q\n%s", code, f.calls, se)
	}
	// Files agree, the container does not: recreated.
	f = newFake(t, "traefik:v3.7.11")
	f.stack.RunningImage = "traefik:v3.7.10"
	if se, code = runUp(t, f, "v3.7.11"); code != 0 || len(f.calls) != 4 || !strings.Contains(se, "recreating it") || !strings.Contains(se, "nothing re-rendered") {
		t.Errorf("stale container: %d %q\n%s", code, f.calls, se)
	}

	f = newFake(t, "traefik:v3.7.10")
	f.up, f.upRC = Up{RolledBack: "yes", Health: "healthy", Image: "traefik:v3.7.10"}, 3
	if se, code = runUp(t, f, "v3.7.11"); code != 1 || !strings.Contains(se, "rolled back to traefik:v3.7.10") {
		t.Errorf("rolled back: %d\n%s", code, se)
	}
	f = newFake(t, "traefik:v3.7.10")
	f.up = Up{RolledBack: "no", Health: "healthy", State: "running", Image: "traefik:v3.7.11", AcmeDigest: "d1", Networks: "a_kasbah b_kasbah"}
	if se, code = runUp(t, f, "v3.7.11"); code != 0 || !strings.Contains(se, "rejoined 2 project network(s): a_kasbah b_kasbah") {
		t.Errorf("rejoined: %d\n%s", code, se)
	}
	f = newFake(t, "traefik:v3.7.10")
	f.up = Up{RolledBack: "no", Health: "healthy", Image: "traefik:v3.7.11", JoinErr: "docker network connect b_kasbah traefik failed: boom"}
	if se, code = runUp(t, f, "v3.7.11"); code != 1 || !strings.Contains(se, "could not rejoin the project networks: docker network connect b_kasbah traefik failed: boom") ||
		!strings.Contains(se, "docker network connect <network> traefik") {
		t.Errorf("join failed: %d\n%s", code, se)
	}
	f = newFake(t, "traefik:v3.7.10")
	f.up, f.upRC = Up{RolledBack: "yes", Health: "healthy", Image: "traefik:v3.7.10", JoinErr: "docker network connect b_kasbah traefik failed: boom"}, 3
	if se, code = runUp(t, f, "v3.7.11"); code != 1 || !strings.Contains(se, "rolled back to traefik:v3.7.10") ||
		!strings.Contains(se, "the restored Traefik could not rejoin the project networks: docker network connect b_kasbah traefik failed: boom") {
		t.Errorf("rolled back, join failed: %d\n%s", code, se)
	}
	f = newFake(t, "traefik:v3.7.10")
	f.up, f.upRC = Up{RolledBack: "failed", Health: "none"}, 3
	if se, code = runUp(t, f, "v3.7.11"); code != 1 || !strings.Contains(se, "every site on this host is down") {
		t.Errorf("rollback failed: %d\n%s", code, se)
	}
}

func TestRecover(t *testing.T) {
	for _, c := range []struct {
		edit func(*fake)
		want string
	}{
		{func(f *fake) { f.stack.Shared = "" }, "dynamic/_shared.yml is missing or unreadable"},
		{func(f *fake) { f.stack.Shared = enc(" \n\n") }, "dynamic/_shared.yml is missing or unreadable"},
		{func(f *fake) { f.stack.Docker = false }, "docker is not on deploy@vps's PATH"},
		{func(f *fake) {
			f.stack.Static = enc("certificatesResolvers:\n  http:\n    acme:\n      email: a@b.c\n")
		}, "does not say what the ACME endpoint (caServer) is"},
		{func(f *fake) { f.stack.Static = enc("a: [") }, "traefik.yml on deploy@vps is not valid YAML"},
		{func(f *fake) { f.stack.Compose = enc("services:\n  traefik:\n    image: mirror/traefik:v3\n") }, "does not say what the traefik service's image is"},
		{func(f *fake) { f.stack.Shared = enc("http:\n  routers:\n    traefik-dashboard-http: {}\n") }, "does not say what the dashboard router's rule is"},
		{func(f *fake) {
			f.stack.Shared = enc("http:\n  routers:\n    traefik-dashboard:\n      rule: \"Host(`traefik.example.com`)\"\n")
		}, "does not say what the dashboard's basic-auth entry is"},
	} {
		f := newFake(t, "traefik:v3.7.10")
		c.edit(f)
		se, code := runUp(t, f, "v3.7.11")
		if code != 1 || len(f.calls) != 1 || !strings.Contains(se, c.want) {
			t.Errorf("%s: %d %q\n%s", c.want, code, f.calls, se)
		}
	}
	// The endpoint is reproduced, never decided.
	f := newFake(t, "traefik:v3.7.10")
	runUp(t, f, "v3.7.11")
	if strings.Contains(f.written["/apps/traefik/traefik.yml"], "acme-v02") {
		t.Error("a staging server stays on staging")
	}
	// A traefik.yml naming the resolver letsencrypt is read back and re-rendered as http.
	f = newFake(t, "traefik:v3.7.10")
	f.stack.Static = enc("certificatesResolvers:\n  letsencrypt:\n    acme:\n      email: old@example.com\n      caServer: " + serverinit.CAStaging + "\n")
	if se, code := runUp(t, f, "v3.7.11"); code != 0 {
		t.Fatalf("legacy resolver name: %d\n%s", code, se)
	}
	if w := f.written["/apps/traefik/traefik.yml"]; !strings.Contains(w, "  http:\n") || strings.Contains(w, "letsencrypt:") ||
		!strings.Contains(w, "old@example.com") || !strings.Contains(w, "acme-staging-v02") {
		t.Errorf("legacy resolver name not migrated:\n%s", w)
	}
}

// A server without a dashboard keeps it off: the anchor, not the dashboard
// router, is the dry run's witness.
func TestDashboardOff(t *testing.T) {
	f := newFake(t, "traefik:v3.7.10")
	cur, err := serverinit.Render(templates.FS, serverinit.Options{Apps: "/apps", Data: "/apps/data"},
		serverinit.Values{Image: "traefik:v3.7.10", Email: "ops@example.com", Acme: serverinit.Acme{CA: serverinit.CAStaging}})
	if err != nil {
		t.Fatal(err)
	}
	f.stack.Shared = enc(cur["dynamic/_shared.yml"])
	f.dry = Dry{Verdict: "spoke", Routers: "kasbah-dry-run-anchor@file gallery@file "}
	se, code := runUp(t, f, "v3.7.11")
	if code != 0 || !strings.Contains(se, "built gallery@file out of 3 fragment(s)") {
		t.Fatalf("%d\n%s", code, se)
	}
	if _, ok := f.written["/apps/traefik/dynamic/_shared.yml"]; ok {
		t.Error("an off _shared.yml was re-rendered")
	}
	if on, _ := serverinit.DashboardOn(f.overlay); on || !strings.Contains(f.overlay, "kasbah-dry-run-anchor") {
		t.Errorf("overlay:\n%s", f.overlay)
	}
	f = newFake(t, "traefik:v3.7.10")
	f.stack.Shared = enc(cur["dynamic/_shared.yml"])
	f.stack.Fragments = []string{"_shared.yml"}
	f.dry = Dry{Verdict: "spoke", Routers: "kasbah-dry-run-anchor@file "}
	if se, code = runUp(t, f, "v3.7.11"); code != 0 || !strings.Contains(se, "built no router but its own anchor") {
		t.Errorf("overlay only, dashboard off: %d\n%s", code, se)
	}
}

func TestDryShared(t *testing.T) {
	cur, err := serverinit.Render(templates.FS, serverinit.Options{Apps: "/apps", Data: "/apps/data"},
		serverinit.Values{Image: "traefik:v3.7.10", Domain: "example.com", Email: "ops@example.com", AuthEntry: "a:$2y$05$x", Dashboard: true, Acme: serverinit.Acme{CA: serverinit.CAStaging}})
	if err != nil {
		t.Fatal(err)
	}
	got, err := DryShared(cur["dynamic/_shared.yml"])
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range [][]string{{"http", "routers", "traefik-dashboard", "service"}, {"http", "routers", "kasbah-dry-run-anchor", "tls", "certResolver"}, {"tls", "options", "default", "minVersion"}} {
		docs, _ := yamlx.Load([]byte(got))
		var p []any
		for _, k := range path {
			p = append(p, k)
		}
		if v, ok := tree.Lookup(docs[0], p...); !ok || v == "" {
			t.Errorf("overlay lacks %v:\n%s", path, got)
		}
	}
	if a, _ := serverinit.ExtractAuth(got); a != "a:$2y$05$x" {
		t.Errorf("the overlay's hash: %q", a)
	}
	if _, err := DryShared("http: [1\n"); err == nil {
		t.Error("an unparseable _shared.yml makes an overlay")
	}
}

// DNS resolvers are read back off traefik.yml and kept, their env files
// required and never written; the dry run sends every resolver to its own CA.
func TestRecoverDNS(t *testing.T) {
	f := newFake(t, "traefik:v3.7.10")
	o := serverinit.Options{Apps: "/apps", Data: "/apps/data", Target: "deploy@vps"}
	v := serverinit.Values{Image: "traefik:v3.7.10", Domain: "example.com", Email: "ops@example.com",
		AuthEntry: "admin:$2y$05$abcdefghijklmnopqrstuuOKS6tiVYGv2Cm5Q4PJBTzH9xvOGHT6e", Dashboard: true, DNS: []string{"cloudflare", "ovh"}}
	v.Acme.CA = serverinit.CAStaging
	cur, err := serverinit.Render(templates.FS, o, v)
	if err != nil {
		t.Fatal(err)
	}
	f.stack.Compose, f.stack.Static = enc(cur["compose.yml"]), enc(cur["traefik.yml"])
	f.stack.AcmeDNS = []string{"cloudflare", "ovh"}
	if se, code := runUp(t, f, "v3.7.11"); code != 0 {
		t.Fatalf("%d\n%s", code, se)
	}
	if w := f.written["/apps/traefik/compose.yml"]; !strings.Contains(w, "      - acme-dns/cloudflare.env\n      - acme-dns/ovh.env\n") || !strings.Contains(w, "traefik:v3.7.11") {
		t.Errorf("compose.yml lost its env_file:\n%s", w)
	}
	if _, ok := f.written["/apps/traefik/traefik.yml"]; ok {
		t.Error("traefik.yml re-rendered differently")
	}
	for k := range f.written {
		if strings.Contains(k, "acme-dns") {
			t.Errorf("upgrade wrote %s", k)
		}
	}
	if strings.Count(f.dryStatic, DryCA) != 3 || strings.Count(f.dryStatic, "/tmp/kasbah-dry-run-acme.json") != 3 || strings.Contains(f.dryStatic, "acme-staging") {
		t.Errorf("a resolver kept its CA or store in the dry run:\n%s", f.dryStatic)
	}

	f = newFake(t, "traefik:v3.7.10")
	f.stack.Static = enc(cur["traefik.yml"])
	f.stack.AcmeDNS = []string{"cloudflare"}
	se, code := runUp(t, f, "v3.7.11")
	if code != 1 || len(f.calls) != 1 || !strings.Contains(se, "declares the DNS resolver 'ovh'") || !strings.Contains(se, "--acme-dns=ovh:<env file>") {
		t.Errorf("missing env file: %d %q\n%s", code, f.calls, se)
	}
}
