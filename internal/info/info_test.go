package info

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
)

func TestParse(t *testing.T) {
	for _, tt := range []struct {
		args   []string
		target string
		err    string
	}{
		{nil, "", ""},
		{[]string{"ops@vps"}, "ops@vps", ""},
		{[]string{"--help"}, "", "help"},
		{[]string{"ops@vps", "-h"}, "", "help"},
		{[]string{"--json"}, "", "info: unknown flag '--json'"},
		{[]string{"a@b", "c@d"}, "", "info: unexpected argument 'c@d'"},
	} {
		o, err := Parse(tt.args)
		switch {
		case tt.err == "" && (err != nil || o.Target != tt.target):
			t.Errorf("%q: %+v, %v", tt.args, o, err)
		case tt.err != "" && (err == nil || !strings.Contains(err.Error(), tt.err)):
			t.Errorf("%q: error %v, want %q", tt.args, err, tt.err)
		}
	}
}

func touch(t *testing.T, p string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte("x"), 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestInstallAndLocate(t *testing.T) {
	d, _ := filepath.EvalSymlinks(t.TempDir())
	lib := filepath.Join(d, "lib", "1.2.3", "kasbah")
	co := filepath.Join(d, "co", "dist", "kasbah")
	other := filepath.Join(d, "opt", "kasbah")
	for _, p := range []string{lib, co, other, filepath.Join(d, "co", "go.mod")} {
		touch(t, p)
	}
	os.MkdirAll(filepath.Join(d, "co", "cmd", "kasbah"), 0o755)
	link := filepath.Join(d, "bin", "kasbah")
	os.MkdirAll(filepath.Dir(link), 0o755)
	if err := os.Symlink(lib, link); err != nil {
		t.Fatal(err)
	}
	for p, want := range map[string]string{lib: "library", link: "library", co: "checkout", other: "other"} {
		if got := Install(p); got != want {
			t.Errorf("Install(%s) = %s, want %s", p, got, want)
		}
	}

	none := func(string) (string, error) { return "", errors.New("not found") }
	onPath := func(string) (string, error) { return link, nil }
	for _, tt := range []struct {
		argv0 string
		look  func(string) (string, error)
		want  Binary
	}{
		{link, none, Binary{link, lib}},
		{"kasbah", onPath, Binary{link, lib}},
		{"kasbah", none, Binary{lib, lib}},
		// argv[0] naming another binary than the one running is not believed.
		{other, none, Binary{lib, lib}},
	} {
		if got := Locate(tt.argv0, lib, tt.look); got != tt.want {
			t.Errorf("Locate(%s) = %+v, want %+v", tt.argv0, got, tt.want)
		}
	}
}

func TestSelf(t *testing.T) {
	d, _ := filepath.EvalSymlinks(t.TempDir())
	bin := filepath.Join(d, "lib", "1.2.3", "kasbah")
	touch(t, bin)
	env := func(k string) string { return map[string]string{"HOME": "/home/u"}[k] }
	var b bytes.Buffer
	Write(&b, Self("1.2.3", "linux", "amd64", Binary{"/home/u/.local/bin/kasbah", bin}, env))
	want := "name: kasbah\nversion: 1.2.3\nbuild: 1.2.3\nos: linux\narch: amd64\n" +
		"binary: /home/u/.local/bin/kasbah\nresolved: " + bin + "\ninstall: library\nlib: " + filepath.Join(d, "lib") +
		"\ndocs: https://github.com/adigourdi/kasbah/tree/v1.2.3/docs\n" +
		"logs: /home/u/.local/state/kasbah/logs\nlogs.last: none\n"
	if b.String() != want {
		t.Errorf("release:\n%s\nwant:\n%s", b.String(), want)
	}

	other := filepath.Join(d, "opt", "kasbah")
	got := Self("1.3.0-dev.4.1700000000+gabc1234", "darwin", "arm64", Binary{other, other}, env)
	m := map[string]string{}
	var keys []string
	for _, f := range got {
		m[f.Key] = f.Value
		keys = append(keys, f.Key)
	}
	if strings.Join(keys, " ") != "name version build os arch binary resolved install lib docs logs logs.last" {
		t.Errorf("keys: %v", keys)
	}
	if m["version"] != "1.3.0-dev" || m["install"] != "other" || m["lib"] != "/home/u/.local/share/kasbah" ||
		m["docs"] != "https://github.com/adigourdi/kasbah/tree/main/docs" {
		t.Errorf("dev build: %v", m)
	}

	m = map[string]string{}
	for _, f := range Self("", "linux", "amd64", Binary{other, other}, func(string) string { return "" }) {
		m[f.Key] = f.Value
	}
	if m["version"] != "unstamped" || m["build"] != "unstamped" || !strings.HasPrefix(m["lib"], "unknown (") ||
		!strings.HasSuffix(m["docs"], "/tree/main/docs") {
		t.Errorf("unstamped: %v", m)
	}

	// The log directory under XDG_STATE_HOME, and the newest log in it.
	state := t.TempDir()
	logs := filepath.Join(state, "kasbah", "logs")
	if err := os.MkdirAll(logs, 0o700); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"20261115T100000.000Z-deploy.log", "20261115T110000.000Z-env-set.log", "notes.txt"} {
		touch(t, filepath.Join(logs, n))
	}
	m = map[string]string{}
	xdg := func(k string) string { return map[string]string{"HOME": "/home/u", "XDG_STATE_HOME": state}[k] }
	for _, f := range Self("1.2.3", "linux", "amd64", Binary{other, other}, xdg) {
		m[f.Key] = f.Value
	}
	if m["logs"] != logs || m["logs.last"] != filepath.Join(logs, "20261115T110000.000Z-env-set.log") {
		t.Errorf("logs: %v", m)
	}
	m = map[string]string{}
	for _, f := range Self("", "linux", "amd64", Binary{other, other}, func(string) string { return "" }) {
		m[f.Key] = f.Value
	}
	if !strings.HasPrefix(m["logs"], "unknown (") || m["logs.last"] != "none" {
		t.Errorf("no HOME: %v", m)
	}
}

