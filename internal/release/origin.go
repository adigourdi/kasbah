package release

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/term"
)

// OriginTimeout bounds a call to origin when there is no terminal; with one,
// the operator may be at a credential prompt, and only ssh's connect timeout
// (sshConnect seconds) applies.
var (
	OriginTimeout = 60 * time.Second
	sshConnect    = "15"
)

// HasOrigin is whether the repository has an 'origin' remote.
func HasOrigin() bool { return exec.Command("git", "remote", "get-url", "origin").Run() == nil }

// originResult is one call to origin: git's exit code (-1 when it timed out or
// never ran) and what it said on stderr.
type originResult struct {
	out    []byte
	rc     int
	stderr []string
}

// failure is what to show for a failed call.
func (r originResult) failure() []string {
	if len(r.stderr) == 0 {
		return []string{fmt.Sprintf("  git exited %d and said nothing", r.rc)}
	}
	return r.stderr
}

// origin runs git against origin. Without a terminal on stdin nothing can be
// answered, so git and ssh are told not to ask and the call is bounded.
func origin(args ...string) originResult {
	tty := term.IsTerminal(os.Stdin.Fd())
	ctx, cancel := context.Background(), func() {}
	if !tty {
		ctx, cancel = context.WithTimeout(ctx, OriginTimeout)
	}
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	cmd.Env = os.Environ()
	if s := sshCommand(tty); s != "" {
		cmd.Env = append(cmd.Env, "GIT_SSH_COMMAND="+s)
	}
	if tty {
		cmd.Stdin = os.Stdin
	} else {
		cmd.Env = append(cmd.Env, "GIT_TERMINAL_PROMPT=0")
		// Its own group, so the timeout takes ssh down with git.
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
		cmd.WaitDelay = 2 * time.Second
	}
	err := cmd.Run()
	r := originResult{out: out.Bytes()}
	for _, l := range strings.Split(strings.TrimSpace(strings.ReplaceAll(errb.String(), "\r", "")), "\n") {
		if l != "" {
			r.stderr = append(r.stderr, "  git: "+l)
		}
	}
	var ee *exec.ExitError
	switch {
	case ctx.Err() != nil:
		r.rc = -1
		r.stderr = append([]string{fmt.Sprintf("git gave no answer within %s", OriginTimeout)}, r.stderr...)
	case err == nil:
	case errors.As(err, &ee):
		r.rc = ee.ExitCode()
	default:
		r.rc = -1
	}
	return r
}

// sshCommand is the operator's ssh command (GIT_SSH_COMMAND, else
// core.sshCommand, else ssh) with a connect timeout and, without a terminal,
// BatchMode appended. "" leaves it alone: a GIT_SSH program, or a command
// whose program is not ssh, whose arguments kasbah cannot know the shape of.
func sshCommand(tty bool) string {
	opts := " -o ConnectTimeout=" + sshConnect
	if !tty {
		opts = " -o BatchMode=yes" + opts
	}
	s := os.Getenv("GIT_SSH_COMMAND")
	if s == "" {
		if out, err := exec.Command("git", "config", "core.sshCommand").Output(); err == nil {
			s = strings.TrimSpace(string(out))
		}
	}
	if s == "" {
		if os.Getenv("GIT_SSH") != "" {
			return ""
		}
		s = "ssh"
	}
	if f := strings.Fields(s); len(f) == 0 || filepath.Base(f[0]) != "ssh" {
		return ""
	}
	return s + opts
}

// onOrigin is whether origin has tag: rc 2 from --exit-code is "no".
func onOrigin(out *cli.Output, tag string) (bool, originResult) {
	out.Info("asking origin whether %s exists…", tag)
	r := origin("ls-remote", "--exit-code", "--tags", "origin", "refs/tags/"+tag)
	return r.rc == 0, r
}

// Push pushes the version tag last, once what it names is on the server
// (landed says what is). What it did is returned for the summary under the
// headline, a failed push included.
func Push(out *cli.Output, version string, push bool, landed string) (string, error) {
	tag := "v" + version
	if !push {
		return tag + " left where it is (--no-git-push)", nil
	}
	if !HasOrigin() {
		out.Warn("this repository has no 'origin' remote, so %s was not pushed — %s regardless; push the tag wherever this project lives", tag, landed)
		return tag + " not pushed — this repository has no 'origin' remote", nil
	}
	there, r := onOrigin(out, tag)
	if there {
		return tag + " is already on origin", nil
	}
	if r.rc == 2 {
		out.Info("pushing %s to origin…", tag)
		if r = origin("push", "origin", "refs/tags/"+tag); r.rc == 0 {
			return "pushed " + tag + " to origin", nil
		}
	}
	return tag + " NOT pushed — origin could not be reached or refused it (see below)", cli.Fail("could not push %s to origin:", tag).Cont(r.failure()...).Cont(
		landed+" and none of that needs redoing —",
		"push the tag once the remote is reachable:  git push origin "+tag)
}
