// Package fsstate is how `drop` and `server destroy` describe a path on the
// server, in the words internal/vlog gives `server status` and `server prune`.
package fsstate

import (
	"encoding/base64"
	"os"
	"syscall"
)

// Access is access(2): what `[ -r ]`, `[ -w ]` and `[ -x ]` answer.
func Access(path string, mode uint32) bool { return syscall.Access(path, mode) == nil }

const (
	R = 4
	W = 2
	X = 1
)

// Dir is dir, noaccess (not readable and enterable), notdir or absent.
func Dir(p string) string {
	fi, err := os.Stat(p)
	switch {
	case err != nil:
		return "absent"
	case !fi.IsDir():
		return "notdir"
	case !Access(p, R|X):
		return "noaccess"
	}
	return "dir"
}

// File is ok, empty, unreadable, notfile or missing.
func File(p string) string {
	fi, err := os.Stat(p)
	switch {
	case err != nil:
		return "missing"
	case !fi.Mode().IsRegular():
		return "notfile"
	case !Access(p, R):
		return "unreadable"
	case fi.Size() == 0:
		return "empty"
	}
	return "ok"
}

// Read is File, and the bytes in base64 when the state is ok; a read that
// fails or comes back empty makes it unreadable.
func Read(p string) (state, b64 string) {
	st := File(p)
	if st != "ok" {
		return st, ""
	}
	b, err := os.ReadFile(p)
	if err != nil || len(b) == 0 {
		return "unreadable", ""
	}
	return "ok", base64.StdEncoding.EncodeToString(b)
}

// Exists is `[ -e ] || [ -L ]`: a dangling link is still a name to remove.
func Exists(p string) bool {
	_, err := os.Lstat(p)
	return err == nil
}

// Remove is rm -f on one name: removed, absent or failed.
func Remove(p string) string {
	if !Exists(p) {
		return "absent"
	}
	if os.Remove(p) != nil {
		return "failed"
	}
	return "removed"
}
