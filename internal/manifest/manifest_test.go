package manifest

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/tree"
)

const ours = "0.9.0-dev"

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
	_, err := Require(path, ours)
	var e *cli.Error
	if !errors.As(err, &e) {
		t.Fatalf("want a refusal containing %q, got %v", want, err)
	}
	if e.Code != code || !strings.Contains(e.Error(), want) {
		t.Errorf("exit %d %q, want exit %d containing %q", e.Code, e.Error(), code, want)
	}
}

func TestMissing(t *testing.T) {
	p := filepath.Join(t.TempDir(), File)
	_, err := Require(p, ours)
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
	p := write(t, "schema: 1\nkasbah_version: "+ours+"\nname: demo\ndomain: \"demo.example.com\"\nsync:\n  - compose.prod.yml -> compose.yml\n")
	m, err := Require(p, ours)
	if err != nil {
		t.Fatal(err)
	}
	if m.Schema != "1" || m.KasbahVersion != ours || m.Name != "demo" || m.Domain != "demo.example.com" {
		t.Errorf("fields %+v", m)
	}
	if v, _ := m.Get("sync", 0); v != "compose.prod.yml -> compose.yml" {
		t.Errorf("sync[0] = %v", v)
	}
}

func TestRefusals(t *testing.T) {
	refused(t, write(t, "schema: 2\nkasbah_version: x\nname: demo\ndomain: \"\"\n"), 1, "schema 2 is newer than this kasbah (0.9.0-dev supports schema 1). Upgrade kasbah.")
	// A newer schema names its major, for the hand-off to a kasbah of it.
	_, err := Require(write(t, "schema: 7\nname: demo\n"), ours)
	var ns *NewerSchema
	if !errors.As(err, &ns) || ns.Schema != 7 {
		t.Errorf("a newer schema is not a *NewerSchema naming it: %#v", err)
	}
	if _, err := Require(write(t, "schema: 0\nname: demo\n"), ours); errors.As(err, &ns) {
		t.Errorf("an older schema is a *NewerSchema: %v", err)
	}
	refused(t, write(t, "kasbah_version: x\nname: demo\n"), 1, "missing required field 'schema'")
	refused(t, write(t, "schema: 1.0\nname: demo\n"), 1, "schema must be an integer (got '1.0')")
	refused(t, write(t, "schema: 1e0\nname: demo\n"), 1, "schema must be an integer (got '1.0')")
	refused(t, write(t, "schema: 1.5\nname: demo\n"), 1, "schema must be an integer (got '1.5')")
	refused(t, write(t, "schema: 1\nname: Demo_App\n"), 1, "invalid name 'Demo_App'")
	refused(t, write(t, "schema: 1\n"), 1, "missing required field 'name'")
	refused(t, write(t, "schema: 1\nname: \"null\"\n"), 1, "missing required field 'name'")
	refused(t, write(t, "schema: 1\nname: false\n"), 1, "name: must be a string, not false")
	refused(t, write(t, "schema: 1\nname: demo\ndomain: false\n"), 1, "domain: must be a string, not false")
	refused(t, write(t, "schema: 1\nkasbah_version: true\nname: demo\n"), 1, "kasbah_version: must be a string, not true")
	refused(t, write(t, "schema: false\nname: demo\n"), 1, "schema must be an integer (got 'false')")
	refused(t, write(t, "schema: 1\nname: [unterminated\n"), 1, "could not parse YAML")
	refused(t, write(t, "just a string\n"), 1, "the document is not a mapping")
	refused(t, write(t, "- a\n"), 1, "the document is not a mapping")
	refused(t, write(t, "schema: 1\nname: a\n---\nschema: 1\nname: b\n"), 1, "expected a single YAML document")
	refused(t, write(t, ""), 1, "expected a single YAML document")
	refused(t, write(t, "# only a comment\n"), 1, "expected a single YAML document")
	refused(t, write(t, "schema: 1\nname: demo\ndomain: {a: 1}\n"), 1, "domain: is a list or a mapping")
	refused(t, write(t, "schema: 1\nname: \"de\\nmo\"\n"), 1, "name: spans more than one line")
	// Only a YAML boolean: `no` is a string to go.yaml.in/yaml/v3.
	for _, v := range []string{"no", `"false"`, "0", "off", "fAlSe", "[false]"} {
		refused(t, write(t, "schema: 1\nname: demo\nrouted: "+v+"\n"), 1, "routed: must be true or false, not ")
	}
	// The schema is judged first: a newer one hands off whatever `routed` holds.
	if _, err := Require(write(t, "schema: 2\nname: demo\nrouted: maybe\n"), ours); !errors.As(err, &ns) || ns.Schema != 2 {
		t.Errorf("schema 2 beside a bad routed: is not a *NewerSchema: %v", err)
	}
	refused(t, write(t, "name: demo\nrouted: maybe\n"), 1, "missing required field 'schema'")
	for _, r := range Reserved {
		p := write(t, "schema: 1\nkasbah_version: 0.1.0\nname: "+r+"\ndomain: \"r.test\"\nsync: []\n")
		refused(t, p, 1, "is reserved — kasbah owns <apps>/"+r+" on every server (reserved: traefik mail data backups kasbah-backup)")
	}
	refused(t, write(t, "schema: 1\nname: kasbah-backup\n"), 1,
		"'kasbah-backup' is reserved — it is the compose project of kasbah's own backup stack, on any server that runs backups (reserved: traefik mail data backups kasbah-backup). Rename the project.")
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
		m, err := Require(write(t, in), ours)
		if err != nil || m.Name != name {
			t.Errorf("%q: %v %v", in, m, err)
		}
	}
	m, _ := Require(write(t, "schema: 1\r\nname: crlf\r\ndomain: \"c.test\"\r\n"), ours)
	if m.Domain != "c.test" {
		t.Errorf("CRLF domain %q", m.Domain)
	}
	m, _ = Require(write(t, "schema: 1\nname: nodomain\ndomain: \"\"\n"), ours)
	if m.Domain != "" || m.Unrouted {
		t.Errorf("empty domain %q, unrouted %v", m.Domain, m.Unrouted)
	}
	for in, unrouted := range map[string]bool{"routed: false\n": true, "routed: False\r\n": true, "routed: true\n": false, "routed: ~\n": false, "": false} {
		m, err := Require(write(t, "schema: 1\nname: relay\n"+in), ours)
		if err != nil || m.Unrouted != unrouted || m.Domain != "" {
			t.Errorf("%q: %+v %v", in, m, err)
		}
	}
}

