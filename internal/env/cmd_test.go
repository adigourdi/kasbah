package env

import (
	"bytes"
	"fmt"
	"os"
	"strings"
	"syscall"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/resources"
	"github.com/adigourdi/kasbah/internal/state"
)

// The cases of tests/env_cmd_test.sh, against a fake server: which calls the
// command makes, in which order, and how each answer ends the run.

type fakeServer struct {
	calls     []string
	markerErr error
	shipErr   error
	reports   []string // Drift answers in turn; the last repeats
	setupRC   int
	injectRC  int
	injected  []string
	limitsRC  int
}

func report(tmpl, env, missing, extra string) string {
	return "template_exists=" + tmpl + "\nenv_exists=" + env + "\nmissing=" + missing + "\nextra=" + extra + "\n"
}

func (f *fakeServer) Marker() (*marker.Marker, error) {
	f.calls = append(f.calls, "marker")
	if f.markerErr != nil {
		return nil, f.markerErr
	}
	return &marker.Marker{AppsPath: "/apps", DataPath: "/apps/data", CPULimit: "14.4", MemLimit: "54g"}, nil
}
func (f *fakeServer) Prepare(dir string) error { f.calls = append(f.calls, "prepare "+dir); return nil }
func (f *fakeServer) ShipTemplate(local, dir string) error {
	f.calls = append(f.calls, "ship "+local+" "+dir)
	return f.shipErr
}
func (f *fakeServer) Drift(dir string) (string, int) {
	f.calls = append(f.calls, "drift "+dir)
	r := f.reports[0]
	if len(f.reports) > 1 {
		f.reports = f.reports[1:]
	}
	return r, 0
}
func (f *fakeServer) Setup(dir string, color bool) int {
	f.calls = append(f.calls, "setup "+dir)
	return f.setupRC
}
func (f *fakeServer) Inject(dir string, pairs []string) int {
	f.calls = append(f.calls, "inject "+dir)
	f.injected = pairs
	return f.injectRC
}

// Limits resolves as the server binary does, on a 16-core host with 60 GiB,
// whose marker reads 14.4 / 54g.
func (f *fakeServer) Limits(cpus, memory string) (string, int) {
	f.calls = append(f.calls, "limits "+cpus+" "+memory)
	if f.limitsRC != 0 {
		return "", f.limitsRC
	}
	spec := resources.Spec{CPUs: strings.TrimPrefix(cpus, "-"), Memory: strings.TrimPrefix(memory, "-")}
	cpu, mem, err := resources.Resolve(spec, 16, 62914560)
	if err != nil {
		return "", 1
	}
	out := "host_cores=16\nhost_mem_kb=62914560\n"
	if cpu != "" {
		out += "cpu=" + cpu + "\n"
	}
	if mem != "" {
		out += "mem=" + mem + "\n"
	}
	return out, 0
}
func (f *fakeServer) Close() {}

func (f *fakeServer) called(prefix string) int {
	for i, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return i
		}
	}
	return -1
}

type run struct {
	code   int
	stderr string
	srv    *fakeServer
	dialed bool
}

func project(t *testing.T, withTemplate bool) {
	t.Helper()
	dir := t.TempDir()
	t.Chdir(dir)
	write(t, "kasbah.yml", "schema: 1\nkasbah_version: 0.1.0\nname: demo\ndomain: demo.test\nsync:\n  - .env.prod.example\n")
	if withTemplate {
		write(t, ".env.prod.example", "A=1\n")
	}
}

func runEnv(t *testing.T, srv *fakeServer, tty bool, input string, args ...string) run {
	t.Helper()
	var stderr bytes.Buffer
	out := &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &stderr}
	r := run{srv: srv}
	o, err := Parse(args)
	if err != nil {
		r.code = out.Report(err)
		r.stderr = stderr.String()
		return r
	}
	pwd, _ := os.Getwd()
	err = Run(Ctx{
		Out:      out,
		Prompter: &prompt.Prompter{In: strings.NewReader(input), Out: out, TTY: tty},
		PWD:      pwd, Version: "0.1.0", TTYIn: tty, TTYOut: tty,
		Dial: func(string) (Session, error) { r.dialed = true; return srv, nil },
	}, o)
	r.code = out.Report(err)
	r.stderr = stderr.String()
	return r
}

