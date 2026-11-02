//go:build !linux

package deploy

import (
	"errors"
	"os"
)

// renameat is the server's, and servers are Linux.
func renameat(*os.File, string, *os.File, string) error {
	return errors.New("renaming across directory handles is supported on Linux only")
}
