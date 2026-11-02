package deploy

import (
	"bufio"
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
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// RestoreFacts is `deploy restore-list`'s report: the scheduler's state, the
// project's live version and restore hook, the tarballs already in backups/,
// and, with the scheduler running, what the repository holds.
type RestoreFacts struct {
	State       string              `json:"state"`
	Live        string              `json:"live"`
	Hooks       bool                `json:"hooks"`
	RestoreHook bool                `json:"restore_hook"`
	Local       []string            `json:"local"`
	List        *backup.RestoreList `json:"list,omitempty"`
}

// inContainer runs the server's kasbah inside the scheduler container, which
// alone reads the repository's credentials.
var inContainer = func(apps string, args ...string) *exec.Cmd {
	return exec.Command("docker", append([]string{"exec", backup.Container, apps + "/.kasbah/bin/kasbah", "remote", "backup"}, args...)...)
}

// schedulerState is the kasbah-backup container's state, a seam for the tests.
var schedulerState = func() string { return backuprec.Scheduler().State }

// fromPathArg is args less one `--from-path=P`, and P; false for a P that
// cannot name a directory in a snapshot, or a second one.
func fromPathArg(args []string) ([]string, string, bool) {
	var rest []string
	from := ""
	for _, a := range args {
		p, ok := strings.CutPrefix(a, "--from-path=")
		switch {
		case !ok:
			rest = append(rest, a)
		case from != "" || !backup.FromPath(p):
			return nil, "", false
		default:
			from = p
		}
	}
	return rest, from, true
}

// fromArgs is from as the container arms' `--from-path P`, none for "".
func fromArgs(from string) []string {
	if from == "" {
		return nil
	}
	return []string{"--from-path", from}
}

// restoreList is `deploy restore-list APPS NAME [SNAPSHOT] [--from-path=P]`,
// read-only.
func restoreList(apps, name, snapshot, from string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	if !filepath.IsAbs(apps) || !IsProjectName(name) || snapshot != "" && !backup.ReSnapshotID.MatchString(snapshot) {
		return fail("usage: restore-list APPS NAME [SNAPSHOT] [--from-path=PATH] (APPS absolute)")
	}
	dir := apps + "/" + name
	f := RestoreFacts{State: schedulerState(), Local: []string{}}
	data, _ := os.ReadFile(filepath.Join(dir, vlog.Log))
	f.Live = liveVersion(vlog.Entries(strings.ReplaceAll(string(data), "\r", "")))
	if h, err := loadHooks(dir); err == nil {
		f.Hooks, f.RestoreHook = true, len(h.Restore) > 0
	}
	if root, err := os.OpenRoot(filepath.Join(dir, Backups)); err == nil {
		names, _ := backupNames(root)
		root.Close()
		for _, n := range names {
			if reBackup.MatchString(n) {
				f.Local = append(f.Local, n)
			}
		}
	}
	if f.State == "running" {
		args := append([]string{"restore-list", "--project", name}, fromArgs(from)...)
		if snapshot != "" {
			args = append(args, "--snapshot", snapshot)
		}
		var out bytes.Buffer
		c := inContainer(apps, args...)
		c.Stdout, c.Stderr = &out, stderr
		if err := c.Run(); err != nil {
			return fail("listing %s's backups in %s failed (see above)", name, backup.Container)
		}
		var l backup.RestoreList
		if err := json.Unmarshal(bytes.TrimSpace(out.Bytes()), &l); err != nil {
			return fail("%s printed no list of %s's backups kasbah can read", backup.Container, name)
		}
		f.List = &l
	}
	b, _ := json.Marshal(f)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}

// IsProjectName is whether name can be a project's directory under apps.
func IsProjectName(name string) bool { return reProjectName.MatchString(name) }

var reProjectName = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// partName is where a fetch writes name until it is verified.
func partName(name string) string { return "." + name + ".part" }

// fetchBackup is `deploy fetch DIR SNAPSHOT BACKUP [--from-path=P]`, under
// .deploy.lock: BACKUP out of the snapshot into backups/, verified (receive),
// one already there used as it is. stdout: fetch=fetched size=, fetch=present.
func fetchBackup(dir, snapshot, name, from string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	dir = strings.TrimSuffix(dir, "/")
	if !filepath.IsAbs(dir) || !IsProjectName(filepath.Base(dir)) || !backup.ReSnapshotID.MatchString(snapshot) {
		return fail("usage: fetch DIR SNAPSHOT BACKUP [--from-path=PATH] (DIR absolute)")
	}
	if !reBackup.MatchString(name) {
		return fail("'%s' is not a backup's name (<version>-<YYYYMMDD-HHMMSS>.tar.gz) — nothing was fetched", name)
	}
	lock, holder, err := serverlock.Project(dir)
	if err != nil {
		return fail("could not open the lock file %s/.deploy.lock — nothing was fetched", dir)
	}
	if lock == nil {
		return fail("%s is running in %s — it holds %s/.deploy.lock. Nothing was fetched; re-run once it has finished.", holder, dir, dir)
	}
	defer lock.Close()
	e := &engine{dir: dir, stderr: stderr}
	if err := e.openBackups(); err != nil {
		return fail("%v — nothing was fetched", err)
	}
	defer e.broot.Close()
	if fi, err := e.broot.Lstat(name); err == nil {
		if !fi.Mode().IsRegular() {
			return fail("%s/%s/%s exists and is not a regular file — nothing was fetched", dir, Backups, name)
		}
		fmt.Fprintln(stdout, "fetch=present")
		return 0
	}
	args := append(append([]string{"restore-dump", "--project", filepath.Base(dir)}, fromArgs(from)...), snapshot, name)
	c := inContainer(filepath.Dir(dir), args...)
	c.Stderr = stderr
	pipe, err := c.StdoutPipe()
	if err != nil {
		return fail("could not start docker exec: %v", err)
	}
	if err := c.Start(); err != nil {
		return fail("could not start docker exec: %v", err)
	}
	n, rerr := receive(e.broot, name, bufio.NewReader(pipe))
	io.Copy(io.Discard, pipe)
	werr := c.Wait()
	if rerr == nil && werr != nil {
		e.broot.Remove(name)
		rerr = fmt.Errorf("%s exited %d after the stream", backup.Container, exitStatus(werr))
	}
	if rerr != nil {
		if werr != nil {
			return fail("could not fetch %s from snapshot %s: the dump in %s failed (see above) — nothing was kept", name, snapshot, backup.Container)
		}
		return fail("could not fetch %s from snapshot %s: %v — nothing was kept", name, snapshot, rerr)
	}
	fmt.Fprintf(stdout, "fetch=fetched\nsize=%d\n", n)
	return 0
}

// receive reads one announced stream — `kasbah_dump size=N sha256=H`, then
// N bytes — into root/.name.part, and renames it to name once the bytes match
// and are a gzip'd tar read to its end. A failure removes the .part.
func receive(root *os.Root, name string, src *bufio.Reader) (int64, error) {
	size, sum, err := dumpHeader(src)
	if err != nil {
		return 0, err
	}
	part := partName(name)
	root.Remove(part)
	f, err := root.OpenFile(part, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0o660)
	if err != nil {
		return 0, err
	}
	pop := atexit.Push(func() { root.Remove(part) })
	defer pop()
	drop := func(err error) (int64, error) {
		f.Close()
		root.Remove(part)
		return 0, err
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(src, size+1))
	if err != nil {
		return drop(fmt.Errorf("the stream broke after %d bytes: %v", n, err))
	}
	if n != size {
		return drop(fmt.Errorf("the stream is %d bytes, %d announced — cut short or padded", n, size))
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != sum {
		return drop(fmt.Errorf("the stream's sha256 is %s, %s announced", got, sum))
	}
	if err := f.Close(); err != nil {
		return drop(err)
	}
	if err := readThrough(root, part); err != nil {
		return drop(fmt.Errorf("the stream is not a readable gzip'd tar: %v", err))
	}
	if err := root.Chmod(part, 0o660); err != nil {
		return drop(err)
	}
	if err := root.Rename(part, name); err != nil {
		return drop(err)
	}
	return n, nil
}

var reDumpHeader = regexp.MustCompile(`^` + backup.DumpKey + ` size=([1-9][0-9]{0,18}) sha256=([0-9a-f]{64})$`)

// dumpHeader is the announced size and sha256; a malformed line is never
// quoted, as it may be the payload's first bytes.
func dumpHeader(src *bufio.Reader) (int64, string, error) {
	var line []byte
	for len(line) <= 200 {
		b, err := src.ReadByte()
		if err != nil {
			return 0, "", errors.New("the stream ended before announcing its size and sha256")
		}
		if b == '\n' {
			g := reDumpHeader.FindSubmatch(line)
			if g == nil {
				break
			}
			n, err := strconv.ParseInt(string(g[1]), 10, 64)
			if err != nil {
				break
			}
			return n, string(g[2]), nil
		}
		line = append(line, b)
	}
	return 0, "", errors.New("the stream did not start by announcing its size and sha256")
}

// readThrough reads the tarball name in root through to its end.
func readThrough(root *os.Root, name string) error {
	tr, done, err := openBackup(root, name)
	if err != nil {
		return err
	}
	defer done()
	for {
		if _, err := tr.Next(); errors.Is(err, io.EOF) {
			return nil
		} else if err != nil {
			return err
		}
		if _, err := io.Copy(io.Discard, tr); err != nil {
			return err
		}
	}
}
