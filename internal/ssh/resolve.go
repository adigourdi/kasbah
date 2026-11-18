package ssh

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/launcher"
	"github.com/adigourdi/kasbah/internal/trace"
)

// sshG is the command whose `user` line names the login for a bare host;
// tests point it at a scratch config with -F.
var sshG = []string{"ssh", "-G"}

// UserOf is the user ssh logs in to a bare host as, and Note prints the line
// saying so — not again in a process a hand-off started, whose parent did;
// parser tests replace both.
var (
	UserOf = sshUser
	Note   = func(line string) {
		if os.Getenv(launcher.Env) == "" {
			cli.Std().Info("%s", line)
		}
	}
)

// reVersion is an argument shaped like a version: X.Y.Z with a pre-release or
// build suffix, or v and anything starting X.Y.Z. A dotted quad is neither.
var reVersion = regexp.MustCompile(`^(v[0-9]+\.[0-9]+\.[0-9]+|[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$)`)

// LooksVersion is arg shaped like a version, v-prefixed or not.
func LooksVersion(arg string) bool { return reVersion.MatchString(arg) }

// ResolveTarget is cmd's server argument s as USER@HOST: '@' as given (Connect
// checks it), a bare host with the user `ssh -G` names, said once on stderr,
// and a resolved root refused, so root owns nothing nobody typed.
func ResolveTarget(cmd, s string) (string, error) {
	s = strings.TrimSuffix(s, "\r")
	if s == "" || strings.Contains(s, "@") {
		return s, nil
	}
	if LooksVersion(s) {
		return "", cli.Fail("%s: '%s' reads as a version, and %s takes no version", cmd, s, cmd).
			Next(fmt.Sprintf("If '%s' is a server, pass it as USER@%s.", s, s))
	}
	if !reHost.MatchString(s) {
		return "", cli.Fail("invalid ssh host '%s' (expected [USER@]HOST: a hostname, ssh alias or IPv4 address — no port, no IPv6 literal)", s)
	}
	user, err := UserOf(s)
	if err != nil {
		return "", cli.Fail("could not tell which user ssh logs in to %s as", s).Cause(err).
			Next(fmt.Sprintf("Pass the user yourself: USER@%s.", s)).Help("troubleshooting")
	}
	if user == "root" {
		return "", cli.Fail("ssh logs in to %s as root, and kasbah takes root only when it is typed", s).
			Cont(fmt.Sprintf("root is the User your ssh config gives %s, or your own login when it gives none.", s)).
			Next(fmt.Sprintf("Pass root@%s to work as root, or USER@%s with the operator kasbah acts as.", s, s)).
			Help("troubleshooting")
	}
	t := user + "@" + s
	Note(fmt.Sprintf("kasbah: as %s (user from ssh config)", t))
	return t, nil
}

// sshUser is the `user` line of `ssh -G host`.
func sshUser(host string) (string, error) {
	args := append(append([]string{}, sshG[1:]...), "--", host)
	out, err := trace.Output(exec.Command(sshG[0], args...))
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if msg := strings.TrimSpace(strings.ReplaceAll(string(ee.Stderr), "\r", "")); msg != "" {
				return "", fmt.Errorf("`ssh -G %s` failed: %s", host, msg)
			}
		}
		return "", fmt.Errorf("`ssh -G %s` failed: %w", host, err)
	}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		k, v, _ := strings.Cut(strings.TrimSuffix(sc.Text(), "\r"), " ")
		if k != "user" {
			continue
		}
		if v = strings.TrimSpace(v); !reUser.MatchString(v) {
			return "", fmt.Errorf("`ssh -G %s` names the user '%s', which kasbah does not take", host, v)
		}
		return v, nil
	}
	return "", fmt.Errorf("`ssh -G %s` printed no user line", host)
}