// init-project's manifest, byte for byte, and it reads back.
func TestRender(t *testing.T) {
	want := "schema: 1\nkasbah_version: 0.9.0-dev\n\nname: demo\ndomain: \"demo.example.com\"\n\nsync:\n  - compose.prod.yml -> compose.yml\n  - .env.prod.example\n"
	if got := string(Render("demo", "demo.example.com", ours)); got != want {
		t.Errorf("render:\n%s\nwant\n%s", got, want)
	}
	p := filepath.Join(t.TempDir(), File)
	if err := Write(p, "integration", "", ours); err != nil {
		t.Fatal(err)
	}
	m, err := Require(p, ours)
	if err != nil || m.Name != "integration" || m.Domain != "" {
		t.Errorf("written manifest reads back as %+v %v", m, err)
	}
	if v, _ := m.Get("sync"); tree.Compact(v) != `["compose.prod.yml -> compose.yml",".env.prod.example"]` {
		t.Errorf("sync %v", tree.Compact(v))
	}
}

func TestClientCheck(t *testing.T) {
	if _, ok := ClientCheck("acme-corp"); !ok {
		t.Error("acme-corp is a client")
	}
	if r, ok := ClientCheck("Acme"); ok || !strings.Contains(r, "must match ^[a-z][a-z0-9-]*$") {
		t.Errorf("Acme: %q", r)
	}
	// A client names a repository, and no repository is called kasbah-backup.
	if r, ok := ClientCheck("kasbah-backup"); !ok {
		t.Errorf("kasbah-backup refused as a client: %s", r)
	}
	if r, ok := ClientCheck("mail"); ok || r != "client 'mail' is reserved — kasbah owns the backup repository of that name (reserved: traefik mail data backups)" {
		t.Errorf("mail: %q", r)
	}
}

