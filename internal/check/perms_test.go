package check

import (
	"os"
	"os/user"
	"strconv"
	"strings"
	"testing"
)

func TestPerms(t *testing.T) {
	gname := strconv.Itoa(os.Getgid())
	if g, err := user.LookupGroupId(gname); err == nil {
		gname = g.Name
	}
	real := t.TempDir()
	os.Chmod(real, 0o775|os.ModeSetgid)
	apps := t.TempDir() + "/link"
	os.Symlink(real, apps)
	me := map[int]bool{os.Getuid(): true}
	for _, d := range []string{"/demo", "/data/demo", "/.kasbah/backup"} {
		os.MkdirAll(apps+d, 0o755)
	}
	os.Chmod(apps+"/.kasbah", 0o775|os.ModeSetgid)
	os.Chmod(apps+"/.kasbah/backup", 0o700)
	os.WriteFile(apps+"/demo/.env", nil, 0o600)
	os.WriteFile(apps+"/demo/compose.yml", nil, 0o644)
	os.WriteFile(apps+"/data/demo/x", nil, 0o600)

	if st, _, _ := Perms(apps, apps+"/data", "no-such-group-kasbah"); st != "absent" {
		t.Errorf("a missing group reads %q", st)
	}
	n, list := perms(apps, apps+"/data", os.Getgid(), me)
	got := strings.Join(list, "\n")
	if n != 3 || !strings.Contains(got, real+"/data (group") || !strings.Contains(got, real+"/demo (group "+gname+", mode 2755)") ||
		!strings.Contains(got, real+"/demo/.env (group "+gname+", mode 600)") {
		t.Fatalf("perms = %d:\n%s", n, got)
	}
	if n, _ := perms(apps, apps+"/data", os.Getgid()+1, me); n != 7 {
		t.Errorf("another group flags every entry outside data/, got %d", n)
	}
	os.Chmod(apps+"/demo", 0o775|os.ModeSetgid)
	os.Chmod(apps+"/data", 0o775|os.ModeSetgid)
	os.Chmod(apps+"/demo/.env", 0o660)
	if n, list := perms(apps, apps+"/data", os.Getgid(), me); n != 0 {
		t.Errorf("a converged tree still flags %v", list)
	}
}

// TestPermsOwnersAndPrivate: what no operator owns, and directories with no
// group bits, are neither the root step's nor the check's.
func TestPermsOwnersAndPrivate(t *testing.T) {
	apps := t.TempDir()
	os.Chmod(apps, 0o775|os.ModeSetgid)
	os.Mkdir(apps+"/demo", 0o775|os.ModeSetgid)
	os.Chmod(apps+"/demo", 0o775|os.ModeSetgid)
	os.Mkdir(apps+"/demo/pgdata", 0o700)
	os.Chmod(apps+"/demo/pgdata", 0o700)
	if n, list := perms(apps, apps+"/data", os.Getgid(), map[int]bool{os.Getuid(): true}); n != 0 {
		t.Errorf("a 700 directory is flagged: %v", list)
	}
	if n, list := perms(apps, apps+"/data", os.Getgid()+1, map[int]bool{os.Getuid() + 1: true}); n != 0 {
		t.Errorf("entries no operator owns are flagged: %v", list)
	}
}
