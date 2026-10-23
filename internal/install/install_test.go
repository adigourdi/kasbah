package install

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

// fakeTTY is a prompter answering from a string, as a terminal would.
func fakeTTY(answer string, out *cli.Output) *prompt.Prompter {
	return &prompt.Prompter{In: strings.NewReader(answer), Out: out, TTY: answer != ""}
}

func script(ver string) []byte { return []byte("#!/bin/sh\necho 'kasbah " + ver + " (schema 1)'\n") }

func write(t *testing.T, path string, body []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, body, 0o755); err != nil {
		t.Fatal(err)
	}
}

// dist is a checkout's dist/ holding a build of ver.
func dist(t *testing.T, ver string) string {
	dir := filepath.Join(t.TempDir(), "dist")
	write(t, filepath.Join(dir, "kasbah"), script(ver))
	for _, arch := range []string{"amd64", "arm64"} {
		write(t, filepath.Join(dir, "server", "kasbah-linux-"+arch), []byte("server "+arch+"\n"))
	}
	return dir
}

// plantVer is an installed version directory of ver whose kasbah runs.
func plantVer(t *testing.T, lib, ver string) string {
	dir := filepath.Join(lib, ver)
	write(t, filepath.Join(dir, "kasbah"), script(ver))
	write(t, filepath.Join(dir, "server", "kasbah-linux-amd64"), []byte("server\n"))
	return dir
}

func target(lib, binDir string, buf *bytes.Buffer) Target {
	out := &cli.Output{Stdout: buf, Stderr: buf}
	return Target{Lib: lib, BinDir: binDir, Out: out, Prompter: fakeTTY("", out), Yes: true, RunTimeout: 5 * time.Second}
}

func listing(t *testing.T, root string) []string {
	var got []string
	filepath.Walk(root, func(p string, _ os.FileInfo, err error) error {
		if err == nil && p != root {
			rel, _ := filepath.Rel(root, p)
			got = append(got, rel)
		}
		return nil
	})
	return got
}

func TestInstall(t *testing.T) {
	const dev = "1.1.0-dev.5.1792460280+gabc1234"
	src := dist(t, dev)
	tmp := t.TempDir()
	lib, binDir := filepath.Join(tmp, "lib"), filepath.Join(tmp, "bin")
	link := filepath.Join(binDir, "kasbah")
	var buf bytes.Buffer
	b, err := Dist(src, dev)
	if err != nil {
		t.Fatal(err)
	}
	if err := Install(target(lib, binDir, &buf), b); err != nil {
		t.Fatalf("install: %v\n%s", err, &buf)
	}
	want := []string{dev, dev + "/kasbah", dev + "/server", dev + "/server/kasbah-linux-amd64", dev + "/server/kasbah-linux-arm64"}
	if got := listing(t, lib); strings.Join(got, " ") != strings.Join(want, " ") {
		t.Errorf("library holds %v, want %v", got, want)
	}
	for _, f := range []string{"kasbah", "server/kasbah-linux-amd64", "server/kasbah-linux-arm64"} {
		a, _ := os.ReadFile(filepath.Join(src, f))
		c, _ := os.ReadFile(filepath.Join(lib, dev, f))
		if !bytes.Equal(a, c) {
			t.Errorf("%s is not the build's bytes", f)
		}
	}
	if got, _ := os.Readlink(link); got != filepath.Join(lib, dev, "kasbah") {
		t.Errorf("symlink -> %s", got)
	}
	for _, w := range []string{"installed kasbah " + dev, "  lib: " + filepath.Join(lib, dev), "  bin: " + link + " -> " + filepath.Join(lib, dev, "kasbah")} {
		if !strings.Contains(buf.String(), w) {
			t.Errorf("output lacks %q:\n%s", w, &buf)
		}
	}

	// Other dev builds go, older and newer, the one the symlink pointed at
	// included; releases stay, and the symlink moves to the newest that runs.
	for _, v := range []string{"1.0.1-dev.3.1792000000+gdef5678", "1.2.0-dev.9.1793000000+g1234567.dirty", "1.0.0", "1.0.0-rc.1"} {
		plantVer(t, lib, v)
	}
	os.Remove(link)
	os.Symlink(filepath.Join(lib, "1.2.0-dev.9.1793000000+g1234567.dirty", "kasbah"), link)
	buf.Reset()
	if err := Install(target(lib, binDir, &buf), b); err != nil {
		t.Fatalf("reinstall: %v\n%s", err, &buf)
	}
	var dirs []string
	ents, _ := os.ReadDir(lib)
	for _, e := range ents {
		dirs = append(dirs, e.Name())
	}
	if got := strings.Join(dirs, " "); got != "1.0.0 1.0.0-rc.1 "+dev {
		t.Errorf("after a dev install the library holds %s", got)
	}
	if got, _ := os.Readlink(link); got != filepath.Join(lib, dev, "kasbah") {
		t.Errorf("symlink -> %s, want this build", got)
	}
	if !strings.Contains(buf.String(), "removed: "+filepath.Join(lib, "1.0.1-dev.3.1792000000+gdef5678")) {
		t.Errorf("the removal is not reported:\n%s", &buf)
	}

	// A release install removes no dev build.
	rel, err := Dist(dist(t, "1.1.0"), "1.1.0")
	if err != nil {
		t.Fatal(err)
	}
	buf.Reset()
	if err := Install(target(lib, binDir, &buf), rel); err != nil {
		t.Fatalf("release: %v\n%s", err, &buf)
	}
	if _, err := os.Stat(filepath.Join(lib, dev, "kasbah")); err != nil {
		t.Error("a release install removed the dev build")
	}
	if got, _ := os.Readlink(link); got != filepath.Join(lib, "1.1.0", "kasbah") {
		t.Errorf("symlink -> %s, want the newest, 1.1.0", got)
	}
}

