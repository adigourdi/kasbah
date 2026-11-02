package deploy

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/remote"
)

// Backups is the project's backup directory; each backup is
// <outgoing version>-<UTC stamp>.tar.gz in it.
const Backups = "backups"

// SnapDir is where a backup holds the snapshot: each target that existed,
// at its path.
const SnapDir = "kasbah-snapshot"

// HooksFile is the backup and restore hooks and the snapshot's targets of
// the version a deploy or rollback left live: the server's record of them.
const HooksFile = ".kasbah-hooks.json"

// stampLayout is a backup's UTC stamp: fixed width, so names sort by time.
const stampLayout = "20060102-150405"

// backupName is a backup's name less its suffix: the version, then the stamp.
const backupName = `^([0-9A-Za-z][0-9A-Za-z.+_-]*)-([0-9]{8}-[0-9]{6})`

var (
	reBackup    = regexp.MustCompile(backupName + `\.tar\.gz$`)
	reBackupDir = regexp.MustCompile(backupName + `$`)
)

// KeepFor is how far back every backup is kept; of the older ones, only the
// newest stays.
const KeepFor = 24 * time.Hour

// safeName is whether a version can name a backup as it is.
func safeName(v string) bool {
	return reBackup.MatchString(v + "-20000101-000000.tar.gz")
}

// Hooks is HooksFile's content.
type Hooks struct {
	Backup  []string `json:"backup"`
	Restore []string `json:"restore"`
	Targets []string `json:"targets"`
}

// checkBackups refuses a backups/ that is there and is not a directory, or
// a link to one; absent is fine.
func checkBackups(dir string) error {
	at := filepath.Join(dir, Backups)
	fi, err := os.Stat(at)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if _, lerr := os.Lstat(at); lerr == nil {
			return failf("%s is a symlink to nothing — make it a directory, or a link to one, for the project's backups", at)
		}
		return nil
	case err != nil:
		return failf("could not read %s: %v", at, err)
	case !fi.IsDir():
		return failf("%s is not a directory — make it one, or a link to one, for the project's backups", at)
	}
	return nil
}

// openBackups opens backups/ once, creating it when absent: a link to a
// directory or a mount point is followed here, and every backup step then
// works relative to this one handle.
func (e *engine) openBackups() error {
	if e.broot != nil {
		return nil
	}
	if err := checkBackups(e.dir); err != nil {
		return err
	}
	at := filepath.Join(e.dir, Backups)
	if err := os.Mkdir(at, 0o777); err != nil && !errors.Is(err, fs.ErrExist) {
		return failf("could not create %s: %v", at, err)
	}
	root, err := os.OpenRoot(at)
	if err != nil {
		return failf("could not open %s: %v", at, err)
	}
	e.broot = root
	return nil
}

// bdirPath is the backup directory's path, as the hooks and messages see it.
func (e *engine) bdirPath() string { return filepath.Join(e.dir, Backups, e.bdir) }

// backupDir creates backups/<outgoing>-<stamp>/, 770 (2770 under a setgid
// backups/): it will hold .env.
func (e *engine) backupDir() error {
	if err := e.openBackups(); err != nil {
		return err
	}
	name := e.outgoing + "-" + e.now().UTC().Format(stampLayout)
	at := filepath.Join(e.dir, Backups, name)
	if err := e.broot.Mkdir(name, 0o770); err != nil {
		return failf("could not create the backup directory %s: %v", at, err)
	}
	// A setgid bit inherited from backups/ stays: the operators' group owns it.
	mode := fs.FileMode(0o770)
	if fi, err := e.broot.Stat(name); err == nil {
		mode |= fi.Mode() & fs.ModeSetgid
	}
	if err := e.broot.Chmod(name, mode); err != nil {
		e.broot.Remove(name)
		return failf("could not set mode 770 on the backup directory %s: %v", at, err)
	}
	e.bdir = name
	return nil
}

// dropDir removes the backup directory: the run left the outgoing version live.
func (e *engine) dropDir() {
	if e.bdir == "" {
		return
	}
	if err := removeTree(e.broot, e.bdir); err != nil {
		e.note("could not remove the backup directory %s: %v", e.bdirPath(), err)
	}
	e.bdir = ""
}

// leftDir is the clause naming a backup directory a failure leaves, "" for none.
func (e *engine) leftDir() string {
	if e.bdir == "" {
		return ""
	}
	return ". The backup directory " + e.bdirPath() + " is kept for the operator"
}

// writeTar is tarDir, a seam for the tests.
var writeTar = tarDir

