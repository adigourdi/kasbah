package ops

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/state"
)

func TestParse(t *testing.T) {
	cases := []struct {
		cmd  string
		args []string
		want string // target|service|follow|tail|cmd, or "err:<needle>"
	}{
		{"logs", nil, "||false|100|"},
		{"logs", []string{"web"}, "|web|false|100|"},
		{"logs", []string{"deploy@vps"}, "deploy@vps||false|100|"},
		{"logs", []string{"web", "deploy@vps\r", "-f", "--tail=all"}, "deploy@vps|web|true|all|"},
		{"logs", []string{"--tail=3"}, "||false|3|"},
		{"logs", []string{"--tail=x"}, "err:is not a number of lines"},
		{"logs", []string{"--tail="}, "err:is not a number of lines"},
		{"logs", []string{"--tail", "3"}, "err:takes its value with '='"},
		{"logs", []string{"-f=1"}, "err:-f takes no value"},
		{"logs", []string{"a@b", "c@d"}, "err:two servers given ('a@b' and 'c@d')"},
		{"logs", []string{"web", "db"}, "err:two services given ('web' and 'db')"},
		{"logs", []string{"--", "ls"}, "err:logs runs none"},
		{"logs", []string{"--follow"}, "err:unknown flag '--follow'"},
		{"exec", []string{"web", "--", "ls", "-la", "--", "a b"}, "|web|false|100|ls -la -- a b"},
		{"exec", []string{"deploy@vps", "web", "--", "true"}, "deploy@vps|web|false|100|true"},
		{"exec", []string{"web", "ls"}, "err:'ls' comes after the service 'web', and there is no '--' between them"},
		{"exec", []string{"web"}, "err:no '--' in the arguments"},
		{"exec", []string{"deploy@vps", "--", "true"}, "err:no service given"},
		{"exec", []string{"web", "--"}, "err:nothing after the '--'"},
		{"exec", []string{"web", "-la"}, "err:unknown flag '-la'"},
		{"exec", []string{"web", "-f"}, "err:unknown flag '-f'"},
	}
	for _, c := range cases {
		o, err := Parse(c.cmd, c.args)
		var got string
		if err != nil {
			got = "err:" + err.Error()
			if strings.HasPrefix(c.want, "err:") && strings.Contains(got, strings.TrimPrefix(c.want, "err:")) {
				continue
			}
		} else {
			got = strings.Join([]string{o.Target, o.Service, map[bool]string{true: "true", false: "false"}[o.Follow], o.Tail, strings.Join(o.Command, " ")}, "|")
		}
		if got != c.want {
			t.Errorf("%s %q: got %q, want %q", c.cmd, c.args, got, c.want)
		}
	}
	if e, _ := Parse("exec", []string{"web", "-la"}); e.Service != "web" {
		t.Error("the service is kept for the hint")
	}
	if _, err := Parse("exec", []string{"you@vps", "web", "ls"}); err == nil || !strings.Contains(err.Error(), "kasbah exec you@vps web -- ls …") {
		t.Errorf("the hint names the server too: %v", err)
	}
	if _, err := Parse("logs", []string{"-h"}); err != ErrHelp {
		t.Error("-h is help")
	}
}

type fake struct {
	rc        int
	tty       bool
	words     []string
	mkErr     error
	streamErr error
}

func (f *fake) Marker() (*marker.Marker, error) {
	if f.mkErr != nil {
		return nil, f.mkErr
	}
	return &marker.Marker{AppsPath: "/srv/apps", DataPath: "/srv/apps/data"}, nil
}
func (f *fake) Stream(tty bool, words ...string) (int, error) {
	f.tty, f.words = tty, words
	return f.rc, f.streamErr
}
func (f *fake) Close() {}

func project(t *testing.T) {
	t.Helper()
	t.Chdir(t.TempDir())
	os.WriteFile("kasbah.yml", []byte("schema: 1\nkasbah_version: 0.1.0\nname: demo\ndomain: demo.test\nsync:\n  - compose.prod.yml -> compose.yml\n"), 0o644)
}

func run(t *testing.T, f *fake, c Ctx, cmd string, args ...string) (string, int) {
	t.Helper()
	o, err := Parse(cmd, args)
	if err != nil {
		t.Fatal(err)
	}
	var se bytes.Buffer
	c.Out = &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &se}
	c.Version = "0.1.0"
	c.Dial = func(target string) (Session, error) { return f, nil }
	code, err := Run(c, o)
	if err != nil {
		code = c.Out.Report(err)
	}
	return se.String(), code
}

func lastServer(t *testing.T) string {
	v, _ := state.Get(state.File, "last_server")
	return v
}

