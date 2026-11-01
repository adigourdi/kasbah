package env

import (
	"bytes"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/treesync"
)

// SSH is the Session a real run uses: one ssh master, and the server's own
// kasbah binary — this build's or a newer one of its major — answering
// `kasbah remote setup-env`.
type SSH struct {
	Conn  *ssh.Conn
	Self  remote.Info
	Local func(arch string) (string, error)
	bin   string
}

// DialSSH connects; the binary is ensured by Marker.
func DialSSH(self remote.Info, local func(arch string) (string, error)) func(string) (Session, error) {
	return func(target string) (Session, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{Conn: c, Self: self, Local: local}, nil
	}
}

// DialSetSSH is DialSSH for `kasbah env set`.
func DialSetSSH(self remote.Info, local func(arch string) (string, error)) func(string) (SetSession, error) {
	return func(target string) (SetSession, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{Conn: c, Self: self, Local: local}, nil
	}
}

func (s *SSH) target() string { return s.Conn.Target.String() }

// Marker is the server's validated marker, judged before the binary ships
// (serverbin.EnsurePrepared; a server with none is refused, exit 4).
func (s *SSH) Marker() (*marker.Marker, error) {
	res, mk, err := serverbin.EnsurePrepared(s.Conn, s.Self, s.Local)
	if err != nil {
		return nil, err
	}
	s.bin = serverbin.Path(res.Apps)
	return mk, nil
}

// HoldServer holds the server lock shared until release, so no server-wide
// step runs anywhere in a deploy, rollback or drop; known once Marker has run.
func (s *SSH) HoldServer(apps, what string) (func(), error) {
	return serverlock.Hold(s.Conn, s.bin, apps, serverlock.Shared, what)
}

// Bin is the server binary's path, known once Marker has run.
func (s *SSH) Bin() string { return s.bin }

// Bounded is bounded, for the other commands riding this session.
func (s *SSH) Bounded(args ...string) []string { return s.bounded(args...) }

func (s *SSH) bounded(args ...string) []string {
	return serverbin.Bounded(s.bin, serverbin.RunTimeout, args...)
}

// Prepare creates the project directory, so the template has somewhere to land.
func (s *SSH) Prepare(dir string) error {
	out, err := s.Conn.Run(s.bounded("setup-env", "prepare", dir)...)
	if err != nil {
		return cli.Fail("could not prepare %s on %s (%s, see above)", dir, s.target(), exitText(ssh.ExitCode(err)))
	}
	if !strings.Contains(string(out), "prepared=yes") {
		return cli.Fail("the prepare step on %s reported no prepared (raw output: %s)", s.target(), strings.TrimSpace(string(out)))
	}
	return nil
}

// ShipTemplate ships the template beside where .env goes: links as links,
// mode and mtime kept (`rsync -lpt`).
func (s *SSH) ShipTemplate(local, dir string) error {
	src, err := treesync.File(local, os.Stderr)
	if err == nil {
		err = treesync.Push(s.Conn, s.bin, src, dir+"/.env.prod.example")
	}
	if err != nil {
		return cli.Fail("could not ship .env.prod.example to %s:%s/", s.target(), dir).Cont(err.Error())
	}
	return nil
}

func (s *SSH) Drift(dir string) (string, int) {
	out, err := s.Conn.Run(s.bounded("setup-env", "drift", dir)...)
	return string(out), ssh.ExitCode(err)
}

// Setup hands this terminal to the server's setup over ssh -t, unbounded since
// it waits on the operator. A headless one asks nothing and is bounded; its
// seed rides on stdin, never argv, and its progress goes to stderr.
func (s *SSH) Setup(dir string, f SetupFlags) int {
	args := []string{"setup-env", "setup", dir, "--color=no"}
	if f.Color {
		args[3] = "--color=yes"
	}
	if f.TTY {
		if f.Token != "" {
			args = append(args, "--seed="+f.Token)
		}
		return ssh.ExitCode(s.Conn.TTY(append([]string{s.bin, "remote"}, args...)...).Run())
	}
	args = append(args, "--headless")
	var stdin string
	if f.Seed != nil {
		args = append(args, "--seed")
		stdin = SetHeader(string(f.Seed)) + string(f.Seed)
	}
	cmd := s.Conn.Command(s.bounded(args...)...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Stdout = os.Stderr
	return ssh.ExitCode(cmd.Run())
}

// StageSeed sends SetHeader and the seed on stdin, never on argv.
func (s *SSH) StageSeed(dir, token string, data []byte) error {
	cmd := s.Conn.Command(s.bounded("setup-env", "seed", dir, token)...)
	cmd.Stdin = strings.NewReader(SetHeader(string(data)) + string(data))
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return cli.Fail("could not stage the env seed in %s on %s (%s, see above)", dir, s.target(), exitText(ssh.ExitCode(err)))
	}
	if !strings.Contains(out.String(), "staged=yes") {
		return cli.Fail("the seed step on %s reported no staged (raw output: %s)", s.target(), strings.TrimSpace(out.String()))
	}
	return nil
}

func (s *SSH) Inject(dir string, pairs []string) int {
	_, err := s.Conn.Run(s.bounded(append([]string{"setup-env", "inject", dir}, pairs...)...)...)
	return ssh.ExitCode(err)
}

func (s *SSH) Limits(cpus, memory string) (string, int) {
	out, err := s.Conn.Run(s.bounded("setup-env", "limits", cpus, memory)...)
	return string(out), ssh.ExitCode(err)
}

func (s *SSH) KeyState(dir, key string) (string, int) {
	out, err := s.Conn.Run(s.bounded("setup-env", "key", dir, key)...)
	return string(out), ssh.ExitCode(err)
}

// SetKey sends SetHeader and the value on stdin, never on argv; bringing the
// project up is bounded by UpTimeout.
func (s *SSH) SetKey(dir, key, value, up string) (string, int) {
	args, limit := []string{"setup-env", "set", dir, key}, serverbin.RunTimeout
	if up != "" {
		args, limit = append(args, "--up="+up), UpTimeout
	}
	cmd := s.Conn.Command(serverbin.Bounded(s.bin, limit, args...)...)
	cmd.Stdin = strings.NewReader(SetHeader(value) + value)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), ssh.ExitCode(err)
}

func (s *SSH) Close() { s.Conn.Close() }
