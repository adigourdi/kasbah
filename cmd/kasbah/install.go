package main

import (
	"os"
	"path/filepath"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/install"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverbin"
)

// installCmd is the hidden `kasbah __install`, which install-dev.sh runs from
// a checkout's dist/: this build, and dist/server/ beside it, into the library
// the environment names — never the one this binary would run from — with
// <bin>/kasbah repointed. The repoint asks nothing: the install is the request.
func installCmd(out *cli.Output, args []string) error {
	if len(args) != 0 {
		return cli.Fail("usage: kasbah __install (run by install-dev.sh, from a checkout's dist/)")
	}
	exe, err := os.Executable()
	if err != nil {
		return cli.Fail("cannot locate this binary: %v", err)
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	lib, err := launcher.EnvRoot(os.Getenv)
	if err != nil {
		return cli.Fail("%v", err)
	}
	binDir, err := install.BinDir(os.Getenv)
	if err != nil {
		return err
	}
	b, err := install.Dist(filepath.Dir(exe), build)
	if err != nil {
		return err
	}
	return install.Install(install.Target{
		Lib:        lib,
		BinDir:     binDir,
		Out:        out,
		Prompter:   prompt.Std(out),
		Yes:        true,
		RunTimeout: time.Duration(serverbin.RunTimeout) * time.Second,
	}, b)
}
