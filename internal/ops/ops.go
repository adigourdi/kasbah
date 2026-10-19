// Package ops is `kasbah logs` and `kasbah exec`: one `docker compose` on the
// server, streamed over ssh. The one write is last_server in the state file.
package ops

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are one command's arguments. Command is everything after `--`,
// verbatim.
type Options struct {
	Cmd             string
	Target, Service string
	Follow          bool
	Tail            string
	DDash           bool
	Command         []string
}

const logsUsage = `Usage: kasbah logs [USER@HOST] [SERVICE] [-f] [--tail=N]

` + "`docker compose logs`" + ` for this project on a server, run against
<apps>/<name>/compose.yml as ` + "`docker compose -p <name>`" + `. Run from the project
root. USER@HOST defaults to the last server this project talked to
(.kasbah/state.json); with SERVICE omitted, every service in the project.

An argument carrying an '@' is the server and anything else is the service —
the same rule ` + "`kasbah exec`" + ` uses, because both commands take the two in that
order and neither can tell them apart by position.

Flags:
  -f           follow, until interrupted
  --tail=N     lines of history per service (default 100; --tail=all for all)

The output is compose's own, unaltered, on stdout: no terminal is allocated for
it, so ` + "`kasbah logs | grep …`" + ` gets the lines rather than a pty's CRs.

Reads the server and writes nothing to it but kasbah's own binary, installed
when the server's is absent or older. See docs/cli.md.
`

const execUsage = `Usage: kasbah exec [USER@HOST] SERVICE -- CMD…

` + "`docker compose exec SERVICE CMD…`" + ` on a server, against
<apps>/<name>/compose.yml as ` + "`docker compose -p <name>`" + `. Run from the project
root. USER@HOST defaults to the last server this project talked to
(.kasbah/state.json).

The '--' is mandatory: it is what makes a flag in CMD belong to CMD rather than
to kasbah, so ` + "`kasbah exec web -- ls -la`" + ` lists a directory instead of being
refused for an unknown '-la'.

SERVICE is required. An argument carrying an '@' is the server, so a service
name may not contain one.

A terminal is allocated only when this side has one at both ends — stdin and
stdout both a tty — so ` + "`kasbah exec db -- pg_dump …`" + ` redirected to a file
gets bytes rather than a pty's CRs. Without one, ` + "`docker compose exec -T`" + ` runs
the command with its stdin closed; feeding data to it is not something this
command does.

CMD's own exit status is this command's exit status — kasbah adds no verdict of
its own to it (docs/cli.md → exit codes).

See docs/cli.md.
`

// Usage is cmd's --help.
func Usage(cmd string) string {
	if cmd == "exec" {
		return execUsage
	}
	return logsUsage
}

func (o *Options) targetPrefix() string {
	if o.Target == "" {
		return ""
	}
	return o.Target + " "
}

// classify is the rule both commands share: an argument carrying an '@' is
// the server, anything else the service.
func (o *Options) classify(arg string) error {
	arg = strings.TrimSuffix(arg, "\r")
	if strings.Contains(arg, "@") {
		if o.Target != "" {
			return cli.Fail("%s: two servers given ('%s' and '%s') — one run goes to one server", o.Cmd, o.Target, arg)
		}
		o.Target = arg
		return nil
	}
	if o.Service != "" && o.Cmd == "exec" {
		return cli.Fail("exec: '%s' comes after the service '%s', and there is no '--' between them", arg, o.Service).Cont(
			"the command to run goes after '--':",
			fmt.Sprintf("  kasbah exec %s%s -- %s …", o.targetPrefix(), o.Service, arg),
			"without it kasbah would have to guess which of its own flags are yours.")
	}
	if o.Service != "" {
		return cli.Fail("%s: two services given ('%s' and '%s') — kasbah will not choose between them", o.Cmd, o.Service, arg)
	}
	o.Service = arg
	return nil
}

func (o *Options) execUnknownFlag(a string) error {
	name, _, _ := strings.Cut(a, "=")
	e := cli.Fail("exec: unknown flag '%s'", name)
	if o.Service != "" {
		return e.Cont("if it belongs to the command you want to run, it goes after '--':",
			fmt.Sprintf("  kasbah exec %s%s -- <cmd> %s …", o.targetPrefix(), o.Service, a))
	}
	return e.Cont("exec takes USER@HOST, SERVICE, then '--' and the command to run:",
		"  kasbah exec [USER@HOST] SERVICE -- CMD…")
}

