package selfupdate

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
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

// Options are `kasbah self-update [vN | vN.M | vN.M.P] [--pre] [--yes] [--from DIR]`.
type Options struct {
	Version string
	Pre     bool
	Yes     bool
	// From is the directory holding the release's checksums.txt and its
	// signature, read instead of fetched.
	From string
}

// Usage is the command's --help.
const Usage = `Usage: kasbah self-update [vN | vN.M | vN.M.P] [--pre] [--yes] [--from DIR]

Installs a released kasbah from GitHub Releases beside the installed
versions (~/.local/share/kasbah/<version>/, the layout install-dev.sh writes)
and points ~/.local/bin/kasbah at the newest installed version that runs,
as install-dev.sh does — or, when a version is named, at the one it resolves to.
Versions come from the repository's published releases (drafts and bare tags
do not count). A token is used when present: GITHUB_TOKEN, else gh's for
github.com when gh is logged in. A private repository needs one; a public one
only gets a higher rate limit from it. A token GitHub refuses (401) is dropped
with a warning naming where it came from, and the request retried without it.
A version already installed and answering for itself is not downloaded
again; the symlink is still moved.

  (no argument)   the newest release of this kasbah's major
  vN              the newest release of major N
  vN.M            the newest release of N.M
  vN.M.P          that release exactly

Before anything lands under the library: the release's checksums.txt must
verify against the key in release.pub (minisign), and the asset's size and
sha256 against the API and checksums.txt. The installed binary must then
answer --version with its own version. A release binary run from outside
the library (a downloaded asset) asked for its own version installs itself:
its own bytes must match the signed checksum, and nothing is downloaded.

  --pre     let a pre-release (v1.4.0-rc.1) be the newest
  --yes     answer the confirmation asked when the symlink would move to a
            different major than it points at now. Without it and without a
            terminal, that question is a hard fail naming the flag.
  --from DIR
            read the release's checksums.txt and checksums.txt.minisig from
            DIR instead of GitHub: nothing is fetched, no API call is made.
            Only for a downloaded release binary installing itself, its own
            version named exactly (vN.M.P) — what get.sh hands off with. The
            same checks apply: signature, trusted comment, this binary's bytes.
            On macOS the two linux server builds (kasbah_<ver>_linux_amd64,
            _arm64) are read from DIR too, each checked against checksums.txt.

A kasbah run from a checkout does not self-update: build and install it.
`

// Parse reads the command line.
func Parse(args []string) (Options, error) {
	var o Options
	for i := 0; i < len(args); i++ {
		a := strings.TrimSuffix(args[i], "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--pre":
			o.Pre = true
		case a == "--yes":
			o.Yes = true
		case a == "--from" || strings.HasPrefix(a, "--from="):
			if o.From != "" {
				return o, cli.Fail("self-update: --from given twice")
			}
			if a == "--from" {
				if i+1 >= len(args) {
					return o, cli.Fail("self-update: --from takes a directory (--from DIR)")
				}
				i++
				a = "--from=" + strings.TrimSuffix(args[i], "\r")
			}
			if o.From = strings.TrimPrefix(a, "--from="); o.From == "" {
				return o, cli.Fail("self-update: --from takes a directory (--from DIR)")
			}
		case strings.HasPrefix(a, "--pre=") || strings.HasPrefix(a, "--yes="):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("self-update: %s takes no value — pass it on its own", f)
		case strings.HasPrefix(a, "-"):
			f, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("self-update: unknown flag '%s' (self-update takes a version, --pre, --yes and --from)", f)
		default:
			if o.Version != "" {
				return o, cli.Fail("self-update: two versions given ('%s' and '%s') — one run installs one", o.Version, a)
			}
			var nm *version.NoMatch
			if _, err := version.Pick(a, nil, false); !errors.As(err, &nm) {
				return o, cli.Fail("self-update: %v", err)
			}
			o.Version = a
		}
	}
	if o.From != "" && !exact(o.Version) {
		return o, cli.Fail("self-update: --from verifies one release — name this binary's version exactly (vN.M.P)")
	}
	return o, nil
}

