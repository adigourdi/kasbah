package treesync

import (
	"os"
	"syscall"
	"unsafe"
)

const (
	atSymlinkNofollow = 0x100
	utimeOmit         = (1 << 30) - 2
)

// lutimes sets the mtime of the symlink name in dir, never its target's; the
// atime is left as it is.
func lutimes(dir *os.File, name string, sec, nsec int64) error {
	p, err := syscall.BytePtrFromString(name)
	if err != nil {
		return err
	}
	ts := [2]syscall.Timespec{{Nsec: utimeOmit}, {Sec: sec, Nsec: nsec}}
	_, _, e := syscall.Syscall6(syscall.SYS_UTIMENSAT, dir.Fd(), uintptr(unsafe.Pointer(p)),
		uintptr(unsafe.Pointer(&ts[0])), atSymlinkNofollow, 0, 0)
	if e != 0 {
		return e
	}
	return nil
}
