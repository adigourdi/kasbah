package selfupdate

import (
	"errors"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/install"
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
versions (~/.local/share/kasbah/<version>/, the layout install-dev.sh writes)
and points ~/.local/bin/kasbah at the newest installed version that runs,
as install-dev.sh does — or at the version named exactly, when one is. The
repository is private: GITHUB_TOKEN, or gh's token (` + "`gh auth login`" + `),
authenticates the download.

  (no argument)   the newest release of this kasbah's major
  vN              the newest release of major N
  vN.M.P          that release exactly, and the symlink moves to it

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
	// A library that is not kasbah's is refused before anything is fetched.
	if err := install.CheckLib(c.Root); err != nil {
		return err
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
	// A version named exactly is the one to run: installed already, it is
	// still what the symlink moves to.
	pin := ""
	if strings.Contains(o.Version, ".") {
		pin = ver
	}
	if install.Reports(bin, ver, c.RunTimeout) {
		if pin == "" {
			return cli.Fail("kasbah %s is already installed at %s", ver, dir).Cont(
				"it runs and reports its version; nothing was downloaded")
		}
		fmt.Fprintf(c.Out.Stdout, "kasbah %s is already installed, nothing downloaded\n  lib: %s\n", ver, dir)
		target, err := install.Repoint(c.Root, c.BinDir, pin, c.Prompter, o.Yes, c.RunTimeout)
		if err != nil {
			return err
		}
		fmt.Fprintf(c.Out.Stdout, "  bin: %s -> %s\n", filepath.Join(c.BinDir, "kasbah"), target)
		return nil
	}
	rel, err := c.Client.Release(ver)
	if err != nil {
		return err
	}
	fmt.Fprintf(c.Out.Stdout, "verified checksums.txt: key %s, trusted comment \"%s\"\n", rel.KeyID, rel.Comment)
	name := AssetName(ver, c.Arch)
	// The release asset for this arch is also the server binary for it.
	return install.Install(install.Target{
		Lib:        c.Root,
		BinDir:     c.BinDir,
		Out:        c.Out,
		Prompter:   c.Prompter,
		Yes:        o.Yes,
		Pin:        pin,
		RunTimeout: c.RunTimeout,
	}, install.Build{
		Version: ver,
		Bin:     func(path string) error { return c.Client.Download(rel, name, path) },
		Server:  map[string]install.Source{c.Arch: install.File(bin)},
	})
}