func TestPrettyName(t *testing.T) {
	for in, want := range map[string]string{
		"NAME=\"Debian GNU/Linux\"\nPRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"\n": "Debian GNU/Linux 12 (bookworm)",
		"PRETTY_NAME='Alpine Linux v3.20'\r\n":                                        "Alpine Linux v3.20",
		"PRETTY_NAME=Arch\n":                                                          "Arch",
		"PRETTY_NAME=\"say \\\"hi\\\"\"\n":                                            `say "hi"`,
		"NAME=x\n":                                                                    "",
	} {
		if got := PrettyName([]byte(in)); got != want {
			t.Errorf("PrettyName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCollect(t *testing.T) {
	rel := []byte("PRETTY_NAME=\"Ubuntu 24.04 LTS\"\n")
	// A daemon that answers with a warning on stderr: the value is stdout alone.
	docker := func(args ...string) (string, string, int) {
		if args[0] == "compose" {
			return "2.29.7\n", "WARNING: plugin config is world-writable\n", 0
		}
		return "27.3.1\n", "WARNING: bridge-nf-call-iptables is disabled\n", 0
	}
	down := func(args ...string) (string, string, int) {
		if args[0] == "compose" {
			return "2.29.7\n", "", 0
		}
		return "\n", "permission denied while trying to connect to the Docker daemon socket\nmore\n", 1
	}
	silent := func(args ...string) (string, string, int) {
		if args[0] == "compose" {
			return "", "docker: 'compose' is not a docker command.\n", 1
		}
		return "", "", 1
	}
	kv := func(fs []Field) map[string]string {
		var b bytes.Buffer
		for _, f := range fs {
			b.WriteString(f.Key + "=" + f.Value + "\n")
		}
		return remote.KV(b.Bytes())
	}
	m := kv(Collect("1.2.3", "arm64", rel, true, docker))
	if m["build"] != "1.2.3" || m["arch"] != "arm64" || m["os"] != "Ubuntu 24.04 LTS" || m["docker"] != "27.3.1" || m["compose"] != "2.29.7" {
		t.Errorf("docker up, warnings on stderr: %v", m)
	}
	if _, ok := m["docker_error"]; ok {
		t.Errorf("docker up: a docker_error: %v", m)
	}
	m = kv(Collect("1.2.3", "amd64", rel, true, down))
	if m["docker"] != "" || m["docker_error"] != "permission denied while trying to connect to the Docker daemon socket" || m["compose"] != "2.29.7" {
		t.Errorf("daemon down: %v", m)
	}
	m = kv(Collect("1.2.3", "amd64", rel, true, silent))
	if m["docker"] != "" || m["docker_error"] != "docker exited 1" || m["compose"] != "" {
		t.Errorf("silent failure: %v", m)
	}
	fs := Collect("1.2.3", "amd64", nil, false, nil)
	m = kv(fs)
	if m["docker"] != "" || m["compose"] != "" || m["os"] != "" || len(fs) != 5 {
		t.Errorf("no docker: %v", fs)
	}
	if _, ok := m["docker_error"]; ok {
		t.Errorf("no docker: a docker_error: %v", m)
	}
}

func inspection(marker bool, bin *remote.Info, present bool) *serverbin.Inspection {
	p := &serverbin.Probe{Apps: "/apps", Source: "default", Marker: marker, Machine: "x86_64"}
	if marker {
		p.MarkerBody = []byte(`{"kasbah_version": "1.2.3", "apps_path": "/apps", "data_path": "/apps/data", "cpu_limit": "2", "mem_limit": "2g"}`)
	}
	p.Bin.Present = present
	return &serverbin.Inspection{Probe: p, Bin: bin}
}

func fields(fs []Field) map[string]string {
	m := map[string]string{}
	for _, f := range fs {
		m[f.Key] = f.Value
	}
	return m
}

func TestServer(t *testing.T) {
	self := remote.Self("1.2.3")
	never := func(string) ([]byte, error) { t.Error("remote info run on another build"); return nil, nil }

	fs, notes, err := Server("ops@vps", self, inspection(false, nil, false), never)
	m := fields(fs)
	all := strings.Join(notes, "\n")
	if err != nil || m["server.kasbah"] != "none" || m["server.prepared"] != "no" || m["server.arch"] != "amd64" ||
		m["server.apps"] != "/apps (default)" || m["server.os"] != "unknown" ||
		!strings.Contains(notes[0], "has no kasbah") || !strings.Contains(notes[0], "changes nothing") ||
		!strings.Contains(all, serverbin.NoMarker("ops@vps", inspection(false, nil, false).Probe).Error()) ||
		strings.Contains(all, "init ops@vps") || strings.Contains(all, "ships this build") {
		t.Errorf("absent, no marker: %v %q %v", m, notes, err)
	}

	in := inspection(true, nil, true)
	in.BinErr = cli.Fail("it hangs").Cont("look at it")
	fs, notes, _ = Server("ops@vps", self, in, never)
	if fields(fs)["server.kasbah"] != "unknown" || len(notes) != 4 || notes[0] != "it hangs" || notes[1] != "look at it" ||
		!strings.Contains(notes[3], "does not replace that binary") || strings.Contains(strings.Join(notes, "\n"), "ships") {
		t.Errorf("unaccounted: %v %q", fs, notes)
	}

	nb := inspection(false, nil, true)
	nb.Probe.Source, nb.Probe.Apps = "pointer", "/srv/apps"
	_, notes, _ = Server("ops@vps", self, nb, never)
	if all := strings.Join(notes, "\n"); !strings.Contains(all, "says this server was prepared at /srv/apps") || strings.Contains(all, "ships") {
		t.Errorf("pointer, no marker: %q", notes)
	}
}

func TestNext(t *testing.T) {
	self := remote.Self("1.2.3")
	next := func(self remote.Info, in *serverbin.Inspection) string {
		return strings.Join(Next("ops@vps", self, in), "\n")
	}
	for _, tt := range []struct {
		name string
		self remote.Info
		in   *serverbin.Inspection
		want []string
		not  []string
	}{
		{"absent", self, inspection(true, nil, false),
			[]string{"the next command that reaches the server, such as `kasbah server status ops@vps`, ships this build"}, []string{"asks", "stops"}},
		{"not runnable", self, inspection(true, nil, true), []string{"ships this build"}, []string{"stops"}},
		{"older", self, inspection(true, &remote.Info{Build: "1.2.2"}, true), []string{"ships this build"}, []string{"asks", "stops"}},
		{"dev over release", remote.Self("1.3.0-dev.2.1+gabc1234"), inspection(true, &remote.Info{Build: "1.2.9"}, true),
			[]string{"asks before it ships this dev build over release 1.2.9", "--ship-dev", "--keep-server"}, []string{"stops"}},
		{"newer", self, inspection(true, &remote.Info{Build: "1.4.0"}, true),
			[]string{"stops there", "the server runs kasbah 1.4.0, newer than this kasbah 1.2.3", "hands the run to kasbah 1.4.0 when that build is installed"}, []string{"ships"}},
		{"newer major", self, inspection(true, &remote.Info{Build: "2.0.0"}, true),
			[]string{"stops there", "a newer major than this kasbah 1.2.3"}, []string{"ships", "hands the run"}},
		{"not a version", self, inspection(true, &remote.Info{Build: "banana"}, true),
			[]string{"stops there", "reports build 'banana', which is not a version"}, []string{"ships"}},
		{"unstamped", remote.Self(""), inspection(true, nil, false),
			[]string{"stops there", "build stamp is '', which is not a version", "docker compose run --rm build"}, []string{"ships"}},
		{"unstamped, a binary", remote.Self(""), inspection(true, &remote.Info{Build: "1.2.3"}, true),
			[]string{"build stamp is ''"}, []string{"ships"}},
	} {
		got := next(tt.self, tt.in)
		for _, w := range tt.want {
			if !strings.Contains(got, w) {
				t.Errorf("%s: %q lacks %q", tt.name, got, w)
			}
		}
		for _, n := range tt.not {
			if strings.Contains(got, n) {
				t.Errorf("%s: %q has %q", tt.name, got, n)
			}
		}
	}

	in := inspection(true, nil, false)
	in.Probe.MarkerBody = []byte(`{"kasbah_version": "2.0.0"}`)
	if got := next(self, in); !strings.Contains(got, "was written by kasbah 2.0.0") || strings.Contains(got, "ships") {
		t.Errorf("marker of a newer major: %q", got)
	}
	in = inspection(true, nil, false)
	in.Probe.MarkerUnreadable = true
	if got := next(self, in); !strings.Contains(got, "could not be read") || strings.Contains(got, "ships") {
		t.Errorf("unreadable marker: %q", got)
	}
	// An empty marker, or one that is not an object, is the refusal status gives.
	for body, want := range map[string]string{
		"":    "/apps/.kasbah/server.json on ops@vps is empty — kasbah server init did not finish, or something truncated it\nRemove it and re-run `kasbah server init ops@vps` to write it again.",
		"[1]": "is not a JSON object\nLook at it before running anything else against this server (`ssh ops@vps cat /apps/.kasbah/server.json`);",
		"{":   "is not a JSON object: unexpected end of JSON input",
	} {
		in = inspection(true, nil, false)
		in.Probe.MarkerBody = []byte(body)
		if got := next(self, in); !strings.Contains(got, "stops there") || !strings.Contains(got, want) || strings.Contains(got, "ships") {
			t.Errorf("marker %q: %q", body, got)
		}
	}
	// A marker the commands' own reading refuses is that refusal, not a ship.
	in = inspection(true, nil, false)
	in.Probe.MarkerBody = []byte(`{"kasbah_version": "1.2.3", "apps_path": "apps", "data_path": "/apps/data", "cpu_limit": "2", "mem_limit": "2g"}`)
	if got := next(self, in); !strings.Contains(got, "both must be absolute paths") || strings.Contains(got, "ships") {
		t.Errorf("relative apps_path: %q", got)
	}
	// An apps path that is not a directory is refused before the marker is looked for.
	in = inspection(false, nil, false)
	in.Probe.AppsNotDir = true
	if got := next(self, in); !strings.Contains(got, serverbin.AppsNotDir("ops@vps", "/apps").Error()) || strings.Contains(got, "has no server marker") {
		t.Errorf("apps path not a directory: %q", got)
	}
	in = inspection(true, nil, false)
	in.Probe.Machine = "riscv64"
	if got := next(self, in); !strings.Contains(got, "stops there") || strings.Contains(got, "ships") {
		t.Errorf("no build for the machine: %q", got)
	}
	if got := Next("ops@vps", self, inspection(true, &remote.Info{Build: "1.2.3"}, true)); got != nil {
		t.Errorf("same build: %q", got)
	}

	// The same build reads the server; the facts arm is never run otherwise.
	fs, notes, err := Server("ops@vps", remote.Self(""), inspection(true, &remote.Info{Build: "1.2.3"}, true),
		func(string) ([]byte, error) { t.Error("remote info run from an unstamped build"); return nil, nil })
	if err != nil || fields(fs)["server.os"] != "unknown" || !strings.Contains(strings.Join(notes, "\n"), "build stamp is ''") {
		t.Errorf("unstamped: %v %q %v", fs, notes, err)
	}
}

func TestServerRead(t *testing.T) {
	self := remote.Self("1.2.3")
	var ran string
	read := func(bin string) ([]byte, error) {
		ran = bin
		return []byte("build=1.2.3+gdead\narch=amd64\nos=Debian GNU/Linux 12 (bookworm)\ndocker=29.7.2\ncompose=5.4.0\nlater=x\n"), nil
	}
	fs, notes, err := Server("ops@vps", self, inspection(true, &remote.Info{Build: "1.2.3+gdead"}, true), read)
	m := fields(fs)
	var keys []string
	for _, f := range fs {
		keys = append(keys, f.Key)
	}
	if err != nil || len(notes) != 0 || ran != "/apps/.kasbah/bin/kasbah" || m["server.kasbah"] != "1.2.3+gdead" ||
		m["server.os"] != "Debian GNU/Linux 12 (bookworm)" || m["server.docker"] != "29.7.2" || m["server.compose"] != "5.4.0" ||
		strings.Join(keys, " ") != "server server.apps server.prepared server.kasbah server.arch server.os server.docker server.compose" {
		t.Errorf("same build: %v %q %v", fs, notes, err)
	}

	read = func(string) ([]byte, error) {
		return []byte("build=1.2.3\nos=x\ndocker=\ndocker_error=denied\ncompose=\n"), nil
	}
	m = fields(must(Server("ops@vps", self, inspection(true, &remote.Info{Build: "1.2.3"}, true), read)))
	if m["server.docker"] != "unknown (denied)" || m["server.compose"] != "none" {
		t.Errorf("docker down: %v", m)
	}
	// What Collect reports with no docker on PATH.
	var b bytes.Buffer
	for _, f := range Collect("1.2.3", "amd64", nil, false, nil) {
		b.WriteString(f.Key + "=" + f.Value + "\n")
	}
	read = func(string) ([]byte, error) { return b.Bytes(), nil }
	m = fields(must(Server("ops@vps", self, inspection(true, &remote.Info{Build: "1.2.3"}, true), read)))
	if m["server.docker"] != "none" || m["server.compose"] != "none" || m["server.os"] != "unknown" {
		t.Errorf("no docker: %v", m)
	}

	read = func(string) ([]byte, error) { return nil, errors.New("it exited 1") }
	fs, _, err = Server("ops@vps", self, inspection(true, &remote.Info{Build: "1.2.3"}, true), read)
	if err == nil || fields(fs)["server.os"] != "unknown" {
		t.Errorf("failed read: %v %v", fs, err)
	}
	read = func(string) ([]byte, error) { return []byte("remote: unknown subcommand\n"), nil }
	if _, _, err = Server("ops@vps", self, inspection(true, &remote.Info{Build: "1.2.3"}, true), read); err == nil {
		t.Error("an answer with no build= was taken")
	}
}

func must(fs []Field, _ []string, err error) []Field {
	if err != nil {
		panic(err)
	}
	return fs
}

func TestRun(t *testing.T) {
	var so, se bytes.Buffer
	c := Ctx{Out: &cli.Output{Stdout: &so, Stderr: &se}, Build: "1.2.3", GOOS: "linux", GOARCH: "amd64",
		Binary: Binary{"/x/kasbah", "/x/kasbah"}, Getenv: func(string) string { return "/h" },
		Inspect: func(string) (*serverbin.Inspection, func(string) ([]byte, error), func(), error) {
			return nil, nil, nil, cli.Failf(cli.ExitSSHUnreachable, "cannot reach")
		}}
	if err := Run(c, Options{}); err != nil || !strings.HasPrefix(so.String(), "name: kasbah\n") || se.Len() != 0 {
		t.Errorf("no host: %v %q %q", err, so.String(), se.String())
	}
	so.Reset()
	err := Run(c, Options{Target: "ops@vps"})
	if err == nil || !strings.Contains(so.String(), "\ndocs: ") || strings.Contains(so.String(), "server") {
		t.Errorf("unreachable: %v %q", err, so.String())
	}
}
