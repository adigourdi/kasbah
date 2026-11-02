package destroy

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/shtest"
)

const (
	B = env.ManagedBegin
	E = env.ManagedEnd
)

func TestParse(t *testing.T) {
	o, err := Parse([]string{"deploy@vps\r", "--yes\r"})
	if err != nil || o.Target != "deploy@vps" || !o.Yes {
		t.Fatalf("%+v %v", o, err)
	}
	for args, want := range map[string]string{
		"":            "no server given",
		"a@b --yes=1": "--yes takes no value",
		"a@b --force": "unknown flag '--force'",
		"a@b c@d":     "two servers given",
	} {
		if _, err := Parse(strings.Fields(args)); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v", args, err)
		}
	}
}

// The sentinel strip, byte for byte: every case the Bash suite pinned.
func TestStripSentinels(t *testing.T) {
	keep := func(l string) bool { return !sentinel(l) }
	for _, c := range []struct{ name, in, want string }{
		{"ordinary", "A=1\n" + B + "\nKASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=8g\n" + E + "\nZ=9\n", "A=1\nKASBAH_CPU_LIMIT=2\nKASBAH_MEM_LIMIT=8g\nZ=9\n"},
		{"crlf", "A=1\r\n" + B + "\r\nKASBAH_CPU_LIMIT=2\r\n" + E + "\r\n", "A=1\r\nKASBAH_CPU_LIMIT=2\r\n"},
		{"two blocks", B + "\nX=1\n" + E + "\n" + B + "\nY=2\n" + E + "\n", "X=1\nY=2\n"},
		{"block at EOF no newline", "X=1\n" + B + "\nKASBAH_MEM_LIMIT=8g\n" + E, "X=1\nKASBAH_MEM_LIMIT=8g\n"},
		{"final value no newline", B + "\nKASBAH_CPU_LIMIT=2\n" + E + "\nLAST=no-newline", "KASBAH_CPU_LIMIT=2\nLAST=no-newline"},
		{"stray and commented", "KASBAH_STRAY=1\n" + B + "\nKASBAH_CPU_LIMIT=2\n" + E + "\n#" + B + "\n", "KASBAH_STRAY=1\nKASBAH_CPU_LIMIT=2\n#" + B + "\n"},
		{"begin with no end", "A=1\n" + B + "\nKASBAH_CPU_LIMIT=2\nB=2\n", "A=1\nKASBAH_CPU_LIMIT=2\nB=2\n"},
		{"awkward bytes", B + "\nK=2\n" + E + "\nA=a b\t c   \nB=\"q # x\"\nC=$d\\b\n\n   export D=i\n# c\n", "K=2\nA=a b\t c   \nB=\"q # x\"\nC=$d\\b\n\n   export D=i\n# c\n"},
		{"only sentinels", B + "\n" + E + "\n", ""},
	} {
		got, _ := filter([]byte(c.in), keep)
		if string(got) != c.want {
			t.Errorf("%s: got %q want %q", c.name, got, c.want)
		}
	}
}

func TestMailKeep(t *testing.T) {
	for l, want := range map[string]bool{
		"MAIL_HOSTNAME=mail.a.test": true, "DOMAIN=a.test\r": true, "  export DATA_PATH=/apps/data": true,
		"\texport\tDOMAIN=x": true, "exportDOMAIN=x": false, "RELAY_PASSWORD=s": false, "# DOMAIN=x": false,
		"": false, "DOMAINS=x": false,
	} {
		if mailKeep(l) != want {
			t.Errorf("%q: %v", l, !want)
		}
	}
}

func stubDocker(t *testing.T, fn func([]string) (string, error)) *[][]string {
	var calls [][]string
	old := docker
	docker = func(dir string, args ...string) (string, error) {
		calls = append(calls, args)
		return fn(args)
	}
	t.Cleanup(func() { docker = old })
	return &calls
}

func tree(t *testing.T) string {
	apps := filepath.Join(t.TempDir(), "apps")
	w := func(p, s string, mode os.FileMode) {
		os.MkdirAll(filepath.Dir(filepath.Join(apps, p)), 0o755)
		os.WriteFile(filepath.Join(apps, p), []byte(s), mode)
	}
	w(".kasbah/server.json", "{}\n", 0o644)
	w(".kasbah/bin/kasbah", "elf", 0o755)
	w(".kasbah/backup/env", "secret", 0o600)
	w("mail/.env", "MAIL_HOSTNAME=mail.a.test\nDOMAIN=a.test\nDATA_PATH=/apps/data\nRELAY_PASSWORD=agency\n", 0o600)
	w("mail/kasbah.yml", "primary_domain: a.test\n", 0o644)
	w("demo/versions.log", "x\n", 0o644)
	w("demo/.kasbah-client", "demo\n", 0o644)
	w("demo/.kasbah-hooks.json", "{}\n", 0o644)
	w("demo/backups/1.0.0-20261102-100000.tar.gz", "tgz", 0o660)
	w("demo/.env", "A=1\n"+B+"\nKASBAH_CPU_LIMIT=0\n"+E+"\n", 0o640)
	w("demo/compose.yml", "services: {}\n", 0o644)
	w("demo/.kasbah-prev/v1/.env", "A=0\n", 0o660)
	w("demo/.kasbah-prev.kept-0.9.0-20261102-100000/v1/.env", "A=0\n", 0o660)
	w("demo/.kasbah-env-seed.0123456789abcdef", "A=s\n", 0o600)
	w("demo/.kasbah-env-seed.0123456789abcdef.42", "A=s\n", 0o600)
	w("beta/scripts/remote-deploy.sh", "#!/bin/sh\n", 0o755)
	w("beta/scripts/setup-env.sh", "#!/bin/sh\n", 0o755)
	w("beta/scripts/notes.txt", "mine\n", 0o644)
	w("gamma/scripts/setup-env.sh", "#!/bin/sh\n", 0o755)
	w("README.md", "x", 0o644)
	w("traefik/dynamic/demo.yml", "x", 0o644)
	return apps
}

