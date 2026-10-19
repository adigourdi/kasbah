package env

import (
	"errors"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/state"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are `kasbah env`'s arguments.
type Options struct{ Target, OnDrift string }

const usage = `Usage: kasbah env [USER@HOST] [--on-drift=setup|continue|abort]

Renders <apps>/<name>/.env on the server from this project's .env.prod.example,
interactively, and refreshes the kasbah-managed KASBAH_* block in it from the
server marker's resource limits. Run from the project root; USER@HOST defaults
to the last server this project deployed to (.kasbah/state.json).

The setup is interactive and needs a terminal at both ends. Without one the run
stops (exit 5) rather than accepting every default silently — including when
--on-drift= is passed, since this command runs the setup whether or not .env has
drifted.

Flags, for when it has:
  --on-drift=setup      re-run the setup. What the command does anyway; there
                        is no default answer, an empty one is asked again
  --on-drift=continue   leave .env alone; only refresh the KASBAH_* block
  --on-drift=abort      stop, changing nothing

See docs/env-template.md for the template conventions.
`

// Usage is `kasbah env --help`.
func Usage() string { return usage }

// CheckOnDrift validates the flag where it is parsed, so a typo costs a
// sentence at the top of the run rather than a prompt at the bottom.
func CheckOnDrift(cmd, v string) error {
	switch strings.TrimSuffix(v, "\r") {
	case "setup", "continue", "abort":
		return nil
	}
	return cli.Fail("%s: --on-drift='%s' is not one of setup, continue or abort", cmd, strings.TrimSuffix(v, "\r"))
}

// Parse reads `kasbah env`'s arguments.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "--on-drift="):
			o.OnDrift = strings.TrimSuffix(strings.TrimPrefix(a, "--on-drift="), "\r")
			if err := CheckOnDrift("env", o.OnDrift); err != nil {
				return o, err
			}
		case a == "--on-drift":
			return o, cli.Fail("env: --on-drift takes its value with '=' — --on-drift=setup, --on-drift=continue or --on-drift=abort")
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("env: unknown flag '%s' (env takes USER@HOST and --on-drift=)", name)
		case o.Target == "":
			o.Target = strings.TrimSuffix(a, "\r")
		default:
			return o, cli.Fail("env: too many arguments ('%s') — env takes USER@HOST and nothing else", a)
		}
	}
	return o, nil
}

// Session is one server, as `kasbah env` needs it. The real one is ssh plus
// the server binary (session.go); tests substitute their own.
type Session interface {
	// Marker ensures the server binary and returns the validated marker.
	Marker() (*marker.Marker, error)
	Prepare(dir string) error
	ShipTemplate(local, dir string) error
	// Drift, Setup and Inject return the server's exit status; Setup runs
	// over a terminal.
	Drift(dir string) (out string, rc int)
	Setup(dir string, color bool) int
	Inject(dir string, pairs []string) int
	Close()
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out      *cli.Output
	Prompter *prompt.Prompter
	PWD      string
	Version  string
	// TTYIn and TTYOut are `[ -t 0 ]` and `[ -t 1 ]`.
	TTYIn, TTYOut bool
	// Color is this terminal's decision, handed to the server's prompts.
	Color bool
	Dial  func(target string) (Session, error)
}

// Run is `kasbah env`.
func Run(c Ctx, o Options) error {
	// Relative, as every project command reads them: from the project root.
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	statePath := state.File
	target, _, err := state.Server(o.Target, "env", "kasbah env user@vps")
	if err != nil {
		return err
	}
	tmpl := ".env.prod.example"
	if fi, err := os.Stat(tmpl); err != nil || !fi.Mode().IsRegular() {
		return cli.Fail("no .env.prod.example in %s — that file is the template this renders .env from (docs/env-template.md)", c.PWD)
	}

	s, err := c.Dial(target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return err
	}
	dir := mk.AppsPath + "/" + m.Name
	if err := s.Prepare(dir); err != nil {
		return err
	}
	// The template first: the setup prompts from it.
	if err := s.ShipTemplate(tmpl, dir); err != nil {
		return err
	}
	st := &Step{Out: c.Out, Prompter: c.Prompter, S: s, Target: target, TTYIn: c.TTYIn, TTYOut: c.TTYOut, Color: c.Color}
	if err := st.Run(dir, mk.CPULimit, mk.MemLimit, o.OnDrift, true); err != nil {
		return err
	}
	if err := state.Record(statePath, c.Version, "last_server", target); err != nil {
		return err
	}
	c.Out.Info("%s's .env on %s is ready", m.Name, target)
	c.Out.Info("  file:   %s/.env", dir)
	c.Out.Info("  limits: KASBAH_CPU_LIMIT=%s KASBAH_MEM_LIMIT=%s (from the server marker)", mk.CPULimit, mk.MemLimit)
	return nil
}

