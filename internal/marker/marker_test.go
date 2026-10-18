package marker

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
)

func golden(t *testing.T, name string) string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

var testBackup = &Backup{RepoBase: "s3:x", At: "03:00", Jitter: 30, Timeout: 3600, Retention: Retention{7, 4, 6}}

// Build's bytes against the jq program it replaces (testdata/README).
func TestBuild(t *testing.T) {
	existing, err := jv.ParseOne([]byte(golden(t, "existing-input.json")))
	if err != nil {
		t.Fatal(err)
	}
	nullBackup, _ := jv.ParseOne([]byte(`{"backup":null}`))
	cases := []struct {
		golden   string
		f        Fields
		existing jv.Value
		backup   *Backup
	}{
		{"fresh.json", Fields{"1.0.0", "/apps", "/data", "2", "1g"}, nil, nil},
		{"existing.json", Fields{"1.0.0", "/srv/apps", "/srv/data", "14.4", "54g"}, existing, nil},
		{"existing-backup.json", Fields{"1.0.0", "/srv/apps", "/srv/data", "14.4", "54g"}, existing, testBackup},
		{"fresh-backup.json", Fields{"1.0.0", "/apps", "/data", "2", "1g"}, nil, testBackup},
		{"null-backup.json", Fields{"1.0.0", "/apps", "/data", "2", "1g"}, nullBackup, nil},
	}
	for _, c := range cases {
		var e *jv.Map
		if c.existing != nil {
			e = c.existing.(*jv.Map)
		}
		m, err := Build(c.f, e, c.backup)
		if err != nil {
			t.Fatalf("%s: %v", c.golden, err)
		}
		if got, want := string(Render(m)), golden(t, c.golden); got != want {
			t.Errorf("%s:\n%s\nwant\n%s", c.golden, got, want)
		}
	}
	// A second run against its own output renders the same bytes: the marker
	// is compared byte for byte on every re-run.
	first, _ := Build(Fields{"1.0.0", "/apps", "/data", "2", "1g"}, nil, testBackup)
	again, _ := Build(Fields{"1.0.0", "/apps", "/data", "2", "1g"}, first, nil)
	if string(Render(first)) != string(Render(again)) {
		t.Error("a re-run changes the marker")
	}
	for _, in := range []string{`{"backup":"x"}`, `{"backup":true}`, `{"backup":{"retention":"x"}}`} {
		bad, _ := jv.ParseOne([]byte(in))
		if _, err := Build(Fields{}, bad.(*jv.Map), testBackup); err == nil {
			t.Errorf("%s merges a new backup; jq errors", in)
		}
	}
	// jq: `$e.backup.retention` on false — Cannot index boolean with string "retention".
	off, _ := jv.ParseOne([]byte(`{"backup":false}`))
	if _, err := Build(Fields{}, off.(*jv.Map), testBackup); err == nil || err.Error() != `Cannot index boolean with string "retention"` {
		t.Errorf("backup false: %v", err)
	}
	if m, err := Build(Fields{}, off.(*jv.Map), nil); err != nil || jv.Compact(m) != `{"backup":false,"kasbah_version":"","apps_path":"","data_path":"","cpu_limit":"","mem_limit":""}` {
		t.Errorf("backup false, none given: %v %v", jv.Compact(m), err)
	}
	if Mode != 0o644 || Path("/srv/apps") != "/srv/apps/.kasbah/server.json" {
		t.Error("mode or path")
	}
}

const (
	path    = "/srv/apps/.kasbah/server.json"
	target  = "deploy@vps"
	initCmd = "kasbah server init deploy@vps --apps-path=/srv/apps"
)