func TestScan(t *testing.T) {
	apps := tree(t)
	stubDocker(t, func(a []string) (string, error) {
		if a[0] == "container" {
			return "running\n", nil
		}
		return "", nil
	})
	old := sudoState
	sudoState = func() string { return "no" }
	defer func() { sudoState = old }()
	os.WriteFile(filepath.Join(apps, ".kasbah", "bin", ".lock"), nil, 0o644)
	os.WriteFile(filepath.Join(apps, ".kasbah", "stray"), nil, 0o644)
	os.WriteFile(filepath.Join(apps, ".kasbah", "layers.map"), []byte("x\n"), 0o664)
	s := scan(apps, filepath.Join(apps, "nope", "apps-path"))
	if s.LayersMap != "ok" {
		t.Errorf("layers map %q", s.LayersMap)
	}
	if s.MarkerState != "ok" || s.BinState != "ok" || s.BackupDir != "dir" || s.BackupContainer != "running" ||
		s.MailEnvExtra != 1 || s.RegistryState != "ok" || s.PointerState != "missing" || s.Sudo != "no" || !s.BinLock {
		t.Fatalf("%+v", s)
	}
	if strings.Join(s.KasbahExtra, " ") != "stray" || strings.Join(s.Skipped, " ") != "README.md" {
		t.Errorf("extra %v skipped %v", s.KasbahExtra, s.Skipped)
	}
	var rows []string
	for _, r := range s.Projects {
		b, _ := json.Marshal(r)
		rows = append(rows, string(b))
	}
	if s.Count != 3 || s.Projects[0].Name != "beta" || s.Projects[0].Helpers != 2 || s.Projects[0].Other != 1 ||
		s.Projects[1].Name != "demo" || s.Projects[1].Sentinels != 2 || s.Projects[1].Vlog != "ok" ||
		s.Projects[1].Prev != "dir" || s.Projects[0].Prev != "absent" || s.Projects[1].Seeds != 2 || s.Projects[0].Seeds != 0 ||
		s.Projects[1].Kept != 1 || s.Projects[0].Kept != 0 ||
		s.Projects[1].Hooks != "ok" || s.Projects[0].Hooks != "missing" {
		t.Errorf("rows: %v", rows)
	}
}

func actOn(t *testing.T, apps string, names ...string) (ActReport, string) {
	var so, se bytes.Buffer
	if code := Remote(append([]string{"act", apps}, names...), &so, &se); code != 0 {
		t.Fatalf("act: %d %s", code, se.String())
	}
	head, body, _ := strings.Cut(so.String(), "\n")
	if head != "started=yes" {
		t.Fatalf("no started: %q", so.String())
	}
	var r ActReport
	if err := json.Unmarshal([]byte(body), &r); err != nil {
		t.Fatal(err)
	}
	return r, se.String()
}

func TestAct(t *testing.T) {
	apps := tree(t)
	calls := stubDocker(t, func(a []string) (string, error) { return "", nil })
	os.WriteFile(filepath.Join(apps, ".kasbah", "layers.map"), []byte("x\n"), 0o664)
	r, _ := actOn(t, apps, "beta", "demo", "gamma")
	if r.BkDown != "ok" || r.BkFiles != "removed" || r.MailEnv != "stripped" || r.MailEnvN != 1 ||
		r.MailRegistry != "removed" || r.LayersMap != "removed" || r.Marker != "removed" {
		t.Fatalf("%+v", r)
	}
	if strings.Join((*calls)[1], " ") != "compose -p kasbah-backup down --remove-orphans" {
		t.Errorf("calls %v", *calls)
	}
	want := []ProjectResult{
		{"beta", "absent", "absent", "kept", "absent", "absent", "absent", "absent", "absent", "absent", "absent"},
		{"demo", "removed", "absent", "absent", "absent", "removed", "stripped", "removed", "removed", "removed", "removed"},
		{"gamma", "absent", "absent", "removed", "absent", "absent", "absent", "absent", "absent", "absent", "absent"},
	}
	for i, w := range want {
		if r.Projects[i] != w {
			t.Errorf("row %d: %+v", i, r.Projects[i])
		}
	}
	env, _ := os.ReadFile(filepath.Join(apps, "demo", ".env"))
	if string(env) != "A=1\nKASBAH_CPU_LIMIT=0\n" {
		t.Errorf(".env: %q", env)
	}
	if fi, _ := os.Stat(filepath.Join(apps, "demo", ".env")); fi.Mode().Perm() != 0o640 {
		t.Errorf(".env mode %o", fi.Mode().Perm())
	}
	mail, _ := os.ReadFile(filepath.Join(apps, "mail", ".env"))
	if string(mail) != "MAIL_HOSTNAME=mail.a.test\nDOMAIN=a.test\nDATA_PATH=/apps/data\n" {
		t.Errorf("mail .env: %q", mail)
	}
	if fi, _ := os.Stat(filepath.Join(apps, "mail", ".env")); fi.Mode().Perm() != 0o600 {
		t.Errorf("mail mode %o", fi.Mode().Perm())
	}
	for _, p := range []string{"beta/scripts/notes.txt", ".kasbah/bin/kasbah", "demo/compose.yml", "demo/backups/1.0.0-20261102-100000.tar.gz", "traefik/dynamic/demo.yml", "README.md"} {
		if _, err := os.Stat(filepath.Join(apps, p)); err != nil {
			t.Errorf("act removed %s", p)
		}
	}
	for _, p := range []string{".kasbah/server.json", ".kasbah/backup", "gamma/scripts", "beta/scripts/setup-env.sh",
		"demo/.kasbah-env-seed.0123456789abcdef", "demo/.kasbah-env-seed.0123456789abcdef.42", "demo/.kasbah-hooks.json",
		"demo/.kasbah-prev", "demo/.kasbah-prev.kept-0.9.0-20261102-100000"} {
		if _, err := os.Stat(filepath.Join(apps, p)); err == nil {
			t.Errorf("act left %s", p)
		}
	}
	for _, d := range []string{"mail", "demo"} {
		es, _ := os.ReadDir(filepath.Join(apps, d))
		for _, e := range es {
			if strings.Contains(e.Name(), ".tmp.") {
				t.Errorf("staging left: %s/%s", d, e.Name())
			}
		}
	}
}

