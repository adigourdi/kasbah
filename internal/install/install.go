// Package install places a build in the workstation's versioned library
// (<lib>/<ver>/kasbah beside <lib>/<ver>/server/kasbah-linux-<arch>,
// docs/files.md) and points <bin>/kasbah at the newest version that runs.
// `kasbah __install` (install-dev.sh, from a checkout's dist/) and self-update
// both install through Install.
package install

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/version"
)

// A Source writes one file's bytes at path, which Place then renames into place.
type Source func(path string) error

// File is the bytes of the file at src.
func File(src string) Source {
	return func(path string) error {
		in, err := os.Open(src)
		if err != nil {
			return cli.Fail("%v", err)
		}
		defer in.Close()
		out, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
		if err != nil {
			return cli.Fail("%v", err)
		}
		_, err = io.Copy(out, in)
		if cerr := out.Close(); err == nil {
			err = cerr
		}
		if err != nil {
			return cli.Fail("could not write %s: %v", path, err)
		}
		return nil
	}
}

// Build is one build to place. The binary is written first, so a server
// Source may read the placed <lib>/<ver>/kasbah.
type Build struct {
	// Version is the stamp the binary reports: its version directory's name.
	Version string
	Bin     Source
	// Server is the linux server binary per arch, for <ver>/server/.
	Server map[string]Source
	// From is the directory the files are read from, "" when none; a library
	// that is that directory, or a version directory that is, is refused.
	From string
}

// Target is where a build goes and how the symlink moves.
type Target struct {
	Lib, BinDir string
	Out         *cli.Output
	// Prompter asks before the symlink moves to another major; Yes answers it.
	Prompter *prompt.Prompter
	Yes      bool
	// Pin, when set, is the version the symlink moves to rather than the newest.
	Pin string
	// RunTimeout bounds each --version probe.
	RunTimeout time.Duration
}

// BinDir is where <bin>/kasbah lives: KASBAH_BIN_DIR, else ~/.local/bin.
func BinDir(getenv func(string) string) (string, error) {
	if d := getenv("KASBAH_BIN_DIR"); d != "" {
		return d, nil
	}
	if home := getenv("HOME"); home != "" {
		return filepath.Join(home, ".local", "bin"), nil
	}
	return "", cli.Fail("neither KASBAH_BIN_DIR nor HOME is set, so there is no <bin>/kasbah to point at the install")
}

// Dist is the build in a checkout's dist/: dir/kasbah, which reports ver,
// beside dir/server/kasbah-linux-{amd64,arm64}.
func Dist(dir, ver string) (Build, error) {
	if _, err := version.Parse(ver); err != nil {
		return Build{}, cli.Fail("%s carries no build stamp (it reports '%s'), so it names no version directory — nothing was installed", filepath.Join(dir, "kasbah"), ver).Cont(
			"build it through the toolchain container: docker compose run --rm build")
	}
	b := Build{Version: ver, Bin: File(filepath.Join(dir, "kasbah")), Server: map[string]Source{}, From: dir}
	for _, arch := range []string{"amd64", "arm64"} {
		p := filepath.Join(dir, "server", "kasbah-linux-"+arch)
		if fi, err := os.Stat(p); err != nil || !fi.Mode().IsRegular() {
			return Build{}, cli.Fail("%s is missing — build it: docker compose run --rm build", p).Cont("nothing was installed")
		}
		b.Server[arch] = File(p)
	}
	return b, nil
}

// Install places b under t.Lib, repoints <bin>/kasbah, and then, when b is a
// dev build, removes every other dev build — the repoint never chooses one of
// those, so the symlink resolves whichever step fails. Nothing is written when a
// refusal comes first: a library that is not kasbah's, one that is b's own
// source, a <bin> it cannot write, or something at <bin>/kasbah that is
// neither a symlink nor a regular file.
func Install(t Target, b Build) error {
	if b.From != "" {
		for _, d := range []string{t.Lib, filepath.Join(t.Lib, b.Version)} {
			if same(d, b.From) {
				return cli.Fail("%s is this build's own %s — refusing to install over it", d, b.From).Cont(
					"set KASBAH_LIB_DIR to a directory outside " + b.From)
			}
		}
	}
	if err := CheckLib(t.Lib); err != nil {
		return err
	}
	if err := checkBin(t.BinDir); err != nil {
		return err
	}
	dir, err := Place(t.Lib, b, t.RunTimeout)
	if err != nil {
		return err
	}
	fmt.Fprintf(t.Out.Stdout, "installed kasbah %s\n  lib: %s\n", b.Version, dir)
	dev := version.Dev(b.Version)
	survives := func(e launcher.Entry) bool {
		return !dev || e.Version.String() == b.Version || !version.Dev(e.Version.String())
	}
	target, err := repoint(t.Lib, t.BinDir, t.Pin, t.Prompter, t.Yes, t.RunTimeout, survives)
	if err != nil {
		return err
	}
	fmt.Fprintf(t.Out.Stdout, "  bin: %s -> %s\n", filepath.Join(t.BinDir, "kasbah"), target)
	PathNote(t.Out, t.BinDir, os.Getenv("PATH"))
	if dev {
		removed, err := pruneDev(t.Lib, b.Version)
		for _, d := range removed {
			fmt.Fprintf(t.Out.Stdout, "  removed: %s (another dev build)\n", d)
		}
		if err != nil {
			return err
		}
	}
	return nil
}