// keep runs once the run's version is live: HooksFile is rendered, and the
// outgoing version's snapshot and hook outputs become its backup tarball —
// versions.log's field 4. It outlasts a signal, and never fails the run.
func (e *engine) keep() {
	release := atexit.Hold(func(os.Signal) {})
	defer release()
	e.writeHooks()
	if !e.history {
		dropSnapshot(e.dir)
		return
	}
	if e.bdir == "" {
		if err := e.backupDir(); err != nil {
			e.note("%v — no backup of %s is kept%s", err, e.outgoing, e.keepAside(e.outgoing+"-"+e.now().UTC().Format(stampLayout), "its snapshot"))
			return
		}
	}
	at := e.bdirPath()
	out := e.bdir + ".tar.gz"
	// A second signal mid-move exits: the snapshot goes aside, the backup
	// directory keeps what reached it, and one line names both.
	name := e.bdir
	pop := atexit.Push(func() {
		held, rest := moveLeft(e.move.Swap(moveStopped))
		e.noteRaw("a signal stopped the snapshot's move into the backup directory %s — that directory, kept for the operator, %s%s", at, held, e.keepAside(name, rest))
	})
	err := e.moveSnapshot()
	pop()
	if err != nil {
		held, rest := moveLeft(e.move.Load())
		e.note("could not move the snapshot into the backup directory %s: %v — that directory, kept for the operator, %s%s, and versions.log records no-backup", at, err, held, e.keepAside(e.bdir, rest))
		e.bdir = ""
		return
	}
	// A second signal exits: it removes the .part, and the directory stays.
	broot := e.broot
	pop = atexit.Push(func() { broot.Remove(out + ".part") })
	err = writeTar(e.broot, e.bdir, out, e.modes)
	pop()
	if err != nil {
		e.note("could not write the backup %s/%s/%s: %v — what it would hold is left in %s for the operator, and versions.log records no-backup", e.dir, Backups, out, err, at)
		e.bdir = ""
		return
	}
	e.backupPath = Backups + "/" + out
	e.dropDir()
	e.note("backup of %s written to %s", e.outgoing, e.backupPath)
}

// The snapshot's move's states: renaming until a rename crosses
// filesystems, then copying, copied once every copy is whole and the
// originals go; stopped by a signal's cleanup, after which none starts.
const (
	moveRenaming int32 = iota
	moveCopying
	moveCopied
	moveStopped
)

// errStopped is a move a signal's cleanup stopped.
var errStopped = errors.New("stopped by a signal")

// moveLeft is what a move cut short in state leaves in the backup directory,
// and what of the snapshot is left.
func moveLeft(state int32) (held, rest string) {
	switch state {
	case moveCopying:
		return "holds the copies made so far, the last perhaps partial", "the whole snapshot"
	case moveCopied:
		return "holds every copy, whole", "what is left of the snapshot's originals"
	}
	return "holds the copies moved so far", "the rest of the snapshot"
}

// dropManifest removes the snapshot's manifest, a seam for the tests.
var dropManifest = func(root *os.Root) error { return root.Remove(snapManifest) }

// keepAside renames what is left of the snapshot to KeptPrefix+name, which
// no run reads, and returns the clause saying where after what it holds, ""
// when nothing is left; failing that, the manifest goes, or else the whole.
func (e *engine) keepAside(name, what string) string {
	prev := e.dir + "/" + PrevDir
	aside := e.dir + "/" + KeptPrefix + name
	byHand := "remove it by hand — the next run's snapshot step refuses it while it is there"
	root, err := os.OpenRoot(e.dir)
	if err != nil {
		if rerr := os.RemoveAll(prev); rerr != nil {
			return fmt.Sprintf("; %s could not be moved aside to %s (%v), nor %s removed (%v): %s", what, aside, err, prev, rerr, byHand)
		}
		return fmt.Sprintf("; %s could not be moved aside to %s (%v), so %s is removed, and those copies with it", what, aside, err, prev)
	}
	defer root.Close()
	if _, lerr := root.Lstat(PrevDir); errors.Is(lerr, fs.ErrNotExist) {
		return ""
	}
	if err = root.Rename(PrevDir, KeptPrefix+name); err == nil {
		return fmt.Sprintf("; %s is kept in %s for the operator", what, aside)
	}
	merr := dropManifest(root)
	if merr == nil || errors.Is(merr, fs.ErrNotExist) {
		return fmt.Sprintf("; %s could not be moved aside to %s (%v), and is left in %s without its manifest, for the next run to remove", what, aside, err, prev)
	}
	rerr := removeTree(root, PrevDir)
	if rerr == nil {
		return fmt.Sprintf("; %s could not be moved aside to %s (%v), nor its manifest removed (%v), so %s is removed, and those copies with it", what, aside, err, merr, prev)
	}
	if _, lerr := root.Lstat(snapManifest); errors.Is(lerr, fs.ErrNotExist) {
		return fmt.Sprintf("; %s could not be moved aside to %s (%v), nor its manifest removed (%v), and %s is only partly removed (%v): what is left has no manifest, for the next run to remove", what, aside, err, merr, prev, rerr)
	}
	return fmt.Sprintf("; %s could not be moved aside to %s (%v), nor its manifest removed (%v), nor %s removed (%v): %s", what, aside, err, merr, prev, rerr, byHand)
}

