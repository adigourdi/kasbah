package trace

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func start(t *testing.T, debug bool, args ...string) *bytes.Buffer {
	t.Helper()
	Reset()
	t.Cleanup(Reset)
	var stderr bytes.Buffer
	state := t.TempDir()
	Begin(Config{Debug: debug, Version: "kasbah 1.2.3 (schema 1)", Args: args, Stderr: &stderr,
		Getenv: func(k string) string { return map[string]string{"XDG_STATE_HOME": state, "HOME": "/nonexistent"}[k] }})
	return &stderr
}

func TestWords(t *testing.T) {
	got := Words([]string{"docker", "compose", "-p", "a b", "it's", "", "x=1"})
	if want := `docker compose -p 'a b' 'it'\''s' '' x=1`; got != want {
		t.Errorf("Words = %s, want %s", got, want)
	}
}

func TestSecret(t *testing.T) {
	// One registered before Begin, as an early caller does, still counts.
	Reset()
	t.Cleanup(Reset)
	Secret("early-token")
	Begin(Config{Stderr: &bytes.Buffer{}, Getenv: func(string) string { return "" }})
	Note("token early-token")
	if strings.Contains(Text(), "early-token") {
		t.Errorf("a secret registered before Begin is recorded:\n%s", Text())
	}
	start(t, false)
	Secret("hunter22", "abc", "", "-----BEGIN KEY-----\nc2VjcmV0bGluZQ==\n-----END KEY-----")
	for in, want := range map[string]string{
		"pw=hunter22 and hunter22": "pw=*** and ***",
		"abc stays: too short":     "abc stays: too short",
		"line c2VjcmV0bGluZQ== in": "line *** in",
	} {
		if got := Scrub(in); got != want {
			t.Errorf("Scrub(%q) = %q, want %q", in, got, want)
		}
	}
	Secret("hunter2")
	if got := Scrub("hunter22 hunter2"); got != "*** ***" {
		t.Errorf("longest first: %q", got)
	}
	Note("the password is hunter22")
	if strings.Contains(Text(), "hunter22") || !strings.Contains(Text(), "note: the password is ***") {
		t.Errorf("a note keeps a secret:\n%s", Text())
	}
}

func TestRun(t *testing.T) {
	start(t, false)
	Secret("s3cr3t-value")
	cmd := exec.Command("sh", "-c", `cat >/dev/null; echo out; echo "warn s3cr3t-value" >&2; printf 'part' >&2; exit 3`, "x")
	cmd.Stdin = strings.NewReader("payload-never-recorded\n")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := Output(cmd)
	if ssh := exitCode(err); ssh != 3 || string(out) != "out\n" || stderr.String() != "warn s3cr3t-value\npart" {
		t.Errorf("Output: rc %d, out %q, stderr %q", ssh, out, stderr.String())
	}
	tr := Text()
	for _, want := range []string{"] run: sh -c ", "[1] stderr: warn ***\n", "[1] stderr: part\n", "[1] exit 3 after "} {
		if !strings.Contains(tr, want) {
			t.Errorf("trace lacks %q:\n%s", want, tr)
		}
	}
	for _, never := range []string{"payload-never-recorded", "s3cr3t-value", "] stderr: out"} {
		if strings.Contains(tr, never) {
			t.Errorf("trace holds %q:\n%s", never, tr)
		}
	}

	// Output with no Stderr of its own still hands back stderr on failure.
	_, err = Output(exec.Command("sh", "-c", "echo why >&2; exit 1"))
	var ee *exec.ExitError
	if !errors.As(err, &ee) || string(ee.Stderr) != "why\n" {
		t.Errorf("ExitError.Stderr: %v", err)
	}
	if err := Run(exec.Command("/nonexistent/tool")); err == nil || !strings.Contains(Text(), "failed: ") {
		t.Errorf("a command that cannot start: %v\n%s", err, Text())
	}
	c := exec.Command("sh", "-c", "kill -TERM $$")
	if Start(c) != nil || Wait(c) == nil || !strings.Contains(Text(), "killed by terminated") {
		t.Errorf("a killed command:\n%s", Text())
	}
}

func exitCode(err error) int {
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	if err != nil {
		return -1
	}
	return 0
}