// Place writes b into <lib>/<ver>/ — each file beside its name and renamed,
// so a version directory never holds a half-written binary; anything else
// there is left alone — and returns the directory once its kasbah reports ver.
func Place(lib string, b Build, limit time.Duration) (string, error) {
	if _, err := version.Parse(b.Version); err != nil {
		return "", cli.Fail("'%s' does not name a version — nothing was installed", b.Version)
	}
	dir := filepath.Join(lib, b.Version)
	bin := filepath.Join(dir, "kasbah")
	if err := put(bin, b.Bin); err != nil {
		return "", err
	}
	arches := make([]string, 0, len(b.Server))
	for a := range b.Server {
		arches = append(arches, a)
	}
	sort.Strings(arches)
	for _, a := range arches {
		if err := put(filepath.Join(dir, "server", "kasbah-linux-"+a), b.Server[a]); err != nil {
			return "", err
		}
	}
	if !Reports(bin, b.Version, limit) {
		return "", cli.Fail("%s does not run here, or does not report kasbah %s — the symlink was not repointed", bin, b.Version).Cont(
			"the files stay under " + dir + " for a look")
	}
	return dir, nil
}

func put(dst string, src Source) error {
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return cli.Fail("%v", err)
	}
	tmp := filepath.Join(filepath.Dir(dst), "."+filepath.Base(dst)+".new")
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	defer os.Remove(tmp)
	if err := src(tmp); err != nil {
		return err
	}
	if err := os.Chmod(tmp, 0o755); err != nil {
		return cli.Fail("%v", err)
	}
	if err := os.Rename(tmp, dst); err != nil {
		return cli.Fail("could not write %s: %v", dst, err)
	}
	return nil
}

// Reports is whether bin answers --version with `kasbah <ver>`.
func Reports(bin, ver string, limit time.Duration) bool {
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, "--version").Output()
	if err != nil {
		return false
	}
	f := strings.Fields(string(out))
	return len(f) >= 2 && f[0] == "kasbah" && f[1] == ver
}

// CheckLib refuses a library directory that is neither absent, empty, nor
// kasbah's — holding a directory named as a version, complete or not (an
// interrupted install's) — since installing deletes inside it and its path
// comes from the environment.
func CheckLib(lib string) error {
	ents, err := os.ReadDir(lib)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		if fi, serr := os.Stat(lib); serr == nil && !fi.IsDir() {
			return cli.Fail("%s is not a directory — set KASBAH_LIB_DIR to an empty or previously installed path", lib)
		}
		return cli.Fail("%v", err)
	}
	if len(ents) == 0 {
		return nil
	}
	for _, e := range ents {
		if _, err := version.Parse(e.Name()); err == nil && e.IsDir() {
			return nil
		}
	}
	return cli.Fail("%s is not empty and is not a kasbah library directory — refusing to remove anything there", lib).Cont(
		"kasbah's holds <version>/ directories (<version>/kasbah with <version>/server/kasbah-linux-*)",
		"set KASBAH_LIB_DIR to an empty or previously installed path")
}

// pruneDev removes every dev-build version directory under lib but keep,
// returning those removed. Releases are never touched.
func pruneDev(lib, keep string) ([]string, error) {
	ents, err := os.ReadDir(lib)
	if err != nil {
		return nil, cli.Fail("%v", err)
	}
	var removed []string
	for _, e := range ents {
		if !e.IsDir() || e.Name() == keep || !version.Dev(e.Name()) {
			continue
		}
		dir := filepath.Join(lib, e.Name())
		if err := os.RemoveAll(dir); err != nil {
			return removed, cli.Fail("could not remove the dev build at %s: %v", dir, err)
		}
		removed = append(removed, dir)
	}
	return removed, nil
}