func TestActHoldsTheMarker(t *testing.T) {
	apps := tree(t)
	stubDocker(t, func([]string) (string, error) { return "", nil })
	// Not a file this step can rewrite (root reads a mode-000 one).
	os.Remove(filepath.Join(apps, "mail", ".env"))
	os.Mkdir(filepath.Join(apps, "mail", ".env"), 0o700)
	r, _ := actOn(t, apps, "demo")
	if r.MailEnv != "unreadable" || r.Marker != "held" || r.Projects[0].Env != "stripped" {
		t.Errorf("%+v", r)
	}
	if _, err := os.Stat(filepath.Join(apps, ".kasbah", "server.json")); err != nil {
		t.Errorf("the marker went")
	}
}

func TestActGuards(t *testing.T) {
	apps := tree(t)
	calls := stubDocker(t, func([]string) (string, error) { return "", nil })
	for _, args := range [][]string{{"act", "apps", "demo"}, {"act", apps + "/", "demo"}, {"act", apps, "Demo"},
		{"act", apps, "../x"}, {"act", apps, "traefik"}} {
		var so, se bytes.Buffer
		if code := Remote(args, &so, &se); code != 1 || so.Len() != 0 || !strings.Contains(se.String(), "refusing to act") {
			t.Errorf("%v: %d %q %q", args, code, so.String(), se.String())
		}
	}
	if len(*calls) != 0 {
		t.Errorf("a refusal ran docker")
	}
}

type fake struct {
	mk        *marker.Marker
	mkErr     error
	scan      *Scan
	actOut    string
	tailOut   string
	tailRC    int
	left      string
	pointer   []string
	calls     []string
	actedWith []string
}

func (f *fake) Marker() (*marker.Marker, error) {
	f.calls = append(f.calls, "marker")
	return f.mk, f.mkErr
}
func (f *fake) Host() string { return "vps.example" }
func (f *fake) Scan(string) ([]byte, int) {
	f.calls = append(f.calls, "scan")
	b, _ := json.Marshal(f.scan)
	return b, 0
}
func (f *fake) Act(apps string, names []string) ([]byte, int) {
	f.calls = append(f.calls, "act")
	f.actedWith = names
	return []byte(f.actOut), 0
}
func (f *fake) Tail(string) ([]byte, int) {
	f.calls = append(f.calls, "tail")
	return []byte(f.tailOut), f.tailRC
}
func (f *fake) Leftovers() ([]byte, int) {
	f.calls = append(f.calls, "leftovers")
	return []byte(f.left), 0
}
func (f *fake) Pointer() ([]byte, int) {
	f.calls = append(f.calls, "pointer")
	if len(f.pointer) == 0 {
		return nil, 255
	}
	out := f.pointer[0]
	f.pointer = f.pointer[1:]
	return []byte(out), 0
}
func (f *fake) Close() {}

func scanFixture() *Scan {
	return &Scan{HaveDocker: true, AppsState: "dir", MarkerState: "ok", KasbahDir: "dir", KasbahExtra: []string{},
		BinState: "ok", BackupDir: "absent", BackupContainer: "absent", BackupVolume: "absent", BackupNetwork: "absent",
		PointerState: "ok", PointerDir: "dir", Sudo: "yes", MailDir: "absent", MailEnvState: "missing", RegistryState: "missing", LayersMap: "missing",
		Projects: []Row{{Name: "data", Dir: "dir", Vlog: "missing", VlogGz: "missing", Lock: "missing", Client: "missing"},
			{Name: "demo", Dir: "dir", Vlog: "ok", VlogGz: "missing", Lock: "ok", Client: "missing", Env: "ok", Sentinels: 2, Seeds: 1, Kept: 1}},
		Count: 2, Skipped: []string{"README.md"}}
}

const okAct = `started=yes
{"bk_down":"skipped","bk_down_detail":"","bk_container":"absent","bk_volume":"absent","bk_network":"absent","bk_files":"absent","projects":[{"name":"demo","vlog":"removed","vlog_gz":"absent","scripts":"absent","lock":"removed","client":"absent","env":"stripped","seeds":"removed","kept":"removed"}],"mail_env":"absent","mail_env_n":0,"mail_registry":"absent","layers_map":"absent","acme_dns":"absent","marker":"removed"}
`

const okTail = "pointer=removed\npointer_dir=removed\nbinary=removed\nbin_dir=removed\nkasbah_dir=removed\ndone=yes\n"

func run(t *testing.T, f *fake, o Options, tty bool, answers string) (string, string, int) {
	var so, se bytes.Buffer
	out := &cli.Output{Stdout: &so, Stderr: &se}
	p := &prompt.Prompter{In: strings.NewReader(answers), Out: out, TTY: tty}
	code := out.Report(Run(Ctx{Out: out, Prompter: p, Dial: func(string) (Session, error) { return f, nil }}, o))
	return so.String(), se.String(), code
}

func mk() *marker.Marker { return &marker.Marker{AppsPath: "/apps", DataPath: "/apps/data"} }

func TestRun(t *testing.T) {
	f := &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: okTail}
	so, se, code := run(t, f, Options{Target: "deploy@vps.example"}, false, "")
	if code != 1 || !strings.Contains(se, "--yes") || strings.Contains(strings.Join(f.calls, " "), "act") {
		t.Fatalf("no tty: %d %s %v", code, se, f.calls)
	}
	if !strings.Contains(so, "\n              /apps/.kasbah/bin/ and /apps/.kasbah/, which hold nothing else\n") {
		t.Errorf("a plan with no lock names one:\n%s", so)
	}
	if !strings.Contains(so, "    demo  versions.log, .deploy.lock, .kasbah-env-seed (1 staged --env-seed file(s), with .env values), .kasbah-prev.kept-* (1 snapshot(s) a backup could not take in, each with a copy of .env), .env: 2 managed-block sentinel comment(s), values kept\n") ||
		strings.Contains(so, "    data ") || !strings.Contains(so, "  binary      /apps/.kasbah/bin/kasbah (ok)") ||
		!strings.Contains(so, "README.md under /apps — not a project name") {
		t.Errorf("plan:\n%s", so)
	}

	f = &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: okTail}
	if _, se, code := run(t, f, Options{Target: "deploy@vps.example"}, true, "y\nvps\n"); code != 1 || !strings.Contains(se, "that is not vps.example") {
		t.Fatalf("mistyped host: %d %s", code, se)
	}
	so, se, code = run(t, f, Options{Target: "deploy@vps.example"}, true, "y\nvps.example\n")
	if code != 0 || strings.Join(f.calls, " ") != "marker scan marker scan act tail" || strings.Join(f.actedWith, " ") != "demo" {
		t.Fatalf("%d %s %v", code, se, f.calls)
	}
	for _, w := range []string{"  removed the server marker /apps/.kasbah/server.json\n  removed /etc/kasbah/apps-path\n  removed /etc/kasbah/\n  removed the server's kasbah binary /apps/.kasbah/bin/kasbah\n  removed /apps/.kasbah/bin/\n  removed /apps/.kasbah/\n",
		"  removed the staged .kasbah-env-seed files\n", "  removed the kept-aside .kasbah-prev.kept-* snapshots\n", "plain Docker Compose host now"} {
		if !strings.Contains(so, w) {
			t.Errorf("lacks %q:\n%s", w, so)
		}
	}
}

