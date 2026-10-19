// Package buildpush is `kasbah build-push [USER@HOST]`: build the images this
// project's compose file declares, tag them with HEAD's version, and stream
// them to a server without a registry (docs/build-deploy.md → kasbah
// build-push). It never moves :current and never starts a container — that
// decoupling is what lets an image be staged ahead of the deploy.
package buildpush

import (
	"errors"
	"os"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
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
}

const usage = `Usage: kasbah build-push [USER@HOST] [--build-only] [--no-git-push]

Builds this project's images, tags them with HEAD's version, and loads them onto
a server over ssh — no registry involved. Run from the project root. USER@HOST
defaults to the last server this project talked to (.kasbah/state.json).

What it does:
  * resolves the version from HEAD's single v-tag
  * builds every service in compose.prod.yml that has a build: key, and tags
    each one <image>:<version> from the image: that service names
  * docker save (one stream, all images) | gzip, streamed over ssh into
    docker load on the server — no tarball is written on either end
  * git push origin v<version>, when the tag is not on origin yet

A project whose compose file builds nothing exits 0 having done nothing: stock
images are pulled on the server by ` + "`kasbah deploy`" + `.

It does not move :current and does not run ` + "`compose up`" + `. Both are ` + "`kasbah deploy`" + `'s.

Flags:
  --build-only    build and tag locally; ship nothing, push nothing
  --no-git-push   ship the images, leave the git tag where it is

See docs/build-deploy.md and docs/cli.md.
`

// Usage is `kasbah build-push --help`.
func Usage() string { return usage }

// Parse reads build-push's arguments, in order, as lib/build_push.sh did.
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
		default:
			name, _, _ := strings.Cut(a, "=")
			switch {
			case name == "--build-only" || name == "--no-git-push":
				return o, cli.Fail("build-push: %s takes no value — pass it on its own", name)
			case strings.HasPrefix(a, "-"):
				return o, cli.Fail("build-push: unknown flag '%s' (build-push takes USER@HOST, --build-only and --no-git-push)", name)
			case o.Target == "":
				o.Target = strings.TrimSuffix(a, "\r")
			default:
				return o, cli.Fail("build-push: too many arguments ('%s') — it takes one USER@HOST, and the version comes from HEAD's tag", a)
			}
		}
	}
	return o, nil
}

// Ctx is what a run needs from the process.
type Ctx struct {
	Out     *cli.Output
	PWD     string
	Version string
	Self    remote.Info
	Local   func(arch string) (string, error)
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
	version, err := release.Resolve(c.PWD)
	if err != nil {
		return err
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
		return nil
	}

	if o.BuildOnly {
		if err := build(m.Name, images); err != nil {
			return err
		}
		c.Out.Info("Built and tagged %s %s — nothing was shipped (--build-only)", m.Name, version)
		listImages(c.Out, images)
		return nil
	}

	target := o.Target
	if target == "" {
		stored, err := state.Get(state.File, "last_server")
		if err != nil {
			return err
		}
		if stored == "" || stored == "null" {
			return cli.Fail("build-push: no server given, and this project has never shipped to one").Cont(
				"pass it once — `kasbah build-push user@vps` — and it is remembered in",
				state.File+" as last_server",
				"to build and tag here without shipping anything, use --build-only")
		}
		target = stored
	}
	// The server is proved reachable and prepared before the build: the end of
	// one is the worst time to learn it is neither.
	conn, err := ssh.Connect(target)
	if err != nil {
		return err
	}
	defer conn.Close()
	res, err := serverbin.Ensure(conn, c.Self, c.Local, serverbin.Options{})
	if err != nil {
		return err
	}
	if err := build(m.Name, images); err != nil {
		return err
	}
	if err := ship(conn, serverbin.Path(res.Apps), images); err != nil {
		return err
	}
	gitResult, err := gitPush(c.Out, target, version, !o.NoGitPush)
	if err != nil {
		return err
	}
	// Only now: a failed command leaves the state file untouched.
	if err := state.Record(state.File, c.Version, "last_server", target); err != nil {
		return err
	}

	c.Out.Info("Shipped %s %s to %s", m.Name, version, target)
	listImages(c.Out, images)
	c.Out.Info("  current: unmoved — `kasbah deploy` is what cuts over to %s", version)
	c.Out.Info("  git:     %s", gitResult)
	return nil
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
// let a compliant file interpolate; 0 is Docker's "no limit".
func build(project string, images []Image) error {
	cmd := docker("compose", "-p", project, "-f", Compose, "build")
	cmd.Env = append(os.Environ(), "KASBAH_CPU_LIMIT=0", "KASBAH_MEM_LIMIT=0")
	if err := cmd.Run(); err != nil {
		return cli.Fail("docker compose -p %s -f %s build failed (see the error above)", project, Compose)
	}
	// The permanent tag only; :current stays where the build put it.
	for _, im := range images {
		if err := docker("tag", im.Source, im.Ref).Run(); err != nil {
			return cli.Fail("could not tag %s as %s (see docker's error above)", im.Source, im.Ref)
		}
	}
	return nil
}

// gitPush pushes the version tag last, after the images are on the server:
// a tag on origin naming images no server has is the worse mess. What it did
// is returned for the line under the `Shipped …` headline.
func gitPush(out *cli.Output, target, version string, push bool) (string, error) {
	tag := "v" + version
	if !push {
		return tag + " left where it is (--no-git-push)", nil
	}
	if exec.Command("git", "remote", "get-url", "origin").Run() != nil {
		out.Warn("this repository has no 'origin' remote, so %s was not pushed", tag)
		out.Warn("the images are on %s regardless — push the tag wherever this project lives", target)
		return tag + " not pushed — this repository has no 'origin' remote", nil
	}
	ls := exec.Command("git", "ls-remote", "--exit-code", "origin", "refs/tags/"+tag)
	ls.Stdin = os.Stdin
	if ls.Run() == nil {
		return tag + " is already on origin", nil
	}
	p := exec.Command("git", "push", "origin", tag)
	p.Stdin, p.Stdout, p.Stderr = os.Stdin, os.Stdout, os.Stderr
	if p.Run() != nil {
		return "", cli.Fail("could not push %s to origin (see git's error above)", tag).Cont(
			"the images are already on "+target+" and none of that needs redoing —",
			"push the tag once the remote is reachable:  git push origin "+tag)
	}
	return "pushed " + tag + " to origin", nil
}