// Stdout and Stderr one writer stay one pipe with one copier: nothing is
// lost or raced (run with -race), and only the command and its exit are kept.
func TestSharedWriter(t *testing.T) {
	start(t, false)
	for i := 0; i < 20; i++ {
		cmd := exec.Command("sh", "-c", `i=0; while [ $i -lt 200 ]; do echo "out $i"; echo "err $i" >&2; i=$((i+1)); done`)
		var b bytes.Buffer
		cmd.Stdout, cmd.Stderr = &b, &b
		if err := Run(cmd); err != nil || cmd.Stderr != &b {
			t.Fatalf("run %d: %v, stderr swapped: %v", i, err, cmd.Stderr != &b)
		}
		if n := strings.Count(b.String(), "\n"); n != 400 {
			t.Fatalf("run %d: %d lines, want 400", i, n)
		}
	}
	if tr := Text(); strings.Contains(tr, "] stderr: ") || !strings.Contains(tr, "[20] exit 0 after ") {
		t.Errorf("trace:\n%s", tr)
	}
}

// With no trace running, the calls are exec's own and touch nothing.
func TestOff(t *testing.T) {
	Reset()
	cmd := exec.Command("sh", "-c", "echo e >&2")
	var b bytes.Buffer
	cmd.Stderr = &b
	if Run(cmd) != nil || cmd.Stderr != &b || b.String() != "e\n" || Text() != "" {
		t.Errorf("off: stderr %q, trace %q", b.String(), Text())
	}
}

func TestDebugStream(t *testing.T) {
	stderr := start(t, true)
	cmd := exec.Command("sh", "-c", "echo hidden >&2")
	var b bytes.Buffer
	cmd.Stderr = &b
	Run(cmd)
	Note("kept")
	got := stderr.String()
	if !strings.Contains(got, "debug: ") || !strings.Contains(got, "[1] stderr: hidden") || !strings.Contains(got, "note: kept") {
		t.Errorf("debug stream:\n%s", got)
	}
	for _, l := range strings.Split(strings.TrimSuffix(got, "\n"), "\n") {
		if !strings.HasPrefix(l, "debug: ") {
			t.Errorf("a streamed line without its prefix: %q", l)
		}
	}
}

// A server arm's frames are folded in and taken out of its stderr, wherever
// they fall and however the writes split them.
func TestFrames(t *testing.T) {
	start(t, false)
	in := "before\n" + frame + "[1] run: docker ps\n" + "half" + frame + "[1] exit 0\n" + "line\n\x1enot a frame\n"
	for split := 1; split <= len(in); split++ {
		var out bytes.Buffer
		f := &frames{out: &out}
		for i := 0; i < len(in); i += split {
			f.Write([]byte(in[i:min(i+split, len(in))]))
		}
		f.flush()
		if want := "before\nhalfline\n\x1enot a frame\n"; out.String() != want {
			t.Fatalf("split %d: passed %q, want %q", split, out.String(), want)
		}
	}
	if n := strings.Count(Text(), "server: [1] run: docker ps\n"); n != len(in) {
		t.Errorf("folded %d times, want %d:\n%s", n, len(in), Text())
	}
}

// Serve's lines come out as frames a workstation folds back.
func TestServeRoundTrip(t *testing.T) {
	Reset()
	t.Cleanup(Reset)
	var wire bytes.Buffer
	Serve(&wire)
	Secret("srv-secret")
	cmd := exec.Command("sh", "-c", "echo 'compose: no srv-secret' >&2; exit 2")
	var shown bytes.Buffer
	cmd.Stderr = &shown
	Run(cmd)
	if shown.String() != "compose: no srv-secret\n" {
		t.Errorf("the arm's own stderr changed: %q", shown.String())
	}
	frames0 := wire.String()
	if strings.Contains(frames0, "srv-secret") || !strings.Contains(frames0, frame+"[1] stderr: compose: no ***\n") {
		t.Errorf("frames:\n%q", frames0)
	}

	start(t, false)
	arm := exec.Command("sh", "-c", `printf '%s' "$FR" >&2 #`)
	arm.Env = append(os.Environ(), "FR="+frames0+"error: shown\n")
	SSH(arm, "ssh u@h: kasbah remote x", true, false)
	var ws bytes.Buffer
	arm.Stderr = &ws
	Run(arm)
	if ws.String() != "error: shown\n" {
		t.Errorf("the workstation shows %q", ws.String())
	}
	if arm.Args[2] != `printf '%s' "$FR" >&2 # --trace` {
		t.Errorf("args: %q", arm.Args)
	}
	tr := Text()
	for _, want := range []string{"[1] ssh u@h: kasbah remote x\n", "server: [1] run: sh -c", "server: [1] exit 2 after", "[1] stderr: error: shown\n"} {
		if !strings.Contains(tr, want) {
			t.Errorf("trace lacks %q:\n%s", want, tr)
		}
	}
}

