package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// The binary itself: a file or stdin in, one line per document out, and a
// stream that does not read is exit 1 with nothing on stdout.
func TestCLI(t *testing.T) {
	dir := t.TempDir()
	bin := filepath.Join(dir, "yaml2json")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	run := func(stdin string, args ...string) (string, string, int) {
		cmd := exec.Command(bin, args...)
		cmd.Stdin = strings.NewReader(stdin)
		var out, errb bytes.Buffer
		cmd.Stdout, cmd.Stderr = &out, &errb
		cmd.Run()
		return out.String(), errb.String(), cmd.ProcessState.ExitCode()
	}

	f := filepath.Join(dir, "f.yml")
	if err := os.WriteFile(f, []byte("z: 1\na: \"<&>\"\n---\n- 2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	want := "{\"z\":1,\"a\":\"<&>\"}\n[2]\n"
	if out, _, rc := run("", f); rc != 0 || out != want {
		t.Errorf("file: rc %d, %q", rc, out)
	}
	if out, _, rc := run("z: 1\na: \"<&>\"\n---\n- 2\n", "-"); rc != 0 || out != want {
		t.Errorf("stdin: rc %d, %q", rc, out)
	}
	if out, _, rc := run(""); rc != 0 || out != "" {
		t.Errorf("empty stdin: rc %d, %q", rc, out)
	}
	if out, errs, rc := run("a: 1\n---\nb:\n\tc: 2\n"); rc != 1 || out != "" || !strings.HasPrefix(errs, "yaml2json: ") {
		t.Errorf("a broken second document: rc %d, out %q, err %q", rc, out, errs)
	}
	if _, errs, rc := run("", filepath.Join(dir, "absent.yml")); rc != 1 || errs == "" {
		t.Errorf("a missing file: rc %d, err %q", rc, errs)
	}
	if _, _, rc := run("", "a", "b"); rc != 2 {
		t.Errorf("two arguments: rc %d", rc)
	}
}
