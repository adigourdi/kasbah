package term

import "syscall"

const (
	ioctlGet = syscall.TCGETS
	ioctlSet = syscall.TCSETS
	// asm-generic's values (amd64, arm64); amd64's syscall lacks TCFLSH.
	tcflsh, tcIflush = 0x540B, 0
)

// Flush discards input the terminal at fd holds that nothing has read yet
// (tcflush(TCIFLUSH)).
func Flush(fd uintptr) error {
	if _, _, e := syscall.Syscall(syscall.SYS_IOCTL, fd, tcflsh, tcIflush); e != 0 {
		return e
	}
	return nil
}
