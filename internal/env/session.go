package env

import (
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

// Setup hands this terminal to the server's setup over ssh -t; it waits on
// the operator, so it has no time limit.
func (s *SSH) Setup(dir string, color bool) int {
	c := "--color=no"
	if color {
		c = "--color=yes"
	}
	return ssh.ExitCode(s.Conn.TTY(s.bin, "remote", "setup-env", "setup", dir, c).Run())
}

func (s *SSH) Inject(dir string, pairs []string) int {
	_, err := s.Conn.Run(s.bounded(append([]string{"setup-env", "inject", dir}, pairs...)...)...)
	return ssh.ExitCode(err)
}

func (s *SSH) Close() { s.Conn.Close() }
