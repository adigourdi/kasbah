package composefile

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
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

func TestServices(t *testing.T) {
	for _, tc := range []struct{ compose, want string }{
		{"services:\r\n  web: {}\r\n  db: {}\r\n", "web db"},
		{"services: {}\n", ""},
		{"name: demo\n", ""},
		{"", ""},
		{"services: [web]\n", "err"},
		{"- web\n", "err"},
	} {
		docs, err := yamlx.Load([]byte(tc.compose))
		if err != nil {
			t.Fatal(err)
		}
		var doc tree.Value
		if len(docs) > 0 {
			doc = docs[0]
		}
		names, err := Services(doc)
		got := strings.Join(names, " ")
		if err != nil {
			got = "err"
		}
		if got != tc.want {
			t.Errorf("Services(%q) = %q %v", tc.compose, got, err)
		}
	}
}

// An include's services count, its path read from the including file's
// directory, in either spelling; one that cannot be read is an error.
func TestAllServices(t *testing.T) {
	dir := t.TempDir()
	write := func(name, body string) {
		t.Helper()
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("sub/side.yml", "include:\r\n  - deeper/more.yml\r\nservices:\r\n  side: {}\r\n")
	write("sub/deeper/more.yml", "services:\n  more: {}\n")
	write("other.yml", "services:\n  other: {}\n  web: {}\n")
	for _, tc := range []struct{ compose, want string }{
		{"include:\r\n  - sub/side.yml\r\nservices:\r\n  web: {}\r\n", "web side more"},
		{"include:\n  - path: [other.yml, sub/side.yml]\nservices:\n  web: {}\n", "web other side more"},
		{"include:\n  - path: other.yml\n", "other web"},
		{"include:\n  - missing.yml\nservices:\n  web: {}\n", "err"},
		{"include:\n  - ${DIR}/x.yml\n", "err"},
		{"include: other.yml\n", "err"},
		{"include:\n  - {project_directory: .}\n", "err"},
	} {
		docs, err := yamlx.Load([]byte(tc.compose))
		if err != nil {
			t.Fatal(err)
		}
		names, err := AllServices(dir, docs[0])
		got := strings.Join(names, " ")
		if err != nil {
			got = "err"
		}
		if got != tc.want {
			t.Errorf("AllServices(%q) = %q %v", tc.compose, got, err)
		}
	}
}
