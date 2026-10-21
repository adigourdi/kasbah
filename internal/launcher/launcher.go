// Package launcher is the versioned install on a workstation
// (<lib>/<ver>/kasbah, docs/files.md) and the hand-off between its versions:
// the binary that answers a command is the one the server, or the project's
// manifest, wants.
package launcher

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/version"
)

// Env marks a process a hand-off started, with the build that handed off; a
// second refusal there is final.
const Env = "KASBAH_HANDOFF"

// Root is the library root: the one the kasbah at exe runs from
// (<root>/<ver>/kasbah, ver a version), else KASBAH_LIB_DIR, else
// $XDG_DATA_HOME/kasbah, else ~/.local/share/kasbah.
func Root(exe string, getenv func(string) string) (string, error) {
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	if dir := filepath.Dir(exe); filepath.Base(exe) == "kasbah" {
		if _, err := version.Parse(filepath.Base(dir)); err == nil {
			return filepath.Dir(dir), nil
		}
	}
	switch {
	case getenv("KASBAH_LIB_DIR") != "":
		return getenv("KASBAH_LIB_DIR"), nil
	case getenv("XDG_DATA_HOME") != "":
		return filepath.Join(getenv("XDG_DATA_HOME"), "kasbah"), nil
	case getenv("HOME") != "":
		return filepath.Join(getenv("HOME"), ".local", "share", "kasbah"), nil
	}
	return "", errors.New("neither KASBAH_LIB_DIR, XDG_DATA_HOME, nor HOME is set")
}

// Entry is one installed version: its directory's name parsed, and its binary.
type Entry struct {
	Version version.Version
	Bin     string
}

// Installed lists root's version directories that hold an executable kasbah,
// newest first. A root that does not exist lists nothing.
func Installed(root string) []Entry {
	ents, _ := os.ReadDir(root)
	var out []Entry
	for _, e := range ents {
		v, err := version.Parse(e.Name())
		if err != nil || !e.IsDir() {
			continue
		}
		bin := filepath.Join(root, e.Name(), "kasbah")
		if fi, err := os.Stat(bin); err != nil || !fi.Mode().IsRegular() || fi.Mode().Perm()&0o111 == 0 {
			continue
		}
		out = append(out, Entry{Version: v, Bin: bin})
	}
	sort.SliceStable(out, func(i, j int) bool { return version.Compare(out[i].Version, out[j].Version) > 0 })
	return out
}

// Find is the binary of exactly ver under root, "" when it is not installed.
func Find(root, ver string) string {
	want, err := version.Parse(ver)
	if err != nil {
		return ""
	}
	for _, e := range Installed(root) {
		if version.Compare(e.Version, want) == 0 {
			return e.Bin
		}
	}
	return ""
}

// Newest is the newest installed version of major under root, "" when none.
func Newest(root string, major uint64) string {
	for _, e := range Installed(root) {
		if e.Version.Major == major {
			return e.Bin
		}
	}
	return ""
}

// Runs reports whether bin answers --version within limit.
func Runs(bin string, limit time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	return exec.CommandContext(ctx, bin, "--version").Run() == nil
}

// Exec replaces this process with bin on the same arguments and environment,
// Env set to from. It returns only when the exec failed.
func Exec(bin, from string, args []string) error {
	env := append(os.Environ(), Env+"="+from)
	return syscall.Exec(bin, append([]string{bin}, args...), env)
}
