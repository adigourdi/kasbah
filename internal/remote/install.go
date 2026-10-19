package remote

import (
	"fmt"
	"io/fs"
	"os"
)

// Install writes body beside path as <path>.tmp.<pid> and renames it over,
// mode set first: a reader sees the old file or the new, and a write that did
// not finish is removed, never renamed.
func Install(path string, body []byte, mode fs.FileMode) error {
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, body, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not write %s", tmp)
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not set mode %o on %s", mode, tmp)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not install %s", path)
	}
	return nil
}
