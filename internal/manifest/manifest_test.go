package manifest

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
)

const version = "0.9.0-dev"

func write(t *testing.T, content string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), File)
	if err := os.WriteFile(p, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func refused(t *testing.T, path string, code int, want string) {
	t.Helper()
	_, err := Require(path, version)
	e, ok := err.(*cli.Error)
	if !ok {
		t.Fatalf("want a refusal containing %q, got %v", want, err)
	}
	if e.Code != code || !strings.Contains(e.Error(), want) {
		t.Errorf("exit %d %q, want exit %d containing %q", e.Code, e.Error(), code, want)
	}
}

func TestMissing(t *testing.T) {
	p := filepath.Join(t.TempDir(), File)
	_, err := Require(p, version)
	e := err.(*cli.Error)
	if e.Code != cli.ExitNoProject || !strings.HasPrefix(e.Lines[0], "No ") || len(e.Lines) != 2 ||
		e.Lines[1] != "Run from the project root, or `kasbah init-project` to scaffold." {
		t.Errorf("missing manifest: %d %q", e.Code, e.Lines)
	}
	// A directory of that name is not a manifest either (`[ -f ]`).
	d := t.TempDir()
	os.Mkdir(filepath.Join(d, File), 0o755)
	refused(t, filepath.Join(d, File), cli.ExitNoProject, "No ")
}

func TestValid(t *testing.T) {
	p := write(t, "schema: 1\nkasbah_version: "+version+"\nname: demo\ndomain: \"demo.example.com\"\nsync:\n  - compose.prod.yml -> compose.yml\n")
	m, err := Require(p, version)
	if err != nil {
		t.Fatal(err)
	}
	if m.Schema != "1" || m.KasbahVersion != version || m.Name != "demo" || m.Domain != "demo.example.com" {
		t.Errorf("fields %+v", m)
	}
	if v, _ := m.Get("sync", 0); v != "compose.prod.yml -> compose.yml" {
		t.Errorf("sync[0] = %v", v)
	}
}

func TestRefusals(t *testing.T) {
	refused(t, write(t, "schema: 2\nkasbah_version: x\nname: demo\ndomain: \"\"\n"), 1, "schema 2 is newer than this kasbah (0.9.0-dev supports schema 1). Upgrade kasbah.")
	refused(t, write(t, "kasbah_version: x\nname: demo\n"), 1, "missing required field 'schema'")
	refused(t, write(t, "schema: 1.0\nname: demo\n"), 1, "schema must be an integer (got '1.0')")
	refused(t, write(t, "schema: 1\nname: Demo_App\n"), 1, "invalid name 'Demo_App'")
	refused(t, write(t, "schema: 1\n"), 1, "missing required field 'name'")
	refused(t, write(t, "schema: 1\nname: \"null\"\n"), 1, "missing required field 'name'")
	refused(t, write(t, "schema: 1\nname: false\n"), 1, "missing required field 'name'")
	refused(t, write(t, "schema: 1\nname: [unterminated\n"), 1, "could not parse YAML")
	refused(t, write(t, "just a string\n"), 1, `Cannot index string with "schema"`)
	refused(t, write(t, "- a\n"), 1, `Cannot index array with "schema"`)
	refused(t, write(t, "schema: 1\nname: a\n---\nschema: 1\nname: b\n"), 1, "expected a single YAML document")
	refused(t, write(t, ""), 1, "expected a single YAML document")
	refused(t, write(t, "# only a comment\n"), 1, "expected a single YAML document")
	// A field rendered over several lines breaks the five-line read, as in Bash.
	refused(t, write(t, "schema: 1\nname: demo\ndomain: {a: 1}\n"), 1, "expected a single YAML document")
	for _, r := range Reserved {
		p := write(t, "schema: 1\nkasbah_version: 0.1.0\nname: "+r+"\ndomain: \"r.test\"\nsync: []\n")
		refused(t, p, 1, "is reserved — kasbah owns <apps>/"+r+" on every server (reserved: traefik mail data backups)")
	}
}

func TestAccepted(t *testing.T) {
	cases := map[string]string{
		"schema: \"1\"\nname: demo\n":               "demo",
		"schema: 0001\nname: demo\n":                "demo",
		"schema: 1\nname: traefik-mirror\n":         "traefik-mirror",
		"schema: 99999999999999999999\nname: big\n": "big",
		"schema: 1\r\nkasbah_version: 0.1.0\r\nname: crlf\r\ndomain: \"c.test\"\r\nsync: []\r\n": "crlf",
	}
	for in, name := range cases {
		m, err := Require(write(t, in), version)
		if err != nil || m.Name != name {
			t.Errorf("%q: %v %v", in, m, err)
		}
	}
	m, _ := Require(write(t, "schema: 1\r\nname: crlf\r\ndomain: \"c.test\"\r\n"), version)
	if m.Domain != "c.test" {
		t.Errorf("CRLF domain %q", m.Domain)
	}
	m, _ = Require(write(t, "schema: 1\nname: nodomain\ndomain: \"\"\n"), version)
	if m.Domain != "" {
		t.Errorf("empty domain %q", m.Domain)
	}
}

// init-project's manifest, byte for byte, and it reads back.
func TestRender(t *testing.T) {
	want := "schema: 1\nkasbah_version: 0.9.0-dev\n\nname: demo\ndomain: \"demo.example.com\"\n\nsync:\n  - compose.prod.yml -> compose.yml\n  - .env.prod.example\n"
	if got := string(Render("demo", "demo.example.com", version)); got != want {
		t.Errorf("render:\n%s\nwant\n%s", got, want)
	}
	p := filepath.Join(t.TempDir(), File)
	if err := Write(p, "integration", "", version); err != nil {
		t.Fatal(err)
	}
	m, err := Require(p, version)
	if err != nil || m.Name != "integration" || m.Domain != "" {
		t.Errorf("written manifest reads back as %+v %v", m, err)
	}
	if v, _ := m.Get("sync"); jv.Compact(v) != `["compose.prod.yml -> compose.yml",".env.prod.example"]` {
		t.Errorf("sync %v", jv.Compact(v))
	}
}

func TestClientCheck(t *testing.T) {
	if _, ok := ClientCheck("acme-corp"); !ok {
		t.Error("acme-corp is a client")
	}
	if r, ok := ClientCheck("Acme"); ok || !strings.Contains(r, "must match ^[a-z][a-z0-9-]*$") {
		t.Errorf("Acme: %q", r)
	}
	if r, ok := ClientCheck("mail"); ok || r != "client 'mail' is reserved — kasbah owns the backup repository of that name (reserved: traefik mail data backups)" {
		t.Errorf("mail: %q", r)
	}
}
