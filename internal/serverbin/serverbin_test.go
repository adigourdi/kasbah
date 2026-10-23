package serverbin

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/shtest"
)

func TestScriptsParse(t *testing.T) {
	shtest.Check(t, "serverbin", map[string]string{"probe": probeScript, "upload": uploadScript})
}

// The upload never overwrites, keeps nothing short, and sweeps what a killed
// run left an hour ago.
func TestUploadScript(t *testing.T) {
	for _, sh := range shtest.Shells(t) {
		dir := filepath.Join(t.TempDir(), "b in")
		up := func(name, body, size string) (string, int) {
			cmd := sh.C(uploadScript, dir, name, size)
			cmd.Stdin = strings.NewReader(body)
			var e strings.Builder
			cmd.Stderr = &e
			err := cmd.Run()
			if err != nil {
				return e.String(), 1
			}
			return e.String(), 0
		}
		if e, rc := up(TempPrefix+"a", "hello", "5"); rc != 0 {
			t.Fatalf("%s: %q", sh.Name, e)
		}
		f := filepath.Join(dir, TempPrefix+"a")
		if b, _ := os.ReadFile(f); string(b) != "hello" {
			t.Errorf("%s: %q", sh.Name, b)
		}
		if fi, err := os.Stat(f); err != nil || fi.Mode().Perm() != 0o755 {
			t.Errorf("%s: mode %v", sh.Name, fi)
		}
		if _, rc := up(TempPrefix+"a", "other", "5"); rc == 0 {
			t.Errorf("%s: an existing upload was overwritten", sh.Name)
		}
		if b, _ := os.ReadFile(f); string(b) != "hello" {
			t.Errorf("%s: an existing upload changed: %q", sh.Name, b)
		}
		if e, rc := up(TempPrefix+"b", "abc", "10"); rc == 0 || !strings.Contains(e, "cut short") {
			t.Errorf("%s: a short upload: %q", sh.Name, e)
		}
		if _, err := os.Stat(filepath.Join(dir, TempPrefix+"b")); err == nil {
			t.Errorf("%s: a short upload was kept", sh.Name)
		}
		old := time.Now().Add(-2 * time.Hour)
		os.Chtimes(f, old, old)
		if _, rc := up(TempPrefix+"c", "x", "1"); rc != 0 {
			t.Errorf("%s: a third upload failed", sh.Name)
		}
		if _, err := os.Stat(f); err == nil {
			t.Errorf("%s: a stale upload was not swept", sh.Name)
		}
	}
}

