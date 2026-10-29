package env

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

func TestParseSet(t *testing.T) {
	o, err := Parse([]string{"set", "API_SECRET", "deploy@vps", "--no-restart"})
	if err != nil || !o.Set || o.Key != "API_SECRET" || o.Target != "deploy@vps" || o.Restart != prompt.No {
		t.Fatalf("%+v %v", o, err)
	}
	if o, err := Parse([]string{"set", "--help"}); err != ErrHelp || !o.Set {
		t.Errorf("help: %+v %v", o, err)
	}
	for _, c := range []struct {
		args []string
		want string
	}{
		{[]string{"set"}, "which key"},
		{[]string{"set", "KASBAH_CPU_LIMIT"}, "kasbah's own"},
		{[]string{"set", "1BAD"}, "not an env key"},
		{[]string{"set", "A", "--value=hunter2"}, "never taken from the command line"},
		{[]string{"set", "A", "--restart", "--no-restart"}, "--restart and --no-restart cannot both"},
		{[]string{"set", "A", "--on-drift=continue"}, "unknown flag '--on-drift'"},
		{[]string{"set", "A", "u@h", "x"}, "too many"},
	} {
		if _, err := Parse(c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%v: %v", c.args, err)
		}
	}
}

const setTmpl = "# --- App ---\nAPP_NAME=demo\nDB_PASSWORD=! echo pw\nAPI_SECRET=\nMAIL_HOST=# host\nKASBAH_CPU_LIMIT=1\n"

func setDir(t *testing.T, env string) string {
	t.Helper()
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", setTmpl)
	if env != "" {
		write(t, dir+"/.env", env)
		os.Chmod(dir+"/.env", 0o600)
	}
	return dir
}

func readFile(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestSetKeyReplacesOneLine(t *testing.T) {
	env := "# my note\r\nAPP_NAME=demo\r\nexport API_SECRET=old\r\n\n" + ManagedBegin + "\nKASBAH_CPU_LIMIT=1\n" + ManagedEnd + "\nMAIL_HOST=smtp\n"
	dir := setDir(t, env)
	verb, err := SetKey(dir, "API_SECRET", "n$w")
	if err != nil || verb != "changed" {
		t.Fatal(verb, err)
	}
	want := strings.Replace(env, "export API_SECRET=old\r\n", "API_SECRET=n$$w\r\n", 1)
	if got := readFile(t, dir+"/.env"); got != want {
		t.Errorf("got %q\nwant %q", got, want)
	}
	if fi, _ := os.Stat(dir + "/.env"); fi.Mode().Perm() != 0o660 {
		t.Errorf("mode %o: a 600 .env converges to 660", fi.Mode().Perm())
	}
	if m, _ := filepath.Glob(dir + "/.env.kasbah-*"); len(m) != 0 {
		t.Errorf("staging left: %v", m)
	}
}

func TestSetKeyEdges(t *testing.T) {
	// Duplicates: every assignment of the key takes the value.
	dir := setDir(t, "API_SECRET=a\nAPP_NAME=demo\nAPI_SECRET=b\n")
	if _, err := SetKey(dir, "API_SECRET", "c"); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, dir+"/.env"); got != "API_SECRET=c\nAPP_NAME=demo\nAPI_SECRET=c\n" {
		t.Errorf("duplicates: %q", got)
	}

	// A CRLF template, a key present only in a comment, a `$` value.
	dir = setDir(t, "APP_NAME=demo\n# API_SECRET=commented\n")
	write(t, dir+"/.env.prod.example", strings.ReplaceAll(setTmpl, "\n", "\r\n"))
	if verb, err := SetKey(dir, "API_SECRET", "p$w"); err != nil || verb != "added" {
		t.Fatal(verb, err)
	}
	if got := readFile(t, dir+"/.env"); got != "APP_NAME=demo\nAPI_SECRET=p$$w\n# API_SECRET=commented\n" {
		t.Errorf("crlf template, commented key: %q", got)
	}

	// Lines compose reads as the key but Assign does not, and a key in the block.
	for _, env := range []string{"API_SECRET =x\n", "API_SECRET: x\n", "export API_SECRET =x\n", "API_SECRET=\xff\n",
		ManagedBegin + "\nAPI_SECRET=x\n" + ManagedEnd + "\n"} {
		dir := setDir(t, env)
		want := "line 1 sets"
		if strings.HasPrefix(env, ManagedBegin) {
			want = "line 2 sets API_SECRET inside the kasbah managed block"
		}
		if _, err := SetKey(dir, "API_SECRET", "v"); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v", env, err)
		}
		if got := readFile(t, dir+"/.env"); got != env {
			t.Errorf("%q: a refusal changed .env to %q", env, got)
		}
	}
	// A longer key that merely starts with this one is no conflict.
	if !readsAs("API_SECRET =1", "API_SECRET") || readsAs("API_SECRETS =1", "API_SECRET") || readsAs("# API_SECRET=1", "API_SECRET") {
		t.Error("readsAs")
	}
}