func TestMarker(t *testing.T) {
	start(t, false)
	cmd := exec.Command("ssh", "u@h", "'kasbah' 'remote' 'x'")
	cmd.Path = "/bin/true"
	SSH(cmd, "ssh u@h: kasbah remote x", true, false)
	Run(cmd)
	if got := cmd.Args[len(cmd.Args)-1]; got != "'kasbah' 'remote' 'x' --trace" {
		t.Errorf("remote command %q", got)
	}
	plain := exec.Command("/bin/true", "'kasbah' 'remote' 'x'")
	SSH(plain, "ssh -t u@h: kasbah remote x", false, false)
	Run(plain)
	if got := plain.Args[1]; got != "'kasbah' 'remote' 'x'" {
		t.Errorf("a call that is no arm got %q", got)
	}
}

func TestNames(t *testing.T) {
	at := time.Date(2026, 11, 15, 12, 1, 2, 345e6, time.FixedZone("x", 3600))
	for args, want := range map[string]string{
		"deploy u@h":            "20261115T110102.345Z-deploy.log",
		"server init u@h --yes": "20261115T110102.345Z-server-init.log",
		"env set KEY u@h":       "20261115T110102.345Z-env-set.log",
		"env u@h":               "20261115T110102.345Z-env.log",
		"migrate server u@h":    "20261115T110102.345Z-migrate-server.log",
		"":                      "20261115T110102.345Z-kasbah.log",
		"--version":             "20261115T110102.345Z-kasbah.log",
		"Deploy":                "20261115T110102.345Z-kasbah.log",
		"server --help":         "20261115T110102.345Z-server.log",
	} {
		if got := Name(at, strings.Fields(args)); got != want || !reLog.MatchString(got) {
			t.Errorf("Name(%q) = %s, want %s", args, got, want)
		}
	}
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	for _, tt := range []struct {
		env  map[string]string
		want string
	}{
		{map[string]string{"XDG_STATE_HOME": "/s", "HOME": "/h"}, "/s/kasbah/logs"},
		{map[string]string{"XDG_STATE_HOME": "rel", "HOME": "/h"}, "/h/.local/state/kasbah/logs"},
		{map[string]string{"HOME": "/h"}, "/h/.local/state/kasbah/logs"},
	} {
		if got, err := Dir(env(tt.env)); err != nil || got != tt.want {
			t.Errorf("Dir(%v) = %s, %v", tt.env, got, err)
		}
	}
	if _, err := Dir(env(nil)); err == nil {
		t.Error("Dir with no HOME")
	}
}

func TestCommandLine(t *testing.T) {
	start(t, false)
	Secret("seed-value-1")
	got := CommandLine([]string{"server", "init", "u@h", "--traefik-auth=admin:pw", "--postmaster-password=x y",
		"--backup-password=r=pw", "--backup-env=K=V", "--backup-repo-base=rest:https://u:p@h/", "--domain=seed-value-1.example"})
	want := "kasbah server init u@h --traefik-auth=*** --postmaster-password=*** --backup-password=*** --backup-env=*** --backup-repo-base=*** --domain=***.example"
	if got != want {
		t.Errorf("CommandLine:\n%s\nwant\n%s", got, want)
	}
}

