package deploy

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// liveVersion is the version live after entries: the last run that went live
// — a success, or a failure past its post-hook — else the last entry that is
// not a failed run's; "" for none.
func liveVersion(entries []vlog.Entry) string {
	n := len(entries)
	if n == 0 {
		return ""
	}
	if last := entries[n-1]; last.OK && (!last.IsFailed() || last.Reason == "post-hook") {
		return last.Version
	}
	for i := n - 1; i >= 0; i-- {
		if !entries[i].IsFailed() {
			return entries[i].Version
		}
	}
	return ""
}

// takeBackup is `kasbah remote deploy backup DIR`: the live version backed up
// as a deploy keeps one, under .deploy.lock and the shared server lock,
// versions.log unwritten. stdout: backup=<backups/…tar.gz> and version=<live>.
func takeBackup(dir string, now func() time.Time, stdout, stderr io.Writer) int {
	e := &engine{dir: strings.TrimSuffix(dir, "/"), stderr: stderr, now: now, sp: Spec{Mode: "backup"}}
	name, err := e.backupLive()
	for _, f := range []*os.File{e.lockFile, e.serverLock} {
		if f != nil {
			f.Close()
		}
	}
	if e.broot != nil {
		e.broot.Close()
	}
	if err != nil {
		fmt.Fprintf(stderr, "remote: backup: %v\n", err)
		return 1
	}
	fmt.Fprintf(stdout, "backup=%s\nversion=%s\n", name, e.sp.Version)
	return 0
}

// backupLive takes the backup: the live .env and the recorded targets into
// kasbah-snapshot/, the backup hook beside them, then the tarball and
// retention. Any failure removes the backup directory.
func (e *engine) backupLive() (string, error) {
	if e.dir == "" || !filepath.IsAbs(e.dir) {
		return "", failf("the project directory must be an absolute path (got '%s')", e.dir)
	}
	if fi, err := os.Stat(e.dir); err != nil || !fi.IsDir() {
		return "", failf("%s is not a project directory on this server — nothing was changed", e.dir)
	}
	e.project = filepath.Base(e.dir)
	if err := e.lock(); err != nil {
		return "", err
	}
	data, err := os.ReadFile(filepath.Join(e.dir, vlog.Log))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return "", failf("could not read %s/%s: %v — nothing was changed", e.dir, vlog.Log, err)
	}
	entries := vlog.Entries(strings.ReplaceAll(string(data), "\r", ""))
	if err := e.inFlight(entries); err != nil {
		return "", err
	}
	live := liveVersion(entries)
	if live == "" {
		return "", failf("%s has no live version: %s/%s records no run that went live, so there is nothing to back up — nothing was changed", e.project, e.dir, vlog.Log)
	}
	e.sp.Version, e.outgoing = live, "unknown"
	if safeName(live) {
		e.outgoing = live
	}
	h, err := loadHooks(e.dir)
	if err != nil {
		return "", err
	}
	targets, err := backupTargets(h.Targets)
	if err != nil {
		return "", failf("%s/%s: %v — nothing was changed", e.dir, HooksFile, err)
	}
	if err := e.backupDir(); err != nil {
		return "", failf("%v — nothing was changed", err)
	}
	broot, bdir, out := e.broot, e.bdir, e.bdir+".tar.gz"
	if _, err := broot.Lstat(out); err == nil {
		e.dropDir()
		return "", failf("%s/%s/%s already exists — re-run in a second. Nothing was changed", e.dir, Backups, out)
	}
	// A signal removes the .part and the directory: the originals are on disk.
	pop := atexit.Push(func() {
		broot.Remove(out + ".part")
		removeTree(broot, bdir)
	})
	defer pop()
	at := e.bdirPath()
	if err := e.copySnapshot(targets); err != nil {
		e.dropDir()
		return "", failf("could not copy the live files into the backup directory %s: %v — no backup of %s was kept, and the directory is removed", at, err, live)
	}
	if err := e.hooks("backup", h.Backup, nil); err != nil {
		e.dropDir()
		return "", failf("%v — no backup of %s was kept, and the backup directory %s is removed", err, live, at)
	}
	if err := writeTar(broot, bdir, out, e.modes); err != nil {
		e.dropDir()
		return "", failf("could not write the backup %s/%s/%s: %v — no backup of %s was kept, and the backup directory is removed", e.dir, Backups, out, err, live)
	}
	pop()
	e.dropDir()
	e.note("backup of %s written to %s/%s", live, Backups, out)
	e.prune()
	return Backups + "/" + out, nil
}