func TestInstallRefusals(t *testing.T) {
	const ver = "1.1.0-dev.5.1792460280+gabc1234"
	tmp := t.TempDir()
	var buf bytes.Buffer
	src := dist(t, ver)
	b, err := Dist(src, ver)
	if err != nil {
		t.Fatal(err)
	}
	untouched := func(dir string, before []string) {
		t.Helper()
		if got := listing(t, dir); strings.Join(got, " ") != strings.Join(before, " ") {
			t.Errorf("%s changed: %v, was %v", dir, got, before)
		}
	}

	// Somebody else's directory, a file.
	foreign := filepath.Join(tmp, "foreign")
	write(t, filepath.Join(foreign, "notes.txt"), []byte("mine\n"))
	write(t, filepath.Join(foreign, "v1.0.0", "kasbah"), []byte("mine\n"))
	write(t, filepath.Join(tmp, "file"), []byte("mine\n"))
	for _, lib := range []string{foreign, filepath.Join(tmp, "file")} {
		before := listing(t, foreign)
		if err := Install(target(lib, filepath.Join(tmp, "fbin"), &buf), b); err == nil || !strings.Contains(err.Error(), "KASBAH_LIB_DIR") {
			t.Errorf("%s: %v", lib, err)
		}
		untouched(foreign, before)
	}
	// This build's own dist/.
	before := listing(t, src)
	if err := Install(target(src, filepath.Join(tmp, "dbin"), &buf), b); err == nil || !strings.Contains(err.Error(), "this build's own") {
		t.Errorf("dist/: %v", err)
	}
	untouched(src, before)
	// Neither a symlink nor a file at <bin>/kasbah: nothing written.
	lib := filepath.Join(tmp, "lib")
	os.MkdirAll(filepath.Join(tmp, "xbin", "kasbah"), 0o755)
	if err := Install(target(lib, filepath.Join(tmp, "xbin"), &buf), b); err == nil || !strings.Contains(err.Error(), "refusing to replace") {
		t.Errorf("a directory at <bin>/kasbah: %v", err)
	}
	if _, err := os.Stat(lib); err == nil {
		t.Error("the refused install wrote the library")
	}
	// A <bin> that cannot be written: refused before the library is.
	if os.Geteuid() != 0 {
		ro := filepath.Join(tmp, "robin")
		os.MkdirAll(ro, 0o555)
		if err := Install(target(lib, ro, &buf), b); err == nil || !strings.Contains(err.Error(), "cannot write "+ro+"/kasbah") {
			t.Errorf("read-only <bin>: %v", err)
		}
		if _, err := os.Stat(lib); err == nil {
			t.Error("a read-only <bin> still let the library be written")
		}
	}
	// A dist/ missing a server binary, or a build without a stamp.
	os.Remove(filepath.Join(src, "server", "kasbah-linux-arm64"))
	if _, err := Dist(src, ver); err == nil || !strings.Contains(err.Error(), "dist/server/kasbah-linux-arm64 is missing") {
		t.Errorf("missing arm64: %v", err)
	}
	if _, err := Dist(src, ""); err == nil || !strings.Contains(err.Error(), "no build stamp") {
		t.Errorf("unstamped: %v", err)
	}
	// A binary that does not report its version: placed for a look, the
	// symlink left where it was, no other dev build removed.
	good := plantVer(t, lib, "1.0.1-dev.3.1792000000+gdef5678")
	link := filepath.Join(tmp, "bin", "kasbah")
	os.MkdirAll(filepath.Join(tmp, "bin"), 0o755)
	os.Symlink(filepath.Join(good, "kasbah"), link)
	liar := Build{Version: ver, Bin: func(p string) error { return os.WriteFile(p, script("9.9.9"), 0o755) }}
	if err := Install(target(lib, filepath.Join(tmp, "bin"), &buf), liar); err == nil || !strings.Contains(err.Error(), "does not report kasbah "+ver) {
		t.Errorf("liar: %v", err)
	}
	if got, _ := os.Readlink(link); got != filepath.Join(good, "kasbah") {
		t.Errorf("liar moved the symlink -> %s", got)
	}
	if _, err := os.Stat(good); err != nil {
		t.Error("a failed install removed another dev build")
	}
	if left, _ := filepath.Glob(filepath.Join(lib, ver, ".*")); len(left) != 0 {
		t.Errorf("staging files left: %v", left)
	}
}

