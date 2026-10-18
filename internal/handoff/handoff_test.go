package handoff

import (
	"os"
	"path/filepath"
	"slices"
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

func envOf(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLocate(t *testing.T) {
	tmp := t.TempDir()

	checkout := filepath.Join(tmp, "repo")
	touch(t, filepath.Join(checkout, "install.sh"))
	touch(t, filepath.Join(checkout, "VERSION"))
	touch(t, filepath.Join(checkout, "dist", "kasbah"))
	touch(t, filepath.Join(checkout, Dispatcher))

	linked := filepath.Join(tmp, "elsewhere", "bin", "kasbah")
	if err := os.MkdirAll(filepath.Dir(linked), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(checkout, "dist", "kasbah"), linked); err != nil {
		t.Fatal(err)
	}

	installed := filepath.Join(tmp, "home", ".local", "bin", "kasbah")
	touch(t, installed)
	home := filepath.Join(tmp, "home")
	touch(t, filepath.Join(home, ".local", "share", "kasbah", Dispatcher))
	xdg := filepath.Join(tmp, "xdg")
	touch(t, filepath.Join(xdg, "kasbah", Dispatcher))
	override := filepath.Join(tmp, "override")
	touch(t, filepath.Join(override, Dispatcher))

	bare := filepath.Join(tmp, "bare")
	touch(t, filepath.Join(bare, "install.sh"))
	touch(t, filepath.Join(bare, "VERSION"))
	touch(t, filepath.Join(bare, "dist", "kasbah"))

	tests := []struct {
		name    string
		exe     string
		env     map[string]string
		want    string
		wantErr string
	}{
		{"checkout", filepath.Join(checkout, "dist", "kasbah"),
			map[string]string{"HOME": home}, filepath.Join(checkout, Dispatcher), ""},
		{"checkout beats KASBAH_LIB_DIR", filepath.Join(checkout, "dist", "kasbah"),
			map[string]string{"KASBAH_LIB_DIR": override}, filepath.Join(checkout, Dispatcher), ""},
		{"symlink to a checkout binary", linked,
			map[string]string{"HOME": home}, filepath.Join(checkout, Dispatcher), ""},
		{"installed, HOME", installed,
			map[string]string{"HOME": home}, filepath.Join(home, ".local", "share", "kasbah", Dispatcher), ""},
		{"installed, XDG_DATA_HOME beats HOME", installed,
			map[string]string{"HOME": home, "XDG_DATA_HOME": xdg}, filepath.Join(xdg, "kasbah", Dispatcher), ""},
		{"installed, KASBAH_LIB_DIR beats both", installed,
			map[string]string{"HOME": home, "XDG_DATA_HOME": xdg, "KASBAH_LIB_DIR": override},
			filepath.Join(override, Dispatcher), ""},
		{"installed, nothing to go on", installed,
			map[string]string{}, "", "neither KASBAH_LIB_DIR, XDG_DATA_HOME, nor HOME is set"},
		{"checkout, dispatcher missing", filepath.Join(tmp, "bare", "dist", "kasbah"),
			map[string]string{"HOME": home}, "",
			"looked for " + filepath.Join(tmp, "bare", Dispatcher)},
		{"installed, dispatcher missing", installed,
			map[string]string{"KASBAH_LIB_DIR": filepath.Join(tmp, "empty")}, "",
			"looked for " + filepath.Join(tmp, "empty", Dispatcher)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Locate(tt.exe, envOf(tt.env))
			if tt.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
					t.Fatalf("Locate() error = %v, want one containing %q", err, tt.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatalf("Locate() error = %v", err)
			}
			if got != tt.want {
				t.Errorf("Locate() = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestEnv(t *testing.T) {
	base := []string{"PATH=/shim:/usr/bin", "HOME=/scratch", "KASBAH_BUILD=stale", "KASBAH_VERSION=0.1.0-dev"}
	tests := []struct {
		name    string
		version string
		want    []string
	}{
		{"stamped binary overrides", "0.1.0-dev.142",
			[]string{"PATH=/shim:/usr/bin", "HOME=/scratch", "KASBAH_VERSION=0.1.0-dev", "KASBAH_BUILD=0.1.0-dev.142"}},
		{"unstamped binary leaves it to VERSION", "",
			[]string{"PATH=/shim:/usr/bin", "HOME=/scratch", "KASBAH_VERSION=0.1.0-dev"}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Env(base, tt.version); !slices.Equal(got, tt.want) {
				t.Errorf("Env() = %q, want %q", got, tt.want)
			}
		})
	}
}
