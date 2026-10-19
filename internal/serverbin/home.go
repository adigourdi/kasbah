package serverbin

import (
	"errors"
	"os"
	"path/filepath"
)

// Home is where the kasbah at exe finds its server binaries: a checkout (its
// dist/kasbah, whatever KASBAH_LIB_DIR says), else KASBAH_LIB_DIR, else
// $XDG_DATA_HOME/kasbah, else ~/.local/share/kasbah.
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

// LocalFor is Local for the kasbah at exe, wherever Home puts it.
func LocalFor(exe string, getenv func(string) string) (func(arch string) (string, error), error) {
	home, checkout, err := Home(exe, getenv)
	if err != nil {
		return nil, err
	}
	return func(arch string) (string, error) { return Local(home, checkout, arch) }, nil
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}
