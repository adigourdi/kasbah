package serverbin

import (
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/shtest"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// A fake server binary is this test binary with "\nFAKE=<build>;<mode>"
// appended: an ELF of this machine that answers `remote …` as told.
const fakeTag = "\nFAKE="

func TestMain(m *testing.M) {
	if len(os.Args) > 1 && os.Args[1] == "remote" {
		os.Exit(fakeMain(os.Args[2:]))
	}
	os.Exit(m.Run())
}

func fakeMain(args []string) int {
	exe, _ := os.Executable()
	b, _ := os.ReadFile(exe)
	i := bytes.LastIndex(b, []byte(fakeTag))
	if i < 0 {
		return 99
	}
	build, mode, _ := strings.Cut(strings.TrimSpace(string(b[i+len(fakeTag):])), ";")
	switch {
	case len(args) == 1 && args[0] == "version":
		switch mode {
		case "exit3":
			fmt.Fprintln(os.Stderr, "boom: out of memory")
			return 3
		case "hang":
			time.Sleep(time.Minute)
		case "garbage":
			fmt.Println("hello")
			return 0
		case "warn":
			fmt.Fprintln(os.Stderr, "warning: something")
		}
		fmt.Println(remote.Self(build).Line())
		return 0
	case len(args) == 2 && args[0] == "install-self":
		if err := InstallSelf(remote.Self(build), exe, args[1], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		return 0
	}
	return 64
}

func fake(t *testing.T, path, build, mode string, perm os.FileMode) {
	t.Helper()
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(self)
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Dir(path), 0o755)
	b = append(b, []byte(fakeTag+build+";"+mode+"\n")...)
	if err := os.WriteFile(path, b, perm); err != nil {
		t.Fatal(err)
	}
}

// scratch is a fake server root: the pointer and the default apps path live
// under it, and the probe reads them instead of the real ones.
type scratch struct {
	t                   *testing.T
	root, pointer, apps string
}

func newScratch(t *testing.T) *scratch {
	root := t.TempDir()
	s := &scratch{t: t, root: root, pointer: filepath.Join(root, "etc", "kasbah", "apps-path"), apps: filepath.Join(root, "apps")}
	t.Cleanup(func() { os.Chmod(filepath.Dir(s.pointer), 0o755); os.Chmod(s.pointer, 0o644) })
	probeDefault, probePointer = s.apps, s.pointer
	t.Cleanup(func() { probeDefault, probePointer = DefaultApps, Pointer })
	return s
}

func (s *scratch) marker(apps string) {
	os.MkdirAll(filepath.Join(apps, ".kasbah"), 0o755)
	os.WriteFile(filepath.Join(apps, ".kasbah", "server.json"), []byte("{}\n"), 0o644)
}

func (s *scratch) point(body string) {
	os.MkdirAll(filepath.Dir(s.pointer), 0o755)
	os.WriteFile(s.pointer, []byte(body), 0o644)
}

// probe runs the probe under every shell; they must agree, and the first answers.
func (s *scratch) probe(explicit string) (int, []byte) {
	rc, out := -1, []byte(nil)
	for i, sh := range shtest.Shells(s.t) {
		cmd := sh.Stdin(probeScript, s.apps, s.pointer, explicit, "2")
		var b bytes.Buffer
		cmd.Stdout = &b
		r := ssh.ExitCode(cmd.Run())
		if i == 0 {
			rc, out = r, b.Bytes()
		} else if r != rc || !bytes.Equal(b.Bytes(), out) {
			s.t.Errorf("%s disagrees: %d %q, against %d %q", sh.Name, r, b.Bytes(), rc, out)
		}
	}
	return rc, out
}

func TestProbe(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads every mode; the unreadable-pointer rows cannot be built")
	}
	t.Run("nothing prepared", func(t *testing.T) {
		s := newScratch(t)
		rc, out := s.probe("")
		_, err := judge("d@h", rc, out, Options{})
		var e *cli.Error
		if !errors.As(err, &e) || e.Code != cli.ExitNoRemoteState || !strings.Contains(err.Error(), "`kasbah server init`") || strings.Contains(err.Error(), "init d@h") {
			t.Fatalf("got %v; want exit 4 naming kasbah server init, and no runnable bare init", err)
		}
	})
	t.Run("default, marker, no binary", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || p.Apps != s.apps || p.Source != "default" || p.Bin.Present || p.Machine == "" {
			t.Errorf("got %+v, %v", p, err)
		}
	})
	t.Run("pointer elsewhere, binary answers on stdout only", func(t *testing.T) {
		s := newScratch(t)
		other := filepath.Join(s.root, "srv", "apps")
		s.marker(other)
		s.point(other + "/./\r\n")
		fake(t, Path(other), "0.1.0-dev.1.1", "warn", 0o755)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || p.Apps != other || p.Source != "pointer" || !p.Bin.Present || p.Bin.RC != 0 ||
			p.Bin.Stdout != "build=0.1.0-dev.1.1" || !runnableHere(p.Bin.Head, runtime.GOARCH) {
			t.Errorf("got %+v, %v", p, err)
		}
	})
	t.Run("pointer without a trailing newline", func(t *testing.T) {
		s := newScratch(t)
		other := filepath.Join(s.root, "srv", "apps")
		s.marker(other)
		s.point(other)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || p.Apps != other {
			t.Errorf("got %+v, %v; want the pointer's path", p, err)
		}
	})
	t.Run("pointer elsewhere, no marker there", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		s.point(filepath.Join(s.root, "gone") + "\n")
		rc, out := s.probe("")
		_, err := judge("d@h", rc, out, Options{})
		var e *cli.Error
		if !errors.As(err, &e) || e.Code != cli.ExitNoRemoteState || !strings.Contains(err.Error(), "does not fall back") {
			t.Errorf("got %v; want exit 4 refusing the fallback", err)
		}
	})
	t.Run("explicit apps path, no marker needed", func(t *testing.T) {
		s := newScratch(t)
		dir := filepath.Join(s.root, "fresh")
		os.MkdirAll(dir, 0o755)
		s.point("/elsewhere\n")
		rc, out := s.probe(dir + "/")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || p.Apps != dir || p.Source != "explicit" || p.Marker {
			t.Errorf("got %+v, %v", p, err)
		}
		rc, out = s.probe(filepath.Join(s.root, "missing"))
		if _, err := judge("d@h", rc, out, Options{}); err == nil || !strings.Contains(err.Error(), "no directory") {
			t.Errorf("an explicit path that does not exist: %v", err)
		}
	})
	t.Run("binary not executable", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		fake(t, Path(s.apps), "9.0.0", "", 0o644)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || !p.Bin.Present || !p.Bin.Regular || p.Bin.Executable || p.Bin.RC != -1 {
			t.Errorf("got %+v, %v; want a present, unexecuted binary", p, err)
		}
	})
	t.Run("binary exits non-zero", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		fake(t, Path(s.apps), "9.0.0", "exit3", 0o755)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || p.Bin.RC != 3 || p.Bin.Stdout != "" || p.Bin.Stderr != "boom: out of memory" {
			t.Errorf("got %+v, %v; want rc 3 with its stderr kept apart", p.Bin, err)
		}
	})
	// busybox's timeout ends a run with 143, not 124: still a timeout, and the
	// binary is not run a second time for its stderr.
	t.Run("busybox timeout", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		fake(t, Path(s.apps), "9.0.0", "", 0o755)
		stub := t.TempDir()
		calls := filepath.Join(stub, "calls")
		os.WriteFile(filepath.Join(stub, "timeout"), []byte("#!/bin/sh\necho x >> '"+calls+"'\nexit 143\n"), 0o755)
		t.Setenv("PATH", stub+":"+os.Getenv("PATH"))
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out, Options{})
		if err != nil || p.Bin.RC != 143 || p.Bin.Stderr != "" {
			t.Fatalf("got %+v, %v", p.Bin, err)
		}
		if b, _ := os.ReadFile(calls); len(shtest.Shells(t))*len("x\n") != len(b) {
			t.Errorf("timeout ran %q, one call per shell wanted", b)
		}
		if _, err := Classify(p.Bin, Path(s.apps), runtime.GOARCH, nil); err == nil || !strings.Contains(err.Error(), "within") {
			t.Errorf("not a timeout: %v", err)
		}
	})
	refusals := []struct {
		name  string
		setup func(s *scratch)
		want  string
	}{
		{"pointer not an absolute path", func(s *scratch) { s.point("apps\n") }, "does not name an absolute path"},
		{"pointer empty", func(s *scratch) { s.point("") }, "does not name an absolute path"},
		{"pointer unreadable", func(s *scratch) { s.point(s.apps + "\n"); os.Chmod(s.pointer, 0) }, "cannot be read"},
		{"pointer directory not enterable", func(s *scratch) { s.point(s.apps + "\n"); os.Chmod(filepath.Dir(s.pointer), 0o600) }, "cannot be entered"},
		{"marker not a regular file", func(s *scratch) {
			os.Remove(filepath.Join(s.apps, ".kasbah", "server.json"))
			os.Mkdir(filepath.Join(s.apps, ".kasbah", "server.json"), 0o755)
		}, "exited 1"},
	}
	for _, tt := range refusals {
		t.Run(tt.name, func(t *testing.T) {
			s := newScratch(t)
			s.marker(s.apps)
			tt.setup(s)
			rc, out := s.probe("")
			_, err := judge("d@h", rc, out, Options{})
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("rc %d, %v; want a refusal saying %q (output %q)", rc, err, tt.want, out)
			}
		})
	}
}

