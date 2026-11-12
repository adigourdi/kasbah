package remote

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
)

// Install writes body beside path as <path>.tmp.<pid>, sets mode (and gid,
// when given and allowed), and renames it over: a reader sees the old file or
// the new, and an unfinished write is removed, never renamed.
func Install(path string, body []byte, mode fs.FileMode, gid ...int) error {
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, body, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not write %s: %v", tmp, OSCause(err))
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not set mode %o on %s: %v", mode, tmp, OSCause(err))
	}
	if len(gid) > 0 && gid[0] != -1 {
		os.Lchown(tmp, -1, gid[0])
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not install %s: %v", path, OSCause(err))
	}
	return nil
}

// OSCause is err without the operation and paths the message already names.
func OSCause(err error) error {
	var pe *fs.PathError
	var le *os.LinkError
	switch {
	case errors.As(err, &pe):
		return pe.Err
	case errors.As(err, &le):
		return le.Err
	}
	return err
}
