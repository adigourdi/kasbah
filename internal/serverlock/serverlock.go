// Package serverlock is <apps>/.kasbah/server.lock, the server-wide flock,
// taken without waiting: exclusive by init, upgrade-traefik, prune, destroy
// and migrate; shared by deploy, rollback, drop and env set.
package serverlock

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/user"
	"strconv"
	"strings"
	"syscall"
	"unicode"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/ssh"
)

const (
	// Group is the Unix group every operator of a server is in; the apps
	// tree, <data> aside, is its.
	Group     = "kasbah"
	Name      = "server.lock"
	Shared    = "shared"
	Exclusive = "exclusive"
	// Mode is the lock file's: every operator in the kasbah group opens it.
	Mode = 0o664
)

// Path is the lock under an apps path.
func Path(apps string) string { return strings.TrimSuffix(apps, "/") + "/.kasbah/" + Name }

// Who is the user this process runs as — the ssh user, on the server — as
// one versions.log token: a name with whitespace, a control character or `=`
// in it, or none at all, is uid=<n>. It never fails.
func Who() string {
	if u, err := user.Current(); err == nil && safeName(u.Username) {
		return u.Username
	}
	return "uid=" + strconv.Itoa(os.Getuid())
}

func safeName(s string) bool {
	return s != "" && strings.IndexFunc(s, func(r rune) bool {
		return r <= ' ' || r == '=' || r == 0x7f || unicode.IsSpace(r) || unicode.IsControl(r)
	}) < 0
}

// EnsureMode sets path's mode to m only when it differs. Only the owner may
// chmod, so another operator's file at the wrong mode is an error naming its
// owner — one at the right mode is no error at all.
func EnsureMode(path string, m os.FileMode) error {
	fi, err := os.Stat(path)
	if err != nil {
		return fmt.Errorf("could not read %s: %v", path, unwrap(err))
	}
	// Special bits count: a private directory born setgid in the group's
	// tree is put back to the plain mode asked for.
	have := fi.Mode() & (fs.ModePerm | fs.ModeSetuid | fs.ModeSetgid | fs.ModeSticky)
	if have == m {
		return nil
	}
	if !Owned(fi) {
		return fmt.Errorf("%s is mode %o and belongs to %s: only its owner or root can set it to %o — ssh in as %s and run chmod %o %s", path, fi.Mode().Perm(), OwnerName(fi), m, OwnerName(fi), m, path)
	}
	if err := os.Chmod(path, m); err != nil {
		return fmt.Errorf("could not set mode %o on %s: %v", m, path, unwrap(err))
	}
	return nil
}

// Foreign is path's owner when it exists and is not this user's, else "".
func Foreign(path string) string {
	if fi, err := os.Lstat(path); err == nil && !Owned(fi) {
		return OwnerName(fi)
	}
	return ""
}

// PrivateRefusal is a step that would change another operator's private
// files: refused up front, naming who may run it.
func PrivateRefusal(flag, owner, path string) error {
	return cli.Fail("%s on this server is %s's to change — run it as %s", flag, owner, owner).Cont(
		fmt.Sprintf("%s is theirs and private (mode 600/700): no other operator reads it.", path), "Nothing was changed.")
}

// OwnerName is the file's owner by name, else by uid.
func OwnerName(fi os.FileInfo) string {
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return "another user"
	}
	id := strconv.Itoa(int(st.Uid))
	if u, err := user.LookupId(id); err == nil {
		return u.Username
	}
	return "uid " + id
}

// Open opens a lock file for flock, creating it at Mode; one this user owns
// is put back to Mode, and another operator's that is not group-writable is
// opened read-only — flock needs no write access.
func Open(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, Mode)
	if errors.Is(err, os.ErrPermission) {
		f, err = os.Open(path)
	}
	if err != nil {
		return nil, err
	}
	if fi, err := f.Stat(); err == nil && fi.Mode().Perm() != Mode && Owned(fi) {
		f.Chmod(Mode)
	}
	return f, nil
}

