package launcher

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func plant(t *testing.T, root, ver string, perm os.FileMode) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, ver), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, ver, "kasbah"), []byte("#!/bin/sh\nexit 0\n"), perm); err != nil {
		t.Fatal(err)
	}
}

func TestRoot(t *testing.T) {
	tmp := t.TempDir()
	lib := filepath.Join(tmp, "lib")
	plant(t, lib, "1.0.2-dev.86.1792460280", 0o755)
	link := filepath.Join(tmp, "bin", "kasbah")
	os.MkdirAll(filepath.Dir(link), 0o755)
	if err := os.Symlink(filepath.Join(lib, "1.0.2-dev.86.1792460280", "kasbah"), link); err != nil {
		t.Fatal(err)
	}
	env := func(string) string { return "/env" }
	for _, exe := range []string{filepath.Join(lib, "1.0.2-dev.86.1792460280", "kasbah"), link} {
		if got, err := Root(exe, env); err != nil || got != lib {
			t.Errorf("Root(%s) = %q, %v; want the running binary's root %q", exe, got, err, lib)
		}
	}
	// EnvRoot never looks at the running binary: what an install from dist/ targets.
	if got, err := EnvRoot(env); err != nil || got != "/env" {
		t.Errorf("EnvRoot = %q, %v; want %q", got, err, "/env")
	}
	// Not in a version directory: a checkout's dist/, a 1.0.x bin/, a name
	// that is not kasbah's — the environment decides.
	for _, exe := range []string{"/repo/dist/kasbah", "/home/u/.local/bin/kasbah", filepath.Join(lib, "1.0.2-dev.86.1792460280", "other")} {
		if got, err := Root(exe, env); err != nil || got != "/env" {
			t.Errorf("Root(%s) = %q, %v; want the environment's %q", exe, got, err, "/env")
		}
	}
	for _, tt := range []struct {
		env  map[string]string
		want string
	}{
		{map[string]string{"KASBAH_LIB_DIR": "/lib", "XDG_DATA_HOME": "/xdg", "HOME": "/home/u"}, "/lib"},
		{map[string]string{"XDG_DATA_HOME": "/xdg", "HOME": "/home/u"}, "/xdg/kasbah"},
		{map[string]string{"HOME": "/home/u"}, "/home/u/.local/share/kasbah"},
	} {
		if got, err := Root("/repo/dist/kasbah", func(k string) string { return tt.env[k] }); err != nil || got != tt.want {
			t.Errorf("Root(%v) = %q, %v; want %q", tt.env, got, err, tt.want)
		}
	}
	if _, err := Root("/repo/dist/kasbah", func(string) string { return "" }); err == nil || !strings.Contains(err.Error(), "nor HOME") {
		t.Errorf("Root() with nothing set: %v", err)
	}
}

func TestInstalled(t *testing.T) {
	root := t.TempDir()
	for _, v := range []string{"1.0.0", "1.0.2-dev.86.1792460280", "1.0.2-dev.86.1792460290", "1.0.2-dev.90.1792460000", "2.0.0", "2.1.0-dev.3.1"} {
		plant(t, root, v, 0o755)
	}
	plant(t, root, "3.0.0", 0o644)                         // not executable
	plant(t, root, "notaversion", 0o755)                   // not a version directory
	os.MkdirAll(filepath.Join(root, "1.5.0"), 0o755)       // no kasbah in it
	os.WriteFile(filepath.Join(root, "1.6.0"), nil, 0o755) // a file, not a directory
	os.MkdirAll(filepath.Join(root, "server"), 0o755)

	var got []string
	for _, e := range Installed(root) {
		got = append(got, e.Version.String())
	}
	want := "2.1.0-dev.3.1 2.0.0 1.0.2-dev.90.1792460000 1.0.2-dev.86.1792460290 1.0.2-dev.86.1792460280 1.0.0"
	if strings.Join(got, " ") != want {
		t.Errorf("Installed = %v, want %s", got, want)
	}
	if Newest(root, 1) != filepath.Join(root, "1.0.2-dev.90.1792460000", "kasbah") {
		t.Errorf("Newest(1) = %q", Newest(root, 1))
	}
	if Newest(root, 2) != filepath.Join(root, "2.1.0-dev.3.1", "kasbah") {
		t.Errorf("Newest(2) = %q", Newest(root, 2))
	}
	if Newest(root, 3) != "" || Newest(root, 0) != "" {
		t.Error("Newest found a major that is not installed")
	}
	if Find(root, "1.0.2-dev.86.1792460280") != filepath.Join(root, "1.0.2-dev.86.1792460280", "kasbah") {
		t.Errorf("Find = %q", Find(root, "1.0.2-dev.86.1792460280"))
	}
	for _, v := range []string{"1.0.1", "1.5.0", "1.6.0", "3.0.0", "junk", ""} {
		if Find(root, v) != "" {
			t.Errorf("Find(%q) found %q", v, Find(root, v))
		}
	}
	if Installed(filepath.Join(root, "absent")) != nil {
		t.Error("an absent root lists something")
	}
	if !Runs(filepath.Join(root, "1.0.0", "kasbah"), time.Second) {
		t.Error("a binary exiting 0 on --version does not run")
	}
	os.WriteFile(filepath.Join(root, "2.0.0", "kasbah"), []byte("#!/bin/sh\nexit 3\n"), 0o755)
	if Runs(filepath.Join(root, "2.0.0", "kasbah"), time.Second) {
		t.Error("a binary failing --version runs")
	}
}
