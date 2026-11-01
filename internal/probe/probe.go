// Package probe is what the server binary's read-only steps (`kasbah remote
// status`, `kasbah remote check`) ask of the filesystem and of docker. It
// reads and never writes.
package probe

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/manifest"
)

// FState is a path in one of the states the readers tell apart: nopath (no
// path given), absent, dir, notfile, unreadable, empty or file. `[ -e ]`
// semantics: a dangling symlink is absent.
func FState(p string) string {
	if p == "" {
		return "nopath"
	}
	fi, err := os.Stat(p)
	switch {
	case err != nil:
		return "absent"
	case fi.IsDir():
		return "dir"
	case !fi.Mode().IsRegular():
		return "notfile"
	case !Readable(p):
		return "unreadable"
	case fi.Size() == 0:
		return "empty"
	}
	return "file"
}

// DirState is absent, dir or notdir.
func DirState(p string) string {
	fi, err := os.Stat(p)
	switch {
	case err != nil:
		return "absent"
	case fi.IsDir():
		return "dir"
	}
	return "notdir"
}

// Readable is `[ -r ]` for this user.
func Readable(p string) bool { return syscall.Access(p, 4) == nil }

// Enterable is `[ -r ] && [ -x ]` on a directory.
func Enterable(p string) bool { return syscall.Access(p, 5) == nil }

// B64 is a regular, readable file's bytes base64'd, "" otherwise.
func B64(p string) string {
	if p == "" {
		return ""
	}
	b, err := ReadRegular(p)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

// ReadRegular is p's contents when p is a regular file: a FIFO or a device
// is refused rather than opened, so a read never blocks on one.
func ReadRegular(p string) ([]byte, error) {
	fi, err := os.Stat(p)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", p)
	}
	return os.ReadFile(p)
}

// Flat is a command's output as one protocol value: CRs dropped, newlines
// turned to spaces, trailing spaces trimmed.
func Flat(s string) string {
	s = strings.ReplaceAll(s, "\r", "")
	s = strings.ReplaceAll(s, "\n", " ")
	return strings.TrimRight(s, " ")
}

// HaveDocker is `command -v docker`.
func HaveDocker() bool {
	_, err := exec.LookPath("docker")
	return err == nil
}

// Docker runs docker with args and returns its stdout and exit status, -1
// when it could not run at all; stderr is discarded.
func Docker(args ...string) (string, int) {
	var out bytes.Buffer
	cmd := exec.Command("docker", args...)
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), rc(err)
}

// DockerErr is Docker with stderr returned instead of stdout.
func DockerErr(args ...string) (string, int) {
	var errb bytes.Buffer
	cmd := exec.Command("docker", args...)
	cmd.Stderr = &errb
	err := cmd.Run()
	return errb.String(), rc(err)
}

// DockerAll is Docker with stdout and stderr together (`2>&1`).
func DockerAll(args ...string) (string, int) {
	out, err := exec.Command("docker", args...).CombinedOutput()
	return string(out), rc(err)
}

func rc(err error) int {
	if err == nil {
		return 0
	}
	if e, ok := err.(*exec.ExitError); ok {
		return e.ExitCode()
	}
	return -1
}

// Lines is the non-empty lines of s.
func Lines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l != "" {
			out = append(out, l)
		}
	}
	return out
}

// Reserved is the names under <apps> that are kasbah's own, never projects.
var Reserved = append([]string{".kasbah"}, manifest.Reserved...)

// IsReserved reports whether name is one of Reserved.
func IsReserved(name string) bool {
	for _, r := range Reserved {
		if r == name {
			return true
		}
	}
	return false
}
