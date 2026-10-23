package main

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/install"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/version"
)

// installCmd is the hidden `kasbah __install [--pin] [DIR]`: the build in DIR
// (default this binary's own dist/) into the library the environment names, then
// <bin>/kasbah at the newest that runs — or, with --pin, at that build — unasked.
func installCmd(out *cli.Output, args []string) error {
	exe, err := os.Executable()
	if err != nil {
		return cli.Fail("cannot locate this binary: %v", err)
	}
	return installFrom(out, args, exe, os.Getenv)
}

func installFrom(out *cli.Output, args []string, exe string, getenv func(string) string) error {
	limit := time.Duration(serverbin.RunTimeout) * time.Second
	pin := len(args) > 0 && args[0] == "--pin"
	if pin {
		args = args[1:]
	}
	var dir, ver string
	switch {
	case len(args) == 0:
		if real, err := filepath.EvalSymlinks(exe); err == nil {
			exe = real
		}
		dir, ver = filepath.Dir(exe), build
	case len(args) == 1 && args[0] != "" && !strings.HasPrefix(args[0], "-"):
		abs, err := filepath.Abs(args[0])
		if err != nil {
			return cli.Fail("%v", err)
		}
		dir = abs
		bin := filepath.Join(dir, "kasbah")
		if fi, err := os.Stat(bin); err != nil || !fi.Mode().IsRegular() {
			return cli.Fail("%s is missing — DIR is a dist/ holding kasbah and server/kasbah-linux-{amd64,arm64}", bin).Cont("nothing was installed")
		}
		got, ok := install.Reported(bin, limit)
		if !ok {
			return cli.Fail("%s does not run here, or does not answer --version as kasbah — nothing was installed", bin)
		}
		ver = got
	default:
		return cli.Fail("usage: kasbah __install [--pin] [DIR] (run by install-dev.sh; DIR is a dist/, by default this binary's own)")
	}
	lib, err := launcher.EnvRoot(getenv)
	if err != nil {
		return cli.Fail("%v", err)
	}
	binDir, err := install.BinDir(getenv)
	if err != nil {
		return err
	}
	b, err := install.Dist(dir, ver)
	if err != nil {
		return err
	}
	t := install.Target{
		Lib:        lib,
		BinDir:     binDir,
		Out:        out,
		Prompter:   prompt.Std(out),
		Yes:        true,
		RunTimeout: limit,
	}
	if pin {
		t.Pin = b.Version
	}
	return install.Install(t, b)
}

// pickTagCmd is the hidden `kasbah __pick-tag VERSION [--pre]`, which
// install-dev.sh runs with `git tag -l 'v*'` on stdin: it prints the tag
// VERSION (vN, vN.M or vN.M.P) names among them.
func pickTagCmd(out *cli.Output, args []string, in io.Reader) error {
	usage := cli.Fail("usage: kasbah __pick-tag vN|vN.M|vN.M.P [--pre] (the tags on stdin)")
	var arg string
	pre := false
	for _, a := range args {
		switch {
		case a == "--pre":
			pre = true
		case arg == "" && a != "" && !strings.HasPrefix(a, "-"):
			arg = a
		default:
			return usage
		}
	}
	if arg == "" {
		return usage
	}
	body, err := io.ReadAll(in)
	if err != nil {
		return cli.Fail("could not read the tags: %v", err)
	}
	v, err := version.Pick(arg, version.Tags(strings.Split(string(body), "\n")), pre)
	var nm *version.NoMatch
	if errors.As(err, &nm) {
		return cli.Fail("no local tag matches %s", nm.Want).Cont(noMatchHints(nm)...)
	}
	if err != nil {
		return cli.Fail("%v", err)
	}
	fmt.Fprintf(out.Stdout, "v%s\n", v)
	return nil
}

func noMatchHints(nm *version.NoMatch) []string {
	var h []string
	if nm.Skipped > 0 {
		h = append(h, fmt.Sprintf("%d pre-release tag(s) were skipped — --pre takes them", nm.Skipped))
	}
	return append(h, "the remote's tags may not be here yet: git fetch --tags")
}
