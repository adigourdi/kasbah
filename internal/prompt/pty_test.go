//go:build linux

package prompt

import (
	"bytes"
	"os"
	"runtime"
	"strconv"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/term"
)

func openPTY(t *testing.T) (master, slave *os.File) {
	t.Helper()
	m, err := os.OpenFile("/dev/ptmx", os.O_RDWR, 0)
	if err != nil {
		t.Skipf("no pty: %v", err)
	}
	var unlock int32
	var n uint32
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, m.Fd(), syscall.TIOCSPTLCK, uintptr(unsafe.Pointer(&unlock))); e != 0 {
		t.Skipf("unlockpt: %v", e)
	}
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, m.Fd(), syscall.TIOCGPTN, uintptr(unsafe.Pointer(&n))); e != 0 {
		t.Skipf("ptsname: %v", e)
	}
	s, err := os.OpenFile("/dev/pts/"+strconv.Itoa(int(n)), os.O_RDWR|syscall.O_NOCTTY, 0)
	if err != nil {
		t.Skipf("open slave: %v", err)
	}
	t.Cleanup(func() { s.Close(); m.Close() })
	return m, s
}

func echoOff(fd uintptr) bool {
	var st syscall.Termios
	syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TCGETS, uintptr(unsafe.Pointer(&st)))
	return st.Lflag&syscall.ECHO == 0
}

// A secret typed at a real terminal comes back whole and never appears on it.
func TestSecretOnARealTerminal(t *testing.T) {
	master, slave := openPTY(t)
	p := &Prompter{
		In:     slave,
		Out:    &cli.Output{Stderr: slave},
		TTY:    term.IsTerminal(slave.Fd()),
		NoEcho: func() (func() error, error) { return term.NoEcho(slave.Fd()) },
	}
	if !p.TTY {
		t.Fatal("a pty is a terminal")
	}
	done := make(chan string, 1)
	go func() {
		a, err := p.Secret("traefik-auth", "Password?", "")
		if err != nil {
			a = "error: " + err.Error()
		}
		done <- a
	}()
	// Typed only once echo is off: input that arrives earlier is echoed by the
	// terminal itself, and the test would pass for the wrong reason.
	deadline := time.Now().Add(5 * time.Second)
	for !echoOff(slave.Fd()) {
		if time.Now().After(deadline) {
			t.Fatal("echo never went off")
		}
		time.Sleep(5 * time.Millisecond)
	}
	master.Write([]byte("hunter2\n"))
	if a := <-done; a != "hunter2" {
		t.Fatalf("answer %q", a)
	}
	if echoOff(slave.Fd()) {
		t.Error("echo not restored")
	}
	slave.Write([]byte("<<end>>"))
	screen := readUntil(t, master, "<<end>>")
	if bytes.Contains(screen, []byte("hunter2")) {
		t.Errorf("the secret reached the terminal: %q", string(screen))
	}
	if !bytes.Contains(screen, []byte("Password?: ")) {
		t.Errorf("the question did not: %q", string(screen))
	}
}

// readUntil reads the master side up to a marker, failing rather than hanging:
// the descriptor is blocking (Fd() made it so), so the read runs aside.
func readUntil(t *testing.T, master *os.File, marker string) []byte {
	t.Helper()
	got := make(chan []byte, 1)
	go func() {
		var screen bytes.Buffer
		buf := make([]byte, 4096)
		for !bytes.Contains(screen.Bytes(), []byte(marker)) {
			n, err := master.Read(buf)
			screen.Write(buf[:n])
			if err != nil {
				break
			}
		}
		got <- screen.Bytes()
	}()
	select {
	case s := <-got:
		return s
	case <-time.After(5 * time.Second):
		t.Fatalf("the terminal never showed %q", marker)
		return nil
	}
}

// Ctrl-C while a secret is typed puts echo back and exits 130, as bash does.
func TestSecretInterrupted(t *testing.T) {
	master, slave := openPTY(t)
	exited := make(chan int, 1)
	p := &Prompter{
		In:     slave,
		Out:    &cli.Output{Stderr: slave},
		TTY:    true,
		NoEcho: func() (func() error, error) { return term.NoEcho(slave.Fd()) },
		// os.Exit never returns: the stub ends the signal handler's goroutine.
		Exit: func(code int) { exited <- code; runtime.Goexit() },
	}
	returned := make(chan string, 1)
	go func() { a, _ := p.Secret("traefik-auth", "Password?", ""); returned <- a }()
	deadline := time.Now().Add(5 * time.Second)
	for !echoOff(slave.Fd()) {
		if time.Now().After(deadline) {
			t.Fatal("echo never went off")
		}
		time.Sleep(5 * time.Millisecond)
	}
	syscall.Kill(os.Getpid(), syscall.SIGINT)
	select {
	case code := <-exited:
		if code != 130 {
			t.Errorf("exit %d, want 130", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("SIGINT did not end the prompt")
	}
	if echoOff(slave.Fd()) {
		t.Error("echo left off after SIGINT")
	}
	// The read the real exit would have abandoned is answered, so the prompt
	// returns before the test does and nothing re-arms after it.
	master.Write([]byte("x\n"))
	select {
	case <-returned:
	case <-time.After(5 * time.Second):
		t.Fatal("the prompt outlived the test")
	}
}