// inFlight refuses while PrevDir holds a manifest: a deploy is between its
// snapshot and its end, or one died or failed its revert, so the project's
// files may be part another version's.
func (e *engine) inFlight(entries []vlog.Entry) error {
	at := e.dir + "/" + PrevDir
	if _, err := os.Lstat(filepath.Join(e.dir, snapManifest)); errors.Is(err, fs.ErrNotExist) {
		return nil
	} else if err != nil {
		return failf("could not read %s/%s: %v — nothing was changed", e.dir, snapManifest, err)
	}
	if n := len(entries); n > 0 && entries[n-1].IsFailed() && entries[n-1].Reason == "revert" {
		return failf("%s is the snapshot a failed revert kept (versions.log ends '%s'): the project's files may be part %s's, part the version before it. Nothing was changed; fix what the revert reported and deploy or roll back again — once a run leaves a version live, back up", at, entries[n-1].Raw, entries[n-1].Version)
	}
	return failf("%s holds a deploy's snapshot: a deploy or rollback is under way, or one stopped before it finished, and the project's files may already be the next version's. Nothing was changed; let it finish, or re-run it, then back up", at)
}

// loadHooks is HooksFile: what the deploy or rollback that left the live
// version recorded of its hooks and its snapshot's targets.
func loadHooks(dir string) (*Hooks, error) {
	at := filepath.Join(dir, HooksFile)
	b, err := os.ReadFile(at)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, failf("%s is missing: every deploy or rollback that goes live writes it, recording the live version's backup hook and what its snapshot copies — deploy once, then back up. Nothing was changed", at)
	}
	if err != nil {
		return nil, failf("could not read %s: %v — nothing was changed", at, err)
	}
	var h Hooks
	if err := json.Unmarshal(b, &h); err != nil {
		return nil, failf("%s is not the JSON a deploy writes (%v) — deploy once to rewrite it. Nothing was changed", at, err)
	}
	return &h, nil
}

// backupTargets is the recorded targets as a snapshot takes them: .env always,
// a path inside another dropped.
func backupTargets(list []string) ([]string, error) {
	var es []Entry
	for _, t := range list {
		if !validTarget(t) || under(t, Backups) {
			return nil, fmt.Errorf("'%s' is not a path inside the project kasbah can keep a copy of", t)
		}
		es = append(es, Entry{Dst: t})
	}
	return SnapshotTargets(es), nil
}

// copySnapshot copies each target that exists to bdir/SnapDir/<path>, where a
// deploy's snapshot lands, and sets e.modes to the real modes of the
// directories the copies widened.
func (e *engine) copySnapshot(targets []string) error {
	root, err := os.OpenRoot(e.dir)
	if err != nil {
		return err
	}
	defer root.Close()
	dst := e.bdir + "/" + SnapDir
	if err := e.broot.Mkdir(dst, 0o770); err != nil {
		return err
	}
	e.modes = map[string]fs.FileMode{}
	for _, t := range targets {
		if _, err := root.Lstat(t); errors.Is(err, fs.ErrNotExist) {
			continue
		} else if err != nil {
			return err
		}
		to := dst + "/" + t
		if err := e.broot.MkdirAll(path.Dir(to), 0o770); err != nil {
			return err
		}
		dirs := map[string]uint32{}
		if err := copyBetween(root, t, e.broot, to, dirs, ""); err != nil {
			return err
		}
		for rel, m := range dirs {
			e.modes[strings.TrimSuffix(SnapDir+"/"+t+"/"+rel, "/")] = fs.FileMode(m)
		}
	}
	return nil
}