func checkTail(v string) error {
	if v == "all" {
		return nil
	}
	if v == "" || strings.IndexFunc(v, func(r rune) bool { return r < '0' || r > '9' }) >= 0 {
		return cli.Fail("logs: --tail='%s' is not a number of lines — pass a count (`--tail=50`) or `--tail=all`", v)
	}
	return nil
}

// Parse reads logs' or exec's arguments; exec's own requirements are checked
// here too, before the manifest is read and long before ssh.
func Parse(cmd string, args []string) (Options, error) {
	o := Options{Cmd: cmd, Tail: "100"}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--":
			if cmd != "exec" {
				return o, cli.Fail("logs: '--' separates kasbah's flags from a command to run, and logs runs none (`kasbah logs [USER@HOST] [SERVICE] [-f] [--tail=N]`)")
			}
			o.DDash = true
			o.Command = append([]string{}, args[i+1:]...)
			i = len(args)
		case a == "-f" || strings.HasPrefix(a, "-f=") || a == "--tail" || strings.HasPrefix(a, "--tail="):
			if cmd != "logs" {
				return o, o.execUnknownFlag(a)
			}
			switch {
			case a == "-f":
				o.Follow = true
			case strings.HasPrefix(a, "-f="):
				return o, cli.Fail("logs: -f takes no value — pass it on its own (`kasbah logs USER@HOST -f`)")
			case a == "--tail":
				return o, cli.Fail("logs: --tail takes its value with '=' — `kasbah logs --tail=100`")
			default:
				o.Tail = strings.TrimSuffix(strings.TrimPrefix(a, "--tail="), "\r")
				if err := checkTail(o.Tail); err != nil {
					return o, err
				}
			}
		case strings.HasPrefix(a, "-"):
			if cmd == "logs" {
				name, _, _ := strings.Cut(a, "=")
				return o, cli.Fail("logs: unknown flag '%s' (logs takes USER@HOST, SERVICE, -f and --tail=N)", name)
			}
			return o, o.execUnknownFlag(a)
		default:
			if err := o.classify(a); err != nil {
				return o, err
			}
		}
	}
	if cmd == "exec" {
		return o, o.requireExec()
	}
	return o, nil
}

func (o *Options) requireExec() error {
	if !o.DDash {
		svc := o.Service
		if svc == "" {
			svc = "web"
		}
		return cli.Fail("exec: no '--' in the arguments, and the command to run goes after it").Cont(
			"`kasbah exec [USER@HOST] SERVICE -- CMD…`, for example:",
			"  kasbah exec "+svc+" -- sh -c 'ls -la /srv'",
			"the '--' is mandatory because it is what makes a flag in CMD belong to CMD",
			"rather than to kasbah (docs/cli.md → kasbah exec).")
	}
	if o.Service == "" {
		return cli.Fail("exec: no service given — `kasbah exec [USER@HOST] SERVICE -- CMD…`").Cont(
			"the service is the one `docker compose exec` runs the command in, named as",
			"compose.prod.yml spells it. An argument carrying an '@' is read as the server,",
			"so a service name cannot contain one.")
	}
	if len(o.Command) == 0 {
		return cli.Fail("exec: nothing after the '--' — there is no command to run").Cont(
			"`kasbah exec "+o.Service+" -- sh -c 'ls -la'`. kasbah runs no default shell:",
			"which one an image has is the image's business, not kasbah's.")
	}
	return nil
}

// Session is what the two need from a server.
type Session interface {
	Marker() (*marker.Marker, error)
	// Stream runs words with this process's stdout and stderr; with tty, a
	// pty and stdin too. It returns the remote status, 128+N for a signal;
	// an error is a command that never ran.
	Stream(tty bool, words ...string) (int, error)
	Close()
}

// SSH is the real Session.
type SSH struct{ *env.SSH }

// Dial connects; Marker ensures the server's binary.
func Dial(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

// Stream runs words over the session's master.
func (s *SSH) Stream(tty bool, words ...string) (int, error) {
	var cmd *exec.Cmd
	if tty {
		cmd = s.Conn.TTY(words...)
	} else {
		cmd = s.Conn.Command(words...)
		cmd.Stdout = os.Stdout
	}
	return Wait(cmd)
}

// Wait runs cmd to its end holding any signal — forwarded to it, not acted
// on — so the caller still decides what to record. Its status is the child's,
// 128+N for a child killed by N, or 128+N when this process was signalled.
func Wait(cmd *exec.Cmd) (int, error) {
	if err := cmd.Start(); err != nil {
		return 0, cli.Fail("could not run ssh: %v", err)
	}
	release := atexit.Hold(func(sig os.Signal) { cmd.Process.Signal(sig) })
	err := cmd.Wait()
	release()
	if c := atexit.Interrupted(); c != 0 {
		return c, nil
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
			return 128 + int(ws.Signal()), nil
		}
		return ee.ExitCode(), nil
	}
	if err != nil {
		return 0, cli.Fail("ssh did not finish: %v", err)
	}
	return 0, nil
}