func TestParseProbeTruncated(t *testing.T) {
	for _, out := range []string{"", "apps=/apps\n", "source=default\napps=/apps\n", "garbage\n"} {
		if _, err := judge("d@h", 0, []byte(out), Options{}); err == nil {
			t.Errorf("a truncated probe %q was absorbed", out)
		}
	}
	if _, err := judge("d@h", 1, []byte("apps=/apps\nsource=default\n"), Options{}); err == nil {
		t.Error("an unexpected probe status was absorbed")
	}
}

func TestClassify(t *testing.T) {
	elf := make([]byte, 20)
	copy(elf, "\x7fELF\x02\x01")
	elf[18] = 62
	arm := append([]byte{}, elf...)
	arm[18] = 183
	good := "build=1.0.0"
	ok := func(rc int, out, errOut string) Facts {
		return Facts{Present: true, Regular: true, Executable: true, Head: elf, RC: rc, Stdout: out, Stderr: errOut}
	}
	errNoexec := errors.New("mounted noexec")
	tests := []struct {
		name    string
		f       Facts
		noexec  error
		info    bool
		refusal string
	}{
		{"absent", Facts{RC: -1}, nil, false, ""},
		{"a directory", Facts{Present: true, RC: -1}, nil, false, "not a regular file"},
		{"not executable", Facts{Present: true, Regular: true, Head: elf, RC: -1}, nil, false, ""},
		{"not an ELF", Facts{Present: true, Regular: true, Executable: true, Head: []byte("#!/bin/sh\n"), RC: -1}, nil, false, ""},
		{"another machine's ELF", Facts{Present: true, Regular: true, Executable: true, Head: arm, RC: -1}, nil, false, ""},
		{"answers", ok(0, good+"\n", ""), nil, true, ""},
		{"answers with garbage", ok(0, "hello", ""), nil, false, "not a version line"},
		{"answers twice", ok(0, good+"\n"+good, ""), nil, false, "not a version line"},
		{"times out", ok(124, "", ""), nil, false, "within"},
		{"killed", ok(137, "", ""), nil, false, "killed"},
		{"busybox's timeout", ok(143, "", ""), nil, false, "within"},
		{"exits 3", ok(3, "", "boom: out of memory"), nil, false, "boom: out of memory"},
		{"126 off a noexec mount", ok(126, "", ""), errNoexec, false, "mounted noexec"},
		{"126 otherwise", ok(126, "", ""), nil, false, ""},
		{"127", ok(127, "", ""), nil, false, ""},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			info, err := Classify(tt.f, "/a/kasbah", "amd64", func() error { return tt.noexec })
			switch {
			case tt.refusal != "":
				if err == nil || !strings.Contains(err.Error(), tt.refusal) {
					t.Errorf("got %v, %v; want a refusal saying %q", info, err, tt.refusal)
				}
			case err != nil:
				t.Errorf("refused: %v", err)
			case tt.info && (info == nil || info.Build != "1.0.0"):
				t.Errorf("got %v, want build 1.0.0", info)
			case !tt.info && info != nil:
				t.Errorf("got %v, want nothing to keep", info)
			}
		})
	}
}