func TestBinDirAndPathNote(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	if d, err := BinDir(env(map[string]string{"KASBAH_BIN_DIR": "/b", "HOME": "/h"})); err != nil || d != "/b" {
		t.Errorf("KASBAH_BIN_DIR: %q, %v", d, err)
	}
	if d, err := BinDir(env(map[string]string{"HOME": "/h"})); err != nil || d != "/h/.local/bin" {
		t.Errorf("HOME: %q, %v", d, err)
	}
	if _, err := BinDir(env(nil)); err == nil || !strings.Contains(err.Error(), "nor HOME") {
		t.Errorf("nothing set: %v", err)
	}
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	PathNote(out, "/h/.local/bin", "/usr/bin:/h/.local/bin")
	if buf.Len() != 0 {
		t.Errorf("in PATH, still noted: %s", &buf)
	}
	PathNote(out, "/h/.local/bin", "/usr/bin")
	if !strings.Contains(buf.String(), "/h/.local/bin is not in PATH") {
		t.Errorf("not in PATH, not noted: %q", &buf)
	}
}

func TestRepoint(t *testing.T) {
	root, binDir := t.TempDir(), t.TempDir()
	plant := func(ver, script string) {
		os.MkdirAll(filepath.Join(root, ver), 0o755)
		os.WriteFile(filepath.Join(root, ver, "kasbah"), []byte(script), 0o755)
	}
	plant("1.2.0", "#!/bin/sh\necho kasbah 1.2.0\n")
	plant("1.3.0", "#!/bin/sh\nexit 1\n")
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	link := filepath.Join(binDir, "kasbah")
	// A 1.0.x regular file there: replaced, its version read by running it.
	os.WriteFile(link, []byte("#!/bin/sh\necho kasbah 0.9.0\n"), 0o755)
	if _, err := Repoint(root, binDir, "", fakeTTY("", out), false, 5*time.Second); err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Errorf("regular file of another major without a tty: %v", err)
	}
	got, err := Repoint(root, binDir, "", fakeTTY("y\n", out), false, 5*time.Second)
	if err != nil || got != filepath.Join(root, "1.2.0", "kasbah") {
		t.Fatalf("repoint: %s, %v", got, err)
	}
	if target, _ := os.Readlink(link); target != got {
		t.Errorf("symlink -> %s", target)
	}
	// Same major: no question even without a tty.
	plant("1.4.0", "#!/bin/sh\necho kasbah 1.4.0\n")
	if got, err := Repoint(root, binDir, "", fakeTTY("", out), false, 5*time.Second); err != nil || !strings.HasSuffix(got, "/1.4.0/kasbah") {
		t.Errorf("same major: %s, %v", got, err)
	}
	// A version named: that one, even with a newer installed; one that does not
	// run, or is not there, is refused by name.
	if got, err := Repoint(root, binDir, "1.2.0", fakeTTY("", out), false, 5*time.Second); err != nil || !strings.HasSuffix(got, "/1.2.0/kasbah") {
		t.Errorf("pinned to 1.2.0: %s, %v", got, err)
	}
	if target, _ := os.Readlink(link); !strings.HasSuffix(target, "/1.2.0/kasbah") {
		t.Errorf("pinned: symlink -> %s", target)
	}
	for _, pin := range []string{"1.3.0", "1.5.0"} {
		if _, err := Repoint(root, binDir, pin, fakeTTY("", out), false, 5*time.Second); err == nil || !strings.Contains(err.Error(), "no kasbah "+pin+" runs") {
			t.Errorf("pinned to %s: %v", pin, err)
		}
	}
	// Something else there is refused.
	os.Remove(link)
	os.Mkdir(link, 0o755)
	if _, err := Repoint(root, binDir, "", fakeTTY("", out), true, 5*time.Second); err == nil || !strings.Contains(err.Error(), "refusing to replace") {
		t.Errorf("a directory: %v", err)
	}
	// Nothing runs.
	if _, err := Repoint(t.TempDir(), t.TempDir(), "", fakeTTY("", out), true, 5*time.Second); err == nil || !strings.Contains(err.Error(), "no installed kasbah runs") {
		t.Errorf("empty: %v", err)
	}
}

