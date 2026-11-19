package ssh

import (
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/launcher"
)

// fakeSSH puts an ssh on PATH that logs its argv and answers -G with body
// (exit rc, stderr msg).
func fakeSSH(t *testing.T, body string, rc int, msg string) (log string, notes *[]string) {
	t.Helper()
	dir := t.TempDir()
	log = filepath.Join(dir, "calls")
	script := "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '" + log + "'\n" +
		"cat <<'EOF'\n" + body + "EOF\n" +
		"printf '%s' '" + msg + "' >&2\nexit " + strconv.Itoa(rc) + "\n"
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	var got []string
	old := Note
	Note = func(l string) { got = append(got, l) }
	t.Cleanup(func() { Note = old })
	return log, &got
}

func sshCalls(t *testing.T, log string) string {
	b, err := os.ReadFile(log)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(b)
}

func TestResolveTargetFromConfig(t *testing.T) {
	log, notes := fakeSSH(t, "host vps\r\nuser alice\r\nhostname 203.0.113.9\r\n", 0, "")
	got, err := ResolveTarget("info", "vps\r")
	if err != nil || got != "alice@vps" {
		t.Fatalf("got %q, %v", got, err)
	}
	if c := sshCalls(t, log); c != "-G -- vps\n" {
		t.Errorf("ssh called as %q", c)
	}
	if len(*notes) != 1 || (*notes)[0] != "kasbah: as alice@vps (user from ssh config)" {
		t.Errorf("notes %q", *notes)
	}
}

func TestResolveTargetTyped(t *testing.T) {
	log, notes := fakeSSH(t, "user alice\n", 0, "")
	for _, in := range []string{"deploy@vps", "root@vps", "", "a@b@c"} {
		if got, err := ResolveTarget("info", in); err != nil || got != in {
			t.Errorf("ResolveTarget(%q) = %q, %v", in, got, err)
		}
	}
	if c := sshCalls(t, log); c != "" || len(*notes) != 0 {
		t.Errorf("a typed user still ran ssh (%q) or noted (%q)", c, *notes)
	}
}

func TestResolveTargetRefusals(t *testing.T) {
	for _, c := range []struct {
		name, body string
		rc         int
		msg, want  string
	}{
		{"root", "user root\n", 0, "", "logs in to vps as root, and kasbah takes root only when it is typed"},
		{"failing", "", 255, "ssh: Could not resolve hostname vps: Name or service not known", "could not tell which user ssh logs in to vps as: `ssh -G vps` failed: ssh: Could not resolve hostname vps: Name or service not known"},
		{"silent failure", "user alice\n", 255, "", "`ssh -G vps` failed: exit status 255"},
		{"dash user", "user -oProxyCommand=x\n", 0, "", "names the user '-oProxyCommand=x', which kasbah does not take"},
		{"no user", "host vps\nhostname vps\n", 0, "", "printed no user line"},
		{"odd user", "user a b\n", 0, "", "names the user 'a b'"},
	} {
		t.Run(c.name, func(t *testing.T) {
			_, notes := fakeSSH(t, c.body, c.rc, c.msg)
			_, err := ResolveTarget("info", "vps")
			if err == nil || !strings.Contains(err.Error(), c.want) {
				t.Fatalf("got %v, want %q", err, c.want)
			}
			if c.name == "root" && !strings.Contains(err.Error(), "root is the User your ssh config gives vps, or your own login when it gives none") {
				t.Errorf("root refusal does not say where root came from: %v", err)
			}
			e := err.(interface{ NextLines() []string })
			next := strings.Join(e.NextLines(), " ")
			want := "USER@vps"
			if c.name == "root" {
				want = "root@vps"
			}
			if !strings.Contains(next, want) {
				t.Errorf("next step %q does not name %s", next, want)
			}
			if len(*notes) != 0 {
				t.Errorf("noted %q on a refusal", *notes)
			}
		})
	}
}

// A version-shaped argument is a misread version, never a host; a dotted quad
// stays an IPv4 address.
func TestResolveTargetVersion(t *testing.T) {
	log, _ := fakeSSH(t, "user alice\n", 0, "")
	for _, in := range []string{"1.2.0", "v1.2.0", "1.2.0-rc.1", "v1.2.0-rc.1", "1.2.0-rc.1+b", "v1.2.0-rc.1+b", "1.2.1-dev.218.1795065102+g54ec93a"} {
		_, err := ResolveTarget("restore", in)
		if err == nil || !strings.Contains(err.Error(), "restore: '"+in+"' reads as a version, and restore takes no version") {
			t.Errorf("ResolveTarget(%q): %v", in, err)
			continue
		}
		if next := strings.Join(err.(interface{ NextLines() []string }).NextLines(), " "); !strings.Contains(next, "USER@"+in) {
			t.Errorf("%s: next step %q", in, next)
		}
	}
	// Near a version, neither a version nor a host: a mistyped version.
	for _, in := range []string{"1.2", "1", "v1.2", "v1", "1.2.3.4.5", "v1.2.3.4"} {
		_, err := ResolveTarget("restore", in)
		if err == nil || !strings.Contains(err.Error(), "restore: '"+in+"' is not a version kasbah can use") {
			t.Errorf("ResolveTarget(%q): %v", in, err)
		}
	}
	if c := sshCalls(t, log); c != "" {
		t.Errorf("ssh ran for a version: %q", c)
	}
	for _, in := range []string{"10.0.0.1", "1.2.3.4", "v2.example.com", "v6host", "v1.2.3.example.com"} {
		if got, err := ResolveTarget("restore", in); err != nil || got != "alice@"+in {
			t.Errorf("a host %s: %q, %v", in, got, err)
		}
	}
}

func TestResolveTargetBadHost(t *testing.T) {
	log, _ := fakeSSH(t, "user alice\n", 0, "")
	for _, in := range []string{"vps:2222", "-oProxyCommand=x", "[::1]", "v ps"} {
		if _, err := ResolveTarget("info", in); err == nil {
			t.Errorf("ResolveTarget(%q) accepted it", in)
		}
	}
	if c := sshCalls(t, log); c != "" {
		t.Errorf("ssh ran for a malformed host: %q", c)
	}
}

// A process a hand-off started re-resolves its target but leaves the note to
// the parent, which printed it already.
func TestNoteOnceAcrossHandoff(t *testing.T) {
	stderr := func() string {
		t.Helper()
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		old := os.Stderr
		os.Stderr = w
		Note("kasbah: as alice@vps (user from ssh config)")
		os.Stderr = old
		w.Close()
		b, _ := io.ReadAll(r)
		return string(b)
	}
	t.Setenv(launcher.Env, "")
	if got := stderr(); !strings.Contains(got, "kasbah: as alice@vps (user from ssh config)") {
		t.Errorf("no note in a first process: %q", got)
	}
	t.Setenv(launcher.Env, "1.2.0")
	if got := stderr(); got != "" {
		t.Errorf("a handed-off process noted again: %q", got)
	}
}