// Project takes a project's .deploy.lock without waiting — the flock
// util-linux's flock takes, so every writer of the project sees the same one.
// When another run holds it, f is nil and holder names that run.
func Project(dir string) (f *os.File, holder string, err error) {
	f, err = Open(strings.TrimSuffix(dir, "/") + "/.deploy.lock")
	if err != nil {
		return nil, "", err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		h := ProjectHolder(dir)
		f.Close()
		return nil, h, nil
	}
	return f, "", nil
}

// ProjectHolder names what holds dir's .deploy.lock, from /proc/locks
// ("env set by alice (pid 12)"); "another kasbah run" when it cannot tell.
func ProjectHolder(dir string) string {
	f, err := os.Open(strings.TrimSuffix(dir, "/") + "/.deploy.lock")
	if err != nil {
		return "another kasbah run"
	}
	defer f.Close()
	if h := procHolders(f, "WRITE"); len(h) > 0 {
		return strings.Join(h, "; ")
	}
	return "another kasbah run"
}

// Owned is whether this process's user owns the file: only the owner may
// chmod it, whatever its group bits allow.
func Owned(fi os.FileInfo) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid()
}

// Take flocks the lock without waiting; it writes nothing, so a re-run
// changes nothing under the apps path. A tree with no .kasbah is no prepared
// server, and has nothing to lock: nil, nil.
func Take(apps, mode, what string) (*os.File, error) {
	path := Path(apps)
	if fi, err := os.Stat(path[:strings.LastIndex(path, "/")]); err != nil || !fi.IsDir() {
		return nil, nil
	}
	how := syscall.LOCK_SH
	if mode == Exclusive {
		how = syscall.LOCK_EX
	}
	f, err := Open(path)
	if err != nil {
		return nil, fmt.Errorf("could not open the server lock %s: %v. Nothing was changed.", path, unwrap(err))
	}
	if err := syscall.Flock(int(f.Fd()), how|syscall.LOCK_NB); err != nil {
		h := holder(f, path)
		f.Close()
		return nil, &Busy{Holder: h, Path: path}
	}
	return f, nil
}

// Busy is Take refused: Holder holds the lock at Path.
type Busy struct{ Holder, Path string }

func (b *Busy) Error() string {
	return fmt.Sprintf("%s is running on this server — it holds %s. Nothing was changed; re-run once it has finished.", b.Holder, b.Path)
}

// holder names what holds the lock, from /proc/locks: the exclusive holder,
// or every shared one, by command, user and pid, so a stale one can be found.
func holder(f *os.File, path string) string {
	g, err := os.Open(path)
	if err != nil {
		return "another kasbah step"
	}
	defer g.Close()
	if syscall.Flock(int(g.Fd()), syscall.LOCK_SH|syscall.LOCK_NB) == nil {
		syscall.Flock(int(g.Fd()), syscall.LOCK_UN)
		if h := procHolders(f, "READ"); len(h) > 0 {
			return strings.Join(h, "; ")
		}
		return "a deploy, rollback, drop or env set"
	}
	if h := procHolders(f, "WRITE"); len(h) > 0 {
		return strings.Join(h, "; ")
	}
	return "a server-wide step (server init, upgrade-traefik, prune, destroy or migrate)"
}

// procHolders is every flock of kind (READ or WRITE) on f's inode in
// /proc/locks, as "server init by alice (pid 123)".
func procHolders(f *os.File, kind string) []string {
	fi, err := f.Stat()
	if err != nil {
		return nil
	}
	st, ok := fi.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	b, err := os.ReadFile("/proc/locks")
	if err != nil {
		return nil
	}
	ino := ":" + strconv.FormatUint(st.Ino, 10)
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		w := strings.Fields(l)
		// 1: FLOCK  ADVISORY  WRITE 1234 08:01:5678 0 EOF
		if len(w) < 6 || w[1] != "FLOCK" || w[3] != kind || !strings.HasSuffix(w[5], ino) {
			continue
		}
		pid := w[4]
		what := "kasbah"
		if c, err := os.ReadFile("/proc/" + pid + "/cmdline"); err == nil {
			what = describe(strings.Split(strings.TrimRight(string(c), "\x00"), "\x00"))
		}
		if p, err := os.Stat("/proc/" + pid); err == nil {
			what += " by " + OwnerName(p)
		}
		out = append(out, fmt.Sprintf("%s (pid %s)", what, pid))
	}
	return out
}