func TestMinKasbah(t *testing.T) {
	const dev = "1.2.1-dev"
	need := func(min string) string { return "schema: 1\nname: demo\nmin_kasbah: " + min + "\n" }
	for min, want := range map[string]string{"1.2.0": "1.2.0", "1.2.2": "1.2.2", "2.0.0": "2.0.0", `"2.0.0"`: "2.0.0", `"2.0.0\r"`: "2.0.0"} {
		m, err := Require(write(t, need(min)), dev)
		if err != nil {
			t.Errorf("min_kasbah %s refused: %v", min, err)
		} else if m.MinKasbah != want {
			t.Errorf("min_kasbah %s read as %q", min, m.MinKasbah)
		}
	}
	if m, err := Require(write(t, "schema: 1\r\nname: demo\r\nmin_kasbah: 1.0.0\r\n"), dev); err != nil || m.MinKasbah != "1.0.0" {
		t.Errorf("CRLF min_kasbah: %+v, %v", m, err)
	}
	if m, err := Require(write(t, "schema: 1\nname: demo\nmin_kasbah:\n"), dev); err != nil || m.MinKasbah != "" {
		t.Errorf("null min_kasbah: %+v, %v", m, err)
	}

	for _, min := range []string{"1.2.3", "1.4.0", "2.1.0", "99.0.0"} {
		_, err := Require(write(t, need(min)), dev)
		var ok *OlderKasbah
		var e *cli.Error
		if !errors.As(err, &ok) || ok.Min != min || !errors.As(err, &e) {
			t.Errorf("min_kasbah %s: not an *OlderKasbah naming it: %#v", min, err)
			continue
		}
		if want := "this project needs kasbah " + min + " or newer (min_kasbah), and this kasbah is " + dev; e.Code != 1 || !strings.Contains(e.Lines[0], want) {
			t.Errorf("min_kasbah %s: exit %d %q", min, e.Code, e.Lines)
		}
		if e.HelpTopic() != "S09" || !strings.Contains(strings.Join(e.NextLines(), " "), "kasbah self-update v"+min) {
			t.Errorf("min_kasbah %s: help %q, next %q", min, e.HelpTopic(), e.NextLines())
		}
	}
	// An unstamped build meets no minimum, and the way out is a stamped build.
	_, err := Require(write(t, need("1.0.0")), "unstamped")
	var older *OlderKasbah
	var ue *cli.Error
	if !errors.As(err, &older) || !errors.As(err, &ue) || !strings.Contains(ue.Lines[0], "carries no build stamp, so it meets no minimum") ||
		!strings.Contains(strings.Join(ue.NextLines(), " "), "docker compose run --rm build") {
		t.Errorf("unstamped build under min_kasbah 1.0.0: %#v", err)
	}
	for _, min := range []string{"v2.0.0", "\">=2.0.0\"", "2.0", "2", "2.0.0-rc.1", "latest"} {
		refused(t, write(t, need(min)), 1, "min_kasbah must be a release version MAJOR.MINOR.PATCH, such as 2.0.0 — no v, no operator (got '")
	}
	refused(t, write(t, need("true")), 1, "min_kasbah: must be a string, not true")
	refused(t, write(t, need("[2.0.0]")), 1, "min_kasbah: is a list or a mapping")
	refused(t, write(t, need("\"2.0.0\\n3.0.0\"")), 1, "min_kasbah: spans more than one line")
	// The schema is judged first: a newer one hands off whatever min_kasbah says.
	var ns *NewerSchema
	if _, err := Require(write(t, "schema: 2\nname: demo\nmin_kasbah: [x]\n"), dev); !errors.As(err, &ns) {
		t.Errorf("schema 2 beside a bad min_kasbah: is not a *NewerSchema: %v", err)
	}
}