// stubSSH puts an ssh first on PATH that runs the remote command locally.
func stubSSH(t *testing.T) {
	dir := t.TempDir()
	script := `#!/bin/sh
for a; do last=$a; done
for a; do [ "$a" = -O ] && exit 0; done
for a; do [ "$a" = -n ] && exec </dev/null; done
exec sh -c "$last"
`
	os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	tmp := filepath.Join(dir, "tmp")
	os.Mkdir(tmp, 0o700)
	t.Setenv("TMPDIR", tmp)
}

func sum(t *testing.T, p string) [32]byte {
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	return sha256.Sum256(b)
}

// The same-build rule end to end, over an ssh that runs everything locally.
func TestEnsure(t *testing.T) {
	const ours = "0.1.0-dev.142.1760790000"
	RunTimeout = 2
	t.Cleanup(func() { RunTimeout = 30 })
	type srv struct {
		build, mode string
		perm        os.FileMode
		script, dir bool
	}
	cases := []struct {
		name     string
		server   *srv
		local    string // the local server binary's build
		explicit bool
		action   remote.Action
		old, now string
		refuse   string
	}{
		{"absent", nil, ours, false, remote.Ship, "", ours, ""},
		{"older", &srv{build: "0.1.0-dev.141.1760790000", perm: 0o755}, ours, false, remote.Ship, "0.1.0-dev.141.1760790000", ours, ""},
		{"same", &srv{build: ours, perm: 0o755}, ours, false, remote.Keep, ours, ours, ""},
		{"newer, same major", &srv{build: "0.9.0", perm: 0o755}, ours, false, 0, "", "", "newer than this kasbah"},
		{"newer major", &srv{build: "1.0.0", perm: 0o755}, ours, false, 0, "", "", "a newer major"},
		{"not executable", &srv{build: "1.0.0", perm: 0o644}, ours, false, remote.Ship, "unknown", ours, ""},
		{"not an executable format", &srv{script: true, perm: 0o755}, ours, false, remote.Ship, "unknown", ours, ""},
		{"exits non-zero", &srv{build: "1.0.0", mode: "exit3", perm: 0o755}, ours, false, 0, "", "", "boom: out of memory"},
		{"answers garbage", &srv{build: "1.0.0", mode: "garbage", perm: 0o755}, ours, false, 0, "", "", "not a version line"},
		{"hangs", &srv{build: "1.0.0", mode: "hang", perm: 0o755}, ours, false, 0, "", "", "within 2 s"},
		{"a directory", &srv{dir: true}, ours, false, 0, "", "", "not a regular file"},
		{"a mismatched local build", nil, "0.1.0-dev.141.1", false, 0, "", "", "from another build"},
		{"explicit apps path, no marker", nil, ours, true, remote.Ship, "", ours, ""},
	}
	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			stubSSH(t)
			s := newScratch(t)
			if !tt.explicit {
				s.marker(s.apps)
			}
			os.MkdirAll(s.apps, 0o755)
			bin := Path(s.apps)
			var before [32]byte
			if v := tt.server; v != nil {
				switch {
				case v.dir:
					os.MkdirAll(bin, 0o755)
				case v.script:
					os.MkdirAll(filepath.Dir(bin), 0o755)
					os.WriteFile(bin, []byte("#!/bin/sh\necho build=9.0.0\n"), v.perm)
				default:
					fake(t, bin, v.build, v.mode, v.perm)
				}
				if !v.dir {
					before = sum(t, bin)
				}
			}
			local := filepath.Join(s.root, "local", "kasbah-linux")
			fake(t, local, tt.local, "", 0o755)

			c, err := ssh.Connect("d@h")
			if err != nil {
				t.Fatal(err)
			}
			defer c.Close()
			opt := Options{}
			if tt.explicit {
				opt.Apps = s.apps
			}
			res, err := Ensure(c, remote.Self(ours), func(string) (string, error) { return local, nil }, opt)

			if tt.refuse != "" {
				if err == nil || !strings.Contains(err.Error(), tt.refuse) {
					t.Fatalf("got %+v, %v; want a refusal saying %q", res, err, tt.refuse)
				}
				switch {
				case tt.server == nil:
					if _, err := os.Stat(bin); err == nil {
						t.Error("a refusal left a binary in place")
					}
				case !tt.server.dir && sum(t, bin) != before:
					t.Error("a refusal replaced the server's binary")
				}
			} else {
				if err != nil {
					t.Fatal(err)
				}
				if res.Action != tt.action || res.Old != tt.old || res.Now != tt.now || res.Apps != s.apps {
					t.Errorf("got %+v; want action %v old %q now %q", res, tt.action, tt.old, tt.now)
				}
				switch tt.action {
				case remote.Ship:
					if sum(t, bin) != sum(t, local) {
						t.Error("the shipped binary is not the local one")
					}
					if fi, _ := os.Stat(bin); fi.Mode().Perm() != 0o755 {
						t.Errorf("the shipped binary is mode %v, want 0755", fi.Mode().Perm())
					}
				case remote.Keep:
					if sum(t, bin) != before {
						t.Error("a kept binary changed")
					}
				}
			}
			ents, _ := os.ReadDir(filepath.Dir(bin))
			for _, e := range ents {
				if e.Name() != "kasbah" && e.Name() != LockName {
					t.Errorf("%s left beside the binary", e.Name())
				}
			}
		})
	}
}