// renameAt renames src in from to dst in to, a seam for the tests.
var renameAt = func(from *os.Root, src string, to *os.Root, dst string) error {
	sd, err := from.Open(path.Dir(src))
	if err != nil {
		return err
	}
	defer sd.Close()
	dd, err := to.Open(path.Dir(dst))
	if err != nil {
		return err
	}
	defer dd.Close()
	if err := renameat(sd, path.Base(src), dd, path.Base(dst)); err != nil {
		return &os.LinkError{Op: "renameat", Old: src, New: dst, Err: err}
	}
	return nil
}

// copyAcross copies src in from to dst in to, modes and mtimes kept, a seam
// for the tests.
var copyAcross = func(from *os.Root, src string, to *os.Root, dst string) error {
	return copyBetween(from, src, to, dst, nil, "")
}

// moveSnapshot moves each copy the snapshot holds to bdir/SnapDir/<path>,
// its manifest removed first, and sets e.modes to the real modes of the
// directories the copies widened, by path under bdir. Across filesystems it
// copies, and removes the originals only once every copy is whole. No
// snapshot moves nothing.
func (e *engine) moveSnapshot() error {
	root, err := os.OpenRoot(e.dir)
	if err != nil {
		return err
	}
	defer root.Close()
	snap := loadSnapshot(root)
	if snap == nil {
		removeTree(root, PrevDir)
		return nil
	}
	if err := root.Remove(snapManifest); err != nil {
		return err
	}
	dst := e.bdir + "/" + SnapDir
	if err := e.broot.Mkdir(dst, 0o770); err != nil {
		return err
	}
	e.modes = map[string]fs.FileMode{}
	for _, t := range snap.Targets {
		if !t.Existed {
			continue
		}
		to := dst + "/" + t.Path
		if err := e.broot.MkdirAll(path.Dir(to), 0o770); err != nil {
			return err
		}
		src := PrevDir + "/" + t.Copy
		err := renameAt(root, src, e.broot, to)
		if errors.Is(err, syscall.EXDEV) {
			// A stopped move starts no copy: its cleanup said none had.
			if !e.move.CompareAndSwap(moveRenaming, moveCopying) && e.move.Load() != moveCopying {
				return errStopped
			}
			err = copyAcross(root, src, e.broot, to)
		}
		if err != nil {
			return err
		}
		for rel, m := range t.Dirs {
			e.modes[strings.TrimSuffix(SnapDir+"/"+t.Path+"/"+rel, "/")] = fs.FileMode(m)
		}
	}
	if !e.move.CompareAndSwap(moveCopying, moveCopied) && e.move.Load() == moveStopped {
		return errStopped
	}
	return removePrev(root)
}

// removePrev removes PrevDir in root, a seam for the tests.
var removePrev = func(root *os.Root) error { return removeTree(root, PrevDir) }