// describe is a holder's command line in the operator's words.
func describe(argv []string) string {
	for i, a := range argv {
		if a != "remote" || i+1 >= len(argv) {
			continue
		}
		rest := argv[i+1:]
		switch {
		case rest[0] == "lock" && len(rest) == 4:
			return rest[3]
		case rest[0] == "prune":
			return "server prune"
		case rest[0] == "destroy":
			return "server destroy"
		case rest[0] == "setup-env" && len(rest) > 1 && rest[1] == "set":
			return "env set"
		case rest[0] == "setup-env" && len(rest) > 1 && rest[1] == "setup":
			return "kasbah env"
		case rest[0] == "setup-env" && len(rest) > 1 && rest[1] == "seed":
			return "the --env-seed staging of kasbah env, a deploy or a rollback"
		case rest[0] == "setup-env" && len(rest) > 1 && rest[1] == "inject":
			return "the managed-block refresh of kasbah env or a deploy"
		case rest[0] == "deploy" && len(rest) > 1 && (rest[1] == "run" || rest[1] == "snapshot"):
			return "a deploy or rollback"
		case rest[0] == "drop":
			return "drop"
		}
		return "kasbah remote " + rest[0]
	}
	return strings.Join(argv, " ")
}

func unwrap(err error) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return pe.Err
	}
	return err
}

// Usage is `kasbah remote lock`'s.
const Usage = "usage: kasbah remote lock APPS shared|exclusive WHAT (held until stdin closes)"

// Remote is `kasbah remote lock APPS MODE WHAT`: the lock taken, `locked=MODE`
// on stdout, then held until stdin closes — the workstation's run ending, or
// its session dropping.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) != 3 || (args[1] != Shared && args[1] != Exclusive) || args[2] == "" {
		fmt.Fprintln(stderr, Usage)
		return 1
	}
	if fi, err := os.Stat(args[0] + "/.kasbah"); err != nil || !fi.IsDir() {
		fmt.Fprintf(stderr, "remote: %s/.kasbah is not a directory — no server prepared there to lock\n", args[0])
		return 1
	}
	f, err := Take(args[0], args[1], args[2])
	if err != nil {
		fmt.Fprintf(stderr, "remote: %v\n", err)
		return 1
	}
	defer f.Close()
	fmt.Fprintf(stdout, "locked=%s\n", args[1])
	io.Copy(io.Discard, stdin)
	return 0
}

// Hold takes the lock for a workstation run that spans several remote steps;
// release lets it go. bin is the server's binary.
func Hold(c *ssh.Conn, bin, apps, mode, what string) (release func(), err error) {
	cmd := c.Command(bin, "remote", "lock", apps, mode, what)
	in, err := cmd.StdinPipe()
	if err != nil {
		return nil, cli.Fail("could not take the server lock on %s: %v", c.Target, err)
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, cli.Fail("could not take the server lock on %s: %v", c.Target, err)
	}
	if err := cmd.Start(); err != nil {
		return nil, cli.Fail("could not take the server lock on %s: %v", c.Target, err)
	}
	line, _ := bufio.NewReader(out).ReadString('\n')
	if strings.TrimSpace(strings.ReplaceAll(line, "\r", "")) != "locked="+mode {
		in.Close()
		rc := ssh.ExitCode(cmd.Wait())
		return nil, cli.Fail("could not take the server lock %s on %s (exit %d, see above)", Path(apps), c.Target, rc)
	}
	return func() {
		in.Close()
		cmd.Wait()
	}, nil
}
