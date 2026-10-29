// Package buildpush is `kasbah build-push [USER@HOST]`: build the images this
// project's compose file declares, tag them with HEAD's version, and stream
// them to a server without a registry (docs/build-deploy.md → kasbah
// build-push). It never moves :current and never starts a container — that
// decoupling is what lets an image be staged ahead of the deploy.
package buildpush

import (
	"bytes"
	"errors"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/release"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are build-push's arguments.
type Options struct {
	Target               string
	BuildOnly, NoGitPush bool
	Dirty                bool
	// Bump answers the question an untagged HEAD asks: patch, minor or major.
	Bump string
}

// The state fields a --dirty build-push leaves for `kasbah deploy --dirty`:
// the label it shipped, where to, and the working tree it built.
const (
	DirtyBuild  = "dirty_build"
	DirtyServer = "dirty_server"
	DirtyTree   = "dirty_tree"
)

const usage = `Usage: kasbah build-push [USER@HOST] [--build-only] [--no-git-push] [--dirty]
                         [--bump=patch|minor|major]

Builds this project's images, tags them with HEAD's version, and loads them onto
a server over ssh — no registry involved. Run from the project root. USER@HOST
defaults to the last server this project talked to (.kasbah/state.json).

What it does:
  * resolves the version from HEAD's single v-tag, and refuses a working tree
    with uncommitted changes or untracked files .gitignore does not cover
  * an untagged HEAD asks which release to tag it as — a patch, minor or major
    bump of the highest release tag merged into HEAD, else of 0.0.0 — and
    tags HEAD before anything is built
  * builds every service in compose.prod.yml that has a build: key, and tags
    each one <image>:<version> from the image: that service names
  * docker save (one stream, all images) | gzip, streamed over ssh into
    docker load on the server — no tarball is written on either end, and the
    layers the server already holds are left out of the stream
  * git push origin v<version>, when the tag is not on origin yet

A project whose compose file builds nothing exits 0 having done nothing: stock
images are pulled on the server by ` + "`kasbah deploy`" + `.

It does not move :current and does not run ` + "`compose up`" + `. Both are ` + "`kasbah deploy`" + `'s.

Flags:
  --build-only    build and tag locally; ship nothing, push nothing
  --no-git-push   ship the images, leave the git tag where it is
  --dirty         build the working tree as it stands, labelled
                  <base>-dirty.<UTC yyyymmddhhmmss> (base: the highest v-tag
                  reachable from HEAD, else 0.0.0). Pushes no tag, is never a
                  rollback target, and is what ` + "`kasbah deploy --dirty`" + ` deploys
  --bump=patch|minor|major
                  answers the untagged-HEAD question; without a terminal and
                  without --bump, an untagged HEAD is a failure

See docs/build-deploy.md and docs/cli.md.
`

// Usage is `kasbah build-push --help`.
func Usage() string { return usage }

// Parse reads build-push's arguments, in order.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch a {
		case "-h", "--help":
			return o, ErrHelp
		case "--build-only":
			o.BuildOnly = true
		case "--no-git-push":
			o.NoGitPush = true
		case "--dirty":
			o.Dirty = true
		default:
			name, val, _ := strings.Cut(a, "=")
			switch {
			case name == "--bump" && strings.Contains(a, "="):
				o.Bump = strings.TrimSuffix(val, "\r")
				if err := release.CheckBump("build-push", o.Bump); err != nil {
					return o, err
				}
			case name == "--bump":
				return o, cli.Fail("build-push: --bump takes its value with '=' — --bump=patch, --bump=minor or --bump=major")
			case name == "--build-only" || name == "--no-git-push" || name == "--dirty":
				return o, cli.Fail("build-push: %s takes no value — pass it on its own", name)
			case strings.HasPrefix(a, "-"):
				return o, cli.Fail("build-push: unknown flag '%s' (build-push takes USER@HOST, --build-only, --no-git-push, --dirty and --bump=)", name)
			case o.Target == "":
				o.Target = strings.TrimSuffix(a, "\r")
			default:
				return o, cli.Fail("build-push: too many arguments ('%s') — it takes one USER@HOST, and the version comes from HEAD's tag", a)
			}
		}
	}
	if o.Dirty && o.Bump != "" {
		return o, cli.Fail("build-push: --dirty ships under no tag, and --bump=%s cuts one — pass one or the other", o.Bump)
	}
	return o, nil
}

// Ctx is what a run needs from the process.
type Ctx struct {
	Out *cli.Output
	// Prompter asks which release an untagged HEAD is.
	Prompter *prompt.Prompter
	PWD      string
	Version  string
	Self     remote.Info
	Local    func(arch string) (string, error)
	// Now labels a --dirty build; time.Now when nil.
	Now func() time.Time
}

