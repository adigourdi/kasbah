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
type scratch struct{ root, pointer, apps string }

func newScratch(t *testing.T) *scratch {
	root := t.TempDir()
	s := &scratch{root: root, pointer: filepath.Join(root, "etc", "kasbah", "apps-path"), apps: filepath.Join(root, "apps")}
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

func (s *scratch) probe(explicit string) (int, []byte) {
	cmd := exec.Command("sh", "-s", "--", s.apps, s.pointer, explicit, "2")
	cmd.Stdin = strings.NewReader(probeScript)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return ssh.ExitCode(err), out.Bytes()
}

func TestProbe(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("root reads every mode; the unreadable-pointer rows cannot be built")
	}
	t.Run("nothing prepared", func(t *testing.T) {
		s := newScratch(t)
		rc, out := s.probe("")
		_, err := judge("d@h", rc, out)
		var e *cli.Error
		if !errors.As(err, &e) || e.Code != cli.ExitNoRemoteState || !strings.Contains(err.Error(), "`kasbah server init d@h`") {
			t.Fatalf("got %v; want exit 4 naming a bare kasbah server init", err)
		}
	})
	t.Run("default, marker, no binary", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out)
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
		p, err := judge("d@h", rc, out)
		if err != nil || p.Apps != other || p.Source != "pointer" || !p.Bin.Present || p.Bin.RC != 0 ||
			p.Bin.Stdout != "build=0.1.0-dev.1.1 protocol=1 min_protocol=1" || !runnableHere(p.Bin.Head, runtime.GOARCH) {
			t.Errorf("got %+v, %v", p, err)
		}
	})
	t.Run("pointer without a trailing newline", func(t *testing.T) {
		s := newScratch(t)
		other := filepath.Join(s.root, "srv", "apps")
		s.marker(other)
		s.point(other)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out)
		if err != nil || p.Apps != other {
			t.Errorf("got %+v, %v; want the pointer's path", p, err)
		}
	})
	t.Run("pointer elsewhere, no marker there", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		s.point(filepath.Join(s.root, "gone") + "\n")
		rc, out := s.probe("")
		_, err := judge("d@h", rc, out)
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
		p, err := judge("d@h", rc, out)
		if err != nil || p.Apps != dir || p.Source != "explicit" || p.Marker {
			t.Errorf("got %+v, %v", p, err)
		}
		rc, out = s.probe(filepath.Join(s.root, "missing"))
		if _, err := judge("d@h", rc, out); err == nil || !strings.Contains(err.Error(), "no directory") {
			t.Errorf("an explicit path that does not exist: %v", err)
		}
	})
	t.Run("binary not executable", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		fake(t, Path(s.apps), "9.0.0", "", 0o644)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out)
		if err != nil || !p.Bin.Present || !p.Bin.Regular || p.Bin.Executable || p.Bin.RC != -1 {
			t.Errorf("got %+v, %v; want a present, unexecuted binary", p, err)
		}
	})
	t.Run("binary exits non-zero", func(t *testing.T) {
		s := newScratch(t)
		s.marker(s.apps)
		fake(t, Path(s.apps), "9.0.0", "exit3", 0o755)
		rc, out := s.probe("")
		p, err := judge("d@h", rc, out)
		if err != nil || p.Bin.RC != 3 || p.Bin.Stdout != "" || p.Bin.Stderr != "boom: out of memory" {
			t.Errorf("got %+v, %v; want rc 3 with its stderr kept apart", p.Bin, err)
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
			_, err := judge("d@h", rc, out)
			if err == nil || !strings.Contains(err.Error(), tt.want) {
				t.Errorf("rc %d, %v; want a refusal saying %q (output %q)", rc, err, tt.want, out)
			}
		})
	}
}

func TestParseProbeTruncated(t *testing.T) {
	for _, out := range []string{"", "apps=/apps\n", "source=default\napps=/apps\n", "garbage\n"} {
		if _, err := judge("d@h", 0, []byte(out)); err == nil {
			t.Errorf("a truncated probe %q was absorbed", out)
		}
	}
	if _, err := judge("d@h", 1, []byte("apps=/apps\nsource=default\n")); err == nil {
		t.Error("an unexpected probe status was absorbed")
	}
}

func TestClassify(t *testing.T) {
	elf := make([]byte, 20)
	copy(elf, "\x7fELF\x02\x01")
	elf[18] = 62
	arm := append([]byte{}, elf...)
	arm[18] = 183
	good := "build=1.0.0 protocol=1 min_protocol=1"
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

// The newer-wins rule end to end, over an ssh that runs everything locally.
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
		{"newer, same major", &srv{build: "0.9.0", perm: 0o755}, ours, false, remote.Keep, "0.9.0", "0.9.0", ""},
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
					os.WriteFile(bin, []byte("#!/bin/sh\necho build=9.0.0 protocol=1 min_protocol=1\n"), v.perm)
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
	if err != nil || string(out) != "kept build=0.1.0-dev.5.1 protocol=1 min_protocol=1\n" {
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