func TestLogs(t *testing.T) {
	project(t)
	f := &fake{}
	se, code := run(t, f, Ctx{}, "logs")
	if code != 1 || !strings.Contains(se, "no server given, and this project has never deployed to one") {
		t.Fatalf("no server: %d %s", code, se)
	}
	_, code = run(t, f, Ctx{}, "logs", "deploy@vps")
	if want := "docker compose -f /srv/apps/demo/compose.yml -p demo logs --tail=100"; code != 0 || strings.Join(f.words, " ") != want || f.tty {
		t.Errorf("got %d %q tty=%v", code, f.words, f.tty)
	}
	if lastServer(t) != "deploy@vps" {
		t.Error("a run that read the logs records the server")
	}
	_, _ = run(t, f, Ctx{TTY: true}, "logs", "web", "-f", "--tail=all")
	if want := "docker compose -f /srv/apps/demo/compose.yml -p demo logs --tail=all -f web"; strings.Join(f.words, " ") != want || f.tty {
		t.Errorf("never a pty for a log: %q tty=%v", f.words, f.tty)
	}
	for _, rc := range []int{255, 130} {
		os.Remove(state.File)
		f.rc = rc
		se, code := run(t, f, Ctx{}, "logs", "deploy@vps")
		if code != rc || se != "" || lastServer(t) != "deploy@vps" {
			t.Errorf("rc %d is stopped, not failed: code=%d stderr=%q last=%q", rc, code, se, lastServer(t))
		}
	}
	os.Remove(state.File)
	f.rc = 1
	se, code = run(t, f, Ctx{}, "logs", "deploy@vps", "nosuch")
	if code != 1 || !strings.Contains(se, "could not read the logs of demo on deploy@vps") || !strings.Contains(se, "'nosuch' is the service") || lastServer(t) != "" {
		t.Errorf("compose failed: code=%d last=%q %s", code, lastServer(t), se)
	}
	f.rc, f.mkErr = 0, cli.Failf(cli.ExitNoRemoteState, "no marker")
	if _, code = run(t, f, Ctx{}, "logs", "deploy@vps"); code != 4 || f.words == nil {
		t.Errorf("no marker: %d", code)
	}
	t.Chdir(t.TempDir())
	if _, code = run(t, &fake{}, Ctx{}, "logs", "deploy@vps"); code != 2 {
		t.Errorf("outside a project: %d", code)
	}
}

func TestExec(t *testing.T) {
	project(t)
	f := &fake{rc: 7}
	se, code := run(t, f, Ctx{}, "exec", "deploy@vps", "web", "--", "sh", "-c", "exit 7")
	if want := "docker compose -f /srv/apps/demo/compose.yml -p demo exec -T web sh -c exit 7"; strings.Join(f.words, " ") != want || f.tty {
		t.Errorf("no terminal: %q tty=%v", f.words, f.tty)
	}
	if f.words[len(f.words)-1] != "exit 7" {
		t.Error("a word with a space reaches the far side as one word")
	}
	if code != 7 || se != "" || lastServer(t) != "deploy@vps" {
		t.Errorf("the command's status, and the server recorded anyway: code=%d stderr=%q last=%q", code, se, lastServer(t))
	}
	f.rc = 0
	_, _ = run(t, f, Ctx{TTY: true}, "exec", "web", "--", "sh")
	if want := "docker compose -f /srv/apps/demo/compose.yml -p demo exec web sh"; strings.Join(f.words, " ") != want || !f.tty {
		t.Errorf("a terminal at both ends: %q tty=%v", f.words, f.tty)
	}
	se, _ = run(t, f, Ctx{Fed: true}, "exec", "web", "--", "cat")
	if !strings.Contains(se, "stdin is not forwarded") {
		t.Errorf("fed stdin warns: %q", se)
	}
	se, _ = run(t, f, Ctx{TTY: true, Fed: true}, "exec", "web", "--", "cat")
	if se != "" {
		t.Errorf("a terminal forwards stdin, nothing to warn about: %q", se)
	}
	os.Remove(state.File)
	f.mkErr = cli.Failf(cli.ExitSSHUnreachable, "cannot reach")
	if _, code = run(t, f, Ctx{}, "exec", "deploy@vps", "web", "--", "true"); code != 3 || lastServer(t) != "" {
		t.Errorf("nothing ran, nothing recorded: %d", code)
	}
}

func TestSignalledAndNeverRan(t *testing.T) {
	project(t)
	f := &fake{rc: 143}
	sig := func() int { return 143 }
	se, code := run(t, f, Ctx{Interrupted: sig}, "logs", "deploy@vps", "-f")
	if code != 143 || !strings.Contains(se, "kasbah was stopped by signal 15") || strings.Contains(se, "exited 143") || lastServer(t) != "" {
		t.Errorf("logs, SIGTERM: %d last=%q %s", code, lastServer(t), se)
	}
	se, code = run(t, f, Ctx{Interrupted: sig}, "exec", "deploy@vps", "web", "--", "sleep", "9")
	if code != 143 || !strings.Contains(se, "not the remote command's") || lastServer(t) != "deploy@vps" {
		t.Errorf("exec, SIGTERM: %d last=%q %s", code, lastServer(t), se)
	}
	os.Remove(state.File)
	f = &fake{rc: 143}
	if se, code = run(t, f, Ctx{}, "exec", "deploy@vps", "web", "--", "sh"); code != 143 || se != "" {
		t.Errorf("the command's own 143 is passed through silently: %d %q", code, se)
	}
	os.Remove(state.File)
	f = &fake{streamErr: cli.Fail("could not run ssh: no such file")}
	if se, code = run(t, f, Ctx{}, "exec", "deploy@vps", "web", "--", "true"); code != 1 || lastServer(t) != "" || !strings.Contains(se, "could not run ssh") {
		t.Errorf("a command that never ran records nothing: %d last=%q %s", code, lastServer(t), se)
	}
}
