package upgrade

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
)

// fakeDocker is a server whose Traefik comes up healthy only on the attempts
// in healthyOn (1-based `up -d` calls); every call is logged.
type fakeDocker struct {
	ups       int
	healthyOn map[int]bool
	calls     []string
	onUp      func(n int)
}

func (f *fakeDocker) run(dir string, args ...string) (string, error) {
	f.calls = append(f.calls, strings.Join(args, " "))
	j := strings.Join(args, " ")
	switch {
	case strings.HasPrefix(j, "compose -p traefik up -d"):
		f.ups++
		if f.onUp != nil {
			f.onUp(f.ups)
		}
		return "", nil
	case strings.HasPrefix(j, "compose -p traefik ps"):
		return "cid", nil
	case strings.HasPrefix(j, "compose -p traefik logs"):
		return "level=error msg=boom", nil
	case args[0] == "inspect":
		switch {
		case strings.Contains(j, "Health"):
			if f.healthyOn[f.ups] {
				return "healthy", nil
			}
			return "unhealthy", nil
		case strings.Contains(j, "Running"):
			if f.healthyOn[f.ups] {
				return "true", nil
			}
			return "false", nil
		case strings.Contains(j, "Config.Image"):
			b, _ := os.ReadFile(filepath.Join(dir, "..", "never"))
			return string(b) + "traefik:image", nil
		}
		return "x", nil
	}
	return "", errors.New("unexpected docker " + j)
}

func install(t *testing.T, f *fakeDocker) {
	oD, oS := dockerCmd, sleep
	t.Cleanup(func() { dockerCmd, sleep = oD, oS })
	dockerCmd, sleep = f.run, func(time.Duration) {}
}

// stack lays out a live stack ("new") and a backup of the one before ("old").
func stack(t *testing.T) (apps, backupDir string) {
	apps = t.TempDir()
	backupDir = apps + "/traefik/backups/S"
	os.MkdirAll(apps+"/traefik/dynamic", 0o755)
	os.MkdirAll(backupDir, 0o755)
	for _, f := range []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml"} {
		os.WriteFile(apps+"/traefik/"+f, []byte("new "+f), 0o644)
		os.WriteFile(backupDir+"/"+filepath.Base(f), []byte("old "+f), 0o644)
	}
	return apps, backupDir
}

func restored(apps string) bool {
	for _, f := range []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml"} {
		if b, _ := os.ReadFile(apps + "/traefik/" + f); string(b) != "old "+f {
			return false
		}
	}
	return true
}

type failWriter struct{}

func (failWriter) Write([]byte) (int, error) { return 0, syscall.EPIPE }

func TestStart(t *testing.T) {
	apps, bk := stack(t)
	install(t, &fakeDocker{healthyOn: map[int]bool{1: true}})
	if u := start(apps, bk, "", time.Second, failWriter{}); u.RolledBack != "no" || u.Health != "healthy" || restored(apps) {
		t.Errorf("healthy: %+v", u)
	}

	apps, bk = stack(t)
	f := &fakeDocker{healthyOn: map[int]bool{2: true}}
	install(t, f)
	var se bytes.Buffer
	u := start(apps, bk, "", time.Second, &se)
	if u.RolledBack != "yes" || !restored(apps) || f.ups != 2 || !strings.Contains(se.String(), "boom") {
		t.Errorf("unhealthy: %+v restored=%v ups=%d %s", u, restored(apps), f.ups, se.String())
	}
	// The failing stack's log is taken before the restore, and said after it.
	if i, j := indexOf(f.calls, "compose -p traefik logs"), lastIndexOf(f.calls, "compose -p traefik up -d"); i < 0 || i > j {
		t.Errorf("order: %q", f.calls)
	}

	apps, _ = stack(t)
	install(t, &fakeDocker{healthyOn: map[int]bool{}})
	if u := start(apps, apps+"/nope", "", time.Second, failWriter{}); u.RolledBack != "failed" || restored(apps) {
		t.Errorf("no backup: %+v", u)
	}
}

func indexOf(l []string, p string) int {
	for i, s := range l {
		if strings.HasPrefix(s, p) {
			return i
		}
	}
	return -1
}

func lastIndexOf(l []string, p string) int {
	for i := len(l) - 1; i >= 0; i-- {
		if strings.HasPrefix(l[i], p) {
			return i
		}
	}
	return -1
}

// TestStartHelper is `kasbah remote traefik start` in a child whose session
// vanishes: stdout and stderr are a pipe nobody reads, and the first `up -d`
// delivers SIGHUP, as a dropped ssh session does.
func TestStartHelper(t *testing.T) {
	apps := os.Getenv("KASBAH_START_APPS")
	if apps == "" {
		t.Skip("helper")
	}
	atexit.HandleSignals()
	f := &fakeDocker{healthyOn: map[int]bool{2: true}, onUp: func(n int) {
		if n == 1 {
			syscall.Kill(os.Getpid(), syscall.SIGHUP)
			time.Sleep(200 * time.Millisecond)
		}
	}}
	dockerCmd, sleep = f.run, func(time.Duration) {}
	os.Exit(Remote([]string{"start", apps, apps + "/traefik/backups/S", "", "1"}, nil, os.Stdout, os.Stderr))
}

