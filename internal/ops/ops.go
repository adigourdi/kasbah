// Package ops is `kasbah logs` and `kasbah exec`: one `docker compose` on the
// server, streamed over ssh. The one write is last_server in the state file.
package ops

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/composefile"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/trace"
)

// ErrHelp is --help: the usage on stdout, exit 0.
var ErrHelp = errors.New("help")

// Options are one command's arguments. Command is everything after `--`,
// verbatim. Word is a lone bare positional beside no '@' server: the service
// when compose.prod.yml names it, else the server (Run settles it).
type Options struct {
	Cmd             string
	Target, Service string
	Word            string
	Follow          bool
	Tail            string
	DDash           bool
	Command         []string
	words           []string
}

const logsUsage = `Usage: kasbah logs [[USER@]HOST] [SERVICE] [-f] [--tail=N]

` + "`docker compose logs`" + ` for this project on a server, run against
<apps>/<name>/compose.yml as ` + "`docker compose -p <name>`" + `. Run from the project
root. [USER@]HOST defaults to the last server this project talked to
(.kasbah/state.json); with SERVICE omitted, every service in the project.

The server comes before the service. An argument carrying an '@' is the
server; of two without one, the first is the server; one alone is the service
when compose.prod.yml, or a file its include: names, has a service of that
name — a service wins over an ssh alias spelled the same — and the server
otherwise, which is said on stderr. A bare host takes its user from ssh's
config.

Flags:
  -f           follow, until interrupted
  --tail=N     lines of history per service (default 100; --tail=all for all)

The output is compose's own, unaltered, on stdout: no terminal is allocated for
it, so ` + "`kasbah logs | grep …`" + ` gets the lines rather than a pty's CRs.

Reads the server and writes nothing to it but kasbah's own binary, installed
when the server's is absent or older. See docs/cli.md.
`

