package selfupdate

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/version"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are `kasbah self-update [vN | vN.M.P] [--pre] [--yes]`.
type Options struct {
	Version string
	Pre     bool
	Yes     bool
}

// Usage is the command's --help.
const Usage = `Usage: kasbah self-update [vN | vN.M.P] [--pre] [--yes]

Installs a released kasbah from GitHub Releases beside the installed
versions (~/.local/share/kasbah/<version>/, the layout install.sh writes)
and points ~/.local/bin/kasbah at the newest installed version that runs,
as install.sh does. The repository is private: GITHUB_TOKEN, or gh's token
(` + "`gh auth login`" + `), authenticates the download.

  (no argument)   the newest release of this kasbah's major
  vN              the newest release of major N
  vN.M.P          that release exactly

Before anything lands under the library: the release's checksums.txt must
verify against the key in release.pub (minisign), and the asset's size and
sha256 against the API and checksums.txt. The installed binary must then
answer --version with its own version.

  --pre     let a pre-release tag (v1.4.0-rc.1) be the newest
  --yes     answer the confirmation asked when the symlink would move to a
            different major than it points at now. Without it and without a
            terminal, that question is a hard fail naming the flag.

A kasbah run from a checkout does not self-update: build and install it.
`

// Parse reads the command line.
func Parse(args []string) (Options, error) {
	var o Options
	for _, raw := range args {
		a := strings.TrimSuffix(raw, "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--pre":
			o.Pre = true
		case a == "--yes":
			o.Yes = true
		case strings.HasPrefix(a, "--pre=") || strings.HasPrefix(a, "--yes="):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("self-update: %s takes no value — pass it on its own", f)
		case strings.HasPrefix(a, "-"):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("self-update: unknown flag '%s' (self-update takes a version, --pre and --yes)", f)
		default:
			if o.Version != "" {
				return o, cli.Fail("self-update: two versions given ('%s' and '%s') — one run installs one", o.Version, a)
			}
			o.Version = a
		}
	}
	return o, nil
}

// Ctx is what a run needs from the process.
type Ctx struct {
	Client *Client
	Out    *cli.Output
	// Prompter asks the major-change question.
	Prompter *prompt.Prompter
	// Root is the library (<lib>), BinDir where the symlink lives, Arch this
	// machine's GOARCH.
	Root, BinDir, Arch string
	// Self is this build's stamp, "" when unstamped: the major a bare
	// `self-update` resolves within.
	Self string
	// RunTimeout bounds each --version probe.
	RunTimeout time.Duration
}

// Run is the command: resolve, verify, install, probe, repoint.
func Run(c Ctx, o Options) error {
	major, haveMajor := uint64(0), false
	if c.Self != "" {
		if v, err := version.Parse(c.Self); err == nil {
			major, haveMajor = v.Major, true
		}
	}
	if o.Version == "" && !haveMajor {
		return cli.Fail("this kasbah carries no build stamp, so `self-update` cannot tell which major to follow — name a version: kasbah self-update vN")
	}
	v, how, err := c.Client.Resolve(o.Version, major, o.Pre)
	if err != nil {
		return err
	}
	ver := v.String()
	fmt.Fprintf(c.Out.Stdout, "resolved %s (%s)\n", ver, how)
	dir := filepath.Join(c.Root, ver)
	bin := filepath.Join(dir, "kasbah")
	if Reports(bin, ver, c.RunTimeout) {
		return cli.Fail("kasbah %s is already installed at %s", ver, dir).Cont(
			"it runs and reports its version; nothing was downloaded")
	}
	rel, err := c.Client.Release(ver)
	if err != nil {
		return err
	}
	fmt.Fprintf(c.Out.Stdout, "verified checksums.txt: key %s, trusted comment \"%s\"\n", rel.KeyID, rel.Comment)
	name := AssetName(ver, c.Arch)
	if err := c.Client.Download(rel, name, bin); err != nil {
		return err
	}
	server := filepath.Join(dir, "server", "kasbah-linux-"+c.Arch)
	if err := copyBeside(bin, server); err != nil {
		return err
	}
	if !Reports(bin, ver, c.RunTimeout) {
		return cli.Fail("%s does not run here, or does not report kasbah %s — %s/kasbah was not repointed", bin, ver, c.BinDir).Cont(
			"the files stay under " + dir + " for a look")
	}
	fmt.Fprintf(c.Out.Stdout, "installed kasbah %s\n  lib: %s\n", ver, dir)
	target, err := Repoint(c.Root, c.BinDir, c.Prompter, o.Yes, c.RunTimeout)
	if err != nil {
		return err
	}
	fmt.Fprintf(c.Out.Stdout, "  bin: %s -> %s\n", filepath.Join(c.BinDir, "kasbah"), target)
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

// copyBeside writes src's bytes at dst, mode 0755, beside its name and renamed.
func copyBeside(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return cli.Fail("%v", err)
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return cli.Fail("%v", err)
	}
	tmp := filepath.Join(filepath.Dir(dst), "."+filepath.Base(dst)+".new")
	out, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return cli.Fail("%v", err)
	}
	_, err = io.Copy(out, in)
	if cerr := out.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, dst)
	}
	if err != nil {
		os.Remove(tmp)
		return cli.Fail("could not write %s: %v", dst, err)
	}
	return nil
}

// Repoint points <binDir>/kasbah at the newest installed version under root
// whose kasbah runs, as install.sh does (`ln -sfn`), and returns the target.
// Moving the link to another major than it points at now is asked first
// (--yes). Something there that is neither a symlink nor a regular file is
// refused.
func Repoint(root, binDir string, p *prompt.Prompter, yes bool, limit time.Duration) (string, error) {
	var newest *launcher.Entry
	for _, e := range launcher.Installed(root) {
		if launcher.Runs(e.Bin, limit) {
			e := e
			newest = &e
			break
		}
	}
	if newest == nil {
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
