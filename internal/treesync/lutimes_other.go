//go:build !linux

package treesync

import (
	"errors"
	"os"
)

// lutimes is the server's, and servers are Linux.
func lutimes(*os.File, string, int64, int64) error {
	return errors.New("setting a symlink's mtime is supported on Linux only")
}