// label is what this run tags its images: HEAD's version on a clean tree —
// fresh when HEAD has no tag yet and v is the one to cut — or a dirty label
// and the tree it was read from with --dirty.
func label(c Ctx, o Options) (v, tree string, fresh bool, err error) {
	if !o.Dirty {
		v, fresh, err = release.Head(c.PWD, release.Tagging{Cmd: "build-push", Retry: "kasbah build-push --dirty",
			Bump: o.Bump, Push: !o.NoGitPush && !o.BuildOnly, P: c.Prompter})
		return v, "", fresh, err
	}
	if err = release.Repo(c.PWD); err != nil {
		return "", "", false, err
	}
	now := c.Now
	if now == nil {
		now = time.Now
	}
	if tree, err = release.Fingerprint("build-push"); err != nil {
		return "", "", false, err
	}
	v, err = release.DirtyLabel("build-push", now())
	return v, tree, false, err
}

// Run is the command. Everything that is a fact about this checkout is
// checked before a build or a round trip is spent on it.
func Run(c Ctx, o Options) error {
	if _, err := exec.LookPath("docker"); err != nil {
		return cli.Fail("docker is required (install docker and retry)")
	}
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	version, tree, fresh, err := label(c, o)
	if err != nil {
		return err
	}
	cut := func() error {
		if !fresh {
			return nil
		}
		return release.Cut(c.Out, version)
	}
	doc, err := ReadCompose(c.PWD, "build-push derives the images to ship from it")
	if err != nil {
		return err
	}
	images, err := Built(doc, m.Name, version)
	if err != nil {
		return err
	}
	if len(images) == 0 {
		c.Out.Info("%s builds nothing — no service in %s has a build: key", m.Name, Compose)
		c.Out.Info("  stock images are pulled on the server by `kasbah deploy`; nothing to ship")
		if fresh {
			c.Out.Info("  HEAD was not tagged v%s — there is nothing to release under it", version)
		}
		return nil
	}

	if o.BuildOnly {
		if err := cut(); err != nil {
			return err
		}
		// No server to ask: the engine's own platform, or DOCKER_DEFAULT_PLATFORM's.
		if err := build(m.Name, images, "", ""); err != nil {
			return err
		}
		c.Out.Info("Built and tagged %s %s — nothing was shipped (--build-only)", m.Name, version)
		listImages(c.Out, images)
		return nil
	}

	target, _, err := state.Server(o.Target, "build-push", "kasbah build-push user@vps",
		"to build and tag here without shipping anything, use --build-only")
	if err != nil {
		return err
	}
	if err := cut(); err != nil {
		return err
	}
	// The server is proved reachable and prepared before the build: the end of
	// one is the worst time to learn it is neither.
	conn, err := ssh.Connect(target)
	if err != nil {
		return err
	}
	defer conn.Close()
	res, _, err := serverbin.EnsurePrepared(conn, c.Self, c.Local)
	if err != nil {
		return err
	}
	if res.Arch == "" {
		return cli.Fail("%s's machine type is not one kasbah builds for, so there is no platform to build its images for", target)
	}
	platform := "linux/" + res.Arch
	engine := enginePlatform()
	if engine != "" && engine != platform {
		c.Out.Info("building for %s, the platform of %s — this docker engine is %s", platform, target, engine)
	}
	for _, im := range images {
		if im.Platform != "" && im.Platform != platform {
			c.Out.Warn("service '%s' sets platform: %s, and %s is %s — its image will not run there", im.Service, im.Platform, target, platform)
		}
	}
	if d := os.Getenv("DOCKER_DEFAULT_PLATFORM"); d != "" && d != platform {
		c.Out.Info("  DOCKER_DEFAULT_PLATFORM=%s is overridden: the images run on %s", d, target)
	}
	if err := build(m.Name, images, platform, engine); err != nil {
		return err
	}
	st, err := ship(c.Out, conn, res.Apps, images)
	if err != nil {
		return err
	}
	if o.Dirty {
		after, err := release.Fingerprint("build-push")
		if err != nil {
			return err
		}
		if after != tree {
			return cli.Fail("the working tree changed while %s was being built — the images shipped to %s may match neither state", version, target).Cont(
				"so they are not recorded for `kasbah deploy --dirty`; leave the tree alone and re-run:",
				"  kasbah build-push "+target+" --dirty")
		}
	}
	kv := []string{"last_server", target}
	gitResult := "nothing pushed — a --dirty build has no tag"
	if o.Dirty {
		kv = append(kv, DirtyBuild, version, DirtyServer, target, DirtyTree, tree)
	} else if gitResult, err = release.Push(c.Out, version, !o.NoGitPush, "the images are on "+target); err != nil {
		return err
	}
	// Only now: a failed command leaves the state file untouched.
	if err := state.Record(state.File, c.Version, kv...); err != nil {
		return err
	}

	c.Out.Info("Shipped %s %s to %s", m.Name, version, target)
	listImages(c.Out, images)
	switch {
	case st.abandoned > 0:
		c.Out.Info("  stream:  %s sent whole, after %s in a stream without the server's layers that it could not load", mb(st.sent), mb(st.abandoned))
	case st.compressed:
		c.Out.Info("  stream:  %s sent; this workstation's image store saves compressed layers — nothing could be left out", mb(st.sent))
	case st.layers > 0:
		c.Out.Info("  stream:  %s sent; %d of %d layers (%s) already on the server, not sent", mb(st.sent), st.skipped, st.layers, mb(st.skippedBytes))
	default:
		c.Out.Info("  stream:  %s sent, every layer", mb(st.sent))
	}
	if o.Dirty {
		c.Out.Info("  current: unmoved — `kasbah deploy %s --dirty` is what cuts over to %s", target, version)
	} else {
		c.Out.Info("  current: unmoved — `kasbah deploy` is what cuts over to %s", version)
	}
	c.Out.Info("  git:     %s", gitResult)
	return nil
}