// Two installs racing over an older binary end on the newer of the two,
// whichever takes the lock first.
func TestInstallSelfRace(t *testing.T) {
	for round := range 4 {
		dir := t.TempDir()
		dest := filepath.Join(dir, "kasbah")
		fake(t, dest, "0.1.0-dev.10.1", "", 0o755)
		a, b := filepath.Join(dir, ".kasbah.a"), filepath.Join(dir, ".kasbah.b")
		fake(t, a, "0.1.0-dev.12.1", "", 0o755)
		fake(t, b, "0.1.0-dev.11.1", "", 0o755)
		want := sum(t, a)
		var wg sync.WaitGroup
		outs := make([]string, 2)
		for i, self := range []string{a, b} {
			if round%2 == 1 {
				self = []string{b, a}[i]
			}
			wg.Add(1)
			go func() {
				defer wg.Done()
				o, err := exec.Command(self, "remote", "install-self", dest).CombinedOutput()
				outs[i] = string(o)
				if err != nil {
					t.Errorf("install-self: %v: %s", err, o)
				}
			}()
		}
		wg.Wait()
		if sum(t, dest) != want {
			t.Errorf("round %d: the server ended on an older build (%q)", round, outs)
		}
	}
}

func TestInstallSelf(t *testing.T) {
	dir := t.TempDir()
	dest := filepath.Join(dir, "kasbah")
	self := filepath.Join(dir, ".kasbah.x")
	fake(t, self, "0.1.0-dev.5.1", "", 0o755)
	out, err := exec.Command(self, "remote", "install-self", dest).Output()
	if err != nil || string(out) != "installed old=none\n" {
		t.Errorf("into nothing: %q, %v", out, err)
	}
	fake(t, self, "0.1.0-dev.4.1", "", 0o755)
	out, err = exec.Command(self, "remote", "install-self", dest).Output()
	if err != nil || string(out) != "kept build=0.1.0-dev.5.1\n" {
		t.Errorf("over a newer one: %q, %v", out, err)
	}
	if _, err := os.Stat(self); err != nil {
		t.Error("a kept install moved itself anyway")
	}
	os.Remove(dest)
	os.Mkdir(dest, 0o755)
	if out, err := exec.Command(self, "remote", "install-self", dest).CombinedOutput(); err == nil || !strings.Contains(string(out), "not a regular file") {
		t.Errorf("over a directory: %q, %v", out, err)
	}
}