// Step is the env step: docs/build-deploy.md step 6, and the whole of
// `kasbah env` (always set). It ends in injection, after any setup.
type Step struct {
	Out           *cli.Output
	Prompter      *prompt.Prompter
	S             Session
	Target        string
	TTYIn, TTYOut bool
	Color         bool
}

// exitText says how a bounded server call ended, from ssh.ExitCode's status.
func exitText(rc int) string { return serverbin.ExitText(rc, serverbin.RunTimeout) }

func (st *Step) probe(dir string) (State, error) {
	out, rc := st.S.Drift(dir)
	if rc != 0 {
		return State{}, cli.Fail("could not read the env state of %s on %s", dir, st.Target).Cont(
			"`kasbah remote setup-env drift` failed: " + exitText(rc) + " (see above)")
	}
	s, absent := ParseReport(out)
	if len(absent) > 0 {
		e := cli.Fail("the env check on %s reported no %s", st.Target, strings.Join(absent, " ")).Cont(
			"the step was truncated, or the server's kasbah is not one this kasbah speaks to —",
			"raw output:")
		for _, l := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
			e.Cont("| " + strings.TrimSuffix(l, "\r"))
		}
		return State{}, e
	}
	return s, nil
}

// remedies are the ways out a refusal offers, per reason: only those that can
// reach the branch they are printed under.
func (st *Step) remedies(reason, dir string) []string {
	t := st.Target
	switch reason {
	case "missing":
		return []string{
			"  * run `kasbah env " + t + "` from a terminal, or",
			"  * write the file on the server yourself, from the template that is",
			"    already beside it:",
			"      ssh " + t + " 'cp " + dir + "/.env.prod.example " + dir + "/.env'   # then edit it there",
			"--on-drift= does not reach this: there is no .env to have drifted.",
		}
	case "drift":
		return []string{
			"  * run `kasbah env " + t + "` from a terminal, or",
			"  * pass --on-drift=continue to deploy against " + dir + "/.env as it stands, or",
			"  * pass --on-drift=abort to stop without touching the server.",
		}
	case "reconfigure":
		return []string{
			"  * run `kasbah env " + t + "` from a terminal.",
			dir + "/.env is already in sync with the template, so `kasbah deploy`",
			"needs nothing from you — this command exists to re-answer the prompts,",
			"and there is nobody here to answer them.",
		}
	}
	return []string{"  * run `kasbah env " + t + "` from a terminal."}
}

// setup runs the server's setup over ssh -t; it needs a terminal on stdin and
// stdout (the prompts go to stdout), else every default would be taken silently.
func (st *Step) setup(dir, why, reason string) error {
	if !st.TTYIn || !st.TTYOut {
		return cli.Failf(cli.ExitEnvSetup, "%s on %s, and there is no terminal here to render it on", why, st.Target).Cont(
			"the setup is interactive — it prompts per variable, masks the secret ones and",
			"runs the template's generators (docs/env-template.md). Either:").Cont(
			st.remedies(reason, dir)...).Cont("Nothing was deployed.")
	}
	st.Out.Info("%s — running the interactive env setup on %s", why, st.Target)
	if rc := st.S.Setup(dir, st.Color); rc != 0 {
		return cli.Failf(cli.ExitEnvSetup, "the env setup on %s did not finish (%s, see above)", st.Target, exitText(rc)).Cont(
			"it was aborted, answered with nothing, or could not run at all — all three",
			"leave the .env unwritten, which is what exit 5 says. Nothing was deployed.",
			"Re-run and answer it through, or:").Cont(st.remedies(reason, dir)...)
	}
	return nil
}