func lastServer(t *testing.T) string {
	v, err := state.Get(state.File, "last_server")
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func expect(t *testing.T, ok bool, format string, a ...any) {
	t.Helper()
	if !ok {
		t.Errorf(format, a...)
	}
}

func inSync() *fakeServer { return &fakeServer{reports: []string{report("yes", "yes", "", "")}} }
func drifted() *fakeServer {
	return &fakeServer{reports: []string{report("yes", "yes", "NEW_KEY", "")}}
}

func TestLocalRefusals(t *testing.T) {
	t.Chdir(t.TempDir())
	r := runEnv(t, inSync(), false, "", "deploy@vps")
	expect(t, r.code == cli.ExitNoProject && strings.Contains(r.stderr, "No kasbah.yml") && !r.dialed,
		"outside a project: %d %q dialed=%v", r.code, r.stderr, r.dialed)

	project(t, true)
	r = runEnv(t, inSync(), false, "")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "last_server") && !r.dialed, "no target: %d %q", r.code, r.stderr)

	project(t, false)
	r = runEnv(t, inSync(), false, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, ".env.prod.example") && !r.dialed, "no template: %d %q", r.code, r.stderr)

	for _, c := range []struct{ args, want []string }{
		{[]string{"--on-drift=maybe"}, []string{"setup, continue or abort"}},
		{[]string{"--on-drift"}, []string{"--on-drift=setup"}},
		{[]string{"--nonsense=1"}, []string{"unknown flag", "'--nonsense'"}},
		{[]string{"a@b", "extra-arg"}, []string{"too many arguments", "extra-arg"}},
	} {
		r = runEnv(t, inSync(), false, "", c.args...)
		for _, w := range c.want {
			expect(t, r.code == 1 && strings.Contains(r.stderr, w) && !r.dialed, "%v: %d %q, want %q", c.args, r.code, r.stderr, w)
		}
	}
	if _, err := Parse([]string{"--help"}); err != ErrHelp || !strings.Contains(Usage(), "--on-drift=continue") {
		t.Errorf("--help: %v", err)
	}
}

func TestServerRefusals(t *testing.T) {
	project(t, true)
	srv := inSync()
	srv.markerErr = cli.Failf(cli.ExitNoRemoteState, "deploy@vps has no server marker at /apps/.kasbah/server.json")
	r := runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == cli.ExitNoRemoteState && srv.called("ship") < 0, "no marker: %d %v", r.code, srv.calls)

	srv = inSync()
	srv.shipErr = cli.Fail("could not ship .env.prod.example to deploy@vps:/apps/demo/")
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && srv.called("drift") < 0, "a failed transfer stops the run: %d %v", r.code, srv.calls)

	srv = &fakeServer{reports: []string{"template_exists=yes\nenv_exists=yes\n"}}
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "reported no missing extra") && strings.Contains(r.stderr, "| env_exists=yes"),
		"a truncated report is refused with its raw output: %d %q", r.code, r.stderr)

	srv = &fakeServer{reports: []string{report("no", "no", "", "")}}
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "sync:") && srv.called("setup") < 0,
		"no .env and no template: %d %q", r.code, r.stderr)

	srv = &fakeServer{reports: []string{report("no", "yes", "", "A")}}
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "cannot be checked for drift") && srv.called("inject") < 0,
		"env with no template on the server: %d %q", r.code, r.stderr)
	expect(t, lastServer(t) == "", "a failed run records no last_server")
}