var prepared = Options{Prepared: func(body []byte, apps string) error {
	if !bytes.HasPrefix(bytes.TrimSpace(body), []byte("{")) {
		return cli.Fail("marker under %s refused", apps)
	}
	return nil
}}

func TestProbePrepared(t *testing.T) {
	code := func(err error) int {
		var e *cli.Error
		if !errors.As(err, &e) {
			return 0
		}
		return e.Code
	}
	t.Run("explicit, no marker: exit 4, nothing to ship to", func(t *testing.T) {
		s := newScratch(t)
		os.MkdirAll(s.apps, 0o755)
		rc, out := s.probe(s.apps)
		if _, err := judge("d@h", rc, out, prepared); code(err) != cli.ExitNoRemoteState || !strings.Contains(err.Error(), "--apps-path") {
			t.Fatalf("got %v; want exit 4 naming --apps-path", err)
		}
		if p, err := judge("d@h", rc, out, Options{}); err != nil || p.Apps != s.apps {
			t.Fatalf("init's mode needs no marker: got %+v, %v", p, err)
		}
	})
	t.Run("explicit, absent: exit 4", func(t *testing.T) {
		s := newScratch(t)
		rc, out := s.probe(filepath.Join(s.root, "nowhere"))
		if _, err := judge("d@h", rc, out, prepared); code(err) != cli.ExitNoRemoteState {
			t.Fatalf("got %v; want exit 4", err)
		}
	})
	t.Run("not a directory: exit 1, in either mode", func(t *testing.T) {
		s := newScratch(t)
		os.MkdirAll(filepath.Dir(s.apps), 0o755)
		os.WriteFile(s.apps, []byte("x"), 0o644)
		for _, explicit := range []string{"", s.apps} {
			rc, out := s.probe(explicit)
			if _, err := judge("d@h", rc, out, prepared); code(err) != cli.ExitFailure || !strings.Contains(err.Error(), "not a directory") {
				t.Fatalf("explicit=%q: got %v; want exit 1, not a directory", explicit, err)
			}
		}
	})
	t.Run("explicit, prepared", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		rc, out := s.probe(s.apps)
		if p, err := judge("d@h", rc, out, prepared); err != nil || p.Source != "explicit" {
			t.Fatalf("got %+v, %v", p, err)
		}
	})
	t.Run("a broken marker is judged before anything ships", func(t *testing.T) {
		for _, body := range []string{"", "not json", "{\"apps_path\":\"/apps\"}"} {
			s := newScratch(t)
			s.marker(s.apps)
			os.WriteFile(filepath.Join(s.apps, ".kasbah", "server.json"), []byte(body), 0o644)
			rc, out := s.probe("")
			_, err := judge("d@h", rc, out, prepared)
			if ok := strings.HasPrefix(body, "{"); (err == nil) != ok {
				t.Errorf("marker %q: %v", body, err)
			}
			if _, err := judge("d@h", rc, out, Options{}); err != nil {
				t.Errorf("init's mode does not judge the marker: %v", err)
			}
		}
	})
	t.Run("an unreadable marker is refused", func(t *testing.T) {
		if os.Getuid() == 0 {
			t.Skip("root reads every mode")
		}
		s := newScratch(t)
		s.marker(s.apps)
		mk := filepath.Join(s.apps, ".kasbah", "server.json")
		os.Chmod(mk, 0)
		t.Cleanup(func() { os.Chmod(mk, 0o644) })
		rc, out := s.probe("")
		if _, err := judge("d@h", rc, out, prepared); err == nil || !strings.Contains(err.Error(), "could not be read") {
			t.Errorf("got %v", err)
		}
	})
}

