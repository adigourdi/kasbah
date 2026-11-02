package deploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/yamlx"
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
	o, err := Parse([]string{"--on-hook-failure=stop", "d@h", "--on-drift=continue", "--no-health-wait", "--skip-hooks"})
	if err != nil || o.Target != "d@h" || o.OnDrift != "continue" || !o.SkipHooks || !o.NoHealthWait || o.OnHookFailure != "stop" {
		t.Fatalf("Parse = %+v %v", o, err)
	}
	for _, bad := range [][]string{{"--skip-hooks=yes"}, {"--on-drift"}, {"--on-drift=x"}, {"--on-hook-failure"}, {"--on-hook-failure=abort"}, {"--on-hook-failure="}, {"--allow-stopped"}, {"--nope"}, {"a@b", "c@d"}} {
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
  pre-deploy: ['  docker compose exec -T web php artisan down  ']
  post-rollback: ["echo \"$KASBAH_VERSION\" | tee -a deployed.txt"]
  backup: ['docker compose exec -T db pg_dump app > "$KASBAH_BACKUP_DIR/db.sql"']
  restore: ['docker compose exec -T db psql app < "$KASBAH_BACKUP_DIR/db.sql"']
health: {timeout: 2m}
mail: {domain: demo.test}
client: acme
`)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(p.Images, " ") != "reg:5000/demo-web" || p.Health.Timeout != 120 || p.Health.Container != "" {
		t.Fatalf("images %v health %+v", p.Images, p.Health)
	}
	if p.Hooks["pre-deploy"][0] != "docker compose exec -T web php artisan down" || p.Hooks["post-rollback"][0] != `echo "$KASBAH_VERSION" | tee -a deployed.txt` {
		t.Fatalf("hooks %v", p.Hooks)
	}
	if p.Hooks["backup"][0] != `docker compose exec -T db pg_dump app > "$KASBAH_BACKUP_DIR/db.sql"` || len(p.Hooks["restore"]) != 1 || p.MailDomain != "demo.test" || p.Client != "acme" {
		t.Fatalf("plan %+v", p)
	}

	for yml, want := range map[string]string{
		"hooks: {pre-deploy: ['  ']}\n":                                "hooks.pre-deploy holds an empty entry",
		"hooks: {pre-deploy: [~]}\n":                                   "hooks.pre-deploy holds null — each entry must be a string",
		"hooks: {pre-deploy: [42]}\n":                                  "hooks.pre-deploy holds 42 — each entry must be a string, one shell command",
		"hooks: {pre-deploy: [\"a\\nb\"]}\n":                           "the pre-deploy hook 'a…' spans more than one line",
		"hooks: {post-deploy: [\"a\\r\\nb\"]}\n":                       "the post-deploy hook 'a…' spans more than one line",
		"hooks: {pre-deploy: demo-web x}\n":                            "is not a list",
		"hooks: {pre-deploy: false}\n":                                 "is not a list",
		"hooks: {pre-deploy: [false]}\n":                               "hooks.pre-deploy holds false — each entry must be a string",
		"hooks: x\n":                                                   "hooks: is not a block",
		"hooks: false\n":                                               "hooks: is not a block",
		"hooks: ['demo-web a']\n":                                      "hooks: is not a block",
		"hooks: {pre_deploy: ['demo-web a']}\n":                        "hooks.pre_deploy is not a hook kasbah runs — hooks: holds the lists backup:, pre-deploy:, post-deploy:, restore:, pre-rollback: and post-rollback:",
		"hooks: {restore: ['a', '']}\n":                                "hooks.restore holds an empty entry",
		"hooks: {backup: \"pg_dump\"}\n":                               "hooks.backup is not a list",
		"backup: {container: c, check: c, command: c, extension: x}\n": "backup: is not a key kasbah reads — a backup is the hooks.backup list",
		"backup: false\n":                                              "backup: is not a key kasbah reads",
		"backup: ~\n":                                                  "backup: is not a key kasbah reads",
		"health: x\n":                                                  "health: is not a block",
		"health: [a]\n":                                                "health: is not a block",
		"health: {timeout: false}\n":                                   "health.timeout must be a duration like 120s, 5m or 2h, not false",
		"health: {container: [a]}\n":                                   "health.container must be a string, not [\"a\"]",
		"client: false\n":                                              "client must be a string, not false",
		"mail: {domain: false}\n":                                      "mail.domain must be a string, not false",
		"health: {timeout: 0s}\n":                                      "is zero",
		"mail: example.test\n":                                         "mail: is not a block",
		"mail: {}\n":                                                   "has no domain:",
	} {
		if _, err := plan(t, yml); err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v; want %q", yml, err, want)
		}
	}
	if _, err := plan(t, ""); err != nil {
		t.Fatal(err)
	}
	if p, err := plan(t, "health: false\nmail: false\n"); err != nil || p.MailDomain != "" || p.Health.Timeout != 120 {
		t.Errorf("false turns a block off: %+v %v", p, err)
	}
	if p, err := plan(t, "health: {timeout: 30}\nhooks: ~\n"); err != nil || p.Health.Timeout != 30 {
		t.Errorf("numbers: %+v %v", p, err)
	}
	for _, sync := range []string{"sync: {a: compose.yml}\n", "sync: compose.yml\n"} {
		docs, _ := yamlx.Load([]byte("schema: 1\nname: demo\n" + sync))
		if _, err := syncLines(&manifest.Manifest{Doc: docs[0]}); err == nil || !strings.Contains(err.Error(), "sync: is not a list") {
			t.Errorf("%q: %v", sync, err)
		}
	}
	os.Remove(filepath.Join(".", "compose.prod.yml"))
	m, _ := manifest.Require(manifest.File, "0.1.0")
	if _, err := ReadPlan(m, ".", "1.0.0"); err == nil || !strings.Contains(err.Error(), "compose.prod.yml — no such file") {
		t.Errorf("no compose file: %v", err)
	}
}
