// Package ssh is the transport: one multiplexed master per Conn — a command
// opens one Conn per run — over the system's own ssh, so the user's config,
// agent and jump hosts apply as they do to `ssh USER@HOST`.
package ssh

import (
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
	"sync"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/trace"
)

// CtlPathMax is the longest ControlPath a master can bind here.
var CtlPathMax = PathMax(runtime.GOOS)

// PathMax is the ControlPath budget on goos: sun_path (108 bytes on linux,
// 104 on macOS and the BSDs) less the NUL and the `.<16 random chars>` the
// master binds before renaming. Measured on linux, OpenSSH 9.6p1: 90 connects, 91 fails.
func PathMax(goos string) int {
	if goos == "linux" {
		return 90
	}
	return 86
}

// Target is USER@HOST.
type Target struct{ User, Host string }

func (t Target) String() string { return t.User + "@" + t.Host }

var (
	reUser = regexp.MustCompile(`^[A-Za-z0-9._-]+$`)
	reHost = regexp.MustCompile(`^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$`)
)

// ParseTarget splits USER@HOST. The host is anything ssh's config resolves,
// but a port suffix or an IPv6 literal is refused: ssh would report it as a
// failed lookup of a host named "vps:2222".
func ParseTarget(s string) (Target, error) {
	s = strings.TrimSuffix(s, "\r")
	if s == "" {
		return Target{}, cli.Fail("no target given (expected USER@HOST)")
	}
	user, host, ok := strings.Cut(s, "@")
	if !ok {
		return Target{}, cli.Fail("invalid target '%s' (expected USER@HOST — the user kasbah deploys as is not optional)", s)
	}
	if !reUser.MatchString(user) {
		return Target{}, cli.Fail("invalid ssh user '%s' in '%s'", user, s)
	}
	if !reHost.MatchString(host) {
		return Target{}, cli.Fail("invalid ssh host '%s' in '%s' (expected a hostname, ssh alias or IPv4 address — no port, no IPv6 literal)", host, s)
	}
	return Target{User: user, Host: host}, nil
}

// Quote quotes a command word by word for the remote shell. `ssh host cmd
// args` re-joins its arguments with spaces for a login shell, so unquoted
// words would arrive split and with their quoting gone.
func Quote(words ...string) string {
	q := make([]string, len(words))
	for i, w := range words {
		q[i] = "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
	}
	return strings.Join(q, " ")
}

// tmpBase is the directory the control directory goes under: TMPDIR, else
// /tmp. A space is refused because ssh splits a ControlPath option on spaces,
// a `%` because ssh reads it in a ControlPath as a token.
func tmpBase(getenv func(string) string) (string, error) {
	tmp := getenv("TMPDIR")
	if tmp != "/" {
		tmp = strings.TrimSuffix(tmp, "/")
	}
	if tmp == "" {
		tmp = "/tmp"
	}
	if strings.ContainsAny(tmp, " \t\n\v\f\r") {
		return "", cli.Fail("TMPDIR ('%s') contains whitespace, and the ssh control socket goes there — ssh splits a ControlPath option on spaces (set TMPDIR to a path without any)", tmp)
	}
	if strings.Contains(tmp, "%") {
		return "", cli.Fail("TMPDIR ('%s') contains a '%%', and the ssh control socket goes there — ssh reads '%%' in a ControlPath as a token (set TMPDIR to a path without one)", tmp)
	}
	if fi, err := os.Stat(tmp); err != nil || !fi.IsDir() {
		return "", cli.Fail("TMPDIR is '%s', which is not a directory — the ssh control socket has nowhere to live", tmp)
	}
	return tmp, nil
}

// ctlPath is the socket's path in dir, refused when over the budget.
func ctlPath(dir string, seq int) (string, error) {
	p := fmt.Sprintf("%s/m%d", dir, seq)
	if len(p) > CtlPathMax {
		return "", cli.Fail("the ssh control socket path '%s' is %d characters, over the %d an ssh master can bind — point TMPDIR at a shorter directory", p, len(p), CtlPathMax)
	}
	return p, nil
}

const alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

// mkCtlDir is mktemp -d's `kasbah-ssh.XXXXXX`, 0700. The name is private
// because `-O exit` closes every session riding a master, whoever opened it.
func mkCtlDir(base string) (string, error) {
	for range 100 {
		b := make([]byte, 6)
		if _, err := rand.Read(b); err != nil {
			return "", err
		}
		for i := range b {
			b[i] = alnum[int(b[i])%len(alnum)]
		}
		dir := filepath.Join(base, "kasbah-ssh."+string(b))
		err := os.Mkdir(dir, 0o700)
		if err == nil {
			return dir, os.Chmod(dir, 0o700)
		}
		if !errors.Is(err, os.ErrExist) {
			return "", err
		}
	}
	return "", errors.New("no unused name")
}

// Conn is one ControlMaster and the options every call over it shares.
type Conn struct {
	Target Target
	dir    string
	path   string
	opts   []string

	mu        sync.Mutex
	connected bool
	popExit   func()
	// sameBuild: the server's binary is this build, so its arms take
	// trace.Marker and send their trace back.
	sameBuild bool
}

// SameBuild records that the server runs this build (serverbin.Ensure).
func (c *Conn) SameBuild() { c.sameBuild = true }

// describe registers cmd with the trace as a call of words over ssh.
func (c *Conn) describe(cmd *exec.Cmd, how string, words []string, noTee bool) *exec.Cmd {
	desc := "ssh" + how + " " + c.Target.String()
	if len(words) > 0 {
		desc += ": " + trace.Words(words)
	}
	trace.SSH(cmd, desc, c.sameBuild && how == "" && isArm(words), noTee)
	return cmd
}

