package main

import (
	"fmt"
	"os"
	"runtime"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/install"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/selfupdate"
	"github.com/adigourdi/kasbah/internal/serverbin"
)

// selfUpdateCmd is `kasbah self-update [vN | vN.M.P] [--pre] [--yes]`.
func selfUpdateCmd(o selfupdate.Options, err error) int {
	out := cli.Std()
	if err == selfupdate.ErrHelp {
		fmt.Fprint(out.Stdout, selfupdate.Usage)
		return cli.ExitOK
	}
	if err != nil {
		return out.Report(err)
	}
	return out.Report(selfUpdate(out, o))
}

func selfUpdate(out *cli.Output, o selfupdate.Options) error {
	if runtime.GOOS != "linux" {
		return cli.Fail("self-update installs the linux release assets, and this kasbah runs on %s", runtime.GOOS)
	}
	exe, err := os.Executable()
	if err != nil {
		return cli.Fail("cannot locate this binary: %v", err)
	}
	home, checkout := serverbin.Home(exe)
	if checkout {
		return cli.Fail("this kasbah runs from the checkout at %s, which self-update does not touch", home).Cont(
			"build it: docker compose run --rm build, then ./install-dev.sh")
	}
	root, err := launcher.Root(exe, os.Getenv)
	if err != nil {
		return cli.Fail("the installed versions cannot be found: %v", err)
	}
	binDir, err := install.BinDir(os.Getenv)
	if err != nil {
		return err
	}
	c, err := selfupdate.New(out, os.Getenv)
	if err != nil {
		return err
	}
	return selfupdate.Run(selfupdate.Ctx{
		Client:     c,
		Out:        out,
		Prompter:   prompt.Std(out),
		Root:       root,
		BinDir:     binDir,
		Arch:       runtime.GOARCH,
		Self:       build,
		RunTimeout: time.Duration(serverbin.RunTimeout) * time.Second,
	}, o)
}
