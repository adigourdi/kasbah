package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const version = "0.9.0-dev"

func path(t *testing.T) string { return filepath.Join(t.TempDir(), ".kasbah", "state.json") }

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// state_init's bytes: jq -n's pretty print and a newline.
func TestInit(t *testing.T) {
	p := path(t)
	if err := Init(p, version); err != nil {
		t.Fatal(err)
	}
	want := `{
  "kasbah_version": "0.9.0-dev",
  "last_server": null,
  "last_deploy": null,
  "last_version": null,
  "schema_migrations_applied": []
}
`
	if got := read(t, p); got != want {
		t.Errorf("init wrote\n%s\nwant\n%s", got, want)
	}
	if v, _ := Get(p, "last_server"); v != "" {
		t.Errorf("a null field reads as empty, got %q", v)
	}
}

// The deploy_test.sh state cases.
func TestRecord(t *testing.T) {
	p := path(t)
	if err := Record(p, version, "last_server", "deploy@vps", "last_version", "1.2.3"); err != nil {
		t.Fatal(err)
	}
	want := `{
  "kasbah_version": "0.9.0-dev",
  "last_server": "deploy@vps",
  "last_deploy": null,
  "last_version": "1.2.3",
  "schema_migrations_applied": []
}
`
	if got := read(t, p); got != want {
		t.Errorf("first record wrote\n%s\nwant\n%s", got, want)
	}

	// Merged, never replaced: fields this command does not own survive, in
	// their place, with jq's spelling of their numbers.
	os.WriteFile(p, []byte(`{"kasbah_version":"0.1.0","last_server":"deploy@vps","last_deploy":null,"last_version":"1.2.3","schema_migrations_applied":["m1"],"future_key":7,"ratio":1.50,"big":1e2}`), 0o644)
	if err := Record(p, version, "last_server", "other@vps"); err != nil {
		t.Fatal(err)
	}
	want = `{
  "kasbah_version": "0.1.0",
  "last_server": "other@vps",
  "last_deploy": null,
  "last_version": "1.2.3",
  "schema_migrations_applied": [
    "m1"
  ],
  "future_key": 7,
  "ratio": 1.50,
  "big": 1E+2
}
`
	if got := read(t, p); got != want {
		t.Errorf("merge wrote\n%s\nwant\n%s", got, want)
	}

	// An empty object gets the whole shape back, present and null.
	os.WriteFile(p, []byte("{}\n"), 0o644)
	if err := Record(p, version, "last_server", "thin@vps", "new_field", "x"); err != nil {
		t.Fatal(err)
	}
	if got := read(t, p); !strings.Contains(got, `"last_version": null`) || !strings.Contains(got, `"schema_migrations_applied": []`) ||
		!strings.HasSuffix(got, "\"new_field\": \"x\"\n}\n") {
		t.Errorf("thin file became\n%s", got)
	}
	if v, _ := Get(p, "last_server"); v != "thin@vps" {
		t.Errorf("get after record: %q", v)
	}
	if entries, _ := os.ReadDir(filepath.Dir(p)); len(entries) != 1 {
		t.Errorf("staging file left behind: %v", entries)
	}
}

func TestRefusals(t *testing.T) {
	p := path(t)
	os.MkdirAll(filepath.Dir(p), 0o755)
	for _, bad := range []string{"not json\n", "[1]\n", "\"s\"\n", ""} {
		os.WriteFile(p, []byte(bad), 0o644)
		err := Record(p, version, "last_server", "x@y")
		if err == nil || !strings.Contains(err.Error(), "not a JSON object — kasbah will not overwrite it") {
			t.Errorf("record over %q: %v", bad, err)
		}
		if read(t, p) != bad {
			t.Errorf("%q was overwritten", bad)
		}
	}
	for _, bad := range []string{"not json\n", "[1]\n", "\"s\"\n"} {
		os.WriteFile(p, []byte(bad), 0o644)
		if _, err := Get(p, "last_server"); err == nil || !strings.Contains(err.Error(), "not readable as JSON") {
			t.Errorf("get over %q: %v", bad, err)
		}
	}
	// An empty file has nothing in it to read: jq prints nothing and succeeds.
	os.WriteFile(p, nil, 0o644)
	if v, err := Get(p, "last_server"); v != "" || err != nil {
		t.Errorf("empty file: %q %v", v, err)
	}
	if err := Record(p, version, "Bad-Key", "x"); err == nil || !strings.Contains(err.Error(), "is not a state field name") {
		t.Errorf("bad key: %v", err)
	}
	if err := Record(p, version, "last_server"); err == nil || !strings.Contains(err.Error(), "odd number") {
		t.Errorf("odd args: %v", err)
	}
	if v, err := Get(filepath.Join(t.TempDir(), "absent.json"), "k"); v != "" || err != nil {
		t.Errorf("absent file: %q %v", v, err)
	}
}

func TestGetRendering(t *testing.T) {
	p := path(t)
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, []byte(`{"s":"a\r","n":1.0,"f":false,"o":{"b":[1,"x"]},"z":null}`), 0o644)
	for k, want := range map[string]string{"s": "a", "n": "1.0", "f": "", "o": `{"b":[1,"x"]}`, "z": "", "missing": ""} {
		if got, err := Get(p, k); got != want || err != nil {
			t.Errorf("%s: %q %v, want %q", k, got, err, want)
		}
	}
}

// jq reads a state file that opens with a byte-order mark; so does this.
func TestBOM(t *testing.T) {
	p := path(t)
	os.MkdirAll(filepath.Dir(p), 0o755)
	os.WriteFile(p, []byte("\ufeff{\"last_server\":\"bom@vps\"}\n"), 0o644)
	if v, err := Get(p, "last_server"); v != "bom@vps" || err != nil {
		t.Errorf("get: %q %v", v, err)
	}
	if err := Record(p, version, "last_version", "1.0.0"); err != nil {
		t.Fatal(err)
	}
	if got := read(t, p); !strings.HasPrefix(got, "{\n  \"kasbah_version\"") || !strings.Contains(got, `"last_server": "bom@vps"`) {
		t.Errorf("record over a BOM'd file wrote\n%s", got)
	}
}