func TestArch(t *testing.T) {
	for in, want := range map[string]string{"x86_64": "amd64", "aarch64": "arm64", "arm64": "arm64", "x86_64\r\n": "amd64"} {
		if got, err := Arch(in); err != nil || got != want {
			t.Errorf("Arch(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"armv7l", "i686", "riscv64", ""} {
		_, err := Arch(in)
		if err == nil || !strings.Contains(err.Error(), "'"+in+"'") {
			t.Errorf("Arch(%q) = %v, want a refusal naming the machine type", in, err)
		}
	}
}

func TestLocal(t *testing.T) {
	root := t.TempDir()
	co := filepath.Join(root, "dist", "server", "kasbah-linux-amd64")
	inst := filepath.Join(root, "server", "kasbah-linux-arm64")
	for _, f := range []string{co, inst} {
		os.MkdirAll(filepath.Dir(f), 0o755)
		os.WriteFile(f, nil, 0o755)
	}
	if got, err := Local(root, true, "amd64"); err != nil || got != co {
		t.Errorf("checkout: %q, %v", got, err)
	}
	if got, err := Local(root, false, "arm64"); err != nil || got != inst {
		t.Errorf("installed: %q, %v", got, err)
	}
	if _, err := Local(root, true, "arm64"); err == nil || !strings.Contains(err.Error(), "docker compose run --rm build") {
		t.Errorf("a missing checkout binary: %v", err)
	}
	if _, err := Local(root, false, "amd64"); err == nil || !strings.Contains(err.Error(), "install-dev.sh") {
		t.Errorf("a missing installed binary: %v", err)
	}
}

func TestLocalFetchesRelease(t *testing.T) {
	lib := t.TempDir()
	var fetched []string
	fetchRelease = func(home, ver, arch string) error {
		fetched = append(fetched, ver+" "+arch)
		p := filepath.Join(home, "server", "kasbah-linux-"+arch)
		os.MkdirAll(filepath.Dir(p), 0o755)
		return os.WriteFile(p, nil, 0o755)
	}
	t.Cleanup(func() { fetchRelease = func(string, string, string) error { return errors.New("no network in tests") } })
	// A release version fetches the missing build, once.
	home := filepath.Join(lib, "1.2.0")
	os.MkdirAll(home, 0o755)
	want := filepath.Join(home, "server", "kasbah-linux-arm64")
	if got, err := Local(home, false, "arm64"); err != nil || got != want {
		t.Errorf("release: %q, %v", got, err)
	}
	if got, err := Local(home, false, "arm64"); err != nil || got != want {
		t.Errorf("release, second time: %q, %v", got, err)
	}
	if len(fetched) != 1 || fetched[0] != "1.2.0 arm64" {
		t.Errorf("fetched %v", fetched)
	}
	// A dev stamp and a checkout never fetch.
	dev := filepath.Join(lib, "1.2.1-dev.88.1700000000")
	os.MkdirAll(dev, 0o755)
	if _, err := Local(dev, false, "arm64"); err == nil || !strings.Contains(err.Error(), "install-dev.sh") {
		t.Errorf("dev stamp: %v", err)
	}
	if _, err := Local(t.TempDir(), true, "arm64"); err == nil || !strings.Contains(err.Error(), "docker compose run --rm build") {
		t.Errorf("checkout: %v", err)
	}
	if len(fetched) != 1 {
		t.Errorf("a dev stamp or a checkout fetched: %v", fetched)
	}
	// A fetch that fails names the release and the remedy; nothing is returned.
	fetchRelease = func(string, string, string) error { return errors.New("no GitHub token: x\nset GITHUB_TOKEN") }
	other := filepath.Join(lib, "1.3.0")
	os.MkdirAll(other, 0o755)
	_, err := Local(other, false, "amd64")
	if err == nil || !strings.Contains(err.Error(), "release v1.3.0 failed") || !strings.Contains(err.Error(), "set GITHUB_TOKEN") || !strings.Contains(err.Error(), "install-dev.sh") {
		t.Errorf("failed fetch: %v", err)
	}
}

func TestNormPath(t *testing.T) {
	for in, want := range map[string]string{
		"/apps": "/apps", "/apps/": "/apps", "//apps": "/apps", "/apps/.": "/apps",
		"/srv//x/./y/ \t": "/srv/x/y", "/": "/", "apps": "apps", "/apps\r": "/apps", "/a/../b": "/a/../b",
	} {
		if got := normPath(in); got != want {
			t.Errorf("normPath(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMount(t *testing.T) {
	proc := []string{
		"/dev/sda1 / ext4 rw,relatime 0 0",
		"tmpfs /srv tmpfs rw,nosuid,noexec 0 0",
		"tmpfs /srv/apps\\040x tmpfs rw,nosuid 0 0",
		"tmpfs /srvx tmpfs rw,noexec 0 0",
	}
	tests := map[string]string{
		"/srv/apps/.kasbah/bin/kasbah":   "/srv tmpfs rw,nosuid,noexec",
		"/srv/apps x/.kasbah/bin/kasbah": "/srv/apps x tmpfs rw,nosuid",
		"/apps/.kasbah/bin/kasbah":       "/ ext4 rw,relatime",
	}
	for file, want := range tests {
		if got := mountOf(file, proc); got != want {
			t.Errorf("mountOf(%q) = %q, want %q", file, got, want)
		}
	}
	err := noexec("d@h", "/srv/apps/.kasbah/bin", "/srv/apps/.kasbah/bin/kasbah", proc)
	if err == nil || !strings.Contains(err.Error(), "noexec") || !strings.Contains(err.Error(), "/srv ") || !strings.Contains(err.Error(), "from /srv/apps/.kasbah/bin ") {
		t.Errorf("noexec over /proc/mounts = %v, want a refusal naming /srv", err)
	}
	if err := noexec("d@h", "/apps/.kasbah/bin", "/apps/.kasbah/bin/kasbah", proc); err != nil {
		t.Errorf("an exec mount was blamed: %v", err)
	}
	err = noexec("d@h", "/x/bin", "/x/bin/kasbah", []string{"/x tmpfs rw,noexec"})
	if err == nil || !strings.Contains(err.Error(), "/x is mounted noexec") {
		t.Errorf("noexec over findmnt = %v", err)
	}
	if err := noexec("d@h", "/x/bin", "/x/bin/kasbah", nil); err != nil {
		t.Errorf("no mount information blamed a mount: %v", err)
	}
}

// One table through both normalisers: the probe's POSIX-sh norm_path, reading
// the pointer file as the probe does, and normPath on the same first line.
func TestNormPathShAndGoAgree(t *testing.T) {
	start := strings.Index(probeScript, "norm_path() {")
	end := strings.Index(probeScript[start:], "\n}\n") + start + 3
	fn := "cr=$(printf '\\r')\n" + probeScript[start:end]
	driver := fn + `IFS= read -r pointed < "$1" || [ -n "$pointed" ] || pointed=""
norm_path "$pointed"`
	dir := t.TempDir()
	for _, in := range []string{
		"/apps\n", "/apps", "/apps/\n", "//apps//x//\n", "/srv/./x/.\n", "/apps \t \n", "/apps\r\n", "/apps\r",
		"/apps \r\n", "/*\n", "/a*/[b]?/x\n", "/\n", "//\n", "apps/x\n", "/a/../b\n", "\n", "", "/apps\n/other\n",
		"/sp ace/x\n",
	} {
		f := filepath.Join(dir, "pointer")
		if err := os.WriteFile(f, []byte(in), 0o644); err != nil {
			t.Fatal(err)
		}
		line, _, _ := strings.Cut(in, "\n")
		for _, sh := range shtest.Shells(t) {
			out, err := sh.C(driver, f).Output()
			if err != nil {
				t.Fatalf("%q: %s: %v", in, sh.Name, err)
			}
			if got := normPath(line); got != string(out) {
				t.Errorf("%q: Go %q, %s %q", in, got, sh.Name, out)
			}
		}
	}
}
