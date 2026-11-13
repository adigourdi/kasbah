//go:build linux

package term

import (
	"os"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

// openPTY opens a pseudo-terminal pair, so the terminal answers are proven on
// a real terminal rather than assumed from a pipe.
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
	if n == 0 {
		return "0"
	}
	var b []byte
	for ; n > 0; n /= 10 {
		b = append([]byte{byte('0' + n%10)}, b...)
	}
	return string(b)
}

func TestIsTerminal(t *testing.T) {
	_, slave := openPTY(t)
	if !IsTerminal(slave.Fd()) {
		t.Error("a pty slave is a terminal")
	}
	null, err := os.Open(os.DevNull)
	if err != nil {
		t.Fatal(err)
	}
	defer null.Close()
	if IsTerminal(null.Fd()) {
		t.Error("/dev/null is a character device, not a terminal")
	}
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	defer w.Close()
	if IsTerminal(r.Fd()) {
		t.Error("a pipe is not a terminal")
	}
}

func TestNoEcho(t *testing.T) {
	_, slave := openPTY(t)
	restore, err := NoEcho(slave.Fd())
	if err != nil {
		t.Fatal(err)
	}
	st, _ := getState(slave.Fd())
	if st.Lflag&echoFlag != 0 {
		t.Error("echo still on after NoEcho")
	}
	if err := restore(); err != nil {
		t.Fatal(err)
	}
	st, _ = getState(slave.Fd())
	if st.Lflag&echoFlag == 0 {
		t.Error("echo not restored")
	}
	if _, err := NoEcho(uintptr(^uint(0) >> 1)); err == nil {
		t.Error("NoEcho on a bad descriptor succeeds")
	}
}

func TestCharMode(t *testing.T) {
	_, slave := openPTY(t)
	restore, err := CharMode(slave.Fd())
	if err != nil {
		t.Fatal(err)
	}
	st, _ := getState(slave.Fd())
	if st.Lflag&syscall.ICANON != 0 || st.Cc[syscall.VMIN] != 1 {
		t.Error("canonical input still on after CharMode")
	}
	if st.Lflag&echoFlag == 0 {
		t.Error("CharMode turned echo off")
	}
	if err := restore(); err != nil {
		t.Fatal(err)
	}
	st, _ = getState(slave.Fd())
	if st.Lflag&syscall.ICANON == 0 {
		t.Error("canonical input not restored")
	}
}

// Flush drops what the terminal holds unread, so the rest of a paste already
// arrived does not reach the next reader.
func TestFlush(t *testing.T) {
	master, slave := openPTY(t)
	master.Write([]byte("left over\n"))
	pending := func() int32 {
		var n int32
		syscall.Syscall(syscall.SYS_IOCTL, slave.Fd(), syscall.TIOCINQ, uintptr(unsafe.Pointer(&n)))
		return n
	}
	for i := 0; i < 500 && pending() == 0; i++ {
		time.Sleep(time.Millisecond)
	}
	if pending() == 0 {
		t.Fatal("the input never arrived")
	}
	if err := Flush(slave.Fd()); err != nil {
		t.Fatal(err)
	}
	if n := pending(); n != 0 {
		t.Errorf("%d bytes still pending", n)
	}
	if err := Flush(uintptr(^uint(0) >> 1)); err == nil {
		t.Error("Flush on a bad descriptor succeeds")
	}
}