// tarDir writes bdir's tree, names relative to it, into out (660, through
// out.part), all within root: modes override a directory's mode by its name.
// Symlinks are kept as links and special files skipped.
func tarDir(root *os.Root, bdir, out string, modes map[string]fs.FileMode) error {
	part := out + ".part"
	f, err := root.OpenFile(part, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o660)
	if err != nil {
		return err
	}
	done := false
	defer func() {
		if !done {
			f.Close()
			root.Remove(part)
		}
	}()
	if err := f.Chmod(0o660); err != nil {
		return err
	}
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	if err := tarTree(root, tw, bdir, "", modes); err != nil {
		return err
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	if err := f.Sync(); err != nil {
		return err
	}
	if err := f.Close(); err != nil {
		root.Remove(part)
		done = true
		return err
	}
	done = true
	if err := root.Rename(part, out); err != nil {
		root.Remove(part)
		return err
	}
	return nil
}

func tarTree(root *os.Root, tw *tar.Writer, base, rel string, modes map[string]fs.FileMode) error {
	at := base
	if rel != "" {
		at = base + "/" + rel
	}
	d, err := root.Open(at)
	if err != nil {
		return err
	}
	names, err := d.Readdirnames(-1)
	d.Close()
	if err != nil {
		return &fs.PathError{Op: "read", Path: at, Err: err}
	}
	sort.Strings(names)
	for _, n := range names {
		name := n
		if rel != "" {
			name = rel + "/" + n
		}
		p := base + "/" + name
		fi, err := root.Lstat(p)
		if err != nil {
			return err
		}
		link := ""
		switch {
		case fi.Mode()&fs.ModeSymlink != 0:
			if link, err = root.Readlink(p); err != nil {
				return err
			}
		case fi.IsDir(), fi.Mode().IsRegular():
		default:
			continue
		}
		h, err := tar.FileInfoHeader(fi, link)
		if err != nil {
			return err
		}
		h.Name = name
		h.Uname, h.Gname = "", ""
		if fi.IsDir() {
			h.Name += "/"
			if m, ok := modes[name]; ok {
				h.Mode = fileModeBits(m)
			}
		}
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		switch {
		case fi.IsDir():
			if err := tarTree(root, tw, base, name, modes); err != nil {
				return err
			}
		case fi.Mode().IsRegular():
			in, err := root.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
			if err != nil {
				return err
			}
			_, err = io.CopyN(tw, in, fi.Size())
			in.Close()
			if err != nil {
				return &fs.PathError{Op: "read", Path: p, Err: err}
			}
		}
	}
	return nil
}

// fileModeBits is a tar header's mode: permissions and the setuid, setgid
// and sticky bits in their c_ISUID places.
func fileModeBits(m fs.FileMode) int64 {
	b := int64(m.Perm())
	if m&fs.ModeSetuid != 0 {
		b |= 0o4000
	}
	if m&fs.ModeSetgid != 0 {
		b |= 0o2000
	}
	if m&fs.ModeSticky != 0 {
		b |= 0o1000
	}
	return b
}

// prune applies retention once a run is recorded, never failing it.
func (e *engine) prune() {
	root := e.broot
	if root == nil {
		r, err := os.OpenRoot(filepath.Join(e.dir, Backups))
		if errors.Is(err, fs.ErrNotExist) {
			return
		}
		if err != nil {
			e.note("could not open %s/%s to apply backup retention: %v", e.dir, Backups, err)
			return
		}
		defer r.Close()
		root = r
	}
	removed, errs := pruneBackups(root, filepath.Join(e.dir, Backups), e.now())
	for _, r := range removed {
		e.note("removed %s/%s — older than 24 hours, and a newer one is kept", Backups, r)
	}
	for _, err := range errs {
		e.note("%v", err)
	}
}

// pruneBackups keeps, of the regular files in root (backups/, shown as at)
// named as kasbah names a backup, every one stamped within KeepFor of now and
// the newest older one, and removes the rest. Nothing else there is touched.
func pruneBackups(root *os.Root, at string, now time.Time) ([]string, []error) {
	d, err := root.Open(".")
	var es []fs.DirEntry
	if err == nil {
		es, err = d.ReadDir(-1)
		d.Close()
	}
	if err != nil {
		return nil, []error{fmt.Errorf("could not list %s to apply backup retention: %v", at, err)}
	}
	type bk struct {
		name string
		at   time.Time
	}
	var old []bk
	cut := now.Add(-KeepFor)
	for _, en := range es {
		g := reBackup.FindStringSubmatch(en.Name())
		if g == nil || !en.Type().IsRegular() {
			continue
		}
		at, err := time.Parse(stampLayout, g[2])
		if err != nil || !at.Before(cut) {
			continue
		}
		old = append(old, bk{en.Name(), at})
	}
	sort.Slice(old, func(i, j int) bool {
		if !old[i].at.Equal(old[j].at) {
			return old[i].at.Before(old[j].at)
		}
		return old[i].name < old[j].name
	})
	var removed []string
	var errs []error
	for i := 0; i+1 < len(old); i++ {
		if err := root.Remove(old[i].name); err != nil {
			errs = append(errs, fmt.Errorf("could not remove the expired backup %s/%s: %v", at, old[i].name, err))
			continue
		}
		removed = append(removed, old[i].name)
	}
	return removed, errs
}

// writeHooks renders HooksFile as .kasbah-client is written: temp and
// rename, 644, only when it changed. A failure is said, never the run's.
func (e *engine) writeHooks() {
	h := Hooks{Backup: e.sp.Backup, Restore: e.sp.Restore, Targets: e.sp.Targets}
	for _, l := range []*[]string{&h.Backup, &h.Restore, &h.Targets} {
		if *l == nil {
			*l = []string{}
		}
	}
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.Encode(h)
	b := buf.Bytes()
	at := filepath.Join(e.dir, HooksFile)
	if fi, err := os.Lstat(at); err == nil && !fi.Mode().IsRegular() {
		e.note("%s exists and is not a regular file — left alone", at)
		return
	}
	if old, err := os.ReadFile(at); err == nil && string(old) == string(b) {
		return
	}
	if err := remote.Install(at, b, 0o644); err != nil {
		e.note("%v — the server's record of %s's backup and restore hooks is not up to date", err, e.sp.Version)
	}
}