// Ctx is what a run needs from the process.
type Ctx struct {
	Client *Client
	Out    *cli.Output
	// Prompter asks the major-change question.
	Prompter *prompt.Prompter
	// Root is the library (<lib>), BinDir where the symlink lives, OS and Arch
	// this machine's GOOS ("" is linux) and GOARCH.
	Root, BinDir, OS, Arch string
	// Self is this build's stamp, "" when unstamped: the major a bare
	// `self-update` resolves within.
	Self string
	// Exe is this binary's path; Loose when it sits in no version directory
	// and no checkout (a downloaded release asset), so it may install itself.
	Exe   string
	Loose bool
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
	var (
		v   version.Version
		how string
		rel *Release
		err error
	)
	if o.From != "" {
		if v, err = fromOwn(c, o); err != nil {
			return err
		}
		if rel, err = c.Client.Local(v.String(), o.From); err != nil {
			return err
		}
		how = "this binary's own release, checksums.txt from " + o.From
	} else {
		if o.Version == "" && !haveMajor {
			return cli.Fail("this kasbah carries no build stamp, so `self-update` cannot tell which major to follow — name a version: kasbah self-update vN")
		}
		if v, how, err = c.Client.Resolve(o.Version, major, o.Pre); err != nil {
			return err
		}
	}
	ver := v.String()
	fmt.Fprintf(c.Out.Stdout, "resolved %s (%s)\n", ver, how)
	dir := filepath.Join(c.Root, ver)
	bin := filepath.Join(dir, "kasbah")
	// A version named is the one to run, installed already or not; with none
	// the symlink goes to the newest installed that runs.
	pin := ""
	if o.Version != "" {
		pin = ver
	}
	if install.Reports(bin, ver, c.RunTimeout) {
		fmt.Fprintf(c.Out.Stdout, "kasbah %s is already installed, nothing downloaded\n  lib: %s\n", ver, dir)
		target, err := install.Repoint(c.Root, c.BinDir, pin, c.Prompter, o.Yes, c.RunTimeout)
		if err != nil {
			return err
		}
		fmt.Fprintf(c.Out.Stdout, "  bin: %s -> %s\n", filepath.Join(c.BinDir, "kasbah"), target)
		install.PathNote(c.Out, c.BinDir, os.Getenv("PATH"))
		return nil
	}
	if rel == nil {
		if rel, err = c.Client.Release(ver); err != nil {
			return err
		}
	}
	fmt.Fprintf(c.Out.Stdout, "verified checksums.txt: key %s, trusted comment \"%s\"\n", rel.KeyID, rel.Comment)
	goos := c.OS
	if goos == "" {
		goos = "linux"
	}
	name := AssetFor(ver, goos, c.Arch)
	t := install.Target{
		Lib:        c.Root,
		BinDir:     c.BinDir,
		Out:        c.Out,
		Prompter:   c.Prompter,
		Yes:        o.Yes,
		Pin:        pin,
		RunTimeout: c.RunTimeout,
	}
	b := install.Build{Version: ver}
	if c.Loose && ver == c.Self && !version.Dev(c.Self) {
		own, err := ownBytes(c.Exe, rel, name)
		if err != nil {
			return err
		}
		fmt.Fprintf(c.Out.Stdout, "this binary is the published %s (sha256 %s) — installing it, nothing downloaded\n", name, rel.Sums[name])
		b.Bin = content(own)
		b.Server = map[string]install.Source{c.Arch: content(own)}
	} else {
		b.Bin = func(path string) error { return c.Client.Download(rel, name, path) }
		// The release asset for this arch is also the server binary for it.
		b.Server = map[string]install.Source{c.Arch: install.File(bin)}
	}
	if goos != "linux" {
		if b.Server, err = serverBuilds(c, rel, ver, o.From); err != nil {
			return err
		}
	}
	return install.Install(t, b)
}

