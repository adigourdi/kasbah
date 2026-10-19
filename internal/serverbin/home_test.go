package serverbin

import (
	"os"
	"path/filepath"
	"strings"
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
	touch(t, filepath.Join(checkout, "install.sh"))
	touch(t, filepath.Join(checkout, "VERSION"))
	touch(t, filepath.Join(checkout, "dist", "kasbah"))
	linked := filepath.Join(tmp, "elsewhere", "bin", "kasbah")
	if err := os.MkdirAll(filepath.Dir(linked), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(checkout, "dist", "kasbah"), linked); err != nil {
		t.Fatal(err)
	}
	installed := filepath.Join(tmp, "home", ".local", "bin", "kasbah")
	touch(t, installed)
	home, xdg, override := filepath.Join(tmp, "home"), filepath.Join(tmp, "xdg"), filepath.Join(tmp, "override")

	tests := []struct {
		name     string
		exe      string
		env      map[string]string
		want     string
		checkout bool
		wantErr  string
	}{
		{"checkout", filepath.Join(checkout, "dist", "kasbah"), map[string]string{"HOME": home}, checkout, true, ""},
		{"checkout beats KASBAH_LIB_DIR", filepath.Join(checkout, "dist", "kasbah"), map[string]string{"KASBAH_LIB_DIR": override}, checkout, true, ""},
		{"symlink to a checkout binary", linked, map[string]string{"HOME": home}, checkout, true, ""},
		{"installed, HOME", installed, map[string]string{"HOME": home}, filepath.Join(home, ".local", "share", "kasbah"), false, ""},
		{"installed, XDG_DATA_HOME beats HOME", installed, map[string]string{"HOME": home, "XDG_DATA_HOME": xdg}, filepath.Join(xdg, "kasbah"), false, ""},
		{"installed, KASBAH_LIB_DIR beats both", installed, map[string]string{"HOME": home, "XDG_DATA_HOME": xdg, "KASBAH_LIB_DIR": override}, override, false, ""},
		{"installed, nothing to go on", installed, map[string]string{}, "", false, "neither KASBAH_LIB_DIR, XDG_DATA_HOME, nor HOME is set"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, co, err := Home(tt.exe, func(k string) string { return tt.env[k] })
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("Home() error = %v, want %q", err, tt.wantErr)
				}
				return
			}
			if err != nil || got != tt.want || co != tt.checkout {
				t.Errorf("Home() = %q, %v, %v; want %q, %v", got, co, err, tt.want, tt.checkout)
			}
		})
	}

	touch(t, filepath.Join(override, "server", "kasbah-linux-arm64"))
	local, err := LocalFor(installed, func(k string) string { return map[string]string{"KASBAH_LIB_DIR": override}[k] })
	if err != nil {
		t.Fatal(err)
	}
	if p, err := local("arm64"); err != nil || p != filepath.Join(override, "server", "kasbah-linux-arm64") {
		t.Errorf("LocalFor: %q, %v", p, err)
	}
}
