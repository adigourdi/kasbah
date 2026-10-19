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
	"unsafe"
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

// A .env the setup creates holds secrets and starts 600 whatever the umask;
// one that exists keeps its mode, and a symlinked one is written through.
func TestSetupMode(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)

	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "A=1\n")
	if rc := runSetup(t, dir, "\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o600 {
		t.Errorf("a created .env is %o, want 600", m)
	}

	os.Chmod(dir+"/.env", 0o640)
	var before syscall.Stat_t
	syscall.Stat(dir+"/.env", &before)
	if rc := runSetup(t, dir, "y\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o640 {
		t.Errorf("an existing .env became %o, want its own 640", m)
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
	if m := mode(t, dir+"/real"); m != 0o644 {
		t.Errorf("the target became %o", m)
	}
}

func TestInjectCreates600(t *testing.T) {
	old := syscall.Umask(0o022)
	defer syscall.Umask(old)
	dir := t.TempDir()
	if rc := Inject(dir+"/.env", []string{"KASBAH_CPU_LIMIT=0"}, &bytes.Buffer{}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if m := mode(t, dir+"/.env"); m != 0o600 {
		t.Errorf("an injected-into-existence .env is %o", m)
	}
	want := ManagedBegin + "\nKASBAH_CPU_LIMIT=0\n" + ManagedEnd + "\n"
	if b, _ := os.ReadFile(dir + "/.env"); string(b) != want {
		t.Errorf("got %q", b)
	}
}

func openPTY(t *testing.T) (master, slave *os.File) {
	t.Helper()
	m, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Skipf("no pty available: %v", err)
	}
	var unlock int32
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, m.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); e != 0 {
		m.Close()
		t.Skipf("unlockpt: %v", e)
	}
	var n uint32
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, m.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&n))); e != 0 {
		m.Close()
		t.Skipf("ptsname: %v", e)
	}
	s, err := os.OpenFile("/dev/pts/"+itoa(n), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		m.Close()
		t.Skipf("open slave: %v", err)
	}
	t.Cleanup(func() { s.Close(); m.Close() })
	return m, s
}

func itoa(n uint32) string {
	var b []byte
	for {
		b = append([]byte{byte('0' + n%10)}, b...)
		if n /= 10; n == 0 {
			return string(b)
		}
	}
}

func lflag(t *testing.T, fd uintptr) uint32 {
	var st syscall.Termios
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TCGETS, uintptr(unsafe.Pointer(&st))); e != 0 {
		t.Fatal(e)
	}
	return st.Lflag
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