func TestExitText(t *testing.T) {
	for rc, want := range map[int]string{124: "it did not finish within 120 s", 137: "it did not finish within 120 s", 143: "it did not finish within 120 s", -1: "ssh could not run, or was killed by a signal", 3: "it exited 3"} {
		if got := ExitText(rc, 120); got != want {
			t.Errorf("ExitText(%d) = %q, want %q", rc, got, want)
		}
	}
}

// A marker far past bufio's default 64 KiB line: every line after it still
// reads, and a line past the bound is a refusal, never a short read.
func TestBigMarker(t *testing.T) {
	big := []byte(`{"apps_path":"/apps","pad":"` + strings.Repeat("x", 40*1024) + `"}`)
	out := "apps=/apps\nsource=default\napps_dir=yes\nmarker=yes\nmarker_hex=" + fmt.Sprintf("%x", big) + "\nmachine=x86_64\nbin=absent\n"
	p, err := ParseProbe([]byte(out))
	if err != nil || !bytes.Equal(p.MarkerBody, big) || p.Machine != "x86_64" {
		t.Fatalf("got %v, body %d bytes, machine %q", err, len(p.MarkerBody), p.Machine)
	}
	huge := "apps=/apps\nsource=default\nmarker_hex=" + strings.Repeat("ab", 1<<20) + "\nmachine=x86_64\n"
	if _, err := ParseProbe([]byte(huge)); err == nil || !strings.Contains(err.Error(), "too long") {
		t.Errorf("an over-long line: %v", err)
	}
	if _, err := judge("d@h", 0, []byte(huge), Options{}); err == nil || len(err.Error()) > 2000 {
		t.Errorf("the refusal quotes the probe clipped: %d bytes", len(err.Error()))
	}

	const ours = "0.1.0-dev.142.1760790000"
	for _, prep := range []bool{false, true} {
		stubSSH(t)
		s := newScratch(t)
		s.marker(s.apps)
		os.WriteFile(filepath.Join(s.apps, ".kasbah", "server.json"), big, 0o644)
		local := filepath.Join(s.root, "local", "kasbah-linux")
		fake(t, local, ours, "", 0o755)
		c, err := ssh.Connect("d@h")
		if err != nil {
			t.Fatal(err)
		}
		opt := Options{}
		var seen []byte
		if prep {
			opt.Prepared = func(body []byte, apps string) error { seen = body; return nil }
		}
		res, err := Ensure(c, remote.Self(ours), func(string) (string, error) { return local, nil }, opt)
		c.Close()
		if err != nil || res.Action != remote.Ship {
			t.Fatalf("prepared=%v: %+v, %v", prep, res, err)
		}
		if prep != bytes.Equal(seen, big) || !bytes.Equal(res.Marker, big) {
			t.Errorf("prepared=%v: the marker was judged on %d bytes, carried %d", prep, len(seen), len(res.Marker))
		}
	}
}