func TestRunHeldAndNosudo(t *testing.T) {
	held := strings.Replace(okAct, `"marker":"removed"`, `"marker":"held"`, 1)
	held = strings.Replace(held, `"mail_env":"absent"`, `"mail_env":"unreadable"`, 1)
	f := &fake{mk: mk(), scan: scanFixture(), actOut: held, tailOut: okTail}
	so, se, code := run(t, f, Options{Target: "deploy@vps.example", Yes: true}, false, "")
	if code != 1 || strings.Contains(strings.Join(f.calls, " "), "tail") || !strings.Contains(so, "kept the server marker") ||
		!strings.Contains(se, "relay credential in it is still on this server") || strings.Contains(so, "plain Docker Compose host now") {
		t.Fatalf("held: %d %v\n%s\n%s", code, f.calls, so, se)
	}
	f = &fake{mk: mk(), scan: scanFixture(), actOut: okAct,
		tailOut: "pointer=nosudo\npointer_dir=nosudo\nbinary=removed\nbin_dir=removed\nkasbah_dir=removed\ndone=yes\n",
		pointer: []string{"pointer=present\npointer_dir=empty\n"}}
	so, se, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, false, "")
	if code != 0 || !strings.Contains(so, "one file short of a plain Docker Compose host") ||
		!strings.Contains(so, "  Run on deploy@vps.example, as root or as deploy with your own sudo") ||
		!strings.Contains(so, "\n      sudo rm -f /etc/kasbah/apps-path\n      sudo rmdir /etc/kasbah\n") ||
		strings.Count(strings.Join(f.calls, " "), "pointer") != 1 {
		t.Fatalf("nosudo: %d\n%s\n%s", code, so, se)
	}
	f = &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: "pointer=removed\n", tailRC: 255}
	if _, se, code := run(t, f, Options{Target: "deploy@vps.example", Yes: true}, false, ""); code != 1 || !strings.Contains(se, "the last destroy step on deploy@vps.example exited 255") {
		t.Fatalf("tail cut: %d %s", code, se)
	}
}

func TestRunNothingLeft(t *testing.T) {
	none := cli.Failf(cli.ExitNoRemoteState, "deploy@vps has no server marker at /apps/.kasbah/server.json")
	for _, c := range []struct {
		left, want string
		code       int
	}{
		{"pointer=no\n", "carries nothing of kasbah's management layer", 0},
		{"pointer=no\nkasbah=/apps/.kasbah\nitem=/apps/.kasbah/notes\n", "/apps/.kasbah is still there, with no marker in it", 0},
		{"pointer=yes\nkasbah=/apps/.kasbah\nitem=/apps/.kasbah/stray\n", "/etc/kasbah/apps-path is still there", 0},
		{"pointer=no\nkasbah=/apps/.kasbah\ncreds=/apps/.kasbah/backup\nitem=/apps/.kasbah/backup\n", "/apps/.kasbah/backup is still there", 1},
	} {
		f := &fake{mkErr: none, left: c.left, pointer: []string{"pointer=present\npointer_dir=empty\n"}}
		so, se, code := run(t, f, Options{Target: "deploy@vps"}, false, "")
		if code != c.code || !strings.Contains(so, c.want) || strings.Contains(strings.Join(f.calls, " "), "scan") {
			t.Errorf("%q: %d\n%s\n%s", c.left, code, so, se)
		}
	}
	// The pointer outlived the marker: the block for what the probe sees, and
	// no rmdir of a directory holding something else.
	for probe, want := range map[string]string{
		"pointer=present\npointer_dir=empty\n": "\n      sudo rm -f /etc/kasbah/apps-path\n      sudo rmdir /etc/kasbah\n",
		"pointer=present\npointer_dir=dir\n":   "\n      sudo rm -f /etc/kasbah/apps-path\n  nothing else",
	} {
		f := &fake{mkErr: none, left: "pointer=yes\nkasbah=/apps/.kasbah\nitem=/apps/.kasbah/stray\n", pointer: []string{probe}}
		so, se, code := run(t, f, Options{Target: "deploy@vps"}, false, "")
		if code != 0 || !strings.Contains(so, want) || strings.Contains(se, "ssh deploy@vps 'sudo") {
			t.Errorf("%q: %d\n%s\n%s", probe, code, so, se)
		}
	}
	s := scanFixture()
	s.MarkerState, s.KasbahDir, s.PointerState, s.Projects, s.Count = "missing", "absent", "missing", nil, 0
	f := &fake{mk: mk(), scan: s}
	if so, _, code := run(t, f, Options{Target: "deploy@vps"}, false, ""); code != 0 || !strings.Contains(so, "nothing to remove") {
		t.Errorf("nothing to do never asks: %d %s", code, so)
	}
}

func TestScriptsParse(t *testing.T) {
	shtest.Check(t, "destroy", map[string]string{"tail": tailScript, "leftover": leftoverScript, "pointer": pointerScript})
}

func TestTailScript(t *testing.T) {
	for _, sh := range shtest.Shells(t) {
		t.Run(sh.Name, func(t *testing.T) { testTailScript(t, sh) })
	}
}