const execUsage = `Usage: kasbah exec [[USER@]HOST] SERVICE -- CMD…

` + "`docker compose exec SERVICE CMD…`" + ` on a server, against
<apps>/<name>/compose.yml as ` + "`docker compose -p <name>`" + `. Run from the project
root. [USER@]HOST defaults to the last server this project talked to
(.kasbah/state.json).

The '--' is mandatory: it is what makes a flag in CMD belong to CMD rather than
to kasbah, so ` + "`kasbah exec web -- ls -la`" + ` lists a directory instead of being
refused for an unknown '-la'.

SERVICE is required, and comes after the server. An argument carrying an '@'
is the server, so a service name may not contain one; of two without one, the
first is the server; one alone is the service when compose.prod.yml, or a file
its include: names, has a service of that name, and the server otherwise. A
bare host takes its user from ssh's config.

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

// lead is what comes before the service on a command line built for a hint.
func (o *Options) lead() string {
	if o.Target == "" && len(o.words) == 2 {
		return lead(o.words[0])
	}
	return lead(o.Target)
}

func lead(server string) string {
	if server == "" {
		return ""
	}
	return server + " "
}

// service is the service as far as the arguments read so far tell it.
func (o *Options) service() string {
	if o.Service != "" {
		return o.Service
	}
	if n := len(o.words); n > 0 {
		return o.words[n-1]
	}
	return ""
}

// classify gathers the positionals both commands share: an argument carrying
// an '@' is the server, and at most two others — the server, then the
// service — are taken, one only beside an '@' server.
func (o *Options) classify(arg string) error {
	arg = strings.TrimSuffix(arg, "\r")
	if strings.Contains(arg, "@") {
		if o.Target != "" || len(o.words) == 2 {
			first := o.Target
			if first == "" {
				first = o.words[0]
			}
			return ssh.TwoServers(o.Cmd, first, arg)
		}
		o.Target = arg
		return nil
	}
	if len(o.words) == 2 || (o.Target != "" && len(o.words) == 1) {
		svc := o.service()
		if o.Cmd == "exec" {
			return cli.Fail("exec: '%s' comes after the service '%s', and there is no '--' between them", arg, svc).Cont(
				"the command to run goes after '--':",
				fmt.Sprintf("  kasbah exec %s%s -- %s …", o.lead(), svc, arg),
				"without it kasbah would have to guess which of its own flags are yours.")
		}
		return cli.Fail("%s: two services given ('%s' and '%s') — kasbah will not choose between them", o.Cmd, svc, arg)
	}
	o.words = append(o.words, arg)
	return nil
}

func (o *Options) execUnknownFlag(a string) error {
	name, _, _ := strings.Cut(a, "=")
	e := cli.Fail("exec: unknown flag '%s'", name)
	if o.Target == "" && len(o.words) == 2 {
		return e.Cont("if it belongs to the command you want to run, it goes after '--'.").Cont(o.readings(a)...)
	}
	if svc := o.service(); svc != "" {
		return e.Cont("if it belongs to the command you want to run, it goes after '--':",
			fmt.Sprintf("  kasbah exec %s%s -- <cmd> %s …", o.lead(), svc, a))
	}
	return e.Cont("exec takes [USER@]HOST, SERVICE, then '--' and the command to run:",
		"  kasbah exec [[USER@]HOST] SERVICE -- CMD…")
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
// here too, before the manifest is read. A server the positions name is
// resolved here, through ssh's config; a lone bare word is left to Run.
func Parse(cmd string, args []string) (Options, error) {
	o := Options{Cmd: cmd, Tail: "100"}
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case a == "--":
			if cmd != "exec" {
				return o, cli.Fail("logs: '--' separates kasbah's flags from a command to run, and logs runs none (`kasbah logs [[USER@]HOST] [SERVICE] [-f] [--tail=N]`)")
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
				return o, cli.Fail("logs: -f takes no value — pass it on its own (`kasbah logs HOST -f`)")
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
				return o, cli.Fail("logs: unknown flag '%s' (logs takes [USER@]HOST, SERVICE, -f and --tail=N)", name)
			}
			return o, o.execUnknownFlag(a)
		default:
			if err := o.classify(a); err != nil {
				return o, err
			}
		}
	}
	host := ""
	switch {
	case len(o.words) == 2:
		host, o.Service = o.words[0], o.words[1]
	case len(o.words) == 1 && o.Target != "":
		o.Service = o.words[0]
	case len(o.words) == 1:
		o.Word = o.words[0]
	}
	if cmd == "exec" {
		if err := o.requireExec(); err != nil {
			return o, err
		}
	}
	if host != "" {
		var err error
		o.Target, err = ssh.ResolveTarget(cmd, host)
		return o, err
	}
	return o, nil
}

func (o *Options) requireExec() error {
	if !o.DDash {
		e := cli.Fail("exec: no '--' in the arguments, and the command to run goes after it")
		switch {
		case o.Target == "" && len(o.words) == 2:
			e.Cont(o.readings("")...)
		case o.service() == "":
			e.Cont("`kasbah exec [[USER@]HOST] SERVICE -- CMD…`, for example:",
				"  kasbah exec "+o.lead()+"web -- sh -c 'ls -la /srv'")
		default:
			e.Cont("`kasbah exec [[USER@]HOST] SERVICE -- CMD…`, for example:",
				"  kasbah exec "+o.lead()+o.service()+" -- sh -c 'ls -la /srv'")
		}
		return e.Cont("the '--' is mandatory because it is what makes a flag in CMD belong to CMD",
			"rather than to kasbah.").Help("exec")
	}
	if o.service() == "" {
		return noService(o.Target, false)
	}
	if len(o.Command) == 0 {
		return cli.Fail("exec: nothing after the '--' — there is no command to run").Cont(
			"`kasbah exec "+o.lead()+o.service()+" -- sh -c 'ls -la'`. kasbah runs no default shell:",
			"which one an image has is the image's business, not kasbah's.")
	}
	return nil
}

// readings is what two bare words before a missing '--' may mean, flag after
// them: service then command, or server then service — only the one
// compose.prod.yml bears out when it names either word.
func (o *Options) readings(flag string) []string {
	w0, w1 := o.words[0], o.words[1]
	asService := "  kasbah exec " + w0 + " -- " + w1 + " …"
	asServer := "  kasbah exec " + w0 + " " + w1 + " -- CMD…"
	if flag != "" {
		asService = "  kasbah exec " + w0 + " -- " + w1 + " " + flag + " …"
		asServer = "  kasbah exec " + w0 + " " + w1 + " -- CMD " + flag + " …"
	}
	if names, err := readServices("", ""); err == nil {
		switch {
		case slices.Contains(names, w0):
			return []string{fmt.Sprintf("'%s' is a service of compose.prod.yml, so the command is what follows it:", w0), asService}
		case slices.Contains(names, w1):
			return []string{fmt.Sprintf("'%s' is a service of compose.prod.yml, so '%s' is the server:", w1, w0), asServer}
		}
	}
	return []string{fmt.Sprintf("with '%s' the service and '%s' the command:", w0, w1), asService,
		fmt.Sprintf("or with '%s' the server and '%s' the service:", w0, w1), asServer}
}

// readServices is the services compose.prod.yml, in the working directory,
// declares, those of the files its include: names among them.
func readServices(pwd, why string) ([]string, error) {
	doc, err := buildpush.ReadCompose(pwd, why)
	if err != nil {
		return nil, err
	}
	names, err := composefile.AllServices(".", doc)
	if err != nil {
		return nil, fmt.Errorf("compose.prod.yml: %w", err)
	}
	return names, nil
}

// noService is exec's refusal of a run that names no service; server is the
// one it names, "" for none, and bare says compose.prod.yml has no service
// of that name.
func noService(server string, bare bool) error {
	e := cli.Fail("exec: no service given — `kasbah exec [[USER@]HOST] SERVICE -- CMD…`")
	switch {
	case bare:
		e = cli.Fail("exec: no service given — compose.prod.yml has no service '%s', so it is the server", server)
	case server != "":
		e = cli.Fail("exec: no service given — '%s' is the server", server)
	}
	return e.Cont(
		"the service is the one `docker compose exec` runs the command in, named as",
		"compose.prod.yml spells it, after the server. An argument carrying an '@' is",
		"read as the server, so a service name cannot contain one.").
		Next("Name the service: `kasbah exec " + lead(server) + "SERVICE -- CMD…`.")
}

// settle decides a lone bare word: the service when compose.prod.yml, read
// here, has a service of that name, else the server, resolved through ssh's
// config.
func (o *Options) settle(pwd string) error {
	w := o.Word
	if w == "" {
		return nil
	}
	names, err := readServices(pwd, "run "+o.Cmd+" from the project root")
	if err != nil {
		e := cli.Fail("%s: cannot tell whether '%s' is a service or the server", o.Cmd, w).Cause(err)
		var ce *cli.Error
		if errors.As(err, &ce) {
			e.Carry(ce)
		}
		if o.Cmd == "exec" {
			return e.Next(fmt.Sprintf("Name the server before it, `kasbah exec HOST %s -- CMD…`, or, with '%s' the server, write it USER@%s before the service: `kasbah exec USER@%s SERVICE -- CMD…`.", w, w, w, w))
		}
		return e.Next(fmt.Sprintf("Name the server before it, `kasbah logs HOST %s`, or the server alone as USER@%s.", w, w))
	}
	o.Word = ""
	switch {
	case slices.Contains(names, w):
		o.Service = w
	case !ssh.Hostlike(w):
		_, err = ssh.ResolveTarget(o.Cmd, w)
	case o.Cmd == "exec":
		return noService(w, true)
	default:
		ssh.Note(fmt.Sprintf("kasbah: '%s' is no service of compose.prod.yml — taken as the server", w))
		o.Target, err = ssh.ResolveTarget(o.Cmd, w)
	}
	return err
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
	if err := trace.Start(cmd); err != nil {
		return 0, cli.Fail("could not run ssh: %v", err)
	}
	release := atexit.Hold(func(sig os.Signal) { cmd.Process.Signal(sig) })
	held()
	err := trace.Wait(cmd)
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

// held runs once Wait's hold is in place; a test's signal waits for it.
var held = func() {}

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
	pwd, _ := os.Getwd()
	if err := o.settle(pwd); err != nil {
		return 0, err
	}
	if c.Interrupted == nil {
		c.Interrupted = atexit.Interrupted
	}
	target, _, err := state.Server(o.Target, o.Cmd, "kasbah "+o.Cmd+" user@vps …")
	if err != nil {
		return 0, err
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
				c.Out.Warn("  (kasbah help exec). Put the data inside the command instead:")
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
