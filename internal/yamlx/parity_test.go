package yamlx

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// knownDivergent names corpus inputs whose Go reading is known to differ from
// yq's, and why. Each is asserted to still differ, so a fix shows up here.
var knownDivergent = map[string]string{
	// libyaml marks a scalar tagged with the non-specific `!` as plain-implicit
	// whatever its quoting, so PyYAML resolves `! "123"` to 123; yaml.v3 drops
	// the `!` before the node is built and a quoted scalar stays a string.
	"internal/yamlx/testdata/edge/explicit-tags-2.yml": "! on a quoted scalar",
	// libyaml (0.2.2+) knows the YAML 1.2 escape `\/`; yaml.v3 refuses the
	// document ("found unknown escape character"). Refused, never misread.
	"internal/yamlx/testdata/edge/escape-slash.yml": "\\/ in a double-quoted scalar",
	// A byte-order mark opening a quoted scalar's continuation line is content
	// to libyaml; Go refuses every line-opening mark inside a document.
	"internal/yamlx/testdata/edge/bom-quoted-continuation.yml": "BOM inside a multi-line quoted scalar",
}

const repoRoot = "../.."

func corpus(t *testing.T) []string {
	t.Helper()
	var files []string
	for _, dir := range []string{"tests/fixtures", "templates", "internal/yamlx/testdata/edge", "internal/yamlx/testdata/captured"} {
		err := filepath.WalkDir(filepath.Join(repoRoot, dir), func(p string, d os.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if !d.IsDir() && (strings.HasSuffix(p, ".yml") || strings.HasSuffix(p, ".yaml")) {
				rel, _ := filepath.Rel(repoRoot, p)
				files = append(files, filepath.ToSlash(rel))
			}
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	sort.Strings(files)
	return files
}

// TestParity holds the loader to `yq -c .` over the whole corpus: the same
// JSON, byte for byte, or the same refusal. Goldens come from the real tool —
// testdata/regen.sh on a host with kislyuk yq.
func TestParity(t *testing.T) {
	files := corpus(t)
	if len(files) < 100 {
		t.Fatalf("corpus has %d files; expected the fixtures, templates, edge cases and captured inputs", len(files))
	}
	matched := 0
	for _, f := range files {
		golden := filepath.Join("testdata", "golden", f)
		want, wantErr := os.ReadFile(golden + ".json")
		_, refusedErr := os.Stat(golden + ".refused")
		if wantErr != nil && refusedErr != nil {
			t.Errorf("%s: no golden — run internal/yamlx/testdata/regen.sh", f)
			continue
		}
		docs, err := LoadFile(filepath.Join(repoRoot, f))
		got, ok := "", err == nil
		if ok {
			got = Render(docs)
		}
		same := (refusedErr == nil && !ok) || (wantErr == nil && ok && got == string(want))
		if reason, known := knownDivergent[f]; known {
			if same {
				t.Errorf("%s: listed as divergent (%s) but now matches yq — drop it from knownDivergent", f, reason)
			}
			continue
		}
		switch {
		case same:
			matched++
		case refusedErr == nil:
			t.Errorf("%s: yq refuses it, Go read:\n%s", f, got)
		case !ok:
			t.Errorf("%s: Go refused (%v), yq read:\n%s", f, err, want)
		default:
			t.Errorf("%s:\n yq: %s\n go: %s", f, want, got)
		}
	}
	t.Logf("%d of %d corpus files match yq byte for byte; %d known divergent", matched, len(files), len(knownDivergent))
}

// Every golden belongs to a corpus file, so a removed input does not leave a
// stale expectation behind.
func TestNoOrphanGoldens(t *testing.T) {
	inputs := map[string]bool{}
	for _, f := range corpus(t) {
		inputs[f] = true
	}
	root := filepath.Join("testdata", "golden")
	err := filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, _ := filepath.Rel(root, p)
		rel = strings.TrimSuffix(strings.TrimSuffix(filepath.ToSlash(rel), ".json"), ".refused")
		if !inputs[rel] {
			t.Errorf("golden %s has no corpus input", p)
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestParityExtra compares uncommitted inputs (real projects) in
// $KASBAH_PARITY_DIR: each <f>.yml beside <f>.yml.json or <f>.yml.refused.
func TestParityExtra(t *testing.T) {
	dir := os.Getenv("KASBAH_PARITY_DIR")
	if dir == "" {
		t.Skip("KASBAH_PARITY_DIR not set")
	}
	files, _ := filepath.Glob(filepath.Join(dir, "*.yml"))
	matched := 0
	for _, f := range files {
		want, wantErr := os.ReadFile(f + ".json")
		_, refusedErr := os.Stat(f + ".refused")
		docs, err := LoadFile(f)
		switch {
		case refusedErr == nil && err != nil:
			matched++
		case wantErr == nil && err == nil && Render(docs) == string(want):
			matched++
		case err != nil:
			t.Errorf("%s: Go refused (%v), yq read it", f, err)
		default:
			t.Errorf("%s:\n yq: %s\n go: %s", f, want, Render(docs))
		}
	}
	t.Logf("%d of %d extra files match yq", matched, len(files))
}