func testTailScript(t *testing.T, sh shtest.Shell) {
	apps := tree(t)
	etc := filepath.Join(t.TempDir(), "etc", "kasbah")
	os.MkdirAll(etc, 0o755)
	os.WriteFile(filepath.Join(etc, "apps-path"), []byte(apps+"\n"), 0o644)
	os.WriteFile(filepath.Join(apps, ".kasbah", "bin", ".lock"), nil, 0o644)
	os.WriteFile(filepath.Join(apps, ".kasbah", "bin", ".kasbah.abc123"), nil, 0o644)
	os.RemoveAll(filepath.Join(apps, ".kasbah", "backup"))
	os.Remove(filepath.Join(apps, ".kasbah", "server.json"))
	tail := func(sudo string) map[string]string {
		bin := t.TempDir()
		os.WriteFile(filepath.Join(bin, "sudo"), []byte(sudo), 0o755)
		os.WriteFile(filepath.Join(bin, "id"), []byte("#!/bin/sh\necho 1000\n"), 0o755)
		cmd := sh.C(tailScript, apps, filepath.Join(etc, "apps-path"), ".kasbah.", ".lock")
		cmd.Env = append(os.Environ(), "PATH="+bin+":"+os.Getenv("PATH"))
		out, err := cmd.Output()
		if err != nil {
			t.Fatal(err)
		}
		return kv(out)
	}
	// No passwordless sudo: the pointer stays, the binary still goes.
	got := tail("#!/bin/sh\nexit 1\n")
	if got["pointer"] != "nosudo" || got["pointer_dir"] != "nosudo" {
		t.Errorf("nosudo: %v", got)
	}
	if _, err := os.Stat(filepath.Join(etc, "apps-path")); err != nil {
		t.Errorf("the pointer went without sudo")
	}
	// Without sudo and without a pointer there is nothing it could not remove.
	os.Rename(filepath.Join(etc, "apps-path"), etc+".pointer")
	if got := tail("#!/bin/sh\nexit 1\n"); got["pointer"] != "absent" || got["pointer_dir"] != "nosudo" {
		t.Errorf("nosudo, no pointer: %v", got)
	}
	os.Rename(etc+".pointer", filepath.Join(etc, "apps-path"))
	os.MkdirAll(filepath.Join(apps, ".kasbah", "bin"), 0o755)
	os.WriteFile(filepath.Join(apps, ".kasbah", "bin", "kasbah"), nil, 0o755)
	got = tail("#!/bin/sh\n[ \"$1\" = -n ] && shift\nexec \"$@\"\n")
	if got["pointer"] != "removed" || got["pointer_dir"] != "removed" {
		t.Errorf("pointer: %v", got)
	}
	if _, err := os.Stat(etc); err == nil {
		t.Errorf("/etc/kasbah survived")
	}
	if got["binary"] != "removed" || got["bin_dir"] != "removed" || got["kasbah_dir"] != "removed" || got["done"] != "yes" {
		t.Errorf("%v", got)
	}
	if _, err := os.Stat(filepath.Join(apps, ".kasbah")); err == nil {
		t.Errorf(".kasbah survived")
	}
	// A file kasbah did not write keeps its directory.
	os.MkdirAll(filepath.Join(apps, ".kasbah", "bin"), 0o755)
	os.WriteFile(filepath.Join(apps, ".kasbah", "bin", "theirs"), nil, 0o644)
	if got := tail("#!/bin/sh\nexit 1\n"); got["binary"] != "absent" || got["bin_dir"] != "kept" || got["kasbah_dir"] != "kept" {
		t.Errorf("%v", got)
	}
	for _, bad := range []string{"apps", apps + "/"} {
		if err := sh.C(tailScript, bad, "/etc/kasbah/apps-path", ".kasbah.", ".lock").Run(); err == nil {
			t.Errorf("%q was accepted", bad)
		}
	}
}

func TestLeftoverScript(t *testing.T) {
	root := t.TempDir()
	def, other := filepath.Join(root, "apps"), filepath.Join(root, "srv")
	os.MkdirAll(filepath.Join(other, ".kasbah", "backup"), 0o700)
	os.MkdirAll(filepath.Join(def, ".kasbah"), 0o755)
	ptr := filepath.Join(root, "apps-path")
	os.WriteFile(ptr, []byte(other+"\r\n"), 0o644)
	want := "pointer=yes\nkasbah=" + def + "/.kasbah\nkasbah=" + other + "/.kasbah\ncreds=" + other + "/.kasbah/backup\nitem=" + other + "/.kasbah/backup\n"
	for _, sh := range shtest.Shells(t) {
		out, err := sh.C(leftoverScript, ptr, def).Output()
		if err != nil {
			t.Fatalf("%s: %v", sh.Name, err)
		}
		if string(out) != want {
			t.Errorf("%s: got %q", sh.Name, out)
		}
	}
}

