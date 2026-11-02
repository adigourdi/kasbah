package env

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/serverlock"
)

func TestEnvDiff(t *testing.T) {
	cur := "SAME=1\r\nCHANGED=new\r\nexport EXPORTED=v\nLIVE=only\nTWICE=a\nTWICE=b\nKASBAH_CPU_LIMIT=2\n# OLD=commented\n"
	old := "SAME=1\nCHANGED=old\nEXPORTED=v\r\nBACKUP=only\nTWICE=b\nKASBAH_CPU_LIMIT=1\nKASBAH_GONE=1\n"
	c, o, l := EnvDiff([]byte(cur), []byte(old))
	if strings.Join(c, ",") != "CHANGED" || strings.Join(o, ",") != "BACKUP" || strings.Join(l, ",") != "LIVE" {
		t.Fatalf("changed %v only old %v only cur %v", c, o, l)
	}
	if c, o, l := EnvDiff(nil, []byte("B=1\nA=2\n")); c != nil || strings.Join(o, ",") != "A,B" || l != nil {
		t.Fatalf("no live .env: %v %v %v", c, o, l)
	}
}

func TestMergeEnv(t *testing.T) {
	cur := "# head\nA=new\r\nB=keep\nA=again\nC=live\nKASBAH_CPU_LIMIT=2\n"
	old := "A=first\nA='old one'\nD=back\nKASBAH_CPU_LIMIT=1\n"
	got := strings.Join(MergeEnv([]byte(cur), []byte(old), []string{"A", "C", "D", "KASBAH_CPU_LIMIT"}), "\n")
	if want := "# head\nA='old one'\nB=keep\nKASBAH_CPU_LIMIT=2\nD=back"; got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
}

func TestRestoreEnv(t *testing.T) {
	dir := t.TempDir()
	if err := RestoreEnv(dir, []byte("A=1\r\nB=2\n"), nil); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, ".env")
	if b, _ := os.ReadFile(p); string(b) != "A=1\r\nB=2\n" {
		t.Fatalf("whole: %q", b)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != Mode {
		t.Errorf("a new .env is %v", fi.Mode().Perm())
	}
	os.Chmod(p, 0o600)
	if err := RestoreEnv(dir, []byte("B=old\n"), []string{"A", "B"}); err != nil {
		t.Fatal(err)
	}
	if b, _ := os.ReadFile(p); string(b) != "B=old\n" {
		t.Fatalf("per key: %q", b)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o660 {
		t.Errorf("a 600 .env converges to 660, got %v", fi.Mode().Perm())
	}
	if m, _ := filepath.Glob(filepath.Join(dir, ".env.*")); len(m) != 0 {
		t.Errorf("staging left: %v", m)
	}
	lock, _, err := serverlock.Project(dir)
	if err != nil || lock == nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := RestoreEnv(dir, []byte("X=1\n"), nil); err == nil || !strings.Contains(err.Error(), ".env left untouched") {
		t.Fatalf("under a held lock: %v", err)
	}
	if b, _ := os.ReadFile(p); string(b) != "B=old\n" {
		t.Fatalf("written under a held lock: %q", b)
	}
}
