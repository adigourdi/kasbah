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
