package composefile

import (
	"os"
	"path/filepath"
	"testing"
)

func TestServiceless(t *testing.T) {
	for _, tc := range []struct {
		compose string
		want    bool
	}{
		{"services: {}\n", true},
		{"services:\n", true},
		{"name: demo\nnetworks:\n  kasbah: {}\n", true},
		{"services: {}\r\n", true},
		{"services:\n  web:\n    image: nginx\n", false},
		{"include:\n  - other.yml\n", false},
		{"", false},
		{"v1.0.0\n", false},
		{"services: [web]\n", false},
		{"services: {\n", false},
	} {
		dir := t.TempDir()
		os.WriteFile(filepath.Join(dir, "compose.yml"), []byte(tc.compose), 0o644)
		if got := Serviceless(dir); got != tc.want {
			t.Errorf("Serviceless(%q) = %v", tc.compose, got)
		}
	}
	if Serviceless(t.TempDir()) {
		t.Error("a directory with no compose.yml is serviceless")
	}
}