// signalled is the line kasbah adds when the status is its own signal's.
func signalled(cmd string, rc int) string {
	return fmt.Sprintf("%s: kasbah was stopped by signal %d (%v) — exit %d is that, not the remote command's", cmd, rc-128, syscall.Signal(rc-128), rc)
}

// Ctx is what a run needs from its process.
type Ctx struct {
	Out     *cli.Output
	Version string
	// TTY: stdin and stdout are both terminals. Fed: stdin is a pipe or a
	// regular file.
	TTY, Fed bool
	Dial     func(target string) (Session, error)
	// Interrupted is the signal status this process received, 0 for none;
	// nil is atexit.Interrupted.
	Interrupted func() int
}

// Run is the command; it returns the exit status to leave with.
func Run(c Ctx, o Options) (int, error) {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return 0, err
	}
	if c.Interrupted == nil {
		c.Interrupted = atexit.Interrupted
	}
	target := o.Target
	if target == "" {
		stored, err := state.Get(state.File, "last_server")
		if err != nil {
			return 0, err
		}
		if stored == "" || stored == "null" {
			return 0, cli.Fail("%s: no server given, and this project has never deployed to one", o.Cmd).Cont(
				"pass it once — `kasbah "+o.Cmd+" user@vps …` — and it is remembered in",
				state.File+" as last_server")
		}
		target = stored
	}
	s, err := c.Dial(target)
	if err != nil {
		return 0, err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return 0, err
	}
	dir := mk.AppsPath + "/" + m.Name
	dc := []string{"docker", "compose", "-f", dir + "/compose.yml", "-p", m.Name}

	if o.Cmd == "exec" {
		var rc int
		var err error
		if c.TTY {
			rc, err = s.Stream(true, append(append(dc, "exec", o.Service), o.Command...)...)
		} else {
			if c.Fed {
				c.Out.Warn("exec: stdin is not forwarded, and this one is a pipe or a file — the command will read EOF")
				c.Out.Warn("  with no terminal here, exec runs `docker compose exec -T` with stdin closed")
				c.Out.Warn("  (docs/cli.md → kasbah exec). Put the data inside the command instead:")
				c.Out.Warn("  kasbah exec %s -- sh -c 'printf %%s \"$DATA\" | %s …'", o.Service, o.Command[0])
			}
			rc, err = s.Stream(false, append(append(dc, "exec", "-T", o.Service), o.Command...)...)
		}
		s.Close()
		if err != nil {
			return 0, err
		}
		// The command ran: whatever it answered is about the container.
		if err := state.Record(state.File, c.Version, "last_server", target); err != nil {
			return 0, err
		}
		if sig := c.Interrupted(); sig != 0 && sig == rc && rc != 130 {
			c.Out.Warn("%s", signalled("exec", rc))
		}
		return rc, nil
	}

	words := append(dc, "logs", "--tail="+o.Tail)
	if o.Follow {
		words = append(words, "-f")
	}
	if o.Service != "" {
		words = append(words, o.Service)
	}
	rc, err := s.Stream(false, words...)
	s.Close()
	if err != nil {
		return 0, err
	}
	if sig := c.Interrupted(); sig != 0 && sig == rc && rc != 130 {
		return 0, cli.Failf(rc, "%s", signalled("logs", rc)).Cont("the log was cut short; compose did not fail, and last_server is not recorded")
	}
	switch rc {
	// 255 is ssh writing into a reader that closed the pipe (OpenSSH ignores
	// SIGPIPE); 130 is an interrupt. Both stopped the run; neither failed it.
	case 0, 255, 130:
	default:
		e := cli.Fail("could not read the logs of %s on %s", m.Name, target).Cont(
			fmt.Sprintf("`docker compose -p %s logs` exited %d in %s (see above).", m.Name, rc, dir))
		if o.Service != "" {
			e.Cont(fmt.Sprintf("'%s' is the service as compose.prod.yml spells it — `kasbah logs %s` shows every one.", o.Service, target))
		}
		return 0, e
	}
	if err := state.Record(state.File, c.Version, "last_server", target); err != nil {
		return 0, err
	}
	return rc, nil
}
