package ops

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
)

func TestParse(t *testing.T) {
	cases := []struct {
		cmd  string
		args []string
		want string // target|service|follow|tail|cmd, or "err:<needle>"
	}{
		{"logs", nil, "||false|100|"},
		{"logs", []string{"web"}, "||false|100|"},
		{"logs", []string{"bob@vps", "web"}, "bob@vps|web|false|100|"},
		{"logs", []string{"vps", "web", "-f"}, "alice@vps|web|true|100|"},
		{"logs", []string{"deploy@vps"}, "deploy@vps||false|100|"},
		{"logs", []string{"web", "deploy@vps\r", "-f", "--tail=all"}, "deploy@vps|web|true|all|"},
		{"logs", []string{"--tail=3"}, "||false|3|"},
		{"logs", []string{"--tail=x"}, "err:is not a number of lines"},
		{"logs", []string{"--tail="}, "err:is not a number of lines"},
		{"logs", []string{"--tail", "3"}, "err:takes its value with '='"},
		{"logs", []string{"-f=1"}, "err:-f takes no value"},
		{"logs", []string{"a@b", "c@d"}, "err:two servers given ('a@b' and 'c@d')"},
		{"logs", []string{"vps", "web", "db"}, "err:two services given ('web' and 'db')"},
		{"logs", []string{"a@b", "web", "db"}, "err:two services given ('web' and 'db')"},
		{"logs", []string{"vps", "web", "c@d"}, "err:two servers given ('vps' and 'c@d')"},
		{"logs", []string{"--", "ls"}, "err:logs runs none"},
		{"logs", []string{"--follow"}, "err:unknown flag '--follow'"},
		{"exec", []string{"web", "--", "ls", "-la", "--", "a b"}, "||false|100|ls -la -- a b"},
		{"exec", []string{"vps", "web", "--", "true"}, "alice@vps|web|false|100|true"},
		{"exec", []string{"deploy@vps", "web", "--", "true"}, "deploy@vps|web|false|100|true"},
		{"exec", []string{"vps", "web", "ls"}, "err:'ls' comes after the service 'web', and there is no '--' between them"},
		{"exec", []string{"web", "ls"}, "err:no '--' in the arguments"},
		{"exec", []string{"web"}, "err:no '--' in the arguments"},
		{"exec", []string{"deploy@vps", "--", "true"}, "err:no service given"},
		{"exec", []string{"web", "--"}, "err:nothing after the '--'"},
		{"exec", []string{"web", "-la"}, "err:unknown flag '-la'"},
		{"exec", []string{"web", "-f"}, "err:unknown flag '-f'"},
	}
	stubUser(t, "alice")
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
	if _, err := Parse("exec", []string{"web", "-la"}); err == nil || !strings.Contains(err.Error(), "kasbah exec web -- <cmd> -la …") {
		t.Errorf("the service is kept for the hint: %v", err)
	}
	if o, err := Parse("exec", []string{"web", "--", "true"}); err != nil || o.Word != "web" || o.Service != "" {
		t.Errorf("a lone bare word waits for the compose file: %+v %v", o, err)
	}
	if _, err := Parse("exec", []string{"you@vps", "web", "ls"}); err == nil || !strings.Contains(err.Error(), "kasbah exec you@vps web -- ls …") {
		t.Errorf("the hint names the server too: %v", err)
	}
	if _, err := Parse("logs", []string{"-h"}); err != ErrHelp {
		t.Error("-h is help")
	}
}