func TestHeadless(t *testing.T) {
	project(t, true)
	srv := inSync()
	r := runEnv(t, srv, false, "", "deploy@vps")
	expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "no terminal"), "headless: %d %q", r.code, r.stderr)
	expect(t, srv.called("setup") < 0 && srv.called("inject") < 0, "headless runs nothing: %v", srv.calls)
	expect(t, !strings.Contains(r.stderr, "--on-drift") && strings.Contains(r.stderr, "already in sync"),
		"the remedy is one that reaches this branch: %q", r.stderr)
	expect(t, lastServer(t) == "", "a failed run records no last_server")

	srv = &fakeServer{reports: []string{report("yes", "no", "", "")}}
	r = runEnv(t, srv, false, "", "deploy@vps", "--on-drift=continue")
	expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "does not exist yet") && strings.Contains(r.stderr, "cp /apps/demo/.env.prod.example"),
		"a missing .env is not answered by --on-drift: %d %q", r.code, r.stderr)

	srv = drifted()
	r = runEnv(t, srv, false, "", "deploy@vps", "--on-drift=continue")
	expect(t, r.code == 0 && strings.Contains(r.stderr, "has drifted") && srv.called("setup") < 0, "continue: %d %q %v", r.code, r.stderr, srv.calls)
	expect(t, strings.Join(srv.injected, " ") == "KASBAH_CPU_LIMIT=14.4 KASBAH_MEM_LIMIT=54g", "the marker's limits, as spelled: %v", srv.injected)
	expect(t, lastServer(t) == "deploy@vps", "a run that worked records last_server")
	p, s, d, i := srv.called("prepare /apps/demo"), srv.called("ship .env.prod.example /apps/demo"), srv.called("drift"), srv.called("inject")
	expect(t, 0 <= p && p < s && s < d && d < i, "prepare, ship, drift, inject in order: %v", srv.calls)
	os.RemoveAll(".kasbah")

	srv = drifted()
	r = runEnv(t, srv, false, "", "deploy@vps", "--on-drift=abort")
	expect(t, r.code == cli.ExitEnvSetup && srv.called("inject") < 0 && lastServer(t) == "", "abort: %d %v", r.code, srv.calls)

	srv = drifted()
	r = runEnv(t, srv, false, "", "deploy@vps")
	expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "--on-drift=continue"), "drift with no flag, no terminal: %d %q", r.code, r.stderr)
}

func TestOnATerminal(t *testing.T) {
	project(t, true)
	srv := inSync()
	r := runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 0, "env on a terminal: %d %q", r.code, r.stderr)
	s, i := srv.called("setup /apps/demo"), srv.called("inject")
	expect(t, 0 <= s && s < i, "setup runs, then injection: %v", srv.calls)
	os.RemoveAll(".kasbah")

	for _, rc := range []int{-1, 1, 124, 126, 127, 130, 137, 143, 255} {
		srv = inSync()
		srv.setupRC = rc
		r = runEnv(t, srv, true, "", "deploy@vps")
		expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "could not run at all") && srv.called("inject") < 0,
			"setup exit %d: %d %q", rc, r.code, r.stderr)
		expect(t, rc != -1 || strings.Contains(r.stderr, "ssh could not run, or was killed by a signal") && !strings.Contains(r.stderr, "-1"),
			"exit -1 is said as ssh's failure: %q", r.stderr)
		// Setup has no time limit: no status of it is a timeout.
		expect(t, rc == -1 || strings.Contains(r.stderr, fmt.Sprintf("it exited %d", rc)) && !strings.Contains(r.stderr, "within"),
			"setup exit %d is said as its status: %q", rc, r.stderr)
	}

	srv = &fakeServer{reports: []string{report("yes", "yes", "", ""), report("yes", "no", "", "")}}
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "left no /apps/demo/.env") && srv.called("inject") < 0,
		"a setup that wrote nothing: %d %q", r.code, r.stderr)

	srv = &fakeServer{reports: []string{report("yes", "yes", "", ""), report("yes", "yes", "X", "")}}
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 0 && strings.Contains(r.stderr, "still differs"), "still drifted after setup: %d %q", r.code, r.stderr)
}

func TestDriftPrompt(t *testing.T) {
	project(t, true)
	cases := []struct {
		in    string
		code  int
		setup bool
	}{
		{"continue\n", 0, false},
		{"abort\n", cli.ExitEnvSetup, false},
		{"setup\n", 0, true},
		{"\nsetup\n", 0, true},
	}
	for _, c := range cases {
		srv := drifted()
		r := runEnv(t, srv, true, c.in, "deploy@vps")
		expect(t, r.code == c.code && strings.Contains(r.stderr, "setup/continue/abort"), "%q: %d %q", c.in, r.code, r.stderr)
		expect(t, (srv.called("setup") >= 0) == c.setup, "%q: setup ran=%v", c.in, srv.called("setup") >= 0)
		expect(t, (srv.called("inject") >= 0) == (c.code == 0), "%q: inject %v", c.in, srv.calls)
		os.RemoveAll(".kasbah")
	}

	srv := drifted()
	r := runEnv(t, srv, true, "yes\nabort\n", "deploy@vps")
	expect(t, r.code == cli.ExitEnvSetup && strings.Contains(r.stderr, "answer setup, continue or abort") &&
		strings.Count(r.stderr, "setup/continue/abort") == 2, "an unrecognised answer is re-asked once: %d %q", r.code, r.stderr)

	srv = drifted()
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "no answer given"), "EOF at the prompt is prompt.go's give-up: %d %q", r.code, r.stderr)

	srv = drifted()
	r = runEnv(t, srv, true, "", "deploy@vps", "--on-drift=continue")
	expect(t, r.code == 0 && !strings.Contains(r.stderr, "setup/continue/abort"), "the flag wins: %d %q", r.code, r.stderr)
}