// A marker EnsurePrepared would refuse ships nothing; a valid one comes back
// validated, with the binary shipped.
func TestEnsurePrepared(t *testing.T) {
	const ours = "0.1.0-dev.142.1760790000"
	RunTimeout = 2
	t.Cleanup(func() { RunTimeout = 30 })
	for _, c := range []struct{ name, body, refuse string }{
		{"not JSON", "nope\n", "is not a JSON object — re-run `kasbah server init d@h --apps-path="},
		{"no limits", `{"apps_path":"/apps","data_path":"/apps/data"}`, "records cpu_limit=''"},
		{"valid", `{"apps_path":"/srv/apps","data_path":"/srv/data","cpu_limit":"1","mem_limit":"1g"}`, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			stubSSH(t)
			s := newScratch(t)
			os.MkdirAll(filepath.Join(s.apps, ".kasbah"), 0o755)
			os.WriteFile(filepath.Join(s.apps, ".kasbah", "server.json"), []byte(c.body), 0o644)
			local := filepath.Join(s.root, "local", "kasbah-linux")
			fake(t, local, ours, "", 0o755)
			conn, err := ssh.Connect("d@h")
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			res, mk, err := EnsurePrepared(conn, remote.Self(ours), func(string) (string, error) { return local, nil })
			_, statErr := os.Stat(Path(s.apps))
			if c.refuse != "" {
				if err == nil || !strings.Contains(err.Error(), c.refuse) || statErr == nil {
					t.Fatalf("got %v (binary shipped: %v); want a refusal saying %q, nothing shipped", err, statErr == nil, c.refuse)
				}
				return
			}
			if err != nil || mk.DataPath != "/srv/data" || res.Apps != s.apps || statErr != nil {
				t.Fatalf("got %+v %+v %v", res, mk, err)
			}
		})
	}
}