// A session dropped after the marker went leaves the pointer and the binary;
// a re-run finishes the last step rather than calling the server clean.
func TestRunFinishesTheTail(t *testing.T) {
	none := cli.Failf(cli.ExitNoRemoteState, "deploy@vps has no server marker at /apps/.kasbah/server.json")
	for _, left := range []string{
		"pointer=yes\nkasbah=/apps/.kasbah\nitem=/apps/.kasbah/bin\nitem=/apps/.kasbah/bin/kasbah\nitem=/apps/.kasbah/bin/.lock\nitem=/apps/.kasbah/bin/.kasbah.x1\n",
		"pointer=yes\n",
		"pointer=no\nkasbah=/apps/.kasbah\n",
	} {
		f := &fake{mkErr: none, left: left, tailOut: okTail}
		so, se, code := run(t, f, Options{Target: "deploy@vps"}, false, "")
		if code != 0 || !strings.Contains(so, "finishing it") || !strings.Contains(so, "removed the server's kasbah binary") ||
			strings.Join(f.calls, " ") != "marker leftovers tail" {
			t.Errorf("%q: %d %v\n%s\n%s", left, code, f.calls, so, se)
		}
	}
	f := &fake{mkErr: none, left: "pointer=yes\n", tailOut: "pointer=failed\n", tailRC: 0}
	if _, _, code := run(t, f, Options{Target: "deploy@vps"}, false, ""); code != 1 {
		t.Errorf("a tail that did not finish: %d", code)
	}
	// No sudo: one wait for the server-wide pointer, after every tail.
	nosudo := "pointer=nosudo\npointer_dir=nosudo\nbinary=removed\nbin_dir=removed\nkasbah_dir=removed\ndone=yes\n"
	two := "pointer=yes\nkasbah=/apps/.kasbah\nkasbah=/srv/apps/.kasbah\n"
	f = &fake{mkErr: none, left: two, tailOut: nosudo,
		pointer: []string{"pointer=present\npointer_dir=empty\n", "pointer=absent\npointer_dir=absent\n"}}
	so, se, code := run(t, f, Options{Target: "deploy@vps"}, true, "\n")
	if code != 0 || strings.Join(f.calls, " ") != "marker leftovers tail tail pointer pointer" || strings.Count(se, "Press Enter") != 1 ||
		!strings.Contains(so, "/etc/kasbah/apps-path and /etc/kasbah/ were removed by hand") || strings.Contains(se, "ssh deploy@vps") {
		t.Errorf("no sudo, a terminal: %d %v\n%s\n%s", code, f.calls, so, se)
	}
	f = &fake{mkErr: none, left: "pointer=yes\n", tailOut: nosudo, pointer: []string{"pointer=present\npointer_dir=empty\n"}}
	so, se, code = run(t, f, Options{Target: "deploy@vps"}, false, "")
	if code != 0 || !strings.Contains(so, "one file short") || strings.Contains(se, "ssh deploy@vps") ||
		!strings.Contains(so, "\n      sudo rm -f /etc/kasbah/apps-path\n      sudo rmdir /etc/kasbah\n") {
		t.Errorf("no sudo, no terminal: %d %v\n%s\n%s", code, f.calls, so, se)
	}
}

func TestRunRefusesAMismatchedReport(t *testing.T) {
	for act, want := range map[string]string{
		strings.Replace(okAct, `"name":"demo"`, `"name":"beta"`, 1): "reported 'beta' where the plan named 'demo'",
		strings.Replace(okAct, `[{"name":"demo","vlog":"removed","vlog_gz":"absent","scripts":"absent","lock":"removed","client":"absent","env":"stripped","seeds":"removed","kept":"removed"}]`, `[]`, 1): "reported 0 of 1 projects",
		"started=yes\n{}": "the destroy step on deploy@vps.example reported no",
		"":                "it refused before changing anything",
	} {
		f := &fake{mk: mk(), scan: scanFixture(), actOut: act, tailOut: okTail}
		_, se, code := run(t, f, Options{Target: "deploy@vps.example", Yes: true}, false, "")
		if code != 1 || !strings.Contains(se, want) || strings.Contains(strings.Join(f.calls, " "), "tail") {
			t.Errorf("%s: %d %s", want, code, se)
		}
	}
}

// snapshot is every path under root with its bytes, to prove a refusal
// changed nothing.
func snapshot(root string) string {
	var b strings.Builder
	filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
		data, _ := os.ReadFile(p)
		fmt.Fprintf(&b, "%s %v %q\n", p, fi.Mode(), data)
		return nil
	})
	return b.String()
}

func TestActNameGuardsChangeNothing(t *testing.T) {
	apps := tree(t)
	calls := stubDocker(t, func([]string) (string, error) { return "", nil })
	before := snapshot(apps)
	for _, n := range []string{"data", "backups", ".kasbah", "traefik", "mail", "", "a/b", "..", "-x", "A"} {
		var so, se bytes.Buffer
		if code := Remote([]string{"act", apps, "demo", n}, &so, &se); code != 1 || so.Len() != 0 {
			t.Errorf("%q: %d %q", n, code, so.String())
		}
	}
	if snapshot(apps) != before || len(*calls) != 0 {
		t.Errorf("a refused act changed the tree or ran docker")
	}
}

func TestActHoldsTheMarkerOnFailures(t *testing.T) {
	apps := tree(t)
	stubDocker(t, func(a []string) (string, error) {
		if a[0] == "compose" {
			return "", fmt.Errorf("compose: daemon error")
		}
		return "", nil
	})
	r, _ := actOn(t, apps, "demo")
	if r.BkDown != "failed" || r.BkDownDetail != "compose: daemon error" || r.Marker != "held" {
		t.Errorf("a failed backup down: %+v", r)
	}

	apps = tree(t)
	stubDocker(t, func([]string) (string, error) { return "", nil })
	env := filepath.Join(apps, "demo", ".env")
	os.Remove(env)
	os.Mkdir(env, 0o700)
	r, _ = actOn(t, apps, "demo")
	if r.Projects[0].Env != "unreadable" || r.Marker != "held" {
		t.Errorf("an unreadable project .env: %+v", r)
	}
}

func TestActDanglingEnvIsAbsent(t *testing.T) {
	apps := tree(t)
	stubDocker(t, func([]string) (string, error) { return "", nil })
	for _, p := range []string{"demo/.env", "mail/.env"} {
		os.Remove(filepath.Join(apps, p))
		os.Symlink("gone.env", filepath.Join(apps, p))
	}
	r, _ := actOn(t, apps, "demo")
	if r.Projects[0].Env != "absent" || r.MailEnv != "absent" || r.Marker != "removed" {
		t.Errorf("%+v", r)
	}
	if fi, err := os.Lstat(filepath.Join(apps, "demo", ".env")); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("the link was touched")
	}
}

