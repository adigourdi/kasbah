package release

import (
	"bytes"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

func TestFinalBaseAndBump(t *testing.T) {
	for _, tt := range []struct {
		tags                []string
		patch, minor, major string
	}{
		{nil, "0.0.1", "0.1.0", "1.0.0"},
		{[]string{"v1.2.3", "v1.10.0", "v1.9.9\r"}, "1.10.1", "1.11.0", "2.0.0"},
		{[]string{"v1.2.3", "v2.0.0-rc.1", "v9.0.0-dirty.20261028080507"}, "1.2.4", "1.3.0", "2.0.0"},
		{[]string{"v2.0.0+build.7", "release-7", "v1.4"}, "2.0.1", "2.1.0", "3.0.0"},
	} {
		b := finalBase(tt.tags)
		if got := []string{Bump(b, "patch"), Bump(b, "minor"), Bump(b, "major")}; strings.Join(got, " ") != tt.patch+" "+tt.minor+" "+tt.major {
			t.Errorf("%q: %v", tt.tags, got)
		}
	}
	if CheckBump("deploy", "minor") != nil || CheckBump("deploy", "Minor") == nil {
		t.Error("CheckBump")
	}
}

func tagging(in string, tty bool, bump string) (Tagging, *bytes.Buffer) {
	var b bytes.Buffer
	out := &cli.Output{Stdout: &b, Stderr: &b}
	return Tagging{Cmd: "deploy", Retry: "kasbah deploy --dirty", Bump: bump,
		P: &prompt.Prompter{In: strings.NewReader(in), Out: out, TTY: tty}}, &b
}

func failed(t *testing.T, err error, want string) {
	t.Helper()
	var b bytes.Buffer
	if err != nil {
		(&cli.Output{Stdout: &b, Stderr: &b}).Report(err)
	}
	if err == nil || !strings.Contains(b.String(), want) {
		t.Errorf("want a failure saying %q, got %s", want, b.String())
	}
}

func TestHead(t *testing.T) {
	newRepo(t)
	pwd, _ := os.Getwd()
	git(t, "tag", "v1.2.3")
	tg, b := tagging("", false, "major")
	if v, fresh, err := Head(pwd, tg); v != "1.2.3" || fresh || err != nil || !strings.Contains(b.String(), "--bump=major is not used") {
		t.Fatalf("tagged HEAD: %q %v %v %s", v, fresh, err, b)
	}
	os.WriteFile("a", []byte("b\n"), 0o644)
	git(t, "commit", "-qam", "two")
	git(t, "tag", "v1.3.0-rc.1", "HEAD~1")

	tg, _ = tagging("", false, "")
	_, _, err := Head(pwd, tg)
	failed(t, err, "--bump=patch|minor|major")
	failed(t, err, "no version tag")

	tg, _ = tagging("2\n", true, "")
	if v, fresh, err := Head(pwd, tg); v != "1.3.0" || !fresh || err != nil {
		t.Errorf("asked, answered 2: %q %v %v", v, fresh, err)
	}
	tg, b = tagging("x\nmajor\n", true, "")
	if v, _, err := Head(pwd, tg); v != "2.0.0" || err != nil || !strings.Contains(b.String(), "patch  v1.2.4") || !strings.Contains(b.String(), "answer 1-3") {
		t.Errorf("asked, answered major: %q %v %s", v, err, b)
	}
	tg, _ = tagging("q\n", true, "")
	_, _, err = Head(pwd, tg)
	failed(t, err, "aborted")

	// Taken elsewhere: on another commit here, or on origin.
	git(t, "tag", "v1.2.4", git(t, "commit-tree", "HEAD^{tree}", "-m", "side"))
	tg, _ = tagging("", false, "patch")
	_, _, err = Head(pwd, tg)
	failed(t, err, "v1.2.4 already exists")
	git(t, "tag", "-d", "v1.2.4")
	origin := t.TempDir()
	git(t, "init", "-q", "--bare", origin)
	git(t, "remote", "add", "origin", origin)
	git(t, "push", "-q", "origin", "HEAD~1:refs/tags/v1.2.4")
	_, _, err = Head(pwd, tg)
	failed(t, err, "v1.2.4 already exists on origin")
	git(t, "push", "-q", "origin", ":refs/tags/v1.2.4")
	if v, _, err := Head(pwd, tg); v != "1.2.4" || err != nil {
		t.Errorf("free on origin: %q %v", v, err)
	}

	// Nothing was tagged by any of it; Cut is what tags.
	if tags := git(t, "tag", "--points-at", "HEAD"); tags != "" {
		t.Fatalf("HEAD's tags %q", tags)
	}
	if err := Cut(tg.P.Out, "1.2.4"); err != nil {
		t.Fatal(err)
	}
	if v, err := Resolve(pwd); v != "1.2.4" || err != nil {
		t.Errorf("after Cut: %q %v", v, err)
	}
	if typ, _ := exec.Command("git", "cat-file", "-t", "v1.2.4").Output(); strings.TrimSpace(string(typ)) != "commit" {
		t.Errorf("not a lightweight tag: %s", typ)
	}

	// Untagged and dirty: commit first, whatever --bump says.
	git(t, "commit", "-q", "--allow-empty", "-m", "three")
	os.WriteFile("scratch", []byte("x"), 0o644)
	tg, _ = tagging("", false, "patch")
	_, _, err = Head(pwd, tg)
	failed(t, err, "commit first")
	failed(t, err, "?? scratch")
	failed(t, err, "kasbah deploy --dirty")
}

func TestHeadCountsOnlyFromAWholeClone(t *testing.T) {
	newRepo(t)
	src, _ := os.Getwd()
	git(t, "tag", "v1.4.0")
	os.WriteFile("a", []byte("b\n"), 0o644)
	git(t, "commit", "-qam", "two")

	// Shallow: refused.
	shallow := t.TempDir()
	git(t, "clone", "-q", "--depth", "1", "--no-tags", "file://"+src, shallow)
	t.Chdir(shallow)
	tg, _ := tagging("", false, "patch")
	_, _, err := Head(shallow, tg)
	failed(t, err, "shallow clone")
	failed(t, err, "git fetch --unshallow --tags")

	// Whole but tag-less while origin has tags: refused.
	bare := t.TempDir()
	git(t, "clone", "-q", "--no-tags", src, bare)
	t.Chdir(bare)
	tg, b := tagging("", false, "patch")
	_, _, err = Head(bare, tg)
	failed(t, err, "origin has version tags this clone lacks (v1.4.0")
	failed(t, err, "git fetch --tags")
	if !strings.Contains(b.String(), "asking origin for its version tags") {
		t.Errorf("said nothing before asking:\n%s", b)
	}
	git(t, "fetch", "-q", "--tags")
	if v, _, err := Head(bare, tg); v != "1.4.1" || err != nil {
		t.Errorf("after the fetch: %q %v", v, err)
	}
}

// An origin that never answers is given up on, and the run carries on saying so.
func TestHeadOriginHangs(t *testing.T) {
	newRepo(t)
	pwd, _ := os.Getwd()
	// Not ssh, so left as it is; git's host argument lands after the comment.
	t.Setenv("GIT_SSH_COMMAND", "sleep 30 #")
	git(t, "remote", "add", "origin", "ssh://nowhere.invalid/x.git")
	defer func(d time.Duration) { OriginTimeout = d }(OriginTimeout)
	OriginTimeout = time.Second
	tg, b := tagging("", false, "minor")
	start := time.Now()
	v, fresh, err := Head(pwd, tg)
	if v != "0.1.0" || !fresh || err != nil {
		t.Fatalf("%q %v %v\n%s", v, fresh, err, b)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Errorf("took %s", d)
	}
	for _, w := range []string{"counting from 0.0.0 regardless", "asking origin whether v0.1.0 exists", "tagging it regardless", "no answer within 1s"} {
		if !strings.Contains(b.String(), w) {
			t.Errorf("no %q in\n%s", w, b)
		}
	}
}

func TestSSHCommand(t *testing.T) {
	newRepo(t)
	t.Setenv("GIT_SSH_COMMAND", "")
	t.Setenv("GIT_SSH", "")
	for _, c := range []struct {
		env, core string
		tty       bool
		want      string
	}{
		{"", "", false, "ssh -o BatchMode=yes -o ConnectTimeout=15"},
		{"", "", true, "ssh -o ConnectTimeout=15"},
		{"", "/usr/bin/ssh -i key", false, "/usr/bin/ssh -i key -o BatchMode=yes -o ConnectTimeout=15"},
		{"ssh -p 2", "ssh -i key", true, "ssh -p 2 -o ConnectTimeout=15"},
		// A wrapper may want the host first: left alone.
		{"mywrap --via bastion", "", false, ""},
		{"", "plink -batch", true, ""},
	} {
		t.Setenv("GIT_SSH_COMMAND", c.env)
		git(t, "config", "core.sshCommand", c.core)
		if got := sshCommand(c.tty); got != c.want {
			t.Errorf("%+v: %q", c, got)
		}
	}
	t.Setenv("GIT_SSH_COMMAND", "")
	git(t, "config", "--unset", "core.sshCommand")
	t.Setenv("GIT_SSH", "/bin/myssh")
	if got := sshCommand(false); got != "" {
		t.Errorf("GIT_SSH: %q", got)
	}
}

// Origin's tags that are here already, on history HEAD does not have, leave
// HEAD counting from 0.0.0.
func TestHeadOrphanCountsFromZero(t *testing.T) {
	newRepo(t)
	pwd, _ := os.Getwd()
	git(t, "tag", "v3.0.0")
	origin := t.TempDir()
	git(t, "init", "-q", "--bare", origin)
	git(t, "remote", "add", "origin", origin)
	git(t, "push", "-q", "origin", "v3.0.0")
	git(t, "checkout", "-q", "--orphan", "fresh")
	git(t, "commit", "-qm", "fresh start")
	tg, b := tagging("", false, "patch")
	if v, _, err := Head(pwd, tg); v != "0.0.1" || err != nil {
		t.Errorf("%q %v\n%s", v, err, b)
	}
	if _, _, err := Head(pwd, Tagging{Cmd: "deploy"}); err == nil || !strings.Contains(err.Error(), "no prompter") {
		t.Errorf("nil prompter: %v", err)
	}
}

func TestHeadOtherTagsWarnedAndCutUnsigned(t *testing.T) {
	newRepo(t)
	pwd, _ := os.Getwd()
	git(t, "tag", "release-7")
	git(t, "config", "tag.gpgSign", "true")
	tg, b := tagging("", false, "patch")
	v, _, err := Head(pwd, tg)
	if v != "0.0.1" || err != nil || !strings.Contains(b.String(), "HEAD is tagged release-7") {
		t.Fatalf("%q %v\n%s", v, err, b)
	}
	if err := Cut(tg.P.Out, v); err != nil {
		t.Fatal(err)
	}
	if typ := git(t, "cat-file", "-t", "v0.0.1"); typ != "commit" {
		t.Errorf("v0.0.1 is a %s", typ)
	}
}