// chooseOnDrift is the tri-state: the flag wins, else a terminal is asked,
// else the run stops naming the flag. No default: Enter must not re-run the
// generator over a live .env.
func (st *Step) chooseOnDrift(given string) (string, error) {
	if given == "" && !st.Prompter.TTY {
		return "", cli.Failf(cli.ExitEnvSetup, "cannot ask what to do about the drift: there is no terminal to ask on").Cont(
			"pass --on-drift=setup (re-run the interactive setup), --on-drift=continue",
			"(deploy against the .env as it stands) or --on-drift=abort.",
			"Nothing was deployed.")
	}
	for {
		a, err := st.Prompter.Value("on-drift",
			"re-run setup, continue with the .env as it stands, or abort? [setup/continue/abort]", given, "")
		if err != nil {
			return "", err
		}
		switch a {
		case "setup", "continue", "abort":
			return a, nil
		}
		st.Out.Warn("answer setup, continue or abort")
		given = ""
	}
}

// Run is the step against dir, with the marker's limits. always is `kasbah
// env`, which runs the setup even when nothing has drifted.
func (st *Step) Run(dir, cpu, mem, onDrift string, always bool) error {
	t := st.Target
	s, err := st.probe(dir)
	if err != nil {
		return err
	}
	action, why, reason := "continue", dir+"/.env is being reconfigured", "reconfigure"
	switch {
	case !s.EnvExists:
		if !s.TemplateExists {
			return cli.Failf(cli.ExitEnvSetup, "%s has no %s/.env, and no %s/.env.prod.example to render one from", t, dir, dir).Cont(
				"the template is the project's own file and reaches the server through the",
				"manifest's sync: list — add .env.prod.example to it",
				"(docs/project-manifest.md, docs/env-template.md). Nothing was deployed.")
		}
		action, why, reason = "setup", dir+"/.env does not exist yet", "missing"
	case !s.TemplateExists:
		// No template: every key would read as extra against an empty set.
		st.Out.Warn("%s has no %s/.env.prod.example, so its .env cannot be checked for drift", t, dir)
		st.Out.Warn("add .env.prod.example to the manifest's sync: list (docs/project-manifest.md)")
		if always {
			return cli.Fail("there is no %s/.env.prod.example on %s to run the setup against", dir, t)
		}
	case s.Missing != "" || s.Extra != "":
		st.Out.Warn("%s/.env on %s has drifted from .env.prod.example", dir, t)
		if s.Missing != "" {
			st.Out.Warn("  in the template, not in .env: %s", s.Missing)
		}
		if s.Extra != "" {
			st.Out.Warn("  in .env, not in the template: %s", s.Extra)
		}
		if action, err = st.chooseOnDrift(onDrift); err != nil {
			return err
		}
		why, reason = dir+"/.env has drifted from .env.prod.example", "drift"
	case always:
		action = "setup"
	}

	switch action {
	case "setup":
		if err := st.setup(dir, why, reason); err != nil {
			return err
		}
		// Re-read: `q` and the EOF path both return having written nothing.
		if s, err = st.probe(dir); err != nil {
			return err
		}
		if !s.EnvExists {
			return cli.Failf(cli.ExitEnvSetup, "the env setup left no %s/.env on %s", dir, t).Cont(
				"it was aborted, or answered with nothing. Nothing was deployed — re-run",
				"`kasbah env "+t+"` and answer it through.")
		}
		if s.Missing != "" || s.Extra != "" {
			st.Out.Warn("%s/.env still differs from .env.prod.example — continuing with it as it stands", dir)
		}
	case "abort":
		return cli.Failf(cli.ExitEnvSetup, "aborted: %s/.env on %s has drifted from .env.prod.example", dir, t).Cont(
			"nothing was deployed. `kasbah env "+t+"` re-runs the setup, or pass",
			"--on-drift=continue to deploy against the .env as it stands.")
	}

	// Exit 1, not 5: injection takes no answer from anyone.
	if rc := st.S.Inject(dir, []string{"KASBAH_CPU_LIMIT=" + cpu, "KASBAH_MEM_LIMIT=" + mem}); rc != 0 {
		return cli.Fail("could not write the kasbah-managed block into %s/.env on %s", dir, t).Cont(
			"`kasbah remote setup-env inject` failed: "+exitText(rc)+" (see above). Without it `compose up`",
			"fails on an unset KASBAH_CPU_LIMIT, so nothing was deployed.")
	}
	return nil
}