func TestValidate(t *testing.T) {
	good := `{"kasbah_version":"1.0.0","apps_path":"/apps","data_path":"/data","cpu_limit":"14.4","mem_limit":"54g","future":"kept"}`
	m, err := Validate([]byte(good+"\n"), path, target, initCmd)
	if err != nil {
		t.Fatal(err)
	}
	if m.AppsPath != "/apps" || m.DataPath != "/data" || m.CPULimit != "14.4" || m.MemLimit != "54g" {
		t.Errorf("fields %+v", m)
	}
	if v, _ := m.JSON.Get("future"); v != "kept" {
		t.Error("unknown keys survive for later readers")
	}
	// $(…) drops trailing newlines before the checks see the values.
	if m, err := Validate([]byte(`{"apps_path":"/apps\n","data_path":"/data\n\n","cpu_limit":"2\n","mem_limit":"1g"}`), path, target, initCmd); err != nil || m.AppsPath != "/apps" || m.CPULimit != "2" {
		t.Errorf("trailing newlines: %+v %v", m, err)
	}
	// A limit of 0 means "no limit" to Docker, and a number is written through.
	if m, err := Validate([]byte(`{"apps_path":"/a","data_path":"/d","cpu_limit":0,"mem_limit":"0"}`), path, target, initCmd); err != nil || m.CPULimit != "0" {
		t.Errorf("zero limit: %v %v", m, err)
	}

	refusals := []struct{ body, want string }{
		{"", "/srv/apps/.kasbah/server.json on deploy@vps is not a JSON object — re-run `" + initCmd + "`"},
		{"[1]", "is not a JSON object"},
		{"not json", "is not a JSON object"},
		{`{"apps_path":"apps","data_path":"/d","cpu_limit":"1","mem_limit":"1g"}`, "records apps_path='apps' data_path='/d'; both must be absolute paths — re-run `" + initCmd + "`"},
		{`{"apps_path":"/","data_path":"/d","cpu_limit":"1","mem_limit":"1g"}`, "both must be absolute paths"},
		{`{"data_path":"/d","cpu_limit":"1","mem_limit":"1g"}`, "both must be absolute paths"},
		{`{"apps_path":"/a","cpu_limit":"1","mem_limit":"1g"}`, "both must be absolute paths"},
		{`{"apps_path":"/a","data_path":"/d","mem_limit":"1g"}`, "records cpu_limit='' mem_limit='1g'"},
		{`{"apps_path":"/a","data_path":"/d","cpu_limit":"1"}`, "records cpu_limit='1' mem_limit=''"},
		{`{"apps_path":"/a","data_path":"/d","cpu_limit":"1 2","mem_limit":"1g"}`, "neither may carry whitespace"},
	}
	for _, r := range refusals {
		_, err := Validate([]byte(r.body), path, target, initCmd)
		e, ok := err.(*cli.Error)
		if !ok || e.Code != 1 || !strings.Contains(e.Error(), r.want) {
			t.Errorf("%q: %v, want %q", r.body, err, r.want)
		}
	}
	_, err = Validate([]byte(`{"apps_path":"/a","data_path":"/d","cpu_limit":"1"}`), path, target, initCmd)
	if e := err.(*cli.Error); len(e.Lines) != 5 || e.Lines[4] != "(docs/env-template.md). Re-run `"+initCmd+"` to rewrite it." {
		t.Errorf("limit refusal lines %q", e.Lines)
	}
}

func TestCompat(t *testing.T) {
	if w, err := Compat([]byte(`{"kasbah_version":"1.4.0"}`), "1.0.0", path, target); w != nil || err != nil {
		t.Errorf("same major: %v %v", w, err)
	}
	if w, err := Compat([]byte(`{"kasbah_version":"0.9.0"}`), "1.0.0", path, target); w != nil || err != nil {
		t.Errorf("older major passes until migrate exists: %v %v", w, err)
	}
	_, err := Compat([]byte(`{"kasbah_version":"v2.0.0"}`), "1.0.0", path, target)
	if err == nil || !strings.Contains(err.Error(), "was written by kasbah v2.0.0, and this is kasbah 1.0.0") {
		t.Errorf("newer major: %v", err)
	}
	if w, err := Compat([]byte(`{}`), "1.0.0", path, target); err != nil || len(w) != 2 ||
		w[0] != path+" records kasbah_version ''; this kasbah is 1.0.0" {
		t.Errorf("incomparable: %q %v", w, err)
	}
	if _, err := Compat([]byte(`[]`), "1.0.0", path, target); err == nil || !strings.Contains(err.Error(), "is not a JSON object") {
		t.Errorf("not an object: %v", err)
	}
	if Major("v10.2.3") != "10" {
		t.Error("major")
	}
	// Bash's `[ "$major" -gt "$ours" ]` errors on a major past int64 and the
	// refusal is skipped: matched, not refused.
	if w, err := Compat([]byte(`{"kasbah_version":"99999999999999999999.0.0"}`), "1.0.0", path, target); w != nil || err != nil {
		t.Errorf("20-digit major: %v %v", w, err)
	}
}
