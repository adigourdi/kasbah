//go:build !linux

package env

import (
	"os"
	"testing"
)

// The pty cases open /dev/ptmx the linux way; elsewhere they are skipped.
func openPTY(t *testing.T) (master, slave *os.File) {
	t.Skip("the pty helper is linux-only")
	return nil, nil
}

func lflag(t *testing.T, fd uintptr) uint32 { return 0 }
