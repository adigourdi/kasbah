package upgrade

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// fakeDocker is a server whose Traefik comes up healthy only on the attempts
// in healthyOn (1-based `up -d` calls); every call is logged.
type fakeDocker struct {
	ups       int
	healthyOn map[int]bool
	calls     []string
	onUp      func(n int)
	// connectErr fails every `network connect`; traefik starts on its own
	// network alone, two project networks waiting.
	connectErr bool
	// shared is each container's `name mode nets` once kasbah-net exists.
	shared string
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
	case strings.HasPrefix(j, "network ls --filter label=com.docker.compose.network=kasbah --format"):
		// hand_kasbah has no <apps>/hand: a compose project run by hand.
		return "mail_kasbah mail\ndemo_kasbah demo\nhand_kasbah hand\n", nil
	case strings.HasPrefix(j, "network inspect"), j == "network rm kasbah-net":
		if f.shared == "" {
			return "", errors.New("Error response from daemon: network kasbah-net not found")
		}
		return "", nil
	case j == "ps -aq":
		return "id\n", nil
	case args[0] == "inspect" && strings.Contains(j, "HostConfig.NetworkMode"):
		return f.shared, nil
	case strings.HasPrefix(j, "network connect"):
		if f.connectErr {
			return "", errors.New("exit status 1")
		}
		return "", nil
	case args[0] == "inspect" && strings.Contains(j, "NetworkSettings.Networks"):
		return "traefik_default\n", nil
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
		case strings.Contains(j, "State.Status"):
			if f.healthyOn[f.ups] {
				return "running", nil
			}
			return "exited", nil
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
	os.MkdirAll(apps+"/demo", 0o755)
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
	f0 := &fakeDocker{healthyOn: map[int]bool{1: true}}
	install(t, f0)
	if u := start(apps, bk, "", time.Second, failWriter{}); u.RolledBack != "no" || u.Health != "healthy" || restored(apps) ||
		u.Networks != "demo_kasbah mail_kasbah" || u.JoinErr != "" || u.Shared != "" {
		t.Errorf("healthy: %+v", u)
	}
	// Rejoined right after the up, before the health wait.
	if i, j, k := indexOf(f0.calls, "compose -p traefik up -d"), indexOf(f0.calls, "network connect demo_kasbah traefik"), indexOf(f0.calls, "inspect -f {{if"); i < 0 || j < i || k < j ||
		indexOf(f0.calls, "network connect mail_kasbah traefik") < 0 {
		t.Errorf("join order: %q", f0.calls)
	}
	if indexOf(f0.calls, "network rm") >= 0 {
		t.Errorf("no kasbah-net to remove: %q", f0.calls)
	}
	// The running Traefik, recreated off kasbah-net, lets it go once nothing
	// else is on it.
	f0 = &fakeDocker{healthyOn: map[int]bool{1: true}, shared: "/traefik traefik_default traefik_default demo_kasbah\n"}
	install(t, f0)
	if u := start(apps, bk, "", time.Second, failWriter{}); u.Shared != "kasbah-net removed: no container is on it" ||
		indexOf(f0.calls, "network rm kasbah-net") < indexOf(f0.calls, "inspect -f {{if") {
		t.Errorf("kasbah-net unused: %+v %q", u, f0.calls)
	}
	install(t, &fakeDocker{healthyOn: map[int]bool{1: true}, shared: "/old-db-1 kasbah-net \n"})
	if u := start(apps, bk, "", time.Second, failWriter{}); u.Shared != "kasbah-net kept: old-db-1 still on it" {
		t.Errorf("kasbah-net in use: %+v", u)
	}

	apps, bk = stack(t)
	install(t, &fakeDocker{healthyOn: map[int]bool{1: true}, connectErr: true})
	if u := start(apps, bk, "", time.Second, failWriter{}); u.RolledBack != "no" || !strings.Contains(u.JoinErr, "docker network connect demo_kasbah traefik failed") {
		t.Errorf("a failed join: %+v", u)
	}

	apps, bk = stack(t)
	f := &fakeDocker{healthyOn: map[int]bool{2: true}}
	install(t, f)
	var se bytes.Buffer
	u := start(apps, bk, "", time.Second, &se)
	if u.RolledBack != "yes" || !restored(apps) || f.ups != 2 || !strings.Contains(se.String(), "boom") {
		t.Errorf("unhealthy: %+v restored=%v ups=%d %s", u, restored(apps), f.ups, se.String())
	}
	// The restored Traefik is a new container too, and rejoins after its up.
	if n := countOf(f.calls, "network connect demo_kasbah traefik"); n != 2 || lastIndexOf(f.calls, "network connect demo_kasbah traefik") < lastIndexOf(f.calls, "compose -p traefik up -d") {
		t.Errorf("the restore did not rejoin (%d): %q", n, f.calls)
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

func countOf(l []string, p string) int {
	n := 0
	for _, s := range l {
		if strings.HasPrefix(s, p) {
			n++
		}
	}
	return n
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

// The restore arm puts the backup back byte for byte, mode and mtime kept,
// and touches no container.
func TestRemoteRestore(t *testing.T) {
	apps, bk := stack(t)
	mt := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	for i, f := range []string{"compose.yml", "traefik.yml", "_shared.yml"} {
		os.Chmod(bk+"/"+f, []os.FileMode{0o600, 0o640, 0o604}[i])
		os.Chtimes(bk+"/"+f, mt, mt)
	}
	f := &fakeDocker{}
	install(t, f)
	var so, se bytes.Buffer
	if code := Remote([]string{"restore", apps, bk}, nil, &so, &se); code != 0 || strings.TrimSpace(so.String()) != `{"restored":"yes"}` || !restored(apps) || len(f.calls) != 0 {
		t.Fatalf("restore: %d %s %s restored=%v calls=%q", code, so.String(), se.String(), restored(apps), f.calls)
	}
	for i, f := range []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml"} {
		fi, err := os.Stat(apps + "/traefik/" + f)
		if err != nil || fi.Mode().Perm() != []os.FileMode{0o600, 0o640, 0o604}[i] || !fi.ModTime().Equal(mt) {
			t.Errorf("%s: %v %v", f, fi.Mode(), err)
		}
	}

	apps, _ = stack(t)
	so.Reset()
	var r Restored
	if code := Remote([]string{"restore", apps, apps + "/traefik/backups/nope"}, nil, &so, &se); code != 0 || json.Unmarshal(so.Bytes(), &r) != nil ||
		r.Restored != "failed" || !strings.Contains(r.Err, "could not read the backup "+apps+"/traefik/backups/nope: no such file or directory") || restored(apps) {
		t.Errorf("no backup: %d %s", code, so.String())
	}
	apps, bk = stack(t)
	os.Remove(bk + "/traefik.yml")
	so.Reset()
	if code := Remote([]string{"restore", apps, bk}, nil, &so, &se); code != 0 || json.Unmarshal(so.Bytes(), &r) != nil ||
		r.Restored != "failed" || !strings.Contains(r.Err, "could not copy "+bk+"/traefik.yml to "+apps+"/traefik/traefik.yml") {
		t.Errorf("a missing file: %d %s", code, so.String())
	}
}

// holdDir flocks dir as a write in flight would, through its own open file.
func holdDir(t *testing.T, dir string) *os.File {
	t.Helper()
	f, err := os.Open(dir)
	if err != nil || syscall.Flock(int(f.Fd()), syscall.LOCK_EX) != nil {
		t.Fatalf("could not hold %s", dir)
	}
	t.Cleanup(func() { f.Close() })
	return f
}

// isLocked is whether another open file holds dir's flock.
func isLocked(t *testing.T, dir string) bool {
	t.Helper()
	f, err := os.Open(dir)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	return syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil
}

func setDirWait(t *testing.T, d time.Duration) {
	prev := serverlock.DirWait
	serverlock.DirWait = d
	t.Cleanup(func() { serverlock.DirWait = prev })
}

// A write holding traefik/ or traefik/dynamic/ finishes before the restore
// copies over it; held past the one shared DirWait, the restore reports
// restored=failed and copies nothing.
func TestRestoreWaitsForAWrite(t *testing.T) {
	for _, held := range []string{"traefik", "traefik/dynamic"} {
		apps, bk := stack(t)
		w := holdDir(t, apps+"/"+held)
		var so, se bytes.Buffer
		done := make(chan int, 1)
		go func() { done <- Remote([]string{"restore", apps, bk}, nil, &so, &se) }()
		select {
		case <-done:
			t.Fatalf("%s: the restore did not wait for the write: %s", held, so.String())
		case <-time.After(200 * time.Millisecond):
		}
		if held == "traefik/dynamic" && !isLocked(t, apps+"/traefik") {
			t.Errorf("the restore waits on traefik/dynamic without holding traefik/")
		}
		if _, err := os.Lstat(RestoredFlag(bk)); err == nil {
			t.Errorf("%s: the flag is set before the restore holds both directories", held)
		}
		os.WriteFile(apps+"/traefik/dynamic/_shared.yml", []byte("written late"), 0o644)
		w.Close()
		select {
		case code := <-done:
			if code != 0 || strings.TrimSpace(so.String()) != `{"restored":"yes"}` || !restored(apps) {
				t.Errorf("%s: after the write: %d %s %s restored=%v", held, code, so.String(), se.String(), restored(apps))
			}
		case <-time.After(5 * time.Second):
			t.Fatalf("%s: the restore still waits after the write let go", held)
		}
		if _, err := os.Lstat(RestoredFlag(bk)); err != nil || isLocked(t, apps+"/traefik") || isLocked(t, apps+"/traefik/dynamic") {
			t.Errorf("%s: after the restore: flag %v, a directory still locked", held, err)
		}
	}

	setDirWait(t, 600*time.Millisecond)
	apps, bk := stack(t)
	top := holdDir(t, apps+"/traefik")
	holdDir(t, apps+"/traefik/dynamic")
	time.AfterFunc(450*time.Millisecond, func() { top.Close() })
	var so, se bytes.Buffer
	var r Restored
	began := time.Now()
	code := Remote([]string{"restore", apps, bk}, nil, &so, &se)
	if took := time.Since(began); took > 950*time.Millisecond {
		t.Errorf("the two directories waited %s, not one DirWait", took)
	}
	if code != 0 || json.Unmarshal(so.Bytes(), &r) != nil || r.Restored != "failed" ||
		!strings.Contains(r.Err, "still holds "+apps+"/traefik/dynamic after 600ms — nothing was copied") {
		t.Errorf("held past the bound: %d %s", code, so.String())
	}
	if _, err := os.Lstat(RestoredFlag(bk)); err == nil {
		t.Errorf("a timed-out restore set the flag")
	}
	if b, _ := os.ReadFile(apps + "/traefik/compose.yml"); string(b) != "new compose.yml" {
		t.Errorf("a timed-out restore copied: %q", b)
	}
}

// shipWrite is the ship's init write of body to dest on this server.
func shipWrite(dest, bk, body string, stdin io.Reader) (string, int) {
	size, sum := remote.Digest([]byte(body))
	var o, e bytes.Buffer
	rc := serverinit.Remote([]string{"write", dest, size, sum, "--unless=" + RestoredFlag(bk)}, stdin, &o, &e)
	return o.String() + e.String(), rc
}

// The two orders a late ship write and the restore can take: the restore
// first, and the write refuses and installs nothing; the write first, and
// the restore copies over it once it lets go.
func TestRestoreAndALateWrite(t *testing.T) {
	apps, bk := stack(t)
	var so, se bytes.Buffer
	if code := Remote([]string{"restore", apps, bk}, nil, &so, &se); code != 0 || !restored(apps) {
		t.Fatalf("restore: %d %s %s", code, so.String(), se.String())
	}
	for _, dest := range []string{apps + "/traefik/compose.yml", apps + "/traefik/dynamic/_shared.yml"} {
		out, rc := shipWrite(dest, bk, "late", strings.NewReader("late"))
		if rc != 1 || !strings.HasPrefix(out, "written=no\nrefused="+RestoredFlag(bk)+"\n") ||
			!strings.Contains(out, "did not write "+dest+": "+RestoredFlag(bk)+" is there") || !restored(apps) {
			t.Errorf("a write after the restore: %d %q restored=%v", rc, out, restored(apps))
		}
	}
	if m, _ := filepath.Glob(apps + "/traefik/*.tmp.*"); len(m) > 0 {
		t.Errorf("a refused write left %v", m)
	}

	apps, bk = stack(t)
	dest := apps + "/traefik/dynamic/_shared.yml"
	pr, pw := io.Pipe()
	wrote := make(chan string, 1)
	go func() {
		out, rc := shipWrite(dest, bk, "late", pr)
		wrote <- fmt.Sprint(rc, " ", out)
	}()
	for i := 0; i < 100 && !isLocked(t, apps+"/traefik/dynamic"); i++ {
		time.Sleep(20 * time.Millisecond)
	}
	if !isLocked(t, apps+"/traefik/dynamic") {
		t.Fatal("the write did not lock traefik/dynamic")
	}
	so.Reset()
	done := make(chan int, 1)
	go func() { done <- Remote([]string{"restore", apps, bk}, nil, &so, &se) }()
	select {
	case <-done:
		t.Fatalf("the restore did not wait for the write: %s", so.String())
	case <-time.After(200 * time.Millisecond):
	}
	pw.Write([]byte("late"))
	pw.Close()
	if got := <-wrote; got != "0 written=yes\n" {
		t.Errorf("the write before the restore: %q", got)
	}
	select {
	case code := <-done:
		if code != 0 || strings.TrimSpace(so.String()) != `{"restored":"yes"}` || !restored(apps) {
			t.Errorf("the restore after the write: %d %s %s restored=%v", code, so.String(), se.String(), restored(apps))
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the restore still waits after the write")
	}
}

// putFile renames a staged copy over the target, the backup's mode and mtime
// kept; a target already holding the bytes is left alone, and a failed write
// leaves the old file whole.
func TestPutFile(t *testing.T) {
	d := t.TempDir()
	src, dst := d+"/src", d+"/dst"
	mt := time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)
	os.WriteFile(src, []byte("old"), 0o640)
	os.Chmod(src, 0o640)
	os.Chtimes(src, mt, mt)
	os.WriteFile(dst, []byte("new, and longer"), 0o644)
	ino := func() uint64 {
		fi, err := os.Stat(dst)
		if err != nil {
			t.Fatal(err)
		}
		return fi.Sys().(*syscall.Stat_t).Ino
	}
	before := ino()
	if err := putFile(src, dst); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(dst)
	if b, _ := os.ReadFile(dst); string(b) != "old" || ino() == before || fi.Mode().Perm() != 0o640 || !fi.ModTime().Equal(mt) {
		t.Errorf("put: %q inode %d -> %d, %v %v", b, before, ino(), fi.Mode(), fi.ModTime())
	}
	if m, _ := filepath.Glob(dst + ".tmp.*"); len(m) != 0 {
		t.Errorf("staging left: %v", m)
	}

	before = ino()
	if err := putFile(src, dst); err != nil || ino() != before {
		t.Errorf("unchanged bytes rewritten: %v, inode %d -> %d", err, before, ino())
	}

	os.WriteFile(dst, []byte("new"), 0o644)
	before = ino()
	os.Mkdir(fmt.Sprintf("%s.tmp.%d", dst, os.Getpid()), 0o755) // the staged write fails
	if err := putFile(src, dst); err == nil {
		t.Error("a failed write reported no error")
	}
	if b, _ := os.ReadFile(dst); string(b) != "new" || ino() != before {
		t.Errorf("a failed write touched the target: %q", b)
	}
}

// Every file the restore cannot put back is named, not only the first.
func TestRestoreFilesNamesEach(t *testing.T) {
	apps, bk := stack(t)
	os.Remove(bk + "/compose.yml")
	os.Remove(bk + "/_shared.yml")
	err := restoreFiles(apps, bk)
	if err == nil || strings.Count(err.Error(), "\n") != 1 || !strings.Contains(err.Error(), "could not copy "+bk+"/compose.yml") ||
		!strings.Contains(err.Error(), "could not copy "+bk+"/_shared.yml") {
		t.Errorf("%v", err)
	}
	if b, _ := os.ReadFile(apps + "/traefik/traefik.yml"); string(b) != "old traefik.yml" {
		t.Errorf("the file that could be put back was not: %q", b)
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
	args := []string{"dry-run", "/apps", "traefik:v3", DryLabel, "S", DryACMEError, DryCA, "5", fmt.Sprint(len(body) + 1), strings.Repeat("0", 64)}
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
