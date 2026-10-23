package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

// distOf is a dist/ whose kasbah answers --version as ver.
func distOf(t *testing.T, ver string) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "dist")
	files := map[string]string{
		"kasbah":                    "#!/bin/sh\necho 'kasbah " + ver + " (schema 1)'\n",
		"server/kasbah-linux-amd64": "amd64\n",
		"server/kasbah-linux-arm64": "arm64\n",
	}
	for name, body := range files {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestInstallDir(t *testing.T) {
	prefix := t.TempDir()
	lib, binDir := filepath.Join(prefix, "lib"), filepath.Join(prefix, "bin")
	getenv := func(k string) string {
		return map[string]string{"KASBAH_LIB_DIR": lib, "KASBAH_BIN_DIR": binDir}[k]
	}
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	// The exe is not the build installed: DIR's kasbah names the version.
	exe := filepath.Join(distOf(t, "0.0.1-dev.1.1700000000+gaaaaaaa"), "kasbah")

	// A release beside a dev build: the dev build stays.
	dev := "1.0.1-dev.5.1800000000+gbbbbbbb"
	if err := installFrom(out, []string{distOf(t, dev)}, exe, getenv); err != nil {
		t.Fatalf("installing a dev build: %v\n%s", err, buf.String())
	}
	if err := installFrom(out, []string{distOf(t, "1.0.0")}, exe, getenv); err != nil {
		t.Fatalf("installing a release: %v\n%s", err, buf.String())
	}
	for _, f := range []string{"1.0.0/kasbah", "1.0.0/server/kasbah-linux-amd64", "1.0.0/server/kasbah-linux-arm64", dev + "/kasbah"} {
		if _, err := os.Stat(filepath.Join(lib, f)); err != nil {
			t.Errorf("%s: %v", f, err)
		}
	}
	if strings.Contains(buf.String(), "removed:") {
		t.Errorf("a release install removed a dev build:\n%s", buf.String())
	}
	// A relative DIR is the caller's.
	rel := distOf(t, "1.0.2")
	wd, _ := os.Getwd()
	defer os.Chdir(wd)
	if err := os.Chdir(filepath.Dir(rel)); err != nil {
		t.Fatal(err)
	}
	if err := installFrom(out, []string{"dist"}, exe, getenv); err != nil {
		t.Fatalf("a relative DIR: %v", err)
	}
	if _, err := os.Stat(filepath.Join(lib, "1.0.2", "kasbah")); err != nil {
		t.Errorf("a relative DIR: %v", err)
	}
}

// --pin points <bin>/kasbah at the build installed, even beside a newer one;
// without it the symlink goes to the newest that runs.
func TestInstallDirPin(t *testing.T) {
	prefix := t.TempDir()
	lib, binDir := filepath.Join(prefix, "lib"), filepath.Join(prefix, "bin")
	getenv := func(k string) string {
		return map[string]string{"KASBAH_LIB_DIR": lib, "KASBAH_BIN_DIR": binDir}[k]
	}
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	exe := filepath.Join(distOf(t, "0.0.1-dev.1.1700000000+gaaaaaaa"), "kasbah")
	link := filepath.Join(binDir, "kasbah")
	points := func(ver string) {
		t.Helper()
		got, err := os.Readlink(link)
		if want := filepath.Join(lib, ver, "kasbah"); err != nil || got != want {
			t.Errorf("<bin>/kasbah -> %q (%v), want %q\n%s", got, err, want, buf.String())
		}
	}
	dev := "1.0.1-dev.5.1800000000+gbbbbbbb"
	steps := []struct {
		args []string
		ver  string
		to   string
	}{
		{nil, dev, dev},
		{nil, "1.0.0", dev},                   // the newest stays
		{[]string{"--pin"}, "1.0.0", "1.0.0"}, // the build named
		{nil, "0.9.0", dev},
		{[]string{"--pin"}, dev, dev},
		{[]string{"--pin"}, "1.1.0-rc.1", "1.1.0-rc.1"},
	}
	for _, s := range steps {
		if err := installFrom(out, append(s.args, distOf(t, s.ver)), exe, getenv); err != nil {
			t.Fatalf("%v %s: %v\n%s", s.args, s.ver, err, buf.String())
		}
		points(s.to)
	}
	if _, err := os.Stat(filepath.Join(lib, dev)); err != nil {
		t.Errorf("a pinned release install removed the dev build: %v", err)
	}
}

func TestInstallDirRefusals(t *testing.T) {
	prefix := t.TempDir()
	lib, binDir := filepath.Join(prefix, "lib"), filepath.Join(prefix, "bin")
	exe := filepath.Join(distOf(t, "1.0.0"), "kasbah")
	broken := distOf(t, "1.0.0")
	os.WriteFile(filepath.Join(broken, "kasbah"), []byte("#!/bin/sh\nexit 3\n"), 0o755)
	stranger := distOf(t, "1.0.0")
	os.WriteFile(filepath.Join(stranger, "kasbah"), []byte("#!/bin/sh\necho hello 1.0.0\n"), 0o755)
	noArm := distOf(t, "1.0.0")
	os.Remove(filepath.Join(noArm, "server", "kasbah-linux-arm64"))
	unstamped := distOf(t, "dev")
	own := distOf(t, "1.0.0")

	tests := []struct {
		name string
		args []string
		lib  string
		want string
	}{
		{"two arguments", []string{"a", "b"}, lib, "usage: kasbah __install [--pin] [DIR]"},
		{"a flag", []string{"--yes"}, lib, "usage: kasbah __install [--pin] [DIR]"},
		{"--pin after DIR", []string{"dist", "--pin"}, lib, "usage: kasbah __install [--pin] [DIR]"},
		{"--pin twice", []string{"--pin", "--pin"}, lib, "usage: kasbah __install [--pin] [DIR]"},
		{"no kasbah in DIR", []string{t.TempDir()}, lib, "is missing"},
		{"a kasbah that does not run", []string{broken}, lib, "does not run here"},
		{"a binary that is not kasbah", []string{stranger}, lib, "does not run here"},
		{"a missing server binary", []string{noArm}, lib, "kasbah-linux-arm64 is missing"},
		{"no build stamp", []string{unstamped}, lib, "carries no build stamp"},
		{"the library is DIR", []string{own}, own, "this build's own"},
	}
	for _, tt := range tests {
		var buf bytes.Buffer
		out := &cli.Output{Stdout: &buf, Stderr: &buf}
		env := func(k string) string {
			return map[string]string{"KASBAH_LIB_DIR": tt.lib, "KASBAH_BIN_DIR": binDir}[k]
		}
		err := installFrom(out, tt.args, exe, env)
		if err == nil || !strings.Contains(err.Error(), tt.want) {
			t.Errorf("%s: got %v, want %q", tt.name, err, tt.want)
		}
	}
	if _, err := os.Stat(lib); !os.IsNotExist(err) {
		t.Errorf("a refusal wrote the library: %v", err)
	}
	if _, err := os.Stat(binDir); !os.IsNotExist(err) {
		t.Errorf("a refusal wrote <bin>: %v", err)
	}
}

func TestPickTag(t *testing.T) {
	tags := "v0.9.0\nv1.0.0\nv1.0.1\nv1.1.0-rc.1\nnot-a-version\n"
	tests := []struct {
		args    []string
		want    string
		wantErr []string
	}{
		{args: []string{"v1"}, want: "v1.0.1\n"},
		{args: []string{"v1", "--pre"}, want: "v1.1.0-rc.1\n"},
		{args: []string{"--pre", "1.0"}, want: "v1.0.1\n"},
		{args: []string{"v1.0.0"}, want: "v1.0.0\n"},
		{args: []string{"v1.1.0-rc.1"}, want: "v1.1.0-rc.1\n"},
		{args: []string{"v1.1"}, wantErr: []string{"no local tag matches v1.1", "1 pre-release tag(s) were skipped", "git fetch --tags"}},
		{args: []string{"v2"}, wantErr: []string{"no local tag matches v2", "git fetch --tags"}},
		{args: []string{"v2.x"}, wantErr: []string{"'v2.x' is not a version"}},
		{args: nil, wantErr: []string{"usage: kasbah __pick-tag"}},
		{args: []string{"--pre"}, wantErr: []string{"usage: kasbah __pick-tag"}},
		{args: []string{"v1", "v2"}, wantErr: []string{"usage: kasbah __pick-tag"}},
		{args: []string{"v1", "--yes"}, wantErr: []string{"usage: kasbah __pick-tag"}},
	}
	for _, tt := range tests {
		var buf bytes.Buffer
		out := &cli.Output{Stdout: &buf, Stderr: &buf}
		err := pickTagCmd(out, tt.args, strings.NewReader(tags))
		if tt.wantErr == nil {
			if err != nil || buf.String() != tt.want {
				t.Errorf("%q: got %q, %v; want %q", tt.args, buf.String(), err, tt.want)
			}
			continue
		}
		if err == nil {
			t.Errorf("%q: printed %q, want a refusal", tt.args, buf.String())
			continue
		}
		for _, w := range tt.wantErr {
			if !strings.Contains(err.Error(), w) {
				t.Errorf("%q: %q does not name %q", tt.args, err.Error(), w)
			}
		}
	}
}
