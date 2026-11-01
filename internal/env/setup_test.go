package env

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

func runSetup(t *testing.T, dir, input string) int {
	t.Helper()
	in := filepath.Join(t.TempDir(), "stdin")
	write(t, in, input)
	f, err := os.Open(in)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	return (&Setup{Dir: dir, In: f, Out: &bytes.Buffer{}, Err: &bytes.Buffer{}}).Run()
}

func mode(t *testing.T, p string) os.FileMode {
	t.Helper()
	fi, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	return fi.Mode().Perm()
}

// A .env the setup creates holds secrets and starts 660 whatever the umask;
// one that exists keeps its mode with the group given the owner's read and
// write, and a symlinked one is written through.
func TestSetupMode(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)

	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "A=1\n")
	if rc := runSetup(t, dir, "\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o660 {
		t.Errorf("a created .env is %o, want 660", m)
	}

	os.Chmod(dir+"/.env", 0o600)
	var before syscall.Stat_t
	syscall.Stat(dir+"/.env", &before)
	if rc := runSetup(t, dir, "y\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o660 {
		t.Errorf("an existing 600 .env became %o, want 660", m)
	}
	var after syscall.Stat_t
	syscall.Stat(dir+"/.env", &after)
	if after.Ino == before.Ino {
		t.Error("the .env was rewritten in place, not renamed over")
	}
	if left, _ := filepath.Glob(dir + "/.env.kasbah-*"); len(left) > 0 {
		t.Errorf("staging left: %v", left)
	}

	dir = t.TempDir()
	write(t, dir+"/.env.prod.example", "A=1\n")
	write(t, dir+"/real", "A=old\nB=1\n")
	os.Chmod(dir+"/real", 0o644)
	os.Symlink("real", dir+"/.env")
	if rc := runSetup(t, dir, "\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if fi, _ := os.Lstat(dir + "/.env"); fi.Mode()&os.ModeSymlink == 0 {
		t.Error("the symlinked .env was replaced by a file")
	}
	if b, _ := os.ReadFile(dir + "/real"); string(b) != "A=old\n" {
		t.Errorf("the link's target holds %q", b)
	}
	if m := mode(t, dir+"/real"); m != 0o664 {
		t.Errorf("the target became %o, want 664", m)
	}
}

