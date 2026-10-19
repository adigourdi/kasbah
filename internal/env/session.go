package env

import (
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
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
		if _, err := exec.LookPath("rsync"); err != nil {
			return nil, cli.Fail("rsync is required (install rsync and retry)")
		}
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{Conn: c, Self: self, Local: local}, nil
	}
}

func (s *SSH) target() string { return s.Conn.Target.String() }

// Marker ships the binary when the server's is absent or older, then has it
// read the marker it found (serverbin refuses a server with none, exit 4).
func (s *SSH) Marker() (*marker.Marker, error) {
	res, err := serverbin.Ensure(s.Conn, s.Self, s.Local, serverbin.Options{})
	if err != nil {
		return nil, err
	}
	s.bin = serverbin.Path(res.Apps)
	path := marker.Path(res.Apps)
	body, err := s.Conn.Run(s.bounded("marker", res.Apps)...)
	if err != nil {
		return nil, cli.Fail("could not read the server marker %s on %s (%s, see above)", path, s.target(), exitText(ssh.ExitCode(err)))
	}
	init := "kasbah server init " + s.target()
	if res.Apps != serverbin.DefaultApps {
		init += " --apps-path=" + res.Apps
	}
	return marker.Validate(body, path, s.target(), init)
}

// bounded is `kasbah remote ARGS…` on the server under a time limit, as every
// non-interactive run of the server binary is.
func (s *SSH) bounded(args ...string) []string {
	return append([]string{"timeout", "-k", "5", strconv.Itoa(serverbin.RunTimeout), s.bin, "remote"}, args...)
}

// Prepare creates the project directory, so rsync has somewhere to land.
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

// ShipTemplate rsyncs the template beside where .env goes: links as links,
// mode and mtime kept.
func (s *SSH) ShipTemplate(local, dir string) error {
	cmd := s.Conn.Rsync("-lpt", "-s", local, s.target()+":"+dir+"/.env.prod.example")
	cmd.Stdout, cmd.Stderr = io.Discard, os.Stderr
	if err := cmd.Run(); err != nil {
		return cli.Fail("could not ship .env.prod.example to %s:%s/", s.target(), dir)
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