// The full strip through the file: mode, symlink target, staging, absence.
func TestStripEnvFile(t *testing.T) {
	keep := func(l string) bool { return !sentinel(l) }
	dir := t.TempDir()
	p := filepath.Join(dir, ".env")
	for _, c := range []struct{ name, in, want, verdict string }{
		{"crlf", "A=1\r\n" + B + "\r\nK=2\r\n" + E + "\r\n", "A=1\r\nK=2\r\n", "stripped"},
		{"no block", "A=1\n", "A=1\n", "noblock"},
		{"no final newline", B + "\nK=2\n" + E + "\nLAST=x", "K=2\nLAST=x", "stripped"},
		{"only sentinels", B + "\n" + E + "\n", "", "stripped"},
	} {
		os.WriteFile(p, []byte(c.in), 0o640)
		os.Chmod(p, 0o640)
		if v := rewrite(p, keep, 0); v != c.verdict {
			t.Errorf("%s: %s", c.name, v)
		}
		got, err := os.ReadFile(p)
		fi, _ := os.Stat(p)
		if err != nil || string(got) != c.want || fi.Mode().Perm() != 0o640 {
			t.Errorf("%s: %q %v", c.name, got, fi.Mode())
		}
	}
	os.Remove(p)
	if v := rewrite(p, keep, 0); v != "absent" {
		t.Errorf("no .env: %s", v)
	}
	os.MkdirAll(filepath.Join(dir, "real"), 0o755)
	os.WriteFile(filepath.Join(dir, "real", "env"), []byte(B+"\nK=1\n"+E+"\n"), 0o600)
	os.Symlink("real/env", p)
	if v := rewrite(p, keep, 0); v != "stripped" {
		t.Errorf("symlink: %s", v)
	}
	got, _ := os.ReadFile(filepath.Join(dir, "real", "env"))
	if fi, _ := os.Lstat(p); string(got) != "K=1\n" || fi.Mode()&os.ModeSymlink == 0 {
		t.Errorf("through a link: %q", got)
	}
	for _, d := range []string{dir, filepath.Join(dir, "real")} {
		if m, _ := filepath.Glob(filepath.Join(d, "*.tmp.*")); len(m) > 0 {
			t.Errorf("staging left: %v", m)
		}
	}
}

// A symlinked .kasbah or bin/ is never descended: what it points at is not
// kasbah's, neither for the probe nor for the tail.
func TestLinksAreNotKasbahs(t *testing.T) {
	for _, sh := range shtest.Shells(t) {
		t.Run(sh.Name, func(t *testing.T) { testLinksAreNotKasbahs(t, sh) })
	}
	if ownOnly([]string{"kasbah\nitem=zzz"}) || ownOnly([]string{""}) {
		t.Errorf("an item with no / is not kasbah's own")
	}
}

func testLinksAreNotKasbahs(t *testing.T, sh shtest.Shell) {
	for _, linked := range []string{".kasbah", ".kasbah/bin"} {
		root := t.TempDir()
		apps, outside := filepath.Join(root, "apps"), filepath.Join(root, "outside")
		os.MkdirAll(outside, 0o755)
		os.WriteFile(filepath.Join(outside, "kasbah"), []byte("theirs"), 0o644)
		os.MkdirAll(filepath.Join(apps, filepath.Dir(linked)), 0o755)
		os.Symlink(outside, filepath.Join(apps, linked))
		out, err := sh.C(leftoverScript, filepath.Join(root, "no-pointer"), apps).Output()
		if err != nil || !strings.Contains(string(out), "foreign="+filepath.Join(apps, linked)) {
			t.Errorf("%s: probe %q %v", linked, out, err)
		}
		f := &fake{mkErr: cli.Failf(cli.ExitNoRemoteState, "no marker"), left: string(out), tailOut: okTail}
		if so, _, _ := run(t, f, Options{Target: "deploy@vps"}, false, ""); strings.Contains(strings.Join(f.calls, " "), "tail") {
			t.Errorf("%s: the tail ran over a link:\n%s", linked, so)
		}
		tout, _ := sh.C(tailScript, apps, filepath.Join(root, "etc", "apps-path"), ".kasbah.", ".lock").Output()
		if got := kv(tout); got["binary"] != "link" {
			t.Errorf("%s: tail %v", linked, got)
		}
		if b, err := os.ReadFile(filepath.Join(outside, "kasbah")); err != nil || string(b) != "theirs" {
			t.Errorf("%s: the file behind the link was touched", linked)
		}
	}
}