func TestStartOutlivesSession(t *testing.T) {
	apps, _ := stack(t)
	r, w, _ := os.Pipe()
	r.Close()
	cmd := exec.Command(os.Args[0], "-test.run=^TestStartHelper$")
	cmd.Env = append(os.Environ(), "KASBAH_START_APPS="+apps)
	cmd.Stdout, cmd.Stderr = w, w
	cmd.Run()
	w.Close()
	if code := cmd.ProcessState.ExitCode(); code != 3 || !restored(apps) {
		t.Fatalf("exit %d (%v), restored=%v", code, cmd.ProcessState, restored(apps))
	}
}

func TestReadStack(t *testing.T) {
	apps, data := t.TempDir(), t.TempDir()
	os.MkdirAll(apps+"/traefik/dynamic/e.yml", 0o755)
	for _, f := range []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml", "dynamic/a.yml", "dynamic/b.yaml", "dynamic/c.toml", "dynamic/d.txt"} {
		os.WriteFile(apps+"/traefik/"+f, []byte(f), 0o644)
	}
	os.MkdirAll(data+"/traefik/letsencrypt", 0o700)
	os.WriteFile(data+"/traefik/letsencrypt/acme.json", []byte(`{"x":1}`), 0o600)
	snap := func() string {
		var b strings.Builder
		for _, root := range []string{apps, data} {
			filepath.Walk(root, func(p string, fi os.FileInfo, _ error) error {
				fmt.Fprintf(&b, "%s %d %v %v\n", p, fi.Size(), fi.Mode(), fi.ModTime().UnixNano())
				return nil
			})
		}
		return b.String()
	}
	before := snap()
	f := &fakeDocker{healthyOn: map[int]bool{0: true}}
	install(t, f)
	oH := haveDocker
	defer func() { haveDocker = oH }()
	haveDocker = func() bool { return true }
	s := readStack(apps, data)
	sort.Strings(s.Fragments)
	h := sha256.Sum256([]byte(`{"x":1}`))
	if strings.Join(s.Fragments, " ") != "_shared.yml a.yml b.yaml c.toml" || s.AcmeState != "nonempty" || s.AcmeDigest != hex.EncodeToString(h[:]) ||
		s.RunningImage != "traefik:image" || s.Health != "healthy" || !s.Docker || decodeB64(s.Shared) != "dynamic/_shared.yml" {
		t.Errorf("%+v", s)
	}
	if snap() != before {
		t.Error("the read changed the tree")
	}
	for _, c := range f.calls {
		if !strings.HasPrefix(c, "compose -p traefik ps") && !strings.HasPrefix(c, "inspect ") {
			t.Errorf("a docker verb that is not a read: %s", c)
		}
	}
	haveDocker = func() bool { return false }
	os.Remove(data + "/traefik/letsencrypt/acme.json")
	if s = readStack(apps, data); s.Docker || s.AcmeState != "absent" || s.State != "absent" {
		t.Errorf("no docker, no store: %+v", s)
	}
}

func TestRemoteDispatch(t *testing.T) {
	var so, se bytes.Buffer
	if code := Remote([]string{"bogus"}, nil, &so, &se); code != 1 || !strings.Contains(se.String(), "usage: kasbah remote traefik") {
		t.Errorf("unknown: %d %s", code, se.String())
	}
	body, _ := json.Marshal(DryPayload{Shared: "a", Static: "b"})
	args := []string{"dry-run", "/apps", "traefik:v3", DryLabel, "S", DryACMEError, DryCA, "5", fmt.Sprint(len(body) + 1), "00"}
	se.Reset()
	if code := Remote(args, bytes.NewReader(body), &so, &se); code != 1 || !strings.Contains(se.String(), "nothing was installed") {
		t.Errorf("a cut payload: %d %s", code, se.String())
	}
	notJSON := []byte("not json")
	h := sha256.Sum256(notJSON)
	args[8], args[9] = fmt.Sprint(len(notJSON)), hex.EncodeToString(h[:])
	se.Reset()
	if code := Remote(args, bytes.NewReader(notJSON), &so, &se); code != 1 || !strings.Contains(se.String(), "not the payload this binary reads") {
		t.Errorf("a foreign payload: %d %s", code, se.String())
	}
	se.Reset()
	if code := Remote([]string{"start", t.TempDir(), "b", "a", "1"}, nil, &so, &se); code != 1 || !strings.Contains(se.String(), "could not enter") {
		t.Errorf("start without a stack: %d %s", code, se.String())
	}
	so.Reset()
	if code := Remote([]string{"read", t.TempDir(), t.TempDir()}, nil, &so, &se); code != 0 || !json.Valid(bytes.TrimSpace(so.Bytes())) {
		t.Errorf("read: %d %s", code, so.String())
	}
}

func TestClipTail(t *testing.T) {
	s := strings.Repeat("é", 4000) + "x"
	if c := clipTail(s, 8000); len(c) != 7999 || !strings.HasPrefix(c, "é") {
		t.Errorf("clipped mid-rune: %d %q", len(c), c[:2])
	}
	if clipTail("short", 8000) != "short" {
		t.Error("a short log is whole")
	}
}