// Two bare words before a missing '--' show both readings, or the one the
// compose file bears out when it names either word.
func TestExecHints(t *testing.T) {
	stubUser(t, "alice")
	hint := func(args ...string) string {
		t.Helper()
		_, err := Parse("exec", args)
		if err == nil {
			t.Fatalf("exec %q accepted", args)
		}
		return err.Error()
	}
	t.Chdir(t.TempDir())
	for args, want := range map[string][]string{
		"web ls":       {"no '--' in the arguments", "kasbah exec web -- ls …", "with 'web' the server and 'ls' the service", "kasbah exec web ls -- CMD…"},
		"web sh -c ls": {"unknown flag '-c'", "kasbah exec web -- sh -c …", "with 'web' the server and 'sh' the service", "kasbah exec web sh -- CMD -c …"},
		"web ls -la":   {"unknown flag '-la'", "kasbah exec web -- ls -la …", "kasbah exec web ls -- CMD -la …"},
	} {
		got := hint(strings.Fields(args)...)
		for _, w := range want {
			if !strings.Contains(got, w) {
				t.Errorf("exec %s, no compose file: want %q in %s", args, w, got)
			}
		}
	}
	project(t)
	for args, want := range map[string]string{
		"web ls":       "'web' is a service of compose.prod.yml, so the command is what follows it:\n  kasbah exec web -- ls …",
		"web sh -c ls": "'web' is a service of compose.prod.yml, so the command is what follows it:\n  kasbah exec web -- sh -c …",
		"web ls -la":   "kasbah exec web -- ls -la …",
		"vps db -T":    "'db' is a service of compose.prod.yml, so 'vps' is the server:\n  kasbah exec vps db -- CMD -T …",
	} {
		got := hint(strings.Fields(args)...)
		if !strings.Contains(got, want) || strings.Contains(got, "or with") {
			t.Errorf("exec %s: want only %q in %s", args, want, got)
		}
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
	os.WriteFile("compose.prod.yml", []byte("services:\r\n  web:\r\n    image: nginx\r\n  db:\r\n    image: postgres\r\n"), 0o644)
}

// stubUser makes ssh's config log in to every bare host as user, and records
// the lookups.
func stubUser(t *testing.T, user string) *[]string {
	oldU, oldN := ssh.UserOf, ssh.Note
	var l []string
	ssh.UserOf = func(h string) (string, error) { l = append(l, h); return user, nil }
	ssh.Note = func(string) {}
	t.Cleanup(func() { ssh.UserOf, ssh.Note = oldU, oldN })
	return &l
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
	if code != 1 || !strings.Contains(se, "no server given, and this project has never talked to one") {
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
	if strings.Contains(se, "USER@nosuch") {
		t.Errorf("a server was given, yet the service is suggested as one: %s", se)
	}
	if err := state.Record(state.File, "1.0.0", "last_server", "deploy@vps"); err != nil {
		t.Fatal(err)
	}
	f.rc = 0
	looked := stubUser(t, "alice")
	if _, code = run(t, f, Ctx{}, "logs", "vps"); code != 0 || strings.Join(f.words, " ") != "docker compose -f /srv/apps/demo/compose.yml -p demo logs --tail=100" ||
		lastServer(t) != "alice@vps" || strings.Join(*looked, " ") != "vps" {
		t.Errorf("a bare word compose.prod.yml has no service of is the server: code=%d %q last=%q looked up %q", code, f.words, lastServer(t), *looked)
	}
	*looked = nil
	if _, code = run(t, f, Ctx{}, "logs", "db"); code != 0 || strings.Join(f.words, " ") != "docker compose -f /srv/apps/demo/compose.yml -p demo logs --tail=100 db" ||
		lastServer(t) != "alice@vps" || len(*looked) != 0 {
		t.Errorf("a bare word compose.prod.yml names is the service, on last_server: code=%d %q last=%q looked up %q", code, f.words, lastServer(t), *looked)
	}
	// Unreadable, the compose file cannot tell the two apart: nothing connects.
	os.WriteFile("compose.prod.yml", []byte("services: [web]\n"), 0o644)
	f.words = nil
	se, code = run(t, f, Ctx{}, "logs", "web")
	if code != 1 || f.words != nil || len(*looked) != 0 || !strings.Contains(se, "logs: cannot tell whether 'web' is a service or the server: compose.prod.yml: its services: is not a map") ||
		!strings.Contains(se, "kasbah logs HOST web") {
		t.Errorf("unreadable compose: code=%d %q %s", code, f.words, se)
	}
	// Services an included file declares count, and an include that cannot be
	// read is the unreadable case.
	os.WriteFile("compose.prod.yml", []byte("include:\r\n  - sub/side.yml\r\nservices:\r\n  web: {}\r\n"), 0o644)
	os.MkdirAll("sub", 0o755)
	os.WriteFile("sub/side.yml", []byte("services:\n  side: {}\n"), 0o644)
	if _, code = run(t, f, Ctx{}, "logs", "side"); code != 0 || strings.Join(f.words, " ") != "docker compose -f /srv/apps/demo/compose.yml -p demo logs --tail=100 side" || len(*looked) != 0 {
		t.Errorf("an included service: code=%d %q looked up %q", code, f.words, *looked)
	}
	os.Remove("sub/side.yml")
	f.words = nil
	if se, code = run(t, f, Ctx{}, "logs", "side"); code != 1 || f.words != nil || len(*looked) != 0 || !strings.Contains(se, "its include sub/side.yml cannot be read") {
		t.Errorf("an unreadable include: code=%d %q %s", code, f.words, se)
	}
	// A word taken as the server because it names no service is said so.
	var notes []string
	ssh.Note = func(l string) { notes = append(notes, l) }
	os.WriteFile("compose.prod.yml", []byte("services:\n  web: {}\n"), 0o644)
	if _, code = run(t, f, Ctx{}, "logs", "wbe"); code != 0 || strings.Join(*looked, " ") != "wbe" ||
		len(notes) != 2 || notes[0] != "kasbah: 'wbe' is no service of compose.prod.yml — taken as the server" {
		t.Errorf("logs wbe: code=%d looked up %q, noted %q", code, *looked, notes)
	}
	// A lone word no server could be is refused as one, with no note.
	*looked, notes = nil, nil
	for _, c := range [][]string{{"logs", "1.2"}, {"exec", "1.2", "--", "ls"}} {
		se, code = run(t, f, Ctx{}, c[0], c[1:]...)
		if code != 1 || len(*looked) != 0 || len(notes) != 0 || !strings.Contains(se, "'1.2' is not a version kasbah can use") || strings.Contains(se, "SERVICE") {
			t.Errorf("%q: code=%d looked up %q, noted %q: %s", c, code, *looked, notes, se)
		}
	}
	*looked, f.words = nil, nil
	os.Remove("compose.prod.yml")
	se, code = run(t, f, Ctx{}, "logs", "web")
	if code != 1 || f.words != nil || !strings.Contains(se, "compose.prod.yml: not found") || !strings.Contains(se, "help: kasbah help S03") {
		t.Errorf("no compose: code=%d %s", code, se)
	}
	if _, code = run(t, f, Ctx{}, "logs", "deploy@vps", "web"); code != 0 {
		t.Errorf("a service named beside the server needs no compose file: %d", code)
	}
	project(t)
	os.Remove(state.File)
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
	looked := stubUser(t, "alice")
	f.words = nil
	se, code = run(t, f, Ctx{}, "exec", "vps", "--", "true")
	if code != 1 || f.words != nil || len(*looked) != 0 || !strings.Contains(se, "compose.prod.yml has no service 'vps', so it is the server") ||
		!strings.Contains(se, "kasbah exec vps SERVICE -- CMD…") {
		t.Errorf("exec with a server and no service: code=%d %q %s", code, f.words, se)
	}
	os.WriteFile("compose.prod.yml", []byte("include:\n  - side.yml\nservices:\n  web: {}\n"), 0o644)
	os.WriteFile("side.yml", []byte("services:\n  side: {}\n"), 0o644)
	if _, code = run(t, f, Ctx{}, "exec", "side", "--", "true"); code != 0 || len(*looked) != 0 ||
		strings.Join(f.words, " ") != "docker compose -f /srv/apps/demo/compose.yml -p demo exec -T side true" {
		t.Errorf("exec on an included service: code=%d %q", code, f.words)
	}
	os.WriteFile("compose.prod.yml", []byte("services: [web]\n"), 0o644)
	f.words = nil
	if se, code = run(t, f, Ctx{}, "exec", "web", "--", "true"); code != 1 || f.words != nil ||
		!strings.Contains(se, "kasbah exec HOST web -- CMD…") || !strings.Contains(se, "kasbah exec USER@web SERVICE -- CMD…") {
		t.Errorf("exec, unreadable compose, names both spellings: code=%d %s", code, se)
	}
	if _, code = run(t, f, Ctx{}, "exec", "vps", "web", "--", "true"); code != 0 || lastServer(t) != "alice@vps" ||
		strings.Join(f.words, " ") != "docker compose -f /srv/apps/demo/compose.yml -p demo exec -T web true" {
		t.Errorf("exec vps web: code=%d %q last=%q", code, f.words, lastServer(t))
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