// No `sudo -n`, but a terminal: destroy waits for the operator to remove the
// pointer, checks, and asks again while anything is left.
func TestRunNosudoWaits(t *testing.T) {
	nosudo := "pointer=nosudo\npointer_dir=nosudo\nbinary=removed\nbin_dir=removed\nkasbah_dir=removed\ndone=yes\n"
	f := &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: nosudo,
		pointer: []string{"pointer=present\npointer_dir=empty\n", "pointer=present\npointer_dir=empty\n", "pointer=absent\npointer_dir=absent\n"}}
	so, se, code := run(t, f, Options{Target: "deploy@vps.example", Yes: true}, true, "\n\n")
	if code != 0 || strings.Count(se, "    sudo rm -f /etc/kasbah/apps-path\n    sudo rmdir /etc/kasbah\n") != 2 ||
		strings.Count(se, "Press Enter") != 2 || strings.Contains(se, "is still there and names") ||
		!strings.Contains(so, "/etc/kasbah/apps-path and /etc/kasbah/ were removed by hand") ||
		!strings.Contains(so, "plain Docker Compose host now") || len(f.pointer) != 0 {
		t.Fatalf("waited: %d %v\n%s\n%s", code, f.calls, so, se)
	}
	// The pointer gone, the offered rmdir skipped, then q: what is left is said,
	// and the block on the terminal is not printed a second time.
	f = &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: nosudo,
		pointer: []string{"pointer=present\npointer_dir=empty\n", "pointer=absent\npointer_dir=empty\n"}}
	so, se, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, true, "\nq\n")
	if code != 0 || !strings.Contains(se, "/etc/kasbah/ on deploy@vps.example is empty and root-owned") ||
		strings.Count(se+so, "sudo rmdir /etc/kasbah") != 2 || strings.Count(se+so, "sudo rm -f") != 1 ||
		!strings.Contains(so, "but for /etc/kasbah/, which is") || strings.Contains(so, "were removed by hand") ||
		!strings.Contains(so, "The commands above finish it.") {
		t.Fatalf("rmdir skipped, then q: %d %v\n%s\n%s", code, f.calls, so, se)
	}
	// A directory holding something else: the pointer alone, and the directory stays.
	f = &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: nosudo,
		pointer: []string{"pointer=present\npointer_dir=dir\n", "pointer=absent\npointer_dir=dir\n"}}
	so, _, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, true, "\n")
	if code != 0 || !strings.Contains(so, "removed by hand; /etc/kasbah/ stays — it holds something kasbah did not write") {
		t.Fatalf("dir kept: %d\n%s", code, so)
	}
	f = &fake{mk: mk(), scan: scanFixture(), actOut: okAct, tailOut: nosudo, pointer: []string{"pointer=present\npointer_dir=empty\n"}}
	so, se, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, true, "q\n")
	if code != 0 || !strings.Contains(so, "one file short") || strings.Count(strings.Join(f.calls, " "), "pointer") != 1 ||
		strings.Count(se+so, "sudo rm -f /etc/kasbah/apps-path") != 1 {
		t.Fatalf("q: %d %v\n%s\n%s", code, f.calls, so, se)
	}
	// No pointer to begin with: nothing about it is promised, failed or waited on.
	sc := scanFixture()
	sc.PointerState, sc.Sudo = "missing", "no"
	nopointer := "pointer=absent\npointer_dir=nosudo\nbinary=removed\nbin_dir=removed\nkasbah_dir=removed\ndone=yes\n"
	f = &fake{mk: mk(), scan: sc, actOut: okAct, tailOut: nopointer, pointer: []string{"pointer=absent\npointer_dir=dir\n"}}
	so, se, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, true, "")
	if code != 0 || strings.Contains(se, "Press Enter") || !strings.Contains(so, "plain Docker Compose host now") ||
		strings.Contains(so, "printed for you to run") || strings.Contains(so, "could NOT remove") ||
		strings.Contains(se, "still there") || !strings.Contains(so, "there was no /etc/kasbah/apps-path") {
		t.Fatalf("no pointer: %d\n%s\n%s", code, so, se)
	}
	// No pointer, but its directory left empty: the rmdir is still the operator's.
	f = &fake{mk: mk(), scan: sc, actOut: okAct, tailOut: nopointer,
		pointer: []string{"pointer=absent\npointer_dir=empty\n", "pointer=absent\npointer_dir=absent\n"}}
	so, se, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, true, "\n")
	if code != 0 || !strings.Contains(se, "    sudo rmdir /etc/kasbah\n") || strings.Contains(se, "sudo rm -f") ||
		!strings.Contains(so, "/etc/kasbah/ was removed by hand") || !strings.Contains(so, "plain Docker Compose host now") {
		t.Fatalf("an empty directory: %d\n%s\n%s", code, so, se)
	}
	f = &fake{mk: mk(), scan: sc, actOut: okAct, tailOut: nopointer, pointer: []string{"pointer=absent\npointer_dir=empty\n"}}
	so, _, code = run(t, f, Options{Target: "deploy@vps.example", Yes: true}, false, "")
	if code != 0 || !strings.Contains(so, "but for /etc/kasbah/, which is") || !strings.Contains(so, "\n      sudo rmdir /etc/kasbah\n") {
		t.Fatalf("an empty directory, no terminal: %d\n%s", code, so)
	}
}

func TestPointerScript(t *testing.T) {
	for _, sh := range shtest.Shells(t) {
		t.Run(sh.Name, func(t *testing.T) { testPointerScript(t, sh) })
	}
}

func testPointerScript(t *testing.T, sh shtest.Shell) {
	dir := t.TempDir() + "/kasbah"
	ptr := dir + "/apps-path"
	probe := func() string {
		out, err := sh.Stdin(pointerScript, ptr).Output()
		if err != nil {
			t.Fatal(err)
		}
		return string(out)
	}
	if got := probe(); got != "pointer=absent\npointer_dir=absent\n" {
		t.Errorf("nothing: %q", got)
	}
	os.Mkdir(dir, 0o755)
	os.WriteFile(ptr, []byte("/apps\n"), 0o644)
	if got := probe(); got != "pointer=present\npointer_dir=empty\n" {
		t.Errorf("present: %q", got)
	}
	os.Remove(ptr)
	if got := probe(); got != "pointer=absent\npointer_dir=empty\n" {
		t.Errorf("an empty directory: %q", got)
	}
	os.WriteFile(dir+"/other", nil, 0o644)
	if got := probe(); got != "pointer=absent\npointer_dir=dir\n" {
		t.Errorf("a directory holding something else: %q", got)
	}
	os.Remove(dir + "/other")
	os.WriteFile(ptr, []byte("/apps\n"), 0o644)
	if os.Geteuid() != 0 {
		os.Chmod(dir, 0o600)
		if got := probe(); got != "pointer=unknown\npointer_dir=dir\n" {
			t.Errorf("behind a wall: %q", got)
		}
		os.Chmod(dir, 0o755)
	}
}

// The DNS providers' credentials leave with kasbah, and compose.yml stops
// naming them so the stack still comes up from its own files.
func TestRemoveAcmeDNS(t *testing.T) {
	apps := t.TempDir()
	if got := removeAcmeDNS(apps); got != "absent" {
		t.Errorf("no credentials: %s", got)
	}
	os.MkdirAll(apps+"/traefik/acme-dns", 0o755)
	os.WriteFile(apps+"/traefik/acme-dns/cloudflare.env", []byte("CF_DNS_API_TOKEN=x\n"), 0o640)
	compose := "services:\n  traefik:\n    volumes:\n      - \"/a:/b\"\n" +
		"    # Each DNS provider's credentials, installed by `kasbah server init --acme-dns=`.\n" +
		"    env_file:\n      - acme-dns/cloudflare.env\n    networks:\n      - kasbah-net\n"
	os.WriteFile(apps+"/traefik/compose.yml", []byte(compose), 0o644)
	if got := removeAcmeDNS(apps); got != "removed" {
		t.Errorf("removal: %s", got)
	}
	b, _ := os.ReadFile(apps + "/traefik/compose.yml")
	if string(b) != "services:\n  traefik:\n    volumes:\n      - \"/a:/b\"\n    networks:\n      - kasbah-net\n" {
		t.Errorf("compose.yml:\n%s", b)
	}
	if _, err := os.Stat(apps + "/traefik/acme-dns"); !os.IsNotExist(err) {
		t.Errorf("still there: %v", err)
	}
}
