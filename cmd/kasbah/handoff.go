package main

import (
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/version"
)

// report is Output.Report behind the hand-off: a refusal naming another
// version's work re-execs that version instead of printing.
func report(out *cli.Output, err error) int {
	if bin := resolve(err, os.Getenv); bin != "" {
		atexit.Run()
		if shipDev != "" {
			os.Setenv(devEnv, shipDev)
		} else {
			os.Unsetenv(devEnv)
		}
		if xerr := launcher.Exec(bin, build, argv); xerr != nil {
			cont(err, fmt.Sprintf("could not run %s: %v", bin, xerr))
		}
	}
	return out.Report(err)
}

// resolve is the binary to hand the command to for err — a server build newer
// than ours (remote.Newer) or a manifest schema above ours
// (manifest.NewerSchema) — or "" when err is any other error, or when the
// hand-off cannot happen: the refusal then carries why.
func resolve(err error, getenv func(string) string) string {
	var newer *remote.Newer
	var schema *manifest.NewerSchema
	var find func(root string) string
	var wanted, remedy string
	switch {
	case errors.As(err, &newer):
		find = func(root string) string { return launcher.Find(root, newer.Server) }
		wanted = "kasbah " + newer.Server
		remedy = installRemedy(newer.Server)
	case errors.As(err, &schema):
		find = func(root string) string { return launcher.Newest(root, schema.Schema) }
		wanted = fmt.Sprintf("a kasbah of major %d", schema.Schema)
		remedy = fmt.Sprintf("install it: `kasbah self-update v%d`, or ./install-dev.sh from that tag's checkout", schema.Schema)
	default:
		return ""
	}
	if from := getenv(launcher.Env); from != "" {
		cont(err, fmt.Sprintf("this run was already handed off from kasbah %s, and the versions still disagree", from))
		return ""
	}
	exe, exeErr := os.Executable()
	if exeErr != nil {
		cont(err, fmt.Sprintf("cannot locate this binary to hand off from it: %v", exeErr))
		return ""
	}
	if _, checkout := serverbin.Home(exe); checkout {
		cont(err, "this kasbah runs from a checkout, which does not hand off to an installed version",
			"check out and build "+wanted+", or run an installed kasbah")
		return ""
	}
	root, rootErr := launcher.Root(exe, getenv)
	if rootErr != nil {
		cont(err, fmt.Sprintf("the installed versions cannot be found: %v", rootErr))
		return ""
	}
	if bin := find(root); bin != "" {
		return bin
	}
	cont(err, fmt.Sprintf("%s is not installed on this workstation (nothing under %s)", wanted, root), remedy)
	return ""
}

// installRemedy is how to get the server's build onto this workstation: a
// release has a tag to self-update to; a pre-release is some checkout's dev
// build, which only that checkout's commit (tools/stamp's +g<sha>) rebuilds.
func installRemedy(build string) string {
	v, err := version.Parse(build)
	if err != nil || len(v.Pre) == 0 {
		return "install it: `kasbah self-update v" + build + "`, or ./install-dev.sh from that tag's checkout"
	}
	commit := "that commit"
	if sha, ok := strings.CutPrefix(v.Meta, "g"); ok {
		sha, dirty := strings.CutSuffix(sha, ".dirty")
		commit = "commit " + sha
		if dirty {
			commit += " (built from a dirty tree, so its exact bytes may not come back)"
		}
	}
	return fmt.Sprintf("the server runs a dev build from another checkout (%s): check out and build %s and install it (./install-dev.sh), or ship a release, which replaces a dev build", build, commit)
}

func cont(err error, lines ...string) {
	var e *cli.Error
	if errors.As(err, &e) {
		e.Cont(lines...)
	}
}
