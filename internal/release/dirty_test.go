package release

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
)

func TestPickBase(t *testing.T) {
	for _, tt := range []struct {
		tags []string
		want string
	}{
		{nil, "0.0.0"},
		{[]string{"v1.2.0", "v1.10.0", "v1.9.9"}, "1.10.0"},
		{[]string{"v1.2.0", "v1.3.0-rc.1"}, "1.3.0-rc.1"},
		{[]string{"v2.0.0+build.7\r"}, "2.0.0"},
		{[]string{"nightly", "v1.4"}, "0.0.0"},
		{[]string{"v1.0.0", "v9.0.0-dirty.20261028080507"}, "1.0.0"},
	} {
		if got := pickBase(tt.tags); got != tt.want {
			t.Errorf("pickBase(%q) = %q, want %q", tt.tags, got, tt.want)
		}
	}
}

func git(t *testing.T, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", args...)
	cmd.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

func newRepo(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	t.Chdir(t.TempDir())
	git(t, "init", "-q")
	os.WriteFile(".gitignore", []byte("ignored\n.kasbah/\n"), 0o644)
	os.WriteFile("a", []byte("a\n"), 0o644)
	git(t, "add", ".")
	git(t, "commit", "-qm", "one")
}

// objects counts the loose objects: a fingerprint writes none.
func objects(t *testing.T) string {
	t.Helper()
	return git(t, "count-objects")
}

func TestCleanAndDirty(t *testing.T) {
	newRepo(t)
	git(t, "tag", "v1.2.0")
	os.WriteFile("ignored", []byte("x"), 0o644)
	os.MkdirAll(".kasbah", 0o755)
	os.WriteFile(".kasbah/state.json", []byte("{}\n"), 0o644)
	if err := RequireClean("deploy", "1.2.0", "kasbah deploy --dirty"); err != nil {
		t.Fatalf("ignored files and .kasbah/ made the tree dirty: %v", err)
	}
	before := objects(t)
	clean, err := Fingerprint("deploy")
	if err != nil || len(clean) != 64 {
		t.Fatalf("Fingerprint of a clean tree = %q, %v", clean, err)
	}

	os.WriteFile("new", []byte("n\n"), 0o644)
	err = RequireClean("deploy", "1.2.0", "kasbah deploy --dirty")
	e, ok := err.(*cli.Error)
	if !ok || !strings.Contains(e.Error(), "?? new") || !strings.Contains(e.Error(), "kasbah deploy --dirty") {
		t.Fatalf("an untracked file: %v", err)
	}
	withNew, _ := Fingerprint("deploy")
	if withNew == clean {
		t.Errorf("an untracked file did not change the fingerprint")
	}
	os.Remove("new")
	if back, _ := Fingerprint("deploy"); back != clean {
		t.Errorf("removing the untracked file did not restore the fingerprint")
	}
	os.WriteFile("a", []byte("changed\n"), 0o644)
	if err := RequireClean("build-push", "1.2.0", "x"); err == nil || !strings.Contains(err.Error(), " M a") {
		t.Errorf("a tracked change: %v", err)
	}
	changed, _ := Fingerprint("deploy")
	if changed == clean || changed == withNew {
		t.Errorf("a tracked change did not change the fingerprint")
	}
	os.WriteFile("a", []byte("changed again\n"), 0o644)
	if again, _ := Fingerprint("deploy"); again == changed {
		t.Errorf("a second edit of the same file did not change the fingerprint")
	}
	os.Chmod("a", 0o755)
	modeOnly, _ := Fingerprint("deploy")
	os.Chmod("a", 0o644)
	if back, _ := Fingerprint("deploy"); back == modeOnly {
		t.Errorf("the exec bit is not in the fingerprint")
	}
	os.Remove("a")
	if gone, _ := Fingerprint("deploy"); gone == changed || gone == clean {
		t.Errorf("a deletion did not change the fingerprint")
	}
	git(t, "checkout", "-q", "--", "a")
	if back, _ := Fingerprint("deploy"); back != clean {
		t.Errorf("the restored tree does not fingerprint as it did")
	}
	if after := objects(t); after != before {
		t.Errorf("the fingerprint wrote objects: %q then %q", before, after)
	}
	// A touched file whose bytes did not change is no change.
	now := time.Now().Add(time.Hour)
	os.Chtimes("a", now, now)
	if touched, _ := Fingerprint("deploy"); touched != clean {
		t.Errorf("a touch changed the fingerprint")
	}

	// Base: the highest reachable tag, an unreachable one not counted.
	git(t, "checkout", "-q", "-b", "side")
	os.WriteFile("a", []byte("side\n"), 0o644)
	git(t, "commit", "-qam", "two")
	git(t, "tag", "v9.0.0")
	git(t, "checkout", "-q", "-")
	git(t, "commit", "-q", "--allow-empty", "-m", "three")
	if b, err := DirtyBase(); err != nil || b != "1.2.0" {
		t.Errorf("DirtyBase = %q, %v; want 1.2.0", b, err)
	}
}

// The digest is against HEAD, not the index: a staged change counts as much as
// an unstaged one, in a repository with no commit too.
func TestFingerprintStaged(t *testing.T) {
	newRepo(t)
	fp := func() string {
		t.Helper()
		s, err := Fingerprint("deploy")
		if err != nil {
			t.Fatal(err)
		}
		return s
	}
	clean := fp()
	os.WriteFile("a", []byte("v1\n"), 0o644)
	git(t, "add", "a")
	v1 := fp()
	os.WriteFile("a", []byte("v2\n"), 0o644)
	git(t, "add", "a")
	if v2 := fp(); v2 == v1 || v1 == clean {
		t.Errorf("staging v1 then v2: %s %s %s", clean, v1, v2)
	}
	git(t, "reset", "-q", "--hard")
	git(t, "rm", "-q", "a")
	if gone := fp(); gone == clean {
		t.Errorf("a staged deletion did not change the fingerprint")
	}
	git(t, "reset", "-q", "--hard")

	git(t, "init", "-q", "emb")
	os.WriteFile("emb/e", []byte("v1\n"), 0o644)
	git(t, "-C", "emb", "add", "e")
	e1 := fp()
	os.WriteFile("emb/e", []byte("v2\n"), 0o644)
	git(t, "-C", "emb", "add", "e")
	if e2 := fp(); e2 == e1 {
		t.Errorf("staging v2 in an embedded repository with no commit did not change the fingerprint")
	}
	git(t, "-C", "emb", "rm", "-q", "--cached", "e")
	os.Remove("emb/e")
	git(t, "-C", "emb", "add", "-A")
	if e3 := fp(); e3 == e1 {
		t.Errorf("a deletion in an embedded repository did not change the fingerprint")
	}
}

// .kasbah/ is left out whether .gitignore covers it or not, from a project in
// a subdirectory of its repository too.
func TestFingerprintOwnState(t *testing.T) {
	newRepo(t)
	os.WriteFile(".gitignore", []byte("ignored\n"), 0o644)
	os.MkdirAll("proj", 0o755)
	os.WriteFile("proj/f", []byte("f\n"), 0o644)
	git(t, "add", ".")
	git(t, "commit", "-qm", "unignore")
	t.Chdir("proj")
	clean, err := Fingerprint("deploy")
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(".kasbah", 0o755)
	os.WriteFile(".kasbah/state.json", []byte("{}\n"), 0o644)
	if err := RequireClean("deploy", "1.0.0", "x"); err != nil {
		t.Errorf("an unignored .kasbah/ made the tree dirty: %v", err)
	}
	if fp, _ := Fingerprint("deploy"); fp != clean {
		t.Errorf("an unignored .kasbah/ changed the fingerprint")
	}
	// The whole repository counts, not only the project's directory.
	os.WriteFile("../outside", []byte("o\n"), 0o644)
	if fp, _ := Fingerprint("deploy"); fp == clean {
		t.Errorf("a file outside the project directory did not change the fingerprint")
	}
	if err := RequireClean("deploy", "1.0.0", "x"); err == nil {
		t.Errorf("a file outside the project directory did not make the tree dirty")
	}
}

// Paths git is told not to read from disk are refused, --dirty included.
func TestHiddenPathsRefused(t *testing.T) {
	for _, bit := range []string{"--assume-unchanged", "--skip-worktree"} {
		newRepo(t)
		git(t, "update-index", bit, "a")
		os.WriteFile("a", []byte("hidden edit\n"), 0o644)
		for name, err := range map[string]error{
			"RequireClean": RequireClean("deploy", "1.0.0", "x"),
			"DirtyLabel":   func() error { _, err := DirtyLabel("deploy", time.Now()); return err }(),
			"Fingerprint":  func() error { _, err := Fingerprint("deploy"); return err }(),
		} {
			if err == nil || !strings.Contains(err.Error(), "kasbah cannot see what is on disk for these") || !strings.Contains(err.Error(), "  a") {
				t.Errorf("%s %s: %v", bit, name, err)
			}
		}
	}
}

// Submodule edits count whatever config hides; an embedded repository —
// committed or not — is digested by its files.
func TestSubmodulesAndEmbedded(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("no git")
	}
	base := t.TempDir()
	t.Chdir(base)
	git(t, "init", "-q", "sub")
	os.WriteFile("sub/s", []byte("s\n"), 0o644)
	git(t, "-C", "sub", "add", ".")
	git(t, "-C", "sub", "commit", "-qm", "s")
	git(t, "init", "-q", "top")
	t.Chdir("top")
	os.WriteFile("a", []byte("a\n"), 0o644)
	git(t, "add", ".")
	git(t, "commit", "-qm", "a")
	git(t, "-c", "protocol.file.allow=always", "submodule", "add", "-q", "../sub", "sm")
	git(t, "commit", "-qm", "sm")
	git(t, "config", "diff.ignoreSubmodules", "all")
	clean, err := Fingerprint("deploy")
	if err != nil {
		t.Fatal(err)
	}
	os.WriteFile("sm/s", []byte("edited\n"), 0o644)
	if err := RequireClean("deploy", "1.0.0", "x"); err == nil || !strings.Contains(err.Error(), "sm") {
		t.Errorf("an edit inside a submodule hidden by config: %v", err)
	}
	edited, _ := Fingerprint("deploy")
	if edited == clean {
		t.Errorf("an edit inside a submodule did not change the fingerprint")
	}
	git(t, "-C", "sm", "checkout", "-q", "--", "s")

	// An embedded repository with no commit, CRLF content under safecrlf.
	git(t, "config", "core.safecrlf", "true")
	git(t, "config", "core.autocrlf", "input")
	git(t, "init", "-q", "emb")
	os.WriteFile("emb/e", []byte("one\r\n"), 0o644)
	stderr, _ := os.CreateTemp(t.TempDir(), "stderr")
	saved := os.Stderr
	os.Stderr = stderr
	first, err := Fingerprint("deploy")
	os.Stderr = saved
	if err != nil || first == clean {
		t.Fatalf("an embedded repository: %q %v", first, err)
	}
	os.WriteFile("emb/e", []byte("two\r\n"), 0o644)
	if second, _ := Fingerprint("deploy"); second == first {
		t.Errorf("an edit inside an embedded repository did not change the fingerprint")
	}
	if said, _ := os.ReadFile(stderr.Name()); len(said) != 0 {
		t.Errorf("the fingerprint wrote to stderr: %s", said)
	}
}

func TestEndpoint(t *testing.T) {
	newRepo(t)
	git(t, "tag", "v1.2.0")
	for _, c := range []struct {
		v, tag, note string
		ok           bool
	}{
		{"1.2.0", "v1.2.0", "", true},
		{"1.2.0-dirty.20261028080507", "v1.2.0", "compared as its base tag v1.2.0", true},
		{"0.0.0-dirty.20261028080507", "", "no tagged base", false},
		{"2.0.0-dirty.20261028080507", "", "based on 2.0.0, and v2.0.0 is no tag in this checkout", false},
	} {
		tag, note, ok := Endpoint(c.v)
		if tag != c.tag || ok != c.ok || !strings.Contains(note, c.note) || (c.note == "" && note != "") {
			t.Errorf("Endpoint(%q) = %q %q %v", c.v, tag, note, ok)
		}
	}
}

func TestDirtyBaseUntagged(t *testing.T) {
	newRepo(t)
	if b, err := DirtyBase(); err != nil || b != "0.0.0" {
		t.Errorf("DirtyBase = %q, %v; want 0.0.0", b, err)
	}
}
