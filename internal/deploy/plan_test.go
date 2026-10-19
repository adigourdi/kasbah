package deploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/manifest"
)

func TestParseSync(t *testing.T) {
	got, err := ParseSync([]string{" compose.prod.yml -> compose.yml\r", "", "null", "site/", "docker/ -> etc/docker", "a/b.txt"})
	if err != nil {
		t.Fatal(err)
	}
	want := []Entry{{"compose.prod.yml", "compose.yml", false}, {"site", "site", true}, {"docker", "etc/docker", true}, {"a/b.txt", "a/b.txt", false}}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("entry %d = %v, want %v", i, got[i], want[i])
		}
	}
	for _, bad := range []string{"/etc/passwd", "-rf", "a:b", "a/../b", "./a", "a -> ", "a\tb\x01"} {
		if _, err := ParseSync([]string{bad}); err == nil {
			t.Errorf("ParseSync(%q) accepted", bad)
		}
	}
	if _, err := ParseSync(nil); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Errorf("an empty list: %v", err)
	}
	if p := RemoteParents("/apps/x", want); strings.Join(p, " ") != "/apps/x/site /apps/x/etc/docker /apps/x/a" {
		t.Errorf("RemoteParents = %v", p)
	}
}

func TestSeconds(t *testing.T) {
	for in, want := range map[string]int{"120": 120, "60s": 60, "5m": 300, "2h": 7200} {
		if n, err := Seconds(in); err != nil || n != want {
			t.Errorf("Seconds(%q) = %d %v", in, n, err)
		}
	}
	for _, bad := range []string{"", "0s", "1d", "-5", "5 m", "1.5m"} {
		if _, err := Seconds(bad); err == nil {
			t.Errorf("Seconds(%q) accepted", bad)
		}
	}
}

func TestArgs(t *testing.T) {
	if o, err := Parse([]string{"1.0.0", "d@h"}); err != nil || o.Version != "1.0.0" || o.Target != "d@h" {
		t.Fatalf("a version and a server: %+v %v", o, err)
	}
	for _, bad := range [][]string{{"v1.0.0"}, {"1.0"}, {"1.0.0", "2.0.0"}} {
		if _, err := ParseRollback(bad); err == nil || !strings.HasPrefix(err.Error(), "rollback: ") {
			t.Errorf("ParseRollback(%q) = %v", bad, err)
		}
	}
	o, err := Parse([]string{"--allow-stopped", "d@h", "--on-drift=continue", "--no-health-wait", "--skip-hooks"})
	if err != nil || o.Target != "d@h" || o.OnDrift != "continue" || !o.SkipHooks || !o.NoHealthWait || !o.AllowStopped {
		t.Fatalf("Parse = %+v %v", o, err)
	}
	for _, bad := range [][]string{{"--skip-hooks=yes"}, {"--on-drift"}, {"--on-drift=x"}, {"--nope"}, {"a@b", "c@d"}} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("Parse(%q) accepted", bad)
		}
	}
	if _, err := Parse([]string{"--help"}); err != ErrHelp {
		t.Errorf("--help = %v", err)
	}
}

func plan(t *testing.T, yml string) (*Plan, error) {
	t.Helper()
	dir := t.TempDir()
	t.Chdir(dir)
	os.WriteFile("kasbah.yml", []byte("schema: 1\nname: demo\nsync:\n  - compose.prod.yml -> compose.yml\n"+yml), 0o644)
	os.WriteFile("compose.prod.yml", []byte("services:\n  web:\n    build: .\n    image: reg:5000/demo-web:current\n  db:\n    image: postgres\n"), 0o644)
	m, err := manifest.Require(manifest.File, "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	return ReadPlan(m, dir, "1.0.0")
}

func TestReadPlan(t *testing.T) {
	p, err := plan(t, `hooks:
  pre-deploy: ['demo-web  php artisan down']
  post-rollback: [demo-web echo]
health: {timeout: 2m}
backup: {container: demo-db, check: 'true', command: dump, extension: sql.gz}
mail: {domain: demo.test, snappymail_domain: s.json}
client: acme
`)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(p.Images, " ") != "reg:5000/demo-web" || p.Health.Timeout != 120 || p.Health.Container != "" {
		t.Fatalf("images %v health %+v", p.Images, p.Health)
	}
	if p.Hooks["pre-deploy"][0] != "demo-web  php artisan down" || len(p.Hooks["post-rollback"]) != 1 {
		t.Fatalf("hooks %v", p.Hooks)
	}
	if p.Backup == nil || p.Backup.Retain != 10 || p.MailDomain != "demo.test" || p.MailSnappy != "s.json" || p.Client != "acme" {
		t.Fatalf("plan %+v %+v", p, p.Backup)
	}

	for yml, want := range map[string]string{
		"hooks: {pre-deploy: ['demo-web']}\n":                                     "names a container and no command",
		"hooks: {pre-deploy: [\"demo-web a\\nb\"]}\n":                             "spans more than one line",
		"hooks: {pre-deploy: demo-web x}\n":                                       "is not a list",
		"health: {timeout: 0s}\n":                                                 "is zero",
		"backup: {container: c, check: c, command: c}\n":                          "has no extension:",
		"backup: {container: c, check: c, command: c, extension: a/b}\n":          "plain filename extension",
		"backup: {container: c, check: c, command: c, extension: \"sql\\a\"}\n":   "plain filename extension",
		"backup: {container: c, check: c, command: c, extension: \"a\u00a0b\"}\n": "plain filename extension",
		"backup: {container: c, check: c, command: c, extension: x, retain: 0}":   "retain is 0",
		"mail: example.test\n":                                                    "mail: has type 'string'",
		"mail: {snappymail_domain: x}\n":                                          "has no domain:",
	} {
		if _, err := plan(t, yml); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v; want %q", yml, err, want)
		}
	}
	if _, err := plan(t, ""); err != nil {
		t.Fatal(err)
	}
	os.Remove(filepath.Join(".", "compose.prod.yml"))
	m, _ := manifest.Require(manifest.File, "0.1.0")
	if _, err := ReadPlan(m, ".", "1.0.0"); err == nil || !strings.Contains(err.Error(), "compose.prod.yml — no such file") {
		t.Errorf("no compose file: %v", err)
	}
}