func TestEncode(t *testing.T) {
	for v, want := range map[string]string{
		"plain":           "plain",
		"a$b":             "a$$b",
		"a=b#c":           "a=b#c",
		`back\slash`:      `back\slash`,
		"  sp  ":          "'  sp  '",
		"pa$$ss #frag":    "'pa$$ss #frag'",
		"'q":              `"'q"`,
		`"dq`:             `'"dq'`,
		`end\`:            `end\`,
		` end\`:           `" end\\"`,
		`it's "x" $y \z `: `"it's \"x\" $$y \\z "`,
		"":                "",
	} {
		if got, err := Encode(v); err != nil || got != want {
			t.Errorf("Encode(%q) = %q %v, want %q", v, got, err, want)
		}
	}
	if _, err := Encode("a\nb"); err == nil {
		t.Error("a newline encoded")
	}
}

func TestSetKeyAddsInTemplatePosition(t *testing.T) {
	for _, c := range []struct{ env, key, want string }{
		// After the nearest earlier template key present.
		{"APP_NAME=demo\n# mail\nMAIL_HOST=smtp\n", "API_SECRET", "APP_NAME=demo\nAPI_SECRET=v\n# mail\nMAIL_HOST=smtp\n"},
		// Before the nearest later one when no earlier key is there.
		{"# top\nMAIL_HOST=smtp\n", "APP_NAME", "# top\nAPP_NAME=v\nMAIL_HOST=smtp\n"},
		// At the end when the .env holds none of the template's keys.
		{"# only a note", "API_SECRET", "# only a note\nAPI_SECRET=v\n"},
	} {
		dir := setDir(t, c.env)
		if verb, err := SetKey(dir, c.key, "v"); err != nil || verb != "added" {
			t.Fatal(verb, err)
		}
		if got := readFile(t, dir+"/.env"); got != c.want {
			t.Errorf("%s into %q: got %q, want %q", c.key, c.env, got, c.want)
		}
	}
}

func TestSetKeyRefusals(t *testing.T) {
	dir := setDir(t, "APP_NAME=demo\n")
	for _, c := range []struct{ key, value, want string }{
		{"NOT_THERE", "v", "not a key of " + dir + "/.env.prod.example"},
		{"KASBAH_CPU_LIMIT", "2", "not a key env set may change"},
		{"APP_NAME", "a\nb", "line break"},
	} {
		if _, err := SetKey(dir, c.key, c.value); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v", c.key, err)
		}
	}
	if got := readFile(t, dir+"/.env"); got != "APP_NAME=demo\n" {
		t.Errorf("a refusal changed .env: %q", got)
	}
	if _, err := SetKey(setDir(t, ""), "APP_NAME", "v"); err == nil || !strings.Contains(err.Error(), "kasbah env") {
		t.Errorf("no .env: %v", err)
	}
}

func TestSetKeyThroughSymlink(t *testing.T) {
	dir := setDir(t, "")
	write(t, dir+"/real.env", "APP_NAME=old\n")
	os.Symlink("real.env", dir+"/.env")
	if _, err := SetKey(dir, "APP_NAME", "new"); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Lstat(dir + "/.env"); fi.Mode()&os.ModeSymlink == 0 {
		t.Error("the link was replaced by a file")
	}
	if got := readFile(t, dir+"/real.env"); got != "APP_NAME=new\n" {
		t.Errorf("target: %q", got)
	}
}

func TestKeyReport(t *testing.T) {
	dir := setDir(t, "APP_NAME=demo\n")
	if got := keyReport(dir, "API_SECRET"); got != "template_exists=yes\nin_template=yes\nenv_exists=yes\n" {
		t.Errorf("%q", got)
	}
	if got := keyReport(dir, "KASBAH_CPU_LIMIT"); !strings.Contains(got, "in_template=no") {
		t.Errorf("reserved: %q", got)
	}
	if got := keyReport(t.TempDir(), "A"); got != "template_exists=no\nin_template=no\nenv_exists=no\n" {
		t.Errorf("empty: %q", got)
	}
}

func remoteSetRun(dir, value, up string) (int, string, string) {
	var out, errb bytes.Buffer
	rc := remoteSet(dir, "API_SECRET", up, strings.NewReader(SetHeader(value)+value), &out, &errb)
	return rc, out.String(), errb.String()
}

func TestRemoteSet(t *testing.T) {
	dir := setDir(t, "API_SECRET=old\n")
	if rc, out, errs := remoteSetRun(dir, "new", ""); rc != 0 || out != "set=changed\n" {
		t.Fatalf("rc %d %q %s", rc, out, errs)
	}
	if got := readFile(t, dir+"/.env"); got != "API_SECRET=new\n" {
		t.Errorf("%q", got)
	}

	// A cut stream, or one without its header, is never written.
	for _, in := range []string{SetHeader("newer") + "new", "new"} {
		var out, errb bytes.Buffer
		if rc := remoteSet(dir, "API_SECRET", "", strings.NewReader(in), &out, &errb); rc != 1 || out.Len() != 0 {
			t.Errorf("stdin %q: rc %d %s", in, rc, errb.String())
		}
	}

	// --up with no compose.yml is refused before the write.
	if rc, _, errs := remoteSetRun(dir, "other", "demo"); rc != 1 || !strings.Contains(errs, "compose.yml") {
		t.Errorf("no compose.yml: rc %d %s", rc, errs)
	}

	held, _, err := serverlock.Project(dir)
	if err != nil || held == nil {
		t.Fatal(err)
	}
	rc, _, errs := remoteSetRun(dir, "other", "")
	var ierr bytes.Buffer
	irc := Inject(dir+"/.env", []string{"KASBAH_CPU_LIMIT=1"}, &ierr)
	held.Close()
	if rc != 1 || !strings.Contains(errs, "(pid ") || !strings.Contains(errs, "holds "+dir+"/.deploy.lock") {
		t.Errorf("under a deploy: rc %d %s", rc, errs)
	}
	if irc != 1 || !strings.Contains(ierr.String(), "holds "+dir+"/.deploy.lock") {
		t.Errorf("inject under a held lock: rc %d %s", irc, ierr.String())
	}
	if got := readFile(t, dir+"/.env"); got != "API_SECRET=new\n" {
		t.Errorf("a refusal changed .env: %q", got)
	}
}

type fakeSet struct {
	calls     []string
	keyOut    string
	setOut    string
	setRC     int
	value, up string
}

func (f *fakeSet) Marker() (*marker.Marker, error) {
	f.calls = append(f.calls, "marker")
	return &marker.Marker{AppsPath: "/apps", CPULimit: "1", MemLimit: "1g"}, nil
}
func (f *fakeSet) KeyState(dir, key string) (string, int) {
	f.calls = append(f.calls, "key "+dir+" "+key)
	return f.keyOut, 0
}
func (f *fakeSet) SetKey(dir, key, value, up string) (string, int) {
	f.calls = append(f.calls, "set "+dir+" "+key)
	f.value, f.up = value, up
	return f.setOut, f.setRC
}
func (f *fakeSet) Close() {}

const known = "template_exists=yes\nin_template=yes\nenv_exists=yes\n"

func runSetCmd(t *testing.T, f *fakeSet, tty bool, input string, args ...string) (int, string, bool) {
	t.Helper()
	var stderr bytes.Buffer
	out := &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &stderr}
	o, err := Parse(append([]string{"set"}, args...))
	if err != nil {
		return out.Report(err), stderr.String(), false
	}
	dialed := false
	hidden := 0
	p := &prompt.Prompter{In: strings.NewReader(input), Out: out, TTY: tty}
	if tty {
		p.NoEcho = func() (func() error, error) { hidden++; return func() error { hidden--; return nil }, nil }
	}
	err = Run(Ctx{Out: out, Prompter: p, Version: "0.1.0",
		DialSet: func(string) (SetSession, error) { dialed = true; return f, nil }}, o)
	if hidden != 0 {
		t.Errorf("echo left off: %d", hidden)
	}
	return out.Report(err), stderr.String(), dialed
}

func TestRunSet(t *testing.T) {
	project(t, true)

	f := &fakeSet{keyOut: known, setOut: "set=changed\n"}
	code, errs, dialed := runSetCmd(t, f, false, "s3cr3t\n", "API_SECRET", "deploy@vps")
	if code != 1 || !strings.Contains(errs, "--restart") || !strings.Contains(errs, "--no-restart") || dialed {
		t.Errorf("no terminal, no flag: %d %q dialed=%v", code, errs, dialed)
	}

	code, errs, _ = runSetCmd(t, f, false, "s3cr3t\r\n", "API_SECRET", "deploy@vps", "--no-restart")
	if code != 0 || f.value != "s3cr3t" || f.up != "" || strings.Contains(errs, "s3cr3t") || !strings.Contains(errs, "API_SECRET changed") {
		t.Errorf("stdin: %d %q value %q up %q", code, errs, f.value, f.up)
	}
	if lastServer(t) != "deploy@vps" {
		t.Error("last_server not recorded")
	}

	for _, in := range []string{"", "\n", "a\nb\n"} {
		f := &fakeSet{keyOut: known}
		if code, errs, dialed := runSetCmd(t, f, false, in, "API_SECRET", "deploy@vps", "--no-restart"); code != 1 || dialed {
			t.Errorf("stdin %q: %d %q dialed=%v", in, code, errs, dialed)
		}
	}

	f = &fakeSet{keyOut: "template_exists=yes\nin_template=no\nenv_exists=yes\n"}
	code, errs, _ = runSetCmd(t, f, false, "v\n", "NOPE", "deploy@vps", "--no-restart")
	if code != 1 || !strings.Contains(errs, "not a key of /apps/demo/.env.prod.example") || len(f.calls) != 2 {
		t.Errorf("unknown key: %d %q %v", code, errs, f.calls)
	}

	// On a terminal: the value hidden, then the restart question.
	f = &fakeSet{keyOut: known, setOut: "set=added\nrestarted=yes\n"}
	code, errs, _ = runSetCmd(t, f, true, "typed-pw\ny\n", "API_SECRET", "deploy@vps")
	if code != 0 || f.value != "typed-pw" || f.up != "demo" || strings.Contains(errs, "typed-pw") || !strings.Contains(errs, "restarted") {
		t.Errorf("tty: %d %q value %q up %q", code, errs, f.value, f.up)
	}

	// The write landed and compose up did not: said so, not "nothing changed".
	f = &fakeSet{keyOut: known, setOut: "set=changed\n", setRC: 1}
	code, errs, _ = runSetCmd(t, f, false, "v", "API_SECRET", "deploy@vps", "--restart")
	if code != 1 || !strings.Contains(errs, "is set in") || f.up != "demo" {
		t.Errorf("up failed: %d %q", code, errs)
	}
}