// isArm is a command line running `kasbah remote …`, however it is wrapped
// (timeout, sudo).
func isArm(words []string) bool {
	for i := 1; i < len(words); i++ {
		if words[i] == "remote" && path.Base(words[i-1]) == "kasbah" {
			return true
		}
	}
	return false
}

// Connect opens the master and proves the host answers, once, before any real
// work. The teardown is registered before the directory exists.
func Connect(target string) (*Conn, error) {
	t, err := ParseTarget(target)
	if err != nil {
		return nil, err
	}
	base, err := tmpBase(os.Getenv)
	if err != nil {
		return nil, err
	}
	c := &Conn{Target: t}
	c.popExit = atexit.Push(c.cleanup)
	// Held across the mkdir, so a signal's cleanup waits for the name it removes.
	c.mu.Lock()
	dir, err := mkCtlDir(base)
	c.dir = dir
	c.mu.Unlock()
	if err != nil {
		c.Close()
		return nil, cli.Fail("could not create a directory under %s for the ssh control socket: %v", base, err)
	}
	path, err := ctlPath(dir, 1)
	if err != nil {
		c.Close()
		return nil, err
	}
	c.path, c.opts = path, Options(path)

	// ssh's own stderr is the reader's diagnosis ("Permission denied
	// (publickey)"); no wrapper message replaces it.
	// Its stderr stays ssh's own: the master this call forks would hold a pipe.
	probe := c.describe(exec.Command("ssh", c.args(true, "true")...), " (connect)", []string{"true"}, true)
	probe.Stderr = os.Stderr
	if err := trace.Run(probe); err != nil {
		c.Close()
		return nil, cli.Failf(cli.ExitSSHUnreachable, "cannot reach %s over ssh (see ssh's own error above)", t)
	}
	c.mu.Lock()
	c.connected = true
	c.mu.Unlock()
	return c, nil
}

// Options are one master's control options: ConnectTimeout outranks the user's
// config, keepalives bound a stalled session at ~60 s, and no BatchMode, so a
// passphrase-protected key with an agent keeps working.
func Options(ctlPath string) []string {
	return []string{
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + ctlPath,
		"-o", "ControlPersist=60s",
		"-o", "ConnectTimeout=10",
		"-o", "ServerAliveInterval=15",
		"-o", "ServerAliveCountMax=4",
	}
}

func (c *Conn) args(noStdin bool, remote string) []string {
	a := []string{}
	if noStdin {
		a = append(a, "-n")
	}
	a = append(a, c.opts...)
	return append(a, c.Target.String(), remote)
}

// Command is one remote command, quoted word by word: `a | b` as one word asks
// for a command of that name. The remote stdin is cmd.Stdin (/dev/null when
// unset); stderr passes through unless the caller replaces it.
func (c *Conn) Command(words ...string) *exec.Cmd {
	cmd := c.describe(exec.Command("ssh", c.args(false, Quote(words...))...), "", words, false)
	cmd.Stderr = os.Stderr
	return cmd
}

// Run runs one remote command with stdin closed, its stderr passed through,
// and returns its stdout.
func (c *Conn) Run(words ...string) ([]byte, error) {
	cmd := c.describe(exec.Command("ssh", c.args(true, Quote(words...))...), "", words, false)
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = os.Stderr
	err := trace.Run(cmd)
	return out.Bytes(), err
}

// Script runs a script on the far side with args as its $1…, the payload on
// stdin so nothing in it is re-quoted. sh, not bash: only the bootstrap is
// shell; remote logic belongs in the Go binary. Stderr passes through.
func (c *Conn) Script(script string, args ...string) *exec.Cmd {
	sh := append([]string{"sh", "-s", "--"}, args...)
	cmd := c.describe(exec.Command("ssh", c.args(false, Quote(sh...))...), " (script on stdin)", sh, false)
	cmd.Stdin = strings.NewReader(script)
	cmd.Stderr = os.Stderr
	return cmd
}

// TTY is one remote command with a terminal: stdin passes through and ssh is
// asked for a pty. Callers refuse without a local terminal first.
func (c *Conn) TTY(words ...string) *exec.Cmd {
	a := append([]string{"-t"}, c.opts...)
	cmd := c.describe(exec.Command("ssh", append(a, c.Target.String(), Quote(words...))...), " -t", words, false)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	return cmd
}

// Close tears the master down and removes its directory; idempotent. `-O
// exit` reaches only this process's sessions, because the path is private.
func (c *Conn) Close() {
	c.cleanup()
	if c.popExit != nil {
		c.popExit()
	}
}

func (c *Conn) cleanup() {
	c.mu.Lock()
	defer c.mu.Unlock()
	// A socket without a finished probe is a master a signal caught mid-connect:
	// left alone, it would outlive the run by its ControlPersist.
	_, serr := os.Stat(c.path)
	if c.connected || (c.path != "" && serr == nil) {
		c.connected = false
		a := append(append([]string{}, c.opts...), "-O", "exit", c.Target.String())
		cmd := c.describe(exec.Command("ssh", a...), " -O exit", nil, false)
		cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
		trace.Run(cmd)
	}
	if c.dir != "" {
		os.RemoveAll(c.dir)
		c.dir = ""
	}
}

// ExitCode is the remote status of a finished ssh: the far side's own code,
// 255 for ssh's failure, -1 when ssh never started or a signal killed it.
func ExitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode()
	}
	return -1
}
