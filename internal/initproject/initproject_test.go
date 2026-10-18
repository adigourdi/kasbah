package initproject

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
)

func output() (*cli.Output, *bytes.Buffer, *bytes.Buffer) {
	var o, e bytes.Buffer
	return &cli.Output{Stdout: &o, Stderr: &e}, &o, &e
}

func read(t *testing.T, p string) string {
	t.Helper()
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestScaffold(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "my-app")
	if err := os.Mkdir(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)
	old := syscall.Umask(0o027)
	defer syscall.Umask(old)
	os.WriteFile(".gitignore", []byte("node_modules\n.env"), 0o600)

	out, stdout, stderr := output()
	if err := Run(out, Options{}, dir, "1.2.3"); err != nil {
		t.Fatal(err)
	}
	if got, want := read(t, "kasbah.yml"), string(manifest.Render("my-app", "", "1.2.3")); got != want {
		t.Errorf("kasbah.yml = %q, want %q", got, want)
	}
	if got := read(t, ".env.prod.example"); got != Template {
		t.Errorf(".env.prod.example = %q", got)
	}
	if got := read(t, ".kasbah/state.json"); !strings.Contains(got, `"kasbah_version": "1.2.3"`) {
		t.Errorf("state.json = %q", got)
	}
	if got, want := read(t, ".gitignore"), "node_modules\n.env\n.kasbah/\n"; got != want {
		t.Errorf(".gitignore = %q, want %q", got, want)
	}
	for p, want := range map[string]os.FileMode{"kasbah.yml": 0o640, ".env.prod.example": 0o640, ".kasbah": 0o750 | os.ModeDir, ".gitignore": 0o600} {
		if fi, err := os.Stat(p); err != nil || fi.Mode() != want {
			t.Errorf("%s: mode %v, want %v (%v)", p, fi.Mode(), want, err)
		}
	}
	if !strings.Contains(stderr.String(), "Initialized kasbah project 'my-app'") ||
		!strings.Contains(stderr.String(), "warning: domain is empty") {
		t.Errorf("stderr = %q", stderr.String())
	}
	if !strings.HasPrefix(stdout.String(), "\nNext step:") || !strings.Contains(stdout.String(), "Host(`<your-domain>`)") {
		t.Errorf("stdout = %q", stdout.String())
	}

	err := Run(out, Options{Name: "other"}, dir, "1.2.3")
	if err == nil || !strings.Contains(err.Error(), "kasbah.yml already exists — refusing to overwrite") {
		t.Errorf("second run: %v", err)
	}
}

func TestRefusals(t *testing.T) {
	t.Chdir(t.TempDir())
	out, _, _ := output()
	for _, tc := range []struct {
		o    Options
		pwd  string
		want string
	}{
		{Options{NameGiven: true}, "/x/demo", "--name=<name> must not be empty"},
		{Options{}, "/x/My_App", "invalid project name 'My_App'"},
		{Options{}, "/", "invalid project name '/'"},
		{Options{}, "/x/data", "project name 'data' is reserved"},
		{Options{Domain: "nodot", DomainGiven: true}, "/x/demo", "invalid domain 'nodot'"},
		{Options{DomainGiven: true}, "/x/demo", "invalid domain ''"},
	} {
		err := Run(out, tc.o, tc.pwd, "1")
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%+v in %s: %v, want %q", tc.o, tc.pwd, err, tc.want)
		}
	}
	if ents, _ := os.ReadDir("."); len(ents) != 0 {
		t.Errorf("a refusal wrote %d files", len(ents))
	}
}

func TestFailureLeavesNothing(t *testing.T) {
	t.Chdir(t.TempDir())
	os.WriteFile(".kasbah", []byte("a file"), 0o644)
	os.WriteFile(".gitignore", []byte("keep\n"), 0o644)
	out, _, _ := output()
	if err := Run(out, Options{Name: "demo"}, "/x", "1"); err == nil {
		t.Fatal("scaffolded over a .kasbah file")
	}
	for _, p := range []string{"kasbah.yml", ".env.prod.example"} {
		if _, err := os.Stat(p); err == nil {
			t.Errorf("%s left behind", p)
		}
	}
	if got := read(t, ".gitignore"); got != "keep\n" {
		t.Errorf(".gitignore = %q", got)
	}
	if fi, err := os.Stat(".kasbah"); err != nil || fi.IsDir() {
		t.Errorf("the .kasbah file that was there: %v, %v", fi, err)
	}
}

func TestParse(t *testing.T) {
	o, err := Parse([]string{"--name=a", "--domain=b.c"})
	if err != nil || o.Name != "a" || o.Domain != "b.c" || !o.NameGiven || !o.DomainGiven {
		t.Errorf("Parse = %+v, %v", o, err)
	}
	if _, err := Parse([]string{"--name=a", "--help", "--bogus"}); !errors.Is(err, ErrHelp) {
		t.Errorf("--help before an unknown flag: %v", err)
	}
	if _, err := Parse([]string{"--bogus", "--help"}); err == nil || errors.Is(err, ErrHelp) {
		t.Errorf("an unknown flag before --help: %v", err)
	}
	for d, ok := range map[string]bool{"a.b": true, "app.co.uk": true, "x-1.example.com": true, "a": false, "-a.com": false, "a-.com": false, "a.c0m": false, "a..b": false} {
		if IsFQDN(d) != ok {
			t.Errorf("IsFQDN(%q) != %v", d, ok)
		}
	}
}

// A .gitignore this run cannot read or append to is the user's: the failure
// leaves it exactly as it was, whatever kind of file it is.
func TestFailureKeepsAnUnusableGitignore(t *testing.T) {
	for name, prep := range map[string]func() error{
		"unreadable": func() error { return os.WriteFile(".gitignore", []byte("secret\n"), 0o000) },
		"directory":  func() error { return os.Mkdir(".gitignore", 0o755) },
	} {
		t.Run(name, func(t *testing.T) {
			t.Chdir(t.TempDir())
			if err := prep(); err != nil {
				t.Fatal(err)
			}
			before, _ := os.Lstat(".gitignore")
			out, _, _ := output()
			if err := Run(out, Options{Name: "demo"}, "/x", "1"); err == nil {
				t.Fatal("scaffolded past an unusable .gitignore")
			}
			after, err := os.Lstat(".gitignore")
			if err != nil || after.Mode() != before.Mode() {
				t.Fatalf(".gitignore after the failure: %v, %v (was %v)", after, err, before.Mode())
			}
			ents, _ := os.ReadDir(".")
			if len(ents) != 1 {
				t.Errorf("left %d entries behind, want only .gitignore", len(ents))
			}
		})
	}
}

// GNU grep ends a line at a NUL in a binary file, so `.env` after one counts.
func TestGitignoreNUL(t *testing.T) {
	t.Chdir(t.TempDir())
	os.WriteFile(".gitignore", []byte("bin\x00.env\n"), 0o644)
	out, _, _ := output()
	if err := Run(out, Options{Name: "demo"}, "/x", "1"); err != nil {
		t.Fatal(err)
	}
	if got := read(t, ".gitignore"); got != "bin\x00.env\n.kasbah/\n" {
		t.Errorf(".gitignore = %q", got)
	}
}
