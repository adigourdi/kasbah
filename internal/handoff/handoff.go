// Package handoff hands a command kasbah does not own to the Bash dispatcher.
package handoff

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// Dispatcher is the Bash dispatcher's path relative to a checkout root or an
// installed library directory.
const Dispatcher = "libexec/kasbah-bash"

// Locate finds the Bash dispatcher for the binary at exe, under Home.
func Locate(exe string, getenv func(string) string) (string, error) {
	home, _, err := Home(exe, getenv)
	if err != nil {
		return "", err
	}
	path := filepath.Join(home, Dispatcher)
	if !isFile(path) {
		return "", fmt.Errorf("cannot locate the Bash dispatcher (looked for %s)", path)
	}
	return path, nil
}

// Home is where the files that travel with the binary at exe live. A checkout
// is recognised the way the dispatcher recognises one — install.sh and
// VERSION beside the binary's parent directory — and a checkout's binary uses
// that checkout, whatever KASBAH_LIB_DIR says. Otherwise it is the installed
// library directory: KASBAH_LIB_DIR, else $XDG_DATA_HOME/kasbah, else
// ~/.local/share/kasbah.
func Home(exe string, getenv func(string) string) (dir string, checkout bool, err error) {
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	root := filepath.Dir(filepath.Dir(exe))
	if isFile(filepath.Join(root, "install.sh")) && isFile(filepath.Join(root, "VERSION")) {
		return root, true, nil
	}
	if lib := getenv("KASBAH_LIB_DIR"); lib != "" {
		return lib, false, nil
	}
	switch {
	case getenv("XDG_DATA_HOME") != "":
		return filepath.Join(getenv("XDG_DATA_HOME"), "kasbah"), false, nil
	case getenv("HOME") != "":
		return filepath.Join(getenv("HOME"), ".local", "share", "kasbah"), false, nil
	}
	return "", false, errors.New("neither KASBAH_LIB_DIR, XDG_DATA_HOME, nor HOME is set")
}

// Env is the environment the dispatcher runs under: the caller's, unchanged,
// except that KASBAH_BUILD carries this binary's build stamp, which only
// --version and the usage print. An unstamped binary drops it, so the
// dispatcher falls back to VERSION.
func Env(environ []string, build string) []string {
	out := make([]string, 0, len(environ)+1)
	for _, kv := range environ {
		if !strings.HasPrefix(kv, "KASBAH_BUILD=") {
			out = append(out, kv)
		}
	}
	if build != "" {
		out = append(out, "KASBAH_BUILD="+build)
	}
	return out
}

// Exec replaces this process with the dispatcher: same PID, so signals sent to
// kasbah reach the dispatcher and its exit status is kasbah's, with no parent
// left to forward either.
func Exec(dispatcher string, args, environ []string) error {
	argv := append([]string{dispatcher}, args...)
	return syscall.Exec(dispatcher, argv, environ)
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}
