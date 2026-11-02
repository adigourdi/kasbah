package deploy

import (
	"os"
	"syscall"
)

// renameat renames from/fromName to to/toName, each name relative to its
// directory: one rename across two handles.
func renameat(from *os.File, fromName string, to *os.File, toName string) error {
	return syscall.Renameat(int(from.Fd()), fromName, int(to.Fd()), toName)
}