func TestInjectCreates660(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	dir := t.TempDir()
	if rc := Inject(dir+"/.env", []string{"KASBAH_CPU_LIMIT=0"}, &bytes.Buffer{}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o660 {
		t.Errorf("an injected-into-existence .env is %o", m)
	}
	os.Chmod(dir+"/.env", 0o600)
	if rc := Inject(dir+"/.env", []string{"KASBAH_CPU_LIMIT=1"}, &bytes.Buffer{}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o660 {
		t.Errorf("an existing 600 .env converged to %o, want 660", m)
	}
	want := ManagedBegin + "\nKASBAH_CPU_LIMIT=1\n" + ManagedEnd + "\n"
	if b, _ := os.ReadFile(dir + "/.env"); string(b) != want {
		t.Errorf("got %q", b)
	}
}

// On a terminal the menu takes one keypress with no Enter, a masked answer is
// not echoed, and the terminal is left as it was found.
func TestSetupOnATerminal(t *testing.T) {
	master, slave := openPTY(t)
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "A=1\nB_SECRET=2\n")
	write(t, dir+"/.env", "A=old\nGONE=1\n")
	before := lflag(t, slave.Fd())

	var mu sync.Mutex
	var echoed bytes.Buffer
	go func() {
		b := make([]byte, 256)
		for {
			n, err := master.Read(b)
			mu.Lock()
			echoed.Write(b[:n])
			mu.Unlock()
			if err != nil {
				return
			}
		}
	}()
	done := make(chan int, 1)
	var out bytes.Buffer
	go func() {
		done <- (&Setup{Dir: dir, In: slave, Out: &out, Err: &bytes.Buffer{}, TTY: true, TermFD: slave.Fd()}).Run()
	}()

	waitFor := func(what string, cond func() bool) {
		t.Helper()
		for range 200 {
			if cond() {
				return
			}
			time.Sleep(10 * time.Millisecond)
		}
		t.Fatalf("timed out waiting for %s", what)
	}
	waitFor("the menu's one-key mode", func() bool { return lflag(t, slave.Fd())&syscall.ICANON == 0 })
	master.Write([]byte("a"))
	waitFor("canonical input back", func() bool { return lflag(t, slave.Fd())&syscall.ICANON != 0 })
	master.Write([]byte("\n"))
	waitFor("echo off for the secret", func() bool { return lflag(t, slave.Fd())&syscall.ECHO == 0 })
	master.Write([]byte("s3cret\n"))

	select {
	case rc := <-done:
		if rc != 0 {
			t.Fatalf("rc %d: %s", rc, out.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the setup did not finish")
	}
	if b, _ := os.ReadFile(dir + "/.env"); string(b) != "A=old\nB_SECRET=s3cret\n" {
		t.Errorf(".env = %q", b)
	}
	if after := lflag(t, slave.Fd()); after != before {
		t.Errorf("terminal flags %#x after, %#x before", after, before)
	}
	time.Sleep(50 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if strings.Contains(echoed.String(), "s3cret") {
		t.Errorf("the secret was echoed: %q", echoed.String())
	}
}

// A generator run from an ssh session reads no rc file: bash would source
// ~/.bashrc there (SSH_CLIENT, SHLVL 0), and its output would become the value.
func TestGeneratorReadsNoRC(t *testing.T) {
	home := t.TempDir()
	write(t, home+"/.bashrc", "echo rc-noise\n")
	write(t, home+"/.bash_profile", "echo profile-noise\n")
	write(t, home+"/env", "echo env-noise\n")
	t.Setenv("HOME", home)
	t.Setenv("SSH_CLIENT", "1 2 3")
	t.Setenv("SHLVL", "0")
	t.Setenv("BASH_ENV", home+"/env")
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "G=! echo g\n")
	if rc := runSetup(t, dir, "\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if b, _ := os.ReadFile(dir + "/.env"); string(b) != "G=g\n" {
		t.Errorf(".env = %q", b)
	}
}

// A FIFO or a directory where a file belongs is refused, never read.
func TestNonRegularFiles(t *testing.T) {
	for _, c := range []struct{ name, fifo string }{
		{"template FIFO", ".env.prod.example"},
		{".env FIFO", ".env"},
		{".env directory", ""},
	} {
		dir := t.TempDir()
		if c.fifo != ".env.prod.example" {
			write(t, dir+"/.env.prod.example", "A=1\n")
		}
		if c.fifo != "" {
			if err := syscall.Mkfifo(dir+"/"+c.fifo, 0o600); err != nil {
				t.Fatal(err)
			}
		} else {
			os.Mkdir(dir+"/.env", 0o755)
		}
		done := make(chan int, 1)
		go func() { done <- runSetup(t, dir, "\n") }()
		select {
		case rc := <-done:
			if rc != 1 {
				t.Errorf("%s: rc %d", c.name, rc)
			}
		case <-time.After(3 * time.Second):
			t.Fatalf("%s: the setup blocked", c.name)
		}
	}
}

// seeded runs the setup with a seed and input, returning rc, stdout, stderr.
func seeded(t *testing.T, dir string, seed map[string]string, headless bool, input string) (int, string, string) {
	t.Helper()
	in := filepath.Join(t.TempDir(), "stdin")
	write(t, in, input)
	f, err := os.Open(in)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out, errw bytes.Buffer
	rc := (&Setup{Dir: dir, In: f, Out: &out, Err: &errw, Seed: seed, Headless: headless}).Run()
	return rc, out.String(), errw.String()
}

const shapes = "# === S ===\nGEN=! touch \"$TARGET_DIR/ran\"; echo gen\nHINT=# a hint\nDEF=d # comment\nEMPTY=\nPLAIN=p\nDB_PASSWORD=x\n"

func TestSetupSeedEveryShape(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", shapes)
	seed := map[string]string{"GEN": "seeded", "HINT": "'a b'", "DEF": "s3cret-def", "EMPTY": "", "PLAIN": "$$x", "DB_PASSWORD": "s3cret-pw", "NOT_IN_TEMPLATE": "s3cret-z"}
	rc, out, errw := seeded(t, dir, seed, true, "")
	if rc != 0 {
		t.Fatalf("rc %d %q %q", rc, out, errw)
	}
	want := "# === S ===\nGEN=seeded\nHINT='a b'\nDEF=s3cret-def\nEMPTY=\nPLAIN=$$x\nDB_PASSWORD=s3cret-pw\n"
	if got, _ := os.ReadFile(dir + "/.env"); string(got) != want {
		t.Errorf(".env = %q, want %q", got, want)
	}
	if _, err := os.Stat(dir + "/ran"); err == nil {
		t.Error("a seeded `! command` key ran its generator")
	}
	if strings.Contains(out+errw, "s3cret") || !strings.Contains(out, "DB_PASSWORD (seed)") || !strings.Contains(out, "seed: 6 answered, 1 not used") {
		t.Errorf("output: %q %q", out, errw)
	}
}

func TestSetupSeedPartial(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", shapes)
	seed := map[string]string{"GEN": "seeded", "DB_PASSWORD": "s3cret-pw"}
	rc, out, errw := seeded(t, dir, seed, true, "")
	if rc != SetupUnanswered || !strings.Contains(errw, "does not answer: HINT DEF EMPTY PLAIN —") || strings.Contains(out+errw, "s3cret") {
		t.Errorf("headless partial: %d %q %q", rc, out, errw)
	}
	if _, err := os.Stat(dir + "/.env"); err == nil {
		t.Error("a refused headless run wrote .env")
	}
	// On a terminal (piped here) the rest is asked, in order.
	rc, out, _ = seeded(t, dir, seed, false, "typed\n\n\n\n")
	want := "# === S ===\nGEN=seeded\nHINT=typed\nDEF=d\nEMPTY=\nPLAIN=p\nDB_PASSWORD=s3cret-pw\n"
	if got, _ := os.ReadFile(dir + "/.env"); rc != 0 || string(got) != want {
		t.Errorf("partial: %d .env = %q, want %q (%q)", rc, got, want, out)
	}
	if strings.Contains(out, "GEN (auto)") || strings.Contains(out, "DB_PASSWORD [") {
		t.Errorf("a seeded key was prompted: %q", out)
	}
}

func TestSetupSeedNeverTouchesSetKeys(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "A=1\nB=2\nC_KEY=3\n")
	write(t, dir+"/.env", "A=live\n")
	seed := map[string]string{"A": "s3cret-a", "B": "seed-b", "C_KEY": "seed-c"}
	rc, out, errw := seeded(t, dir, seed, true, "")
	if got, _ := os.ReadFile(dir + "/.env"); rc != 0 || string(got) != "A=live\nB=seed-b\nC_KEY=seed-c\n" {
		t.Errorf("fill: %d %q %q %q", rc, got, out, errw)
	}
	if strings.Contains(out, "[Enter]") || !strings.Contains(out, "Filling 2 new variable(s) from the seed") || !strings.Contains(out, "2 answered, 1 not used") {
		t.Errorf("drift the seed covers asks nothing: %q", out)
	}

	// Reconfigure all: a set key is asked, the seed fills only what .env lacks.
	write(t, dir+"/.env", "A=live\n")
	rc, _, _ = seeded(t, dir, map[string]string{"A": "s3cret-a"}, false, "a\n\n\n")
	if got, _ := os.ReadFile(dir + "/.env"); rc != 0 || string(got) != "A=live\nB=2\nC_KEY=3\n" {
		t.Errorf("reconfigure: %d %q", rc, got)
	}

	for _, env := range []string{"A=live\nB=2\nC_KEY=3\nOLD=1\n", "A=live\nB=2\nC_KEY=3\n", "A=live\n"} {
		write(t, dir+"/.env", env)
		rc, _, errw = seeded(t, dir, map[string]string{"B": "x"}, true, "")
		if got, _ := os.ReadFile(dir + "/.env"); rc != SetupUnanswered || string(got) != env || !strings.Contains(errw, "does not answer") {
			t.Errorf("headless with a question left (%q): %d %q %q", env, rc, got, errw)
		}
	}
}

func TestRemoteSeed(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "A=1\nB_SECRET=2\n")
	body := "A=x\nB_SECRET='s3cret v'\n"
	var out, errw bytes.Buffer
	call := func(in string, args ...string) int {
		out.Reset()
		errw.Reset()
		f := filepath.Join(t.TempDir(), "in")
		write(t, f, in)
		r, _ := os.Open(f)
		defer r.Close()
		return Remote(args, r, &out, &errw)
	}
	const tok = "0123456789abcdef"
	path := filepath.Join(dir, SeedName+"."+tok)
	gone := func(what string) {
		t.Helper()
		if es, _ := filepath.Glob(filepath.Join(dir, SeedName+"*")); len(es) > 0 {
			t.Errorf("%s left %v", what, es)
		}
	}
	for _, bad := range []string{"", body, "5 abc\n" + body, SetHeader(body) + body[:5], SetHeader("KASBAH_X=1\n") + "KASBAH_X=1\n", SetHeader("# c\n") + "# c\n"} {
		if rc := call(bad, "seed", dir, tok); rc != 1 || strings.Contains(errw.String(), "s3cret") {
			t.Errorf("staged %q: %d %q", bad, rc, errw.String())
		}
		gone("a refused payload")
	}
	for _, bad := range []string{"", "../x", "0123456789ABCDEF", "short"} {
		if rc := call(SetHeader(body)+body, "seed", dir, bad); rc != 1 {
			t.Errorf("token %q: %d", bad, rc)
		}
		gone("a bad token")
	}
	if rc := call(SetHeader(body)+body, "seed", dir, tok); rc != 0 || out.String() != "staged=yes\n" || mode(t, path) != 0o600 {
		t.Fatalf("stage: %d %q %q", rc, out.String(), errw.String())
	}
	if rc := call("", "setup", dir, "--color=no", "--seed=fedcba9876543210", "--headless"); rc != 1 || !strings.Contains(errw.String(), "no staged seed") {
		t.Errorf("another run's token: %d %q", rc, errw.String())
	}
	if rc := call("", "setup", dir, "--color=no", "--seed="+tok, "--headless"); rc != 0 {
		t.Fatalf("setup: %d %q %q", rc, out.String(), errw.String())
	}
	if got, _ := os.ReadFile(dir + "/.env"); string(got) != body || strings.Contains(out.String(), "s3cret") {
		t.Errorf(".env %q, output %q", got, out.String())
	}
	gone("the setup")
	if rc := call("", "setup", dir, "--seed="+tok, "--headless"); rc != 1 || !strings.Contains(errw.String(), "no staged seed") {
		t.Errorf("setup with no staged seed: %d %q", rc, errw.String())
	}

	// Headless, the seed rides on stdin and nothing is staged.
	os.Remove(dir + "/.env")
	if rc := call(SetHeader(body)+body, "setup", dir, "--headless", "--seed"); rc != 0 {
		t.Fatalf("headless stdin: %d %q", rc, errw.String())
	}
	if got, _ := os.ReadFile(dir + "/.env"); string(got) != body {
		t.Errorf("headless stdin .env %q", got)
	}
	gone("a headless setup")
	os.Remove(dir + "/.env")
	for _, bad := range []string{"", "DB_PASSWORD=my secret\n", SetHeader(body) + body[:5]} {
		if rc := call(bad, "setup", dir, "--headless", "--seed"); rc != 1 || strings.Contains(errw.String(), "my") {
			t.Errorf("headless stdin %q: %d %q", bad, rc, errw.String())
		}
	}
	if rc := call("A=x\n", "setup", dir, "--seed"); rc != 1 || !strings.Contains(errw.String(), "usage") {
		t.Errorf("a bare --seed needs --headless: %d %q", rc, errw.String())
	}
	if _, err := os.Stat(dir + "/.env"); err == nil {
		t.Error("a refused seed wrote .env")
	}
	if rc := call(SetHeader("A=x\n")+"A=x\n", "setup", dir, "--headless", "--seed"); rc != SetupUnanswered || !strings.Contains(errw.String(), "B_SECRET") {
		t.Errorf("headless partial: %d %q", rc, errw.String())
	}

	call(SetHeader(body)+body, "seed", dir, tok)
	if rc := call("", "setup", dir, "--seed="+tok, "--bogus"); rc != 1 {
		t.Errorf("a usage error: %d", rc)
	}
	gone("a usage error")
	call(SetHeader(body)+body, "seed", dir, tok)
	call(SetHeader(body)+body, "seed", dir, "fedcba9876543210")
	write(t, path+".99", "A=x\n")
	if rc := call("", "drift", dir); rc != 0 {
		t.Errorf("drift: %d", rc)
	}
	gone("the drift step")
}