func TestLog(t *testing.T) {
	stderr := start(t, false, "deploy", "u@h", "--token=abc123")
	Note("first")
	path, err := Failed(1)
	if err != nil || path == "" {
		t.Fatalf("Failed: %s, %v", path, err)
	}
	dir := filepath.Dir(path)
	for p, mode := range map[string]os.FileMode{path: 0o600, dir: 0o700, filepath.Dir(dir): 0o700} {
		if fi, err := os.Stat(p); err != nil || fi.Mode().Perm() != mode {
			t.Errorf("%s: %v %v, want %04o", p, fi.Mode(), err, mode)
		}
	}
	if again, _ := Failed(1); again != path {
		t.Errorf("a second failure names %s, not %s", again, path)
	}
	Note("during the cleanups")
	Finish(130, true)
	body, _ := os.ReadFile(path)
	head := "kasbah 1.2.3 (schema 1)\ncommand: kasbah deploy u@h --token=***\nstarted: "
	if !strings.HasPrefix(string(body), head) || !strings.Contains(string(body), "\nexit: 130\n\n") ||
		!strings.Contains(string(body), "note: first\n") || !strings.Contains(string(body), "note: during the cleanups\n") {
		t.Errorf("log:\n%s", body)
	}
	if stderr.Len() != 0 {
		t.Errorf("Finish after a failure that named the log printed %q", stderr.String())
	}

	// The rewrite goes through the file it created, never a link put there.
	start(t, false, "deploy")
	path, _ = Failed(1)
	other := filepath.Join(t.TempDir(), "elsewhere")
	os.WriteFile(other, []byte("untouched"), 0o600)
	os.Remove(path)
	if err := os.Symlink(other, path); err != nil {
		t.Fatal(err)
	}
	Finish(1, false)
	if got, _ := os.ReadFile(other); string(got) != "untouched" {
		t.Errorf("the rewrite followed a symlink: %q", got)
	}
}

// A signal, or a --debug run, saves the log at the exit and names it there.
func TestFinish(t *testing.T) {
	stderr := start(t, false, "logs", "-f")
	Finish(0, false)
	if stderr.Len() != 0 {
		t.Errorf("a run that succeeded: %q", stderr.String())
	}
	Finish(130, true)
	if !strings.HasPrefix(stderr.String(), "log: ") || !strings.HasSuffix(stderr.String(), "-logs.log\n") {
		t.Errorf("a signal: %q", stderr.String())
	}
	stderr = start(t, true, "info")
	Finish(0, false)
	if got := stderr.String(); !strings.Contains(got, "debug: log: ") {
		t.Errorf("a debug run: %q", got)
	}
}

func TestRetention(t *testing.T) {
	start(t, false, "deploy")
	dir, _ := Dir(st.log.getenv)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	for i := range 25 {
		os.WriteFile(filepath.Join(dir, fmt.Sprintf("2020010%dT000000.000Z-old%02d.log", i/10, i)), nil, 0o600)
	}
	os.WriteFile(filepath.Join(dir, "notes.txt"), nil, 0o600)
	path, err := Failed(1)
	if err != nil {
		t.Fatal(err)
	}
	logs := list(dir)
	if len(logs) != Keep || logs[len(logs)-1] != filepath.Base(path) || logs[0] != "20200100T000000.000Z-old06.log" {
		t.Errorf("kept %d: %v", len(logs), logs)
	}
	if _, err := os.Stat(filepath.Join(dir, "notes.txt")); err != nil {
		t.Error("a file that is no log was removed")
	}
	if Latest(dir) != path {
		t.Errorf("Latest = %s", Latest(dir))
	}

	// Two runs in the same millisecond do not share a log.
	st.log.saved = false
	second, err := Failed(1)
	if err != nil || second == path || !strings.HasSuffix(second, ".1.log") {
		t.Errorf("second: %s, %v", second, err)
	}
}

func TestUnwritable(t *testing.T) {
	Reset()
	t.Cleanup(Reset)
	var stderr bytes.Buffer
	file := filepath.Join(t.TempDir(), "file")
	os.WriteFile(file, nil, 0o600)
	Begin(Config{Args: []string{"deploy"}, Stderr: &stderr, Getenv: func(k string) string {
		return map[string]string{"XDG_STATE_HOME": file}[k]
	}})
	if path, err := Failed(1); path != "" || err == nil {
		t.Errorf("Failed under a file: %s, %v", path, err)
	}
}