// checkBin makes <binDir> and proves a symlink can be made there, and refuses
// <binDir>/kasbah when it is neither absent, a symlink, nor a regular file.
func checkBin(binDir string) error {
	link := filepath.Join(binDir, "kasbah")
	if fi, err := os.Lstat(link); err == nil && fi.Mode()&os.ModeSymlink == 0 && !fi.Mode().IsRegular() {
		return cli.Fail("%s exists and is not a regular file or a symlink — refusing to replace it", link).Cont("nothing was installed")
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return cli.Fail("cannot make %s: %v", binDir, err).Cont("nothing was installed")
	}
	tmp := filepath.Join(binDir, ".kasbah.new")
	os.Remove(tmp)
	if err := os.Symlink("kasbah", tmp); err != nil {
		return cli.Fail("cannot write %s/kasbah: %v", binDir, err).Cont("nothing was installed")
	}
	os.Remove(tmp)
	return nil
}

// Repoint points <binDir>/kasbah at the newest installed version under root
// whose kasbah runs — at version pin when it is named and runs — and returns
// the target. Moving the link to another major than it points at now is asked
// first (yes answers it). Something there that is neither a symlink nor a
// regular file is refused.
func Repoint(root, binDir, pin string, p *prompt.Prompter, yes bool, limit time.Duration) (string, error) {
	return repoint(root, binDir, pin, p, yes, limit, nil)
}

// repoint is Repoint choosing only among the versions keep accepts (all, nil).
func repoint(root, binDir, pin string, p *prompt.Prompter, yes bool, limit time.Duration, keep func(launcher.Entry) bool) (string, error) {
	var newest *launcher.Entry
	for _, e := range launcher.Installed(root) {
		if keep != nil && !keep(e) {
			continue
		}
		if pin != "" && e.Version.String() != pin {
			continue
		}
		if launcher.Runs(e.Bin, limit) {
			e := e
			newest = &e
			break
		}
	}
	if newest == nil {
		if pin != "" {
			return "", cli.Fail("no kasbah %s runs under %s — %s/kasbah was not repointed", pin, root, binDir)
		}
		return "", cli.Fail("no installed kasbah runs under %s — %s/kasbah was not repointed", root, binDir)
	}
	link := filepath.Join(binDir, "kasbah")
	fi, err := os.Lstat(link)
	exists := err == nil
	if exists && fi.Mode()&os.ModeSymlink == 0 && !fi.Mode().IsRegular() {
		return "", cli.Fail("%s exists and is not a regular file or a symlink — refusing to replace it", link)
	}
	if exists {
		if cur, ok := currentVersion(link, fi, limit); ok && cur.Major != newest.Version.Major {
			q := fmt.Sprintf("point %s at kasbah %s? it points at kasbah %s now, a different major", link, newest.Version, cur)
			ok, err := p.Confirm("yes", q, yes)
			if err != nil {
				return "", err
			}
			if !ok {
				return "", cli.Fail("not confirmed — %s still points at kasbah %s; kasbah %s stays installed under %s", link, cur, newest.Version, root)
			}
		}
	}
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		return "", cli.Fail("%v", err)
	}
	tmp := filepath.Join(binDir, ".kasbah.new")
	os.Remove(tmp)
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	if err := os.Symlink(newest.Bin, tmp); err != nil {
		return "", cli.Fail("%v", err)
	}
	if err := os.Rename(tmp, link); err != nil {
		os.Remove(tmp)
		return "", cli.Fail("could not repoint %s: %v", link, err)
	}
	return newest.Bin, nil
}

// currentVersion is the version <bin>/kasbah points at: the version
// directory a symlink names, else what a regular file (a 1.0.x install)
// reports; false when neither tells.
func currentVersion(link string, fi os.FileInfo, limit time.Duration) (version.Version, bool) {
	if fi.Mode()&os.ModeSymlink != 0 {
		target, err := os.Readlink(link)
		if err != nil {
			return version.Version{}, false
		}
		if !filepath.IsAbs(target) {
			target = filepath.Join(filepath.Dir(link), target)
		}
		if filepath.Base(target) == "kasbah" {
			v, err := version.Parse(filepath.Base(filepath.Dir(target)))
			return v, err == nil
		}
		return version.Version{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	out, err := exec.CommandContext(ctx, link, "--version").Output()
	if err != nil {
		return version.Version{}, false
	}
	f := bytes.Fields(out)
	if len(f) < 2 || string(f[0]) != "kasbah" {
		return version.Version{}, false
	}
	v, err := version.Parse(string(f[1]))
	return v, err == nil
}

// PathNote says so on stderr when binDir is not in path (a PATH value).
func PathNote(out *cli.Output, binDir, path string) {
	for _, d := range filepath.SplitList(path) {
		if d == binDir {
			return
		}
	}
	fmt.Fprintf(out.Stderr, "note: %s is not in PATH\n", binDir)
}

func same(a, b string) bool {
	fa, err := os.Stat(a)
	if err != nil {
		return false
	}
	fb, err := os.Stat(b)
	return err == nil && os.SameFile(fa, fb)
}