// serverBuilds are both linux server builds, for a workstation that is not
// linux: the copies in from (get.sh downloads them) verified, else downloaded.
func serverBuilds(c Ctx, rel *Release, ver, from string) (map[string]install.Source, error) {
	m := map[string]install.Source{}
	for _, arch := range ServerArches {
		name := AssetName(ver, arch)
		if from == "" {
			m[arch] = func(path string) error { return c.Client.Download(rel, name, path) }
			continue
		}
		b, err := listedBytes(filepath.Join(from, name), rel, name)
		if err != nil {
			return nil, err
		}
		m[arch] = content(b)
	}
	return m, nil
}

// listedBytes is the file at p when its sha256 is the one rel signed for name.
func listedBytes(p string, rel *Release, name string) ([]byte, error) {
	want, ok := rel.Sums[name]
	if !ok {
		return nil, cli.Fail("%s's checksums.txt has no entry for %s — nothing was installed", rel.Tag, name)
	}
	b, err := os.ReadFile(p)
	if err != nil {
		return nil, cli.Fail("cannot read the server build %s: %v", p, err).Cont("nothing was installed — get.sh downloads both linux server builds beside the binary")
	}
	sum := sha256.Sum256(b)
	if got := hex.EncodeToString(sum[:]); got != want {
		return nil, cli.Fail("%s is not the published %s: sha256 %s, the signed checksums.txt says %s", p, name, got, want).Cont("nothing was installed")
	}
	return b, nil
}

// fromOwn is the version --from may install: this binary's own, a release,
// run from outside any library — refused otherwise, before anything is read.
func fromOwn(c Ctx, o Options) (version.Version, error) {
	v, err := version.Parse(strings.TrimPrefix(strings.TrimSpace(o.Version), "v"))
	if err != nil {
		return v, cli.Fail("self-update: %v", err)
	}
	switch {
	case !c.Loose:
		return v, cli.Fail("--from installs a downloaded release binary, and %s is already in the library", c.Exe).Cont(
			"nothing was installed — drop --from to install through the releases API")
	case c.Self == "":
		return v, cli.Fail("--from installs this binary itself, and it carries no build stamp — nothing was installed")
	case version.Dev(c.Self):
		return v, cli.Fail("--from installs this binary itself, and it is a dev build (%s), not a release — nothing was installed", c.Self)
	case v.String() != c.Self:
		return v, cli.Fail("--from installs this binary itself, and it is kasbah %s, not %s", c.Self, v).Cont(
			"nothing was installed — drop --from to install another version through the releases API")
	}
	return v, nil
}

// ownBytes reads the binary at exe whole and returns it when its size and
// sha256 are the ones rel lists and signed for asset name.
func ownBytes(exe string, rel *Release, name string) ([]byte, error) {
	want, ok := rel.Sums[name]
	if !ok {
		return nil, cli.Fail("%s's checksums.txt has no entry for %s — nothing was installed", rel.Tag, name)
	}
	b, err := os.ReadFile(exe)
	if err != nil {
		return nil, cli.Fail("cannot read this binary at %s: %v", exe, err)
	}
	sum := sha256.Sum256(b)
	got := hex.EncodeToString(sum[:])
	a, listed := rel.Assets[name]
	if got != want || (listed && a.Size != int64(len(b))) {
		return nil, cli.Fail("this binary (%s) is not the published %s: sha256 %s, %d bytes; the signed checksums.txt says %s", exe, name, got, len(b), want).Cont(
			"nothing was installed — download the release asset again, or run self-update from an installed kasbah")
	}
	return b, nil
}

// content is a Source writing b.
func content(b []byte) install.Source {
	return func(path string) error {
		if err := os.WriteFile(path, b, 0o755); err != nil {
			return cli.Fail("could not write %s: %v", path, err)
		}
		return nil
	}
}
