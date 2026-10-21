package serverbin

import (
	"os"
	"path/filepath"
)

// Home is where the kasbah at exe finds its server binaries: a checkout (its
// dist/kasbah, with install.sh and VERSION two levels up), else the exe's own
// directory — one version directory of the installed library
// (<lib>/<ver>/kasbah beside <lib>/<ver>/server/).
func Home(exe string) (dir string, checkout bool) {
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	root := filepath.Dir(filepath.Dir(exe))
	if isFile(filepath.Join(root, "install.sh")) && isFile(filepath.Join(root, "VERSION")) {
		return root, true
	}
	return filepath.Dir(exe), false
}

// LocalFor is Local for the kasbah at exe, wherever Home puts it.
func LocalFor(exe string) func(arch string) (string, error) {
	home, checkout := Home(exe)
	return func(arch string) (string, error) { return Local(home, checkout, arch) }
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}
