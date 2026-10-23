package serverbin

import (
	"os"
	"path/filepath"
	"testing"
)

func touch(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, nil, 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestHome(t *testing.T) {
	tmp := t.TempDir()
	checkout := filepath.Join(tmp, "repo")
	touch(t, filepath.Join(checkout, "go.mod"))
	touch(t, filepath.Join(checkout, "cmd", "kasbah", "main.go"))
	touch(t, filepath.Join(checkout, "dist", "kasbah"))
	linked := filepath.Join(tmp, "elsewhere", "bin", "kasbah")
	if err := os.MkdirAll(filepath.Dir(linked), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(checkout, "dist", "kasbah"), linked); err != nil {
		t.Fatal(err)
	}
	// The installed layout: <lib>/<ver>/kasbah, linked from a bin directory.
	lib := filepath.Join(tmp, "home", ".local", "share", "kasbah")
	verdir := filepath.Join(lib, "1.0.2-dev.86.1792460280")
	touch(t, filepath.Join(verdir, "kasbah"))
	installed := filepath.Join(tmp, "home", ".local", "bin", "kasbah")
	if err := os.MkdirAll(filepath.Dir(installed), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(verdir, "kasbah"), installed); err != nil {
		t.Fatal(err)
	}
	// A Go module with a dist/kasbah of its own but no cmd/kasbah/ is not a checkout.
	other := filepath.Join(tmp, "other")
	touch(t, filepath.Join(other, "go.mod"))
	touch(t, filepath.Join(other, "cmd", "kasbah"))
	touch(t, filepath.Join(other, "dist", "kasbah"))
	// A 1.0.x install: a regular file in the bin directory is its own version dir.
	plain := filepath.Join(tmp, "plain", "bin", "kasbah")
	touch(t, plain)

	tests := []struct {
		name     string
		exe      string
		want     string
		checkout bool
	}{
		{"checkout", filepath.Join(checkout, "dist", "kasbah"), checkout, true},
		{"symlink to a checkout binary", linked, checkout, true},
		{"installed, through the symlink", installed, verdir, false},
		{"installed, the version dir itself", filepath.Join(verdir, "kasbah"), verdir, false},
		{"a regular file in a bin directory", plain, filepath.Dir(plain), false},
		{"go.mod, and cmd/kasbah a file", filepath.Join(other, "dist", "kasbah"), filepath.Join(other, "dist"), false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, co := Home(tt.exe)
			if got != tt.want || co != tt.checkout {
				t.Errorf("Home() = %q, %v; want %q, %v", got, co, tt.want, tt.checkout)
			}
		})
	}

	touch(t, filepath.Join(verdir, "server", "kasbah-linux-arm64"))
	if p, err := LocalFor(installed)("arm64"); err != nil || p != filepath.Join(verdir, "server", "kasbah-linux-arm64") {
		t.Errorf("LocalFor: %q, %v", p, err)
	}
	if _, err := LocalFor(installed)("amd64"); err == nil {
		t.Error("LocalFor found a server binary that is not there")
	}
}