func TestInjectFailureIsExit1(t *testing.T) {
	project(t, true)
	srv := drifted()
	srv.injectRC = 1
	r := runEnv(t, srv, false, "", "deploy@vps", "--on-drift=continue")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "managed block") && lastServer(t) == "", "inject failure: %d %q", r.code, r.stderr)
}

func TestResources(t *testing.T) {
	withResources := func(block string) {
		project(t, true)
		write(t, "kasbah.yml", "schema: 1\nkasbah_version: 0.1.0\nname: demo\ndomain: demo.test\nsync:\n  - .env.prod.example\n"+block)
	}
	pairs := func(srv *fakeServer) string { return strings.Join(srv.injected, " ") }

	project(t, true)
	srv := inSync()
	r := runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 0 && srv.called("limits") < 0 && pairs(srv) == "KASBAH_CPU_LIMIT=14.4 KASBAH_MEM_LIMIT=54g",
		"unset keeps the marker's ceilings: %d %v %q", r.code, srv.calls, pairs(srv))

	withResources("resources:\n  cpus: 50%\n  memory: 2g\n")
	srv = inSync()
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 0 && pairs(srv) == "KASBAH_CPU_LIMIT=8.0 KASBAH_MEM_LIMIT=2g", "resolved: %d %q %q", r.code, pairs(srv), r.stderr)
	expect(t, srv.called("limits 50% 2g") == 1 && srv.called("prepare") == 2, "resolved first, before anything is written: %v", srv.calls)

	withResources("resources:\n  memory: 10%\n")
	srv = inSync()
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 0 && pairs(srv) == "KASBAH_CPU_LIMIT=14.4 KASBAH_MEM_LIMIT=6g", "half set: %d %q", r.code, pairs(srv))

	withResources("resources:\n  memory: 95%\n")
	srv = inSync()
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "resources.memory '95%' comes to 57g on deploy@vps") &&
		strings.Contains(r.stderr, "ceiling of 54g") && srv.called("prepare") < 0 && srv.called("inject") < 0 && lastServer(t) == "",
		"above the ceiling: %d %q %v", r.code, r.stderr, srv.calls)

	withResources("resources:\n  cpus: 15\n")
	srv = inSync()
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "resources.cpus '15' comes to 15.0") && strings.Contains(r.stderr, "ceiling of 14.4"),
		"cores above the ceiling: %d %q", r.code, r.stderr)

	withResources("resources:\n  memory: 512\n")
	r = runEnv(t, inSync(), false, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "m, g or %") && !r.dialed, "a bare memory: %d %q", r.code, r.stderr)

	withResources("resources:\n  cpus: 1\n")
	srv = inSync()
	srv.limitsRC = 1
	r = runEnv(t, srv, true, "", "deploy@vps")
	expect(t, r.code == 1 && strings.Contains(r.stderr, "setup-env limits") && srv.called("prepare") < 0, "a failed resolve: %d %q", r.code, r.stderr)
}

func TestResolveLenient(t *testing.T) {
	var stderr bytes.Buffer
	out := &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &stderr}
	mk := &marker.Marker{CPULimit: "14.4", MemLimit: "54g"}
	l, err := Resolve(out, inSync(), "deploy@vps", resources.Spec{CPUs: "2", Memory: "95%"}, mk, true)
	expect(t, err == nil && l.CPU == "2.0" && l.Mem == "54g" && l.Source == "cpus from kasbah.yml resources, memory from the server marker" &&
		strings.Contains(stderr.String(), "taking the ceiling"), "a tag over the ceiling: %+v %v %q", l, err, stderr.String())

	stderr.Reset()
	srv := inSync()
	srv.limitsRC = 1
	l, err = Resolve(out, srv, "deploy@vps", resources.Spec{Memory: "1%"}, mk, true)
	expect(t, err == nil && l.CPU == "14.4" && l.Mem == "54g" && l.Source == "from the server marker" &&
		strings.Contains(stderr.String(), "taking the server's ceilings"), "a tag whose resolve fails: %+v %v %q", l, err, stderr.String())

	_, err = Resolve(out, inSync(), "deploy@vps", resources.Spec{Memory: "90%"}, &marker.Marker{CPULimit: "14.4", MemLimit: "50g"}, false)
	expect(t, err != nil && strings.Contains(err.Error(), "ceiling of 50g") && strings.Contains(err.Error(), "re-run it"),
		"above a ceiling measured on a smaller host: %v", err)
}

