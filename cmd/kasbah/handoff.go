package main

import (
	"errors"
	"fmt"
	"os"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
)

// report is Output.Report behind the hand-off: a refusal naming another
// version's work re-execs that version instead of printing.
func report(out *cli.Output, err error) int {
	if bin := resolve(err, os.Getenv); bin != "" {
		atexit.Run()
		if xerr := launcher.Exec(bin, build, os.Args[1:]); xerr != nil {
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
		remedy = "kasbah self-update " + newer.Server
	case errors.As(err, &schema):
		find = func(root string) string { return launcher.Newest(root, schema.Schema) }
		wanted = fmt.Sprintf("a kasbah of major %d", schema.Schema)
		remedy = fmt.Sprintf("kasbah self-update <%d.x.y>", schema.Schema)
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
	cont(err, fmt.Sprintf("%s is not installed on this workstation (nothing under %s)", wanted, root),
		"install it: `"+remedy+"`, or ./install.sh from that tag's checkout")
	return ""
}

func cont(err error, lines ...string) {
	var e *cli.Error
	if errors.As(err, &e) {
		e.Cont(lines...)
	}
}

// newestCmd is the hidden `kasbah __newest DIR`: the newest version directory
// under DIR whose kasbah runs, as install.sh repoints the symlink.
func newestCmd(out *cli.Output, args []string) error {
	if len(args) != 1 {
		return cli.Fail("usage: kasbah __newest DIR")
	}
	for _, e := range launcher.Installed(args[0]) {
		if launcher.Runs(e.Bin, time.Duration(serverbin.RunTimeout)*time.Second) {
			fmt.Fprintln(out.Stdout, e.Version)
			return nil
		}
	}
	return cli.Fail("no installed kasbah runs under %s", args[0])
}
