package ssh

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
)

func TestParseTarget(t *testing.T) {
	good := map[string]Target{
		"deploy@vps.example.com":   {"deploy", "vps.example.com"},
		"stevedore@rig":            {"stevedore", "rig"},
		"root@10.0.0.1":            {"root", "10.0.0.1"},
		"deploy-user_1.x@host-1":   {"deploy-user_1.x", "host-1"},
		"deploy@vps.example.com\r": {"deploy", "vps.example.com"},
	}
	for in, want := range good {
		got, err := ParseTarget(in)
		if err != nil || got != want {
			t.Errorf("ParseTarget(%q) = %v, %v; want %v", in, got, err, want)
		}
	}
	for _, in := range []string{
		"", "vps.example.com", "deploy@", "@vps.example.com", "deploy@vps:2222",
		"deploy@[::1]", "deploy@-vps", "deploy@vps-", "de ploy@vps", "deploy@v ps", "a@b@c",
	} {
		if _, err := ParseTarget(in); err == nil {
			t.Errorf("ParseTarget(%q) accepted it", in)
		}
	}
}

// The quoting cases of tests/ssh_test.sh, and the proof: sh reads each quoted
// word back as exactly the word given.
func TestQuote(t *testing.T) {
	tests := []struct {
		words []string
		want  string
	}{
		{[]string{"docker", "ps", "--format", "{{.Names}} {{.Status}}", "--filter", "label=a b"},
			`'docker' 'ps' '--format' '{{.Names}} {{.Status}}' '--filter' 'label=a b'`},
		{[]string{"docker ps | wc -l"}, `'docker ps | wc -l'`},
		{[]string{"bash", "-s", "--", "one", "two three"}, `'bash' '-s' '--' 'one' 'two three'`},
		{[]string{"it's"}, `'it'\''s'`},
		{[]string{""}, `''`},
	}
	for _, tt := range tests {
		if got := Quote(tt.words...); got != tt.want {
			t.Errorf("Quote(%q) = %s, want %s", tt.words, got, tt.want)
		}
	}
	nasty := []string{"a b", "it's \"quoted\"", "$HOME", "`date`", "x\ny", "*", "'", "\\", "--", "-n", "", "$(id)", "%C"}
	script := `set -- ` + Quote(nasty...) + `; for a; do printf '%s\0' "$a"; done`
	out, err := exec.Command("sh", "-c", script).Output()
	if err != nil {
		t.Fatal(err)
	}
	got := strings.Split(strings.TrimSuffix(string(out), "\x00"), "\x00")
	if len(got) != len(nasty) {
		t.Fatalf("sh read %d words back, want %d: %q", len(got), len(nasty), got)
	}
	for i := range nasty {
		if got[i] != nasty[i] {
			t.Errorf("word %d: sh read %q, want %q", i, got[i], nasty[i])
		}
	}
}

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestTmpBase(t *testing.T) {
	dir := t.TempDir()
	spaced := filepath.Join(dir, "has space")
	pct := filepath.Join(dir, "a%b")
	for _, d := range []string{spaced, pct} {
		os.Mkdir(d, 0o700)
	}
	tests := []struct {
		tmpdir, want, wantErr string
	}{
		{"", "/tmp", ""},
		{dir, dir, ""},
		{dir + "/", dir, ""},
		{spaced, "", "splits a ControlPath"},
		{pct, "", "token"},
		{filepath.Join(dir, "missing"), "", "not a directory"},
	}
	for _, tt := range tests {
		got, err := tmpBase(env(map[string]string{"TMPDIR": tt.tmpdir}))
		if tt.wantErr != "" {
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) || !strings.Contains(err.Error(), "TMPDIR") {
				t.Errorf("tmpBase(%q) = %q, %v; want an error naming TMPDIR and %q", tt.tmpdir, got, err, tt.wantErr)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("tmpBase(%q) = %q, %v; want %q", tt.tmpdir, got, err, tt.want)
		}
	}
}

func TestCtlPath(t *testing.T) {
	// "/m1" is three bytes: a directory of 87 fits exactly, 88 does not.
	fits := "/" + strings.Repeat("d", 86)
	if p, err := ctlPath(fits, 1); err != nil || len(p) != CtlPathMax {
		t.Errorf("a %d-byte path was refused or mis-built: %q, %v", len(fits)+3, p, err)
	}
	over := fits + "d"
	if _, err := ctlPath(over, 1); err == nil || !strings.Contains(err.Error(), "TMPDIR") {
		t.Errorf("a %d-byte path was not refused naming TMPDIR: %v", len(over)+3, err)
	}
}

func TestMkCtlDir(t *testing.T) {
	base := t.TempDir()
	a, err := mkCtlDir(base)
	if err != nil {
		t.Fatal(err)
	}
	b, err := mkCtlDir(base)
	if err != nil {
		t.Fatal(err)
	}
	if a == b {
		t.Errorf("two control directories share a name: %s", a)
	}
	for _, d := range []string{a, b} {
		fi, err := os.Stat(d)
		if err != nil || fi.Mode().Perm() != 0o700 {
			t.Errorf("%s: mode %v, %v; want 0700", d, fi.Mode().Perm(), err)
		}
		if name := filepath.Base(d); !strings.HasPrefix(name, "kasbah-ssh.") || len(name) != len("kasbah-ssh.XXXXXX") {
			t.Errorf("%s is not named kasbah-ssh.XXXXXX", d)
		}
	}
}