func TestManagedLimits(t *testing.T) {
	p := t.TempDir() + "/.env"
	write(t, p, "KASBAH_CPU_LIMIT=9\nSECRET=x\n"+ManagedBegin+"\r\nKASBAH_CPU_LIMIT=2.0\r\nKASBAH_MEM_LIMIT=1g\n"+ManagedEnd+"\n")
	cpu, mem, ok := ManagedLimits(p)
	expect(t, ok && cpu == "2.0" && mem == "1g", "managed block: %q %q %v", cpu, mem, ok)
	if _, _, ok := ManagedLimits(p + ".missing"); ok {
		t.Error("a missing .env read")
	}
	fifo := t.TempDir() + "/.env"
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, _, ok := ManagedLimits(fifo); ok {
		t.Error("a FIFO .env read")
	}
}

func TestRemoteModes(t *testing.T) {
	dir := t.TempDir()
	var out, errw bytes.Buffer
	if rc := Remote([]string{"prepare", dir + "/demo"}, nil, &out, &errw); rc != 0 || out.String() != "prepared=yes\n" {
		t.Errorf("prepare: %d %q %q", rc, out.String(), errw.String())
	}
	if rc := Remote([]string{"prepare", dir + "/no/such"}, nil, &out, &errw); rc != 1 {
		t.Errorf("prepare under a missing apps path: %d", rc)
	}
	write(t, dir+"/demo/.env.prod.example", "A=1\n")
	out.Reset()
	if rc := Remote([]string{"drift", dir + "/demo"}, nil, &out, &errw); rc != 0 || out.String() != report("yes", "no", "A", "") {
		t.Errorf("drift: %d %q", rc, out.String())
	}
	if rc := Remote([]string{"inject", dir + "/demo", "KASBAH_A=1"}, nil, &out, &errw); rc != 0 {
		t.Errorf("inject: %d", rc)
	}
	out.Reset()
	if rc := Remote([]string{"limits", "100%", "6m"}, nil, &out, &errw); rc != 0 || !strings.Contains(out.String(), "host_cores=") ||
		!strings.Contains(out.String(), "\ncpu=") || !strings.Contains(out.String(), "\nmem=6m\n") {
		t.Errorf("limits: %d %q", rc, out.String())
	}
	errw.Reset()
	if rc := Remote([]string{"limits", "-", "512"}, nil, &out, &errw); rc != 1 || !strings.Contains(errw.String(), "m, g or %") {
		t.Errorf("limits with a bare memory: %d %q", rc, errw.String())
	}
	for _, args := range [][]string{nil, {"drift"}, {"bogus", dir}, {"drift", dir, "extra"}, {"limits", "1"}} {
		errw.Reset()
		if rc := Remote(args, nil, &out, &errw); rc != 1 || !strings.Contains(errw.String(), "usage") {
			t.Errorf("%v: %d %q", args, rc, errw.String())
		}
	}
}

// A terminal on stdin with stdout on a file cannot show the setup's prompts
// either: the run stops with exit 5, as a headless one does.
func TestStdoutRedirected(t *testing.T) {
	project(t, true)
	srv := inSync()
	var stderr bytes.Buffer
	out := &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &stderr}
	o, _ := Parse([]string{"deploy@vps"})
	pwd, _ := os.Getwd()
	err := Run(Ctx{
		Out:      out,
		Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: out, TTY: true},
		PWD:      pwd, Version: "0.1.0", TTYIn: true, TTYOut: false,
		Dial: func(string) (Session, error) { return srv, nil },
	}, o)
	code := out.Report(err)
	expect(t, code == cli.ExitEnvSetup && strings.Contains(stderr.String(), "no terminal"), "stdout redirected: %d %q", code, stderr.String())
	expect(t, srv.called("setup") < 0 && srv.called("inject") < 0, "runs nothing: %v", srv.calls)
}