// An interrupted install — an empty or partial version directory — is
// kasbah's library still, and a rerun completes it.
func TestInstallAfterInterrupt(t *testing.T) {
	const ver = "1.1.0-dev.5.1792460280+gabc1234"
	tmp := t.TempDir()
	lib, binDir := filepath.Join(tmp, "lib"), filepath.Join(tmp, "bin")
	os.MkdirAll(filepath.Join(lib, ver), 0o755)
	if err := CheckLib(lib); err != nil {
		t.Errorf("an empty version directory: %v", err)
	}
	write(t, filepath.Join(lib, ver, ".kasbah.new"), []byte("half"))
	b, err := Dist(dist(t, ver), ver)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	if err := Install(target(lib, binDir, &buf), b); err != nil {
		t.Fatalf("rerun: %v\n%s", err, &buf)
	}
	if got, _ := os.Readlink(filepath.Join(binDir, "kasbah")); got != filepath.Join(lib, ver, "kasbah") {
		t.Errorf("symlink -> %s", got)
	}
}

// A repoint that fails leaves every other dev build, and the symlink resolving.
func TestInstallRepointFails(t *testing.T) {
	const ver = "1.1.0-dev.5.1792460280+gabc1234"
	tmp := t.TempDir()
	lib, binDir := filepath.Join(tmp, "lib"), filepath.Join(tmp, "bin")
	other := plantVer(t, lib, "2.0.1-dev.3.1792000000+gdef5678")
	link := filepath.Join(binDir, "kasbah")
	os.MkdirAll(binDir, 0o755)
	os.Symlink(filepath.Join(other, "kasbah"), link)
	b, err := Dist(dist(t, ver), ver)
	if err != nil {
		t.Fatal(err)
	}
	var buf bytes.Buffer
	tg := target(lib, binDir, &buf)
	tg.Yes = false // another major, no terminal: the question fails
	if err := Install(tg, b); err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Fatalf("install: %v\n%s", err, &buf)
	}
	if got, _ := os.Readlink(link); got != filepath.Join(other, "kasbah") {
		t.Errorf("symlink -> %s", got)
	}
	if !Reports(link, "2.0.1-dev.3.1792000000+gdef5678", 5*time.Second) {
		t.Error("the symlink no longer resolves to a kasbah that runs")
	}
	if strings.Contains(buf.String(), "removed:") {
		t.Errorf("a dev build was removed before the repoint:\n%s", &buf)
	}
}