// mb is a byte count in decimal units, as docker prints image sizes.
func mb(n int64) string {
	switch {
	case n < 1000:
		return strconv.FormatInt(n, 10) + " B"
	case n < 1e6:
		return strconv.FormatFloat(float64(n)/1e3, 'f', 1, 64) + " kB"
	}
	return strconv.FormatFloat(float64(n)/1e6, 'f', 1, 64) + " MB"
}

func listImages(out *cli.Output, images []Image) {
	for _, im := range images {
		out.Info("  image:   %s (service %s)", im.Ref, im.Service)
	}
}

func docker(args ...string) *exec.Cmd {
	cmd := exec.Command("docker", args...)
	cmd.Stdout, cmd.Stderr = os.Stdout, os.Stderr
	return cmd
}

// build is `compose build`, never `up --build`: a service with both build:
// and image: is not rebuilt by up while an image of that name exists. -p
// because COMPOSE_PROJECT_NAME outranks the file's name:. The two limits only
// let a compliant file interpolate; 0 is Docker's "no limit". platform, when
// set, is the server's: compose builds every service without its own
// platform: for it.
func build(project string, images []Image, platform, engine string) error {
	cmd := docker("compose", "-p", project, "-f", Compose, "build")
	cmd.Env = append(os.Environ(), "KASBAH_CPU_LIMIT=0", "KASBAH_MEM_LIMIT=0")
	if platform != "" {
		cmd.Env = append(cmd.Env, "DOCKER_DEFAULT_PLATFORM="+platform)
	}
	// compose's stderr still reaches the terminal; a copy is kept to read its refusal.
	var errs bytes.Buffer
	cmd.Stderr = io.MultiWriter(os.Stderr, &tail{&errs, 64 << 10})
	if err := cmd.Run(); err != nil {
		f := cli.Fail("docker compose -p %s -f %s build failed (see the error above)", project, Compose)
		if platform != "" && strings.Contains(errs.String(), "does not support value set by DOCKER_DEFAULT_PLATFORM") {
			f.Cont("the server runs " + platform + ", so every built service's build.platforms must include " + platform + " (or be left out)")
		} else if engine != "" && platform != "" && engine != platform {
			f.Cont("building for "+platform+" on a "+engine+" engine needs emulation: Docker Desktop has it;",
				"on a Linux engine, install it once: docker run --privileged --rm tonistiigi/binfmt --install "+strings.TrimPrefix(platform, "linux/"))
		}
		return f
	}
	// The permanent tag only; :current stays where the build put it.
	for _, im := range images {
		if err := docker("tag", im.Source, im.Ref).Run(); err != nil {
			return cli.Fail("could not tag %s as %s (see docker's error above)", im.Source, im.Ref)
		}
	}
	return nil
}

// tail keeps at most max bytes written to b, and never fails a write.
type tail struct {
	b   *bytes.Buffer
	max int
}

func (t *tail) Write(p []byte) (int, error) {
	if room := t.max - t.b.Len(); room > 0 {
		t.b.Write(p[:min(len(p), room)])
	}
	return len(p), nil
}

// enginePlatform is the local docker engine's os/arch, "" when it does not say.
func enginePlatform() string {
	out, err := exec.Command("docker", "version", "--format", "{{.Server.Os}}/{{.Server.Arch}}").Output()
	p := strings.TrimSpace(string(out))
	if err != nil || !strings.Contains(p, "/") || strings.HasPrefix(p, "/") || strings.HasSuffix(p, "/") {
		return ""
	}
	return p
}