// A marker of another major is refused before anything ships, in every mode
// but Migrating's, which admits the older one.
func TestEnsureMajor(t *testing.T) {
	const ours = "1.0.2-dev.142.1760790000"
	RunTimeout = 2
	t.Cleanup(func() { RunTimeout = 30 })
	body := func(v string) string {
		return `{"kasbah_version":"` + v + `","apps_path":"/srv/apps","data_path":"/srv/data","cpu_limit":"1","mem_limit":"1g"}`
	}
	for _, c := range []struct {
		name, version string
		opt           Options
		refuse        string
	}{
		{"older, prepared", "0.9.0", prepared, "`kasbah migrate server d@h`"},
		{"older, bootstrap", "0.9.0", Options{}, "`kasbah migrate server d@h`"},
		{"older, migrating", "0.9.0", Options{Prepared: prepared.Prepared, Migrating: true}, ""},
		{"newer, prepared", "99.0.0", prepared, "written by kasbah 99.0.0"},
		{"newer, migrating", "99.0.0", Options{Prepared: prepared.Prepared, Migrating: true}, "written by kasbah 99.0.0"},
		{"same", "1.4.0", prepared, ""},
		{"incomparable", "", prepared, ""},
	} {
		t.Run(c.name, func(t *testing.T) {
			stubSSH(t)
			s := newScratch(t)
			os.MkdirAll(filepath.Join(s.apps, ".kasbah"), 0o755)
			os.WriteFile(filepath.Join(s.apps, ".kasbah", "server.json"), []byte(body(c.version)), 0o644)
			local := filepath.Join(s.root, "local", "kasbah-linux")
			fake(t, local, ours, "", 0o755)
			conn, err := ssh.Connect("d@h")
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			res, err := Ensure(conn, remote.Self(ours), func(string) (string, error) { return local, nil }, c.opt)
			_, statErr := os.Stat(Path(s.apps))
			if c.refuse != "" {
				if err == nil || !strings.Contains(err.Error(), c.refuse) || statErr == nil {
					t.Fatalf("got %v (binary shipped: %v); want a refusal saying %q, nothing shipped", err, statErr == nil, c.refuse)
				}
				if strings.Contains(c.name, "older") && !strings.Contains(err.Error(), "0.9.0") {
					t.Errorf("the refusal does not name the server's version: %v", err)
				}
				return
			}
			if err != nil || res.Action != remote.Ship || statErr != nil {
				t.Fatalf("got %+v %v (shipped: %v)", res, err, statErr == nil)
			}
		})
	}
}

func TestBounded(t *testing.T) {
	if got := strings.Join(Bounded("/a/kasbah", 30, "status", "/a"), " "); got != "timeout -k 5 30 /a/kasbah remote status /a" {
		t.Errorf("%q", got)
	}
	if InitCmd("d@h", DefaultApps) != "kasbah server init d@h" || InitCmd("d@h", "/srv") != "kasbah server init d@h --apps-path=/srv" {
		t.Error("InitCmd")
	}
}