// stub puts a recording ssh first on PATH: it logs its argv one word per line
// between BEGIN and END, and runs the remote command locally with sh.
func stub(t *testing.T, rc string) (log, tmp string) {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "bin")
	os.Mkdir(bin, 0o755)
	log = filepath.Join(dir, "log")
	tmp = filepath.Join(dir, "tmp")
	os.Mkdir(tmp, 0o755)
	script := `#!/bin/sh
{ echo BEGIN; for a; do printf '%s\n' "$a"; done; echo END; } >> "$SSH_STUB_LOG"
for a; do last=$a; done
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
if [ "${SSH_STUB_RC:-0}" != 0 ]; then echo "ssh: connect to host: Connection refused" >&2; exit "$SSH_STUB_RC"; fi
exec sh -c "$last"
`
	if err := os.WriteFile(filepath.Join(bin, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("SSH_STUB_LOG", log)
	t.Setenv("SSH_STUB_RC", rc)
	t.Setenv("TMPDIR", tmp)
	return log, tmp
}

func calls(t *testing.T, log string) [][]string {
	b, _ := os.ReadFile(log)
	var out [][]string
	var cur []string
	for _, l := range strings.Split(string(b), "\n") {
		switch l {
		case "BEGIN":
			cur = []string{}
		case "END":
			out = append(out, cur)
		default:
			cur = append(cur, l)
		}
	}
	return out
}

func has(words []string, w string) bool {
	for _, x := range words {
		if x == w {
			return true
		}
	}
	return false
}

func TestConnectRunClose(t *testing.T) {
	log, tmp := stub(t, "0")
	c, err := Connect("deploy@vps.example.com")
	if err != nil {
		t.Fatal(err)
	}
	out, err := c.Run("printf", "%s|", "a b", "it's")
	if err != nil || string(out) != "a b|it's|" {
		t.Errorf("Run = %q, %v", out, err)
	}
	cmd := c.Script("printf '%s|' \"$@\"; cat", "one", "two three")
	got, err := cmd.Output()
	if err != nil || string(got) != "one|two three|" {
		t.Errorf("Script = %q, %v", got, err)
	}
	ents, _ := os.ReadDir(tmp)
	if len(ents) != 1 {
		t.Fatalf("TMPDIR holds %d entries while connected, want the control directory", len(ents))
	}
	c.Close()
	c.Close()

	cs := calls(t, log)
	if len(cs) != 4 {
		t.Fatalf("got %d ssh calls, want probe, run, script, one teardown: %q", len(cs), cs)
	}
	var ctl string
	for _, w := range cs[0] {
		if strings.HasPrefix(w, "ControlPath=") {
			ctl = strings.TrimPrefix(w, "ControlPath=")
		}
	}
	if !strings.HasPrefix(ctl, tmp+"/kasbah-ssh.") || len(ctl) > CtlPathMax || strings.Contains(ctl, "%") {
		t.Errorf("the control path %q is not a private one under TMPDIR within %d bytes", ctl, CtlPathMax)
	}
	for i, call := range cs {
		if !has(call, "ControlPath="+ctl) || !has(call, "ControlMaster=auto") {
			t.Errorf("call %d does not ride the master: %q", i, call)
		}
	}
	if !has(cs[0], "-n") || !has(cs[1], "-n") {
		t.Errorf("the probe and Run must close stdin: %q / %q", cs[0], cs[1])
	}
	if has(cs[2], "-n") {
		t.Errorf("Script must leave stdin open for its payload: %q", cs[2])
	}
	if last := cs[2][len(cs[2])-1]; last != `'sh' '-s' '--' 'one' 'two three'` {
		t.Errorf("Script's remote command is %s", last)
	}
	if n := len(cs[3]); n < 3 || cs[3][n-3] != "-O" || cs[3][n-2] != "exit" || cs[3][n-1] != "deploy@vps.example.com" {
		t.Errorf("the teardown is not -O exit TARGET: %q", cs[3])
	}
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("TMPDIR is not left empty after Close: %v", ents)
	}
}

func TestUnreachable(t *testing.T) {
	log, tmp := stub(t, "255")
	_, err := Connect("deploy@vps.example.com")
	var e *cli.Error
	if !errors.As(err, &e) || e.Code != cli.ExitSSHUnreachable {
		t.Fatalf("Connect to an unreachable host = %v, want exit %d", err, cli.ExitSSHUnreachable)
	}
	for _, call := range calls(t, log) {
		if has(call, "-O") {
			t.Errorf("a failed connect tore down a master it never opened: %q", call)
		}
	}
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("TMPDIR is not left empty after a failed connect: %v", ents)
	}
}

// What a signal's exit runs: the teardown is on the atexit stack from the
// moment the directory exists.
func TestCleanupRegistered(t *testing.T) {
	log, tmp := stub(t, "0")
	if _, err := Connect("deploy@vps.example.com"); err != nil {
		t.Fatal(err)
	}
	atexit.Run()
	cs := calls(t, log)
	if len(cs) != 2 || !has(cs[1], "-O") {
		t.Errorf("atexit.Run did not tear the master down: %q", cs)
	}
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("TMPDIR is not left empty by atexit.Run: %v", ents)
	}
}

func TestLongTmpdirRefusedBeforeSSH(t *testing.T) {
	log, _ := stub(t, "0")
	long := filepath.Join(t.TempDir(), strings.Repeat("d", 90))
	os.Mkdir(long, 0o700)
	t.Setenv("TMPDIR", long)
	if _, err := Connect("deploy@vps.example.com"); err == nil || !strings.Contains(err.Error(), "TMPDIR") {
		t.Errorf("a TMPDIR too long for a socket was not refused naming TMPDIR: %v", err)
	}
	if len(calls(t, log)) != 0 {
		t.Error("ssh ran before the refusal")
	}
	if ents, _ := os.ReadDir(long); len(ents) != 0 {
		t.Errorf("the refusal left %v behind", ents)
	}
}
