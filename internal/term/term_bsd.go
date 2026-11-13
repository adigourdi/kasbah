//go:build darwin || freebsd || netbsd || openbsd

package term

import (
	"syscall"
	"unsafe"
)

const (
	ioctlGet = syscall.TIOCGETA
	ioctlSet = syscall.TIOCSETA
)

// Flush discards input the terminal at fd holds that nothing has read yet
// (tcflush(TCIFLUSH)).
func Flush(fd uintptr) error {
	which := int32(syscall.O_RDONLY + 1) // FREAD
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, syscall.TIOCFLUSH, uintptr(unsafe.Pointer(&which))); e != 0 {
		return e
	}
	return nil
}
