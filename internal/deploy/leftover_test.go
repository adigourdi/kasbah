package deploy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/serverlock"
)

func TestScanLeftovers(t *testing.T) {
	d := t.TempDir()
	mk := func(p string) {
		if err := os.MkdirAll(filepath.Join(d, p), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	mk("backups/1.0.0-20261102-100000/kasbah-snapshot")
	mk("backups/notabackup")
	mk(KeptPrefix + "0.9.0-20261102-090000")
	mk(UnpackedPrefix + "4242")
	os.WriteFile(filepath.Join(d, "backups/1.0.0-20261101-100000.tar.gz"), nil, 0o644)
	os.WriteFile(filepath.Join(d, "backups/2.0.0-20261101-110000"), nil, 0o644)
	l := ScanLeftovers(d)
	if strings.Join(l.Backups, ",") != "1.0.0-20261102-100000" || strings.Join(l.Kept, ",") != KeptPrefix+"0.9.0-20261102-090000" ||
		strings.Join(l.Unpacked, ",") != UnpackedPrefix+"4242" || l.Error != "" || l.Holder != "" {
		t.Errorf("scan: %+v", l)
	}

	// Nothing there: empty kinds, sent as [] rather than null.
	b, _ := json.Marshal(ScanLeftovers(t.TempDir()))
	if string(b) != `{"backups":[],"kept":[],"unpacked":[],"holder":"","error":""}` {
		t.Errorf("wire form: %s", b)
	}
}

func TestScanLeftoversSymlinks(t *testing.T) {
	// A backups/ symlinked to a directory is followed.
	d, elsewhere := t.TempDir(), t.TempDir()
	os.MkdirAll(filepath.Join(elsewhere, "1.0.0-20261102-100000"), 0o755)
	os.Mkdir(filepath.Join(elsewhere, "target"), 0o755)
	// A symlink inside it, named like a backup directory, is none.
	os.Symlink(filepath.Join(elsewhere, "target"), filepath.Join(elsewhere, "1.1.0-20261102-110000"))
	os.Symlink(elsewhere, filepath.Join(d, Backups))
	if l := ScanLeftovers(d); strings.Join(l.Backups, ",") != "1.0.0-20261102-100000" || l.Error != "" {
		t.Errorf("symlinked backups/: %+v", l)
	}
}

func TestScanLeftoversUnlistable(t *testing.T) {
	d := t.TempDir()
	os.WriteFile(filepath.Join(d, Backups), nil, 0o644)
	os.Mkdir(filepath.Join(d, KeptPrefix+"0.9.0-20261102-090000"), 0o755)
	if l := ScanLeftovers(d); l.Error != "backups/ could not be listed: not a directory" || len(l.Kept) != 1 || !l.Report() {
		t.Errorf("backups/ a file: %+v", l)
	}
	if l := ScanLeftovers(filepath.Join(d, "gone")); !strings.HasPrefix(l.Error, "the project directory could not be listed: ") || l.Any() {
		t.Errorf("no directory: %+v", l)
	}
	if os.Getuid() == 0 {
		return
	}
	os.Remove(filepath.Join(d, Backups))
	os.Mkdir(filepath.Join(d, Backups), 0o000)
	defer os.Chmod(filepath.Join(d, Backups), 0o755)
	if l := ScanLeftovers(d); l.Error != "backups/ could not be listed: permission denied" {
		t.Errorf("backups/ unreadable: %+v", l)
	}
}

func TestScanAgainstLock(t *testing.T) {
	d := t.TempDir()
	own := UnpackedPrefix + strconv.Itoa(os.Getpid())
	for _, p := range []string{"backups/1.0.0-20261102-100000", own, UnpackedPrefix + "1", KeptPrefix + "0.9.0-20261102-090000"} {
		os.MkdirAll(filepath.Join(d, p), 0o755)
	}
	if l := ScanAgainstLock(d); l.Holder != "" || len(l.Unpacked) != 2 || l.Running().Any() || len(l.Settled().Paths(d)) != 4 {
		t.Errorf("no run: %+v", l)
	}
	f, holder, err := serverlock.Project(d)
	if err != nil || f == nil {
		t.Fatalf("lock: %v %s", err, holder)
	}
	defer f.Close()
	l := ScanAgainstLock(d)
	if !strings.HasSuffix(l.Holder, "(pid "+strconv.Itoa(os.Getpid())+")") {
		t.Fatalf("holder not seen (needs /proc/locks): %+v", l)
	}
	// The holder's own extraction is left out; another's stays.
	if strings.Join(l.Unpacked, ",") != UnpackedPrefix+"1" {
		t.Errorf("unpacked: %v", l.Unpacked)
	}
	if got := strings.Join(l.Running().Paths(d), " "); got != d+"/backups/1.0.0-20261102-100000 "+d+"/"+UnpackedPrefix+"1" {
		t.Errorf("running: %s", got)
	}
	if got := strings.Join(l.Settled().Paths(d), " "); got != d+"/"+KeptPrefix+"0.9.0-20261102-090000" {
		t.Errorf("settled: %s", got)
	}
}

func TestIsProject(t *testing.T) {
	apps, elsewhere := t.TempDir(), t.TempDir()
	for _, n := range []string{"demo", ".hidden", "Caps", "traefik", "backups"} {
		os.Mkdir(filepath.Join(apps, n), 0o755)
	}
	os.WriteFile(filepath.Join(apps, "afile"), nil, 0o644)
	os.Symlink(elsewhere, filepath.Join(apps, "linked"))
	os.Symlink(filepath.Join(apps, "nowhere"), filepath.Join(apps, "dangling"))
	for n, want := range map[string]bool{"demo": true, "linked": true, ".hidden": false, "Caps": false, "traefik": false,
		"backups": false, "afile": false, "dangling": false, "absent": false} {
		if IsProject(apps, n) != want {
			t.Errorf("IsProject(%q) = %v", n, !want)
		}
	}
}
