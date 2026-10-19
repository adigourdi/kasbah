//go:build linux || darwin || freebsd || netbsd || openbsd

package term

import (
	"syscall"
	"unsafe"
)

const echoFlag = syscall.ECHO

func getState(fd uintptr) (*syscall.Termios, error) {
	var st syscall.Termios
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, ioctlGet, uintptr(unsafe.Pointer(&st))); e != 0 {
		return nil, e
	}
	return &st, nil
}

func setState(fd uintptr, st *syscall.Termios) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, ioctlSet, uintptr(unsafe.Pointer(st))); e != 0 {
		return e
	}
	return nil
}

// CharMode is `read -n 1`'s terminal: canonical input off, so one keypress is
// returned without Enter; echo and signals unchanged.
func CharMode(fd uintptr) (restore func() error, err error) {
	st, err := getState(fd)
	if err != nil {
		return nil, err
	}
	raw := *st
	raw.Lflag &^= syscall.ICANON
	raw.Cc[syscall.VMIN] = 1
	raw.Cc[syscall.VTIME] = 0
	if err := setState(fd, &raw); err != nil {
		return nil, err
	}
	return func() error { return setState(fd, st) }, nil
}
