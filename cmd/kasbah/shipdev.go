package main

import (
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverbin"
)

// devEnv carries the answer to serverbin.ShipDev across a hand-off, whose
// command line has lost the flags: ship or keep.
const devEnv = "KASBAH_SHIP_DEV"

// devFlags takes serverbin.DevFlags out of a workstation command's arguments,
// wherever they sit before a `--`: every command that reaches a server meets
// the question, so no command parses them itself.
func devFlags(args []string) ([]string, prompt.Given, error) {
	var given prompt.Given
	rest := make([]string, 0, len(args))
	for i, a := range args {
		if a == "--" {
			rest = append(rest, args[i:]...)
			break
		}
		var err error
		switch a {
		case "--" + serverbin.DevFlags.Yes:
			err = given.Set(prompt.Yes, serverbin.DevFlags, "kasbah")
		case "--" + serverbin.DevFlags.No:
			err = given.Set(prompt.No, serverbin.DevFlags, "kasbah")
		default:
			rest = append(rest, a)
		}
		if err != nil {
			return nil, 0, err
		}
	}
	return rest, given, nil
}

// answerShipDev reads devFlags out of args — in a hand-off, devEnv — and has
// serverbin.ShipDev answer from them, else ask on p. The rest is what a
// hand-off re-runs, so an older build never meets flags it does not know; the
// answer is what it carries in devEnv.
func answerShipDev(p *prompt.Prompter, args []string, getenv func(string) string) ([]string, string, error) {
	rest, given, err := devFlags(args)
	if err != nil {
		return nil, "", err
	}
	if given == prompt.Unset && getenv(launcher.Env) != "" {
		switch v := getenv(devEnv); v {
		case "ship":
			given = prompt.Yes
		case "keep":
			given = prompt.No
		case "":
		default:
			return nil, "", cli.Fail("%s='%s' is not an answer kasbah knows (ship or keep)", devEnv, v)
		}
	}
	serverbin.ShipDev = func(server, ours string) (bool, error) {
		return serverbin.AskShipDev(p, given, server, ours)
	}
	answer := map[prompt.Given]string{prompt.Yes: "ship", prompt.No: "keep"}[given]
	return rest, answer, nil
}
