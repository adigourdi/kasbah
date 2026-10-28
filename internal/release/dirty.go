package release

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"hash"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/version"
)

// state is kasbah's own directory in the project, which a run writes into and
// which is no change to the project.
const state = ".kasbah"

// gitIn runs git in dir with stderr captured: a failure reports what git
// said, and nothing reaches the terminal on success.
func gitIn(dir string, args ...string) ([]byte, error) {
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	var errb bytes.Buffer
	cmd.Stderr = &errb
	out, err := cmd.Output()
	if err != nil {
		return nil, cli.Fail("git %s failed in %s", strings.Join(args, " "), dir).Cont(
			strings.Split(strings.TrimSpace(errb.String()), "\n")...)
	}
	return out, nil
}

func nul(b []byte) []string {
	var out []string
	for _, s := range strings.Split(string(b), "\x00") {
		if s != "" {
			out = append(out, s)
		}
	}
	return out
}

// top is the repository's root and the project directory's path within it.
func top() (root, prefix string, err error) {
	out, err := gitIn(".", "rev-parse", "--show-toplevel", "--show-prefix")
	if err != nil {
		return "", "", err
	}
	lines := strings.SplitN(strings.TrimRight(string(out), "\n"), "\n", 2)
	if len(lines) == 2 {
		prefix = lines[1]
	}
	return lines[0], prefix, nil
}

// ownState is whether path, relative to the top repository, is in .kasbah/.
func ownState(path, prefix string) bool {
	s := prefix + state
	return path == s || strings.HasPrefix(path, s+"/")
}

// repo is one repository the tree spans: the top one, a checked-out
// submodule, or a repository embedded in the tree untracked.
type repo struct{ dir, rel string }

// nested is every checked-out submodule of r.
func nested(r repo) ([]repo, error) {
	out, err := gitIn(r.dir, "ls-files", "-s", "-z")
	if err != nil {
		return nil, err
	}
	var subs []repo
	for _, l := range nul(out) {
		meta, path, ok := strings.Cut(l, "\t")
		if !ok || !strings.HasPrefix(meta, "160000 ") {
			continue
		}
		if fi, err := os.Stat(filepath.Join(r.dir, path, ".git")); err == nil && fi != nil {
			subs = append(subs, repo{filepath.Join(r.dir, path), r.rel + path + "/"})
		}
	}
	return subs, nil
}

// hidden is every path git is told not to look at on disk — assume-unchanged
// (lowercase in `ls-files -v`) and skip-worktree (S, sparse checkouts) — in r
// and the submodules under it.
func hidden(r repo, prefix string) ([]string, error) {
	out, err := gitIn(r.dir, "ls-files", "-v", "-z")
	if err != nil {
		return nil, err
	}
	var paths []string
	for _, l := range nul(out) {
		if len(l) < 3 || (r.rel == "" && ownState(l[2:], prefix)) {
			continue
		}
		if c := l[0]; c == 'S' || (c >= 'a' && c <= 'z') {
			paths = append(paths, r.rel+l[2:])
		}
	}
	subs, err := nested(r)
	if err != nil {
		return nil, err
	}
	for _, s := range subs {
		p, err := hidden(s, "")
		if err != nil {
			return nil, err
		}
		paths = append(paths, p...)
	}
	return paths, nil
}

// RequireVisible refuses a tree with paths git does not read from disk: no
// check of what changed — nor --dirty's fingerprint — can see into them.
func RequireVisible(cmd string) error {
	root, prefix, err := top()
	if err != nil {
		return err
	}
	paths, err := hidden(repo{root, ""}, prefix)
	if err != nil || len(paths) == 0 {
		return err
	}
	e := cli.Fail("%s: kasbah cannot see what is on disk for these — git is told to skip them (assume-unchanged, or skip-worktree as a sparse checkout sets):", cmd)
	list(e, paths)
	return e.Cont("clear the bits (git update-index --no-assume-unchanged / --no-skip-worktree <path>,",
		"or git sparse-checkout disable) and retry; --dirty is refused the same way")
}

func list(e *cli.Error, lines []string) {
	const show = 10
	for i, l := range lines {
		if i == show {
			e.Cont(fmt.Sprintf("  … and %d more", len(lines)-show))
			return
		}
		e.Cont("  " + l)
	}
}

// Changes is `git status --porcelain` over the whole repository but .kasbah/:
// tracked changes, submodule edits whatever config says to hide, and untracked
// files .gitignore does not cover, one per line.
func Changes() ([]string, error) {
	out, err := gitIn(".", "status", "--porcelain", "--untracked-files=normal", "--ignore-submodules=none",
		"--", ":/", ":(exclude)"+state)
	if err != nil {
		return nil, err
	}
	var lines []string
	for _, l := range strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n") {
		if l != "" {
			lines = append(lines, l)
		}
	}
	return lines, nil
}

// RequireClean refuses a working tree that is not HEAD's: what cmd would ship
// under HEAD's tag would then not be the tag. retry spells the --dirty run.
func RequireClean(cmd, v, retry string) error {
	if err := RequireVisible(cmd); err != nil {
		return err
	}
	ch, err := Changes()
	if err != nil || len(ch) == 0 {
		return err
	}
	e := cli.Fail("%s: the working tree differs from HEAD (v%s) — what it would ship as %s is not what v%s holds", cmd, v, v, v)
	list(e, ch)
	return e.Cont(
		"commit them and cut a new tag, stash them, or ship them as a labelled test build:",
		"  "+retry,
		"which runs as "+v+"-dirty.<UTC time> and is never a rollback target")
}

// DirtyBase is the version a --dirty build is labelled from: the highest
// v-tag reachable from HEAD, or 0.0.0 when there is none.
func DirtyBase() (string, error) {
	out, err := gitIn(".", "tag", "--merged", "HEAD", "--list", "v*")
	if err != nil {
		return "", err
	}
	return pickBase(strings.Split(string(out), "\n")), nil
}

