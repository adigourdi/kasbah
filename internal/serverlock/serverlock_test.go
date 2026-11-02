package serverlock

import (
	"bufio"
	"io"
	"os"
	"strings"
	"testing"
)

func TestTake(t *testing.T) {
	apps := t.TempDir()
	if f, err := Take(apps, Exclusive, "x"); f != nil || err != nil {
		t.Fatalf("a tree with no .kasbah has nothing to lock: %v %v", f, err)
	}
	os.Mkdir(apps+"/.kasbah", 0o755)

	a, err := Take(apps, Shared, "")
	if err != nil {
		t.Fatal(err)
	}
	b, err := Take(apps, Shared, "")
	if err != nil {
		t.Fatalf("two deploys share it: %v", err)
	}
	if fi, _ := os.Stat(Path(apps)); fi.Mode().Perm() != Mode {
		t.Errorf("lock mode %o, want %o", fi.Mode().Perm(), Mode)
	}
	if _, err := Take(apps, Exclusive, "server init"); err == nil || !strings.Contains(err.Error(), "is running on this server") ||
		!strings.Contains(err.Error(), "(pid ") {
		t.Fatalf("exclusive under shared: %v", err)
	}
	a.Close()
	b.Close()

	x, err := Take(apps, Exclusive, "server prune")
	if err != nil {
		t.Fatal(err)
	}
	_, err = Take(apps, Shared, "")
	if err == nil || !strings.Contains(err.Error(), " (pid ") || !strings.Contains(err.Error(), Path(apps)) {
		t.Fatalf("shared under exclusive names the holder: %v", err)
	}
	x.Close()
	if s, err := Take(apps, Shared, ""); err != nil {
		t.Fatalf("released, it is free again: %v", err)
	} else {
		s.Close()
	}
}

// TestRemote: the lock is held from locked= until stdin closes.
func TestRemote(t *testing.T) {
	apps := t.TempDir()
	if rc := Remote([]string{apps, Exclusive, "server init"}, strings.NewReader(""), io.Discard, io.Discard); rc != 1 {
		t.Errorf("no .kasbah: rc %d", rc)
	}
	os.Mkdir(apps+"/.kasbah", 0o755)
	r, w := io.Pipe()
	outR, outW := io.Pipe()
	done := make(chan int)
	go func() { done <- Remote([]string{apps, Exclusive, "server init"}, r, outW, io.Discard) }()
	line, _ := bufio.NewReader(outR).ReadString('\n')
	if line != "locked=exclusive\n" {
		t.Fatalf("reported %q", line)
	}
	if _, err := Take(apps, Shared, ""); err == nil || !strings.Contains(err.Error(), "is running on this server") {
		t.Fatalf("held by the remote: %v ", err)
	}
	w.Close()
	if rc := <-done; rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	if s, err := Take(apps, Shared, ""); err != nil {
		t.Fatalf("stdin closed, the lock is gone: %v", err)
	} else {
		s.Close()
	}
	if rc := Remote([]string{apps, "both", "x"}, strings.NewReader(""), io.Discard, io.Discard); rc != 1 {
		t.Errorf("a bad mode: rc %d", rc)
	}
}

func TestProjectNamesItsHolder(t *testing.T) {
	dir := t.TempDir()
	a, h, err := Project(dir)
	if err != nil || a == nil || h != "" {
		t.Fatal(a, h, err)
	}
	defer a.Close()
	// This test binary holds it: named by command and pid.
	if b, h, err := Project(dir); err != nil || b != nil || !strings.Contains(h, "(pid ") {
		t.Errorf("held: %v %q %v", b, h, err)
	}
}

func TestDescribe(t *testing.T) {
	for argv, want := range map[string]string{
		"/apps/.kasbah/bin/kasbah remote lock /apps exclusive server init": "server init",
		"/apps/.kasbah/bin/kasbah remote prune rm /apps a:1":               "server prune",
		"/apps/.kasbah/bin/kasbah remote destroy act /apps":                "server destroy",
		"/apps/.kasbah/bin/kasbah remote deploy run /apps/x":               "a deploy or rollback",
		"/apps/.kasbah/bin/kasbah remote deploy images 1.0":                "kasbah remote deploy",
		"/apps/.kasbah/bin/kasbah remote deploy backup /apps/x":            "kasbah backup",
		"/apps/.kasbah/bin/kasbah remote setup-env set /apps/x K":          "env set",
		"/apps/.kasbah/bin/kasbah remote setup-env setup /apps/x":          "kasbah env",
		"/apps/.kasbah/bin/kasbah remote setup-env seed /apps/x 0123":      "the --env-seed staging of kasbah env, a deploy or a rollback",
		"/apps/.kasbah/bin/kasbah remote drop act /apps x":                 "drop",
	} {
		w := strings.Fields(argv)
		if argv == "/apps/.kasbah/bin/kasbah remote lock /apps exclusive server init" {
			w = []string{"/apps/.kasbah/bin/kasbah", "remote", "lock", "/apps", "exclusive", "server init"}
		}
		if got := describe(w); got != want {
			t.Errorf("describe(%q) = %q, want %q", argv, got, want)
		}
	}
}

func TestWhoAndEnsureMode(t *testing.T) {
	if w := Who(); !safeName(w) && !strings.HasPrefix(w, "uid=") {
		t.Errorf("Who = %q", w)
	}
	for _, bad := range []string{"", "a b", "a=b", "a\tb", "a\x01"} {
		if safeName(bad) {
			t.Errorf("%q passed as a versions.log token", bad)
		}
	}
	p := t.TempDir() + "/f"
	os.WriteFile(p, nil, 0o644)
	if err := EnsureMode(p, 0o600); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(p); fi.Mode().Perm() != 0o600 {
		t.Errorf("mode %o", fi.Mode().Perm())
	}
	if err := EnsureMode(p, 0o600); err != nil {
		t.Errorf("a file already at the mode: %v", err)
	}
	d := t.TempDir() + "/d"
	os.Mkdir(d, 0o700)
	os.Chmod(d, 0o700|os.ModeSetgid)
	if err := EnsureMode(d, 0o700); err != nil {
		t.Fatal(err)
	}
	if fi, _ := os.Stat(d); fi.Mode()&os.ModeSetgid != 0 {
		t.Error("a setgid directory kept its setgid bit under EnsureMode 0700")
	}
}

func TestPrivate(t *testing.T) {
	p := t.TempDir() + "/env"
	if Foreign(p) != "" {
		t.Error("an absent file has an owner")
	}
	os.WriteFile(p, nil, 0o600)
	if Foreign(p) != "" {
		t.Error("this user's own file reads as another's")
	}
	err := PrivateRefusal("--with-backup", "alice", "/apps/.kasbah/backup")
	if !strings.Contains(err.Error(), "--with-backup on this server is alice's to change — run it as alice") {
		t.Errorf("refusal: %v", err)
	}
}