func pickBase(names []string) string {
	var best *version.Version
	tags := version.Tags(names)
	for i, t := range tags {
		if version.IsDirty(t.String()) {
			continue
		}
		if best == nil || version.Compare(t, *best) > 0 {
			best = &tags[i]
		}
	}
	if best == nil {
		return "0.0.0"
	}
	// Build metadata's '+' cannot be in a Docker tag.
	base, _, _ := strings.Cut(best.String(), "+")
	return base
}

// DirtyLabel is DirtyBase's label at now, for a tree kasbah can see whole.
func DirtyLabel(cmd string, now time.Time) (string, error) {
	if err := RequireVisible(cmd); err != nil {
		return "", err
	}
	base, err := DirtyBase()
	if err != nil {
		return "", err
	}
	return version.DirtyLabel(base, now), nil
}

// Fingerprint is a digest of the working tree as it stands, written nowhere:
// sha256 over each repository's HEAD tree and, for every path that differs
// from it (staged or not, deleted, untracked and not ignored), the path, its
// mode and a hash of its bytes — submodules and embedded repositories alike.
func Fingerprint(cmd string) (string, error) {
	if err := RequireVisible(cmd); err != nil {
		return "", err
	}
	root, prefix, err := top()
	if err != nil {
		return "", err
	}
	h := sha256.New()
	if err := digest(h, repo{root, ""}, prefix); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func digest(h hash.Hash, r repo, prefix string) error {
	// What differs from HEAD, staged or not, plus what is untracked; a
	// repository with no commit yet has no HEAD, so every file it has counts.
	head, _ := gitIn(r.dir, "rev-parse", "-q", "--verify", "HEAD^{tree}")
	fmt.Fprintf(h, "repo %q %s\n", r.rel, strings.TrimSpace(string(head)))
	var out []byte
	if len(head) == 0 {
		o, err := gitIn(r.dir, "ls-files", "-z", "-c", "-o", "--exclude-standard")
		if err != nil {
			return err
		}
		out = o
	} else {
		changed, err := gitIn(r.dir, "diff", "--name-only", "-z", "--no-renames", "--no-ext-diff", "--no-relative", "HEAD", "--")
		if err != nil {
			return err
		}
		untracked, err := gitIn(r.dir, "ls-files", "-z", "-o", "--exclude-standard")
		if err != nil {
			return err
		}
		out = append(append(changed, 0), untracked...)
	}
	subs, err := nested(r)
	if err != nil {
		return err
	}
	gitlink := map[string]bool{}
	for _, s := range subs {
		gitlink[strings.TrimSuffix(strings.TrimPrefix(s.rel, r.rel), "/")] = true
	}
	paths := nul(out)
	sort.Strings(paths)
	last := ""
	for _, p := range paths {
		if p == last || gitlink[p] || (r.rel == "" && ownState(p, prefix)) {
			continue
		}
		last = p
		if strings.HasSuffix(p, "/") {
			// `ls-files -o` names an embedded repository, not its files.
			subs = append(subs, repo{filepath.Join(r.dir, p), r.rel + p})
			continue
		}
		if err := entry(h, filepath.Join(r.dir, p), r.rel+p); err != nil {
			return err
		}
	}
	sort.Slice(subs, func(i, j int) bool { return subs[i].rel < subs[j].rel })
	for _, s := range subs {
		if err := digest(h, s, ""); err != nil {
			return err
		}
	}
	return nil
}

func entry(h hash.Hash, abs, rel string) error {
	fi, err := os.Lstat(abs)
	switch {
	case os.IsNotExist(err):
		fmt.Fprintf(h, "deleted %q\n", rel)
		return nil
	case err != nil:
		return cli.Fail("could not read %s: %v", rel, err)
	case fi.Mode()&os.ModeSymlink != 0:
		target, err := os.Readlink(abs)
		if err != nil {
			return cli.Fail("could not read the link %s: %v", rel, err)
		}
		fmt.Fprintf(h, "120000 %q %q\n", rel, target)
		return nil
	case !fi.Mode().IsRegular():
		fmt.Fprintf(h, "other %q %s\n", rel, fi.Mode().Type())
		return nil
	}
	f, err := os.Open(abs)
	if err != nil {
		return cli.Fail("could not read %s: %v", rel, err)
	}
	defer f.Close()
	c := sha256.New()
	if _, err := io.Copy(c, f); err != nil {
		return cli.Fail("could not read %s: %v", rel, err)
	}
	mode := "100644"
	if fi.Mode()&0o111 != 0 {
		mode = "100755"
	}
	fmt.Fprintf(h, "%s %q %x\n", mode, rel, c.Sum(nil))
	return nil
}

// Endpoint is the tag a changelog reads v as — a --dirty build's base tag —
// with the line that says so; ok is false, and the line says why there is no
// changelog, when that base is no tag in this checkout.
func Endpoint(v string) (tag, note string, ok bool) {
	if !version.IsDirty(v) {
		return "v" + v, "", true
	}
	b := version.DirtyBase(v)
	if exec.Command("git", "rev-parse", "-q", "--verify", "refs/tags/v"+b+"^{commit}").Run() == nil {
		return "v" + b, v + " is a --dirty build — compared as its base tag v" + b + "; its own changes are in no commit", true
	}
	if b == "0.0.0" {
		return "", v + " is a --dirty build with no tagged base — no v-tag was reachable where it was built — so there is no changelog", false
	}
	return "", v + " is a --dirty build based on " + b + ", and v" + b + " is no tag in this checkout (a tag with +metadata loses it in the label) — so there is no changelog", false
}
