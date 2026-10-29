package deploy

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/user"
	"path"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/treesync"
)

// PrevDir holds, inside the project, the files the live stack started from
// wherever a run overwrote them; the engine's revert puts them back. It is
// removed whenever the files on disk are the live stack's again.
const PrevDir = ".kasbah-prev"

const snapManifest = PrevDir + "/snapshot.json"

// snapshot is snapshot.json: the token of the run it now serves, and each
// target with whether it existed before the live stack's files were touched.
type snapshot struct {
	Token   string       `json:"token"`
	Targets []snapTarget `json:"targets"`
	// IDs are each built image's :current id the live stack started from,
	// "" for none: recorded by the first engine run the snapshot serves.
	IDs map[string]string `json:"ids,omitempty"`
}

type snapTarget struct {
	Path    string `json:"path"`
	Existed bool   `json:"existed"`
	// Copy is where the copy is, under PrevDir.
	Copy string `json:"copy"`
	// Dirs are the real modes of directories the copy holds widened to
	// owner rwx, by path under the copy ("" for the copy itself).
	Dirs map[string]uint32 `json:"dirs,omitempty"`
}

// under is whether p is q or inside it.
func under(p, q string) bool { return p == q || strings.HasPrefix(p, q+"/") }

// SnapshotTargets is every path a run overwrites: the sync destinations and
// .env, a path inside another one dropped.
func SnapshotTargets(entries []Entry) []string {
	all := []string{".env"}
	for _, e := range entries {
		all = append(all, e.Dst)
	}
	sort.Strings(all)
	var out []string
	for _, p := range all {
		inside := false
		for _, q := range out {
			if under(p, q) {
				inside = true
				break
			}
		}
		if !inside {
			out = append(out, p)
		}
	}
	return out
}

func validTarget(p string) bool {
	if under(p, PrevDir) {
		return false
	}
	for _, seg := range strings.Split(p, "/") {
		if seg == "" || seg == "." || seg == ".." || strings.ContainsAny(seg, "\x00") {
			return false
		}
	}
	return true
}

func validToken(t string) bool {
	return t != "" && validTarget(t) && !strings.Contains(t, "/") && t != "snapshot.json" && !strings.HasPrefix(t, ".")
}

func loadSnapshot(root *os.Root) *snapshot {
	b, err := root.ReadFile(snapManifest)
	if err != nil {
		return nil
	}
	var s snapshot
	if json.Unmarshal(b, &s) != nil || s.Token == "" {
		return nil
	}
	// A copy that is gone is a drop cut short: no snapshot at all.
	for _, t := range s.Targets {
		if !validTarget(t.Path) || t.Existed && (t.Copy == "" || !validTarget(t.Copy)) {
			return nil
		}
		if _, err := root.Lstat(PrevDir + "/" + t.Copy); t.Existed && err != nil {
			return nil
		}
	}
	return &s
}

// takeSnapshot is `kasbah remote deploy snapshot DIR TOKEN TARGET…`, under
// .deploy.lock. A snapshot already there is the live stack's files — a run
// that failed on the workstation left it — so its entries stay and only
// targets it lacks are copied from disk; snapshot.json is written last, so
// one cut short reverts nothing. A missing DIR is a first deploy.
func takeSnapshot(dir, token string, targets []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: snapshot: "+format+"\n", a...)
		return 1
	}
	if !strings.HasPrefix(dir, "/") || !validToken(token) {
		return fail("usage: snapshot DIR TOKEN TARGET… (DIR absolute)")
	}
	for _, t := range targets {
		if !validTarget(t) {
			return fail("'%s' is not a path inside the project kasbah can keep a copy of — nothing was changed", t)
		}
	}
	if fi, err := os.Stat(dir); errors.Is(err, fs.ErrNotExist) {
		fmt.Fprintln(stdout, "snapshot=none")
		return 0
	} else if err != nil || !fi.IsDir() {
		return fail("%s is not a directory", dir)
	}
	lock, holder, err := serverlock.Project(dir)
	if err != nil {
		return fail("could not open the lock file %s/.deploy.lock — nothing was changed", dir)
	}
	if lock == nil {
		return fail("%s is running in %s — it holds %s/.deploy.lock. Nothing was changed; re-run once it has finished.", holder, dir, dir)
	}
	defer lock.Close()
	root, err := os.OpenRoot(dir)
	if err != nil {
		return fail("cannot open %s: %v", dir, err)
	}
	defer root.Close()

	old := loadSnapshot(root)
	fresh := old == nil
	if fresh {
		if err := removeTree(root, PrevDir); err != nil {
			return fail("could not remove %s/%s, which holds no whole snapshot: %v — nothing was changed", dir, PrevDir, err)
		}
		old = &snapshot{}
	} else {
		fmt.Fprintf(stderr, "remote: snapshot: kept %s/%s — a run that did not finish left it, and it holds the files the running stack started from\n", dir, PrevDir)
	}
	err = root.MkdirAll(PrevDir+"/"+token, 0o770)
	snap := snapshot{Token: token, IDs: old.IDs}
	var added []snapTarget
	for _, t := range targets {
		if err != nil {
			break
		}
		covered := false
		for _, o := range old.Targets {
			covered = covered || under(t, o.Path)
		}
		if !covered {
			var st snapTarget
			st, err = copyTarget(root, token, t, old.Targets)
			added = append(added, st)
		}
	}
	// What the old snapshot keeps: every entry no new target took in.
	for _, o := range old.Targets {
		absorbed := false
		for _, a := range added {
			absorbed = absorbed || under(o.Path, a.Path)
		}
		if !absorbed {
			snap.Targets = append(snap.Targets, o)
		}
	}
	snap.Targets = append(snap.Targets, added...)
	if err == nil {
		b, _ := json.Marshal(snap)
		err = writeIn(root, snapManifest, b)
	}
	if err != nil {
		if fresh {
			removeTree(root, PrevDir)
		} else {
			removeTree(root, PrevDir+"/"+token)
		}
		return fail("%s — nothing was changed, and a failed deploy could not be reverted without it", snapshotError(dir, err))
	}
	// Copies no entry names any more go.
	keep := map[string]bool{"snapshot.json": true}
	for _, t := range snap.Targets {
		if t.Existed {
			keep[strings.SplitN(t.Copy, "/", 2)[0]] = true
		}
	}
	if d, err := root.Open(PrevDir); err == nil {
		names, _ := d.Readdirnames(-1)
		d.Close()
		for _, n := range names {
			if !keep[n] {
				removeTree(root, PrevDir+"/"+n)
			}
		}
	}
	fmt.Fprintln(stdout, "snapshot=written")
	return 0
}

// copyTarget copies t from disk under PrevDir/gen, then lays over it the old
// entries inside t: those hold what the live stack started from.
func copyTarget(root *os.Root, gen, t string, old []snapTarget) (snapTarget, error) {
	st := snapTarget{Path: t, Copy: gen + "/" + t, Dirs: map[string]uint32{}}
	dst := PrevDir + "/" + st.Copy
	if err := root.MkdirAll(path.Dir(dst), 0o770); err != nil {
		return st, err
	}
	_, lerr := root.Lstat(t)
	switch {
	case lerr == nil:
		st.Existed = true
		if err := copyEntry(root, t, dst, st.Dirs, ""); err != nil {
			return st, err
		}
	case !errors.Is(lerr, fs.ErrNotExist):
		return st, lerr
	}
	for _, o := range old {
		if o.Path == t || !under(o.Path, t) {
			continue
		}
		rel := strings.TrimPrefix(o.Path, t+"/")
		at := dst + "/" + rel
		if err := removeTree(root, at); err != nil {
			return st, err
		}
		if !o.Existed {
			continue
		}
		if err := root.MkdirAll(path.Dir(at), 0o770); err != nil {
			return st, err
		}
		if err := copyEntry(root, PrevDir+"/"+o.Copy, at, nil, ""); err != nil {
			return st, err
		}
		for k, m := range o.Dirs {
			st.Dirs[strings.TrimSuffix(rel+"/"+k, "/")] = m
		}
		st.Existed = true
	}
	if len(st.Dirs) == 0 {
		st.Dirs = nil
	}
	return st, nil
}

// snapshotError names the path that could not be copied, and the likely
// cause when it is permissions.
func snapshotError(dir string, err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) && errors.Is(err, fs.ErrPermission) {
		who := fmt.Sprintf("uid %d", os.Getuid())
		if u, uerr := user.Current(); uerr == nil {
			who = u.Username
		}
		return fmt.Sprintf("could not copy aside %s/%s: %s may not read it (%v). A file a container wrote into a directory the sync: list ships is the usual cause — make it readable by the kasbah group, or keep it out of the synced directory", dir, pe.Path, who, pe.Err)
	}
	return fmt.Sprintf("could not copy aside what this run replaces in %s: %v", dir, err)
}

// writeIn is a temp file renamed over name.
func writeIn(root *os.Root, name string, b []byte) error {
	tmp := name + ".part"
	if err := root.WriteFile(tmp, b, 0o664); err != nil {
		return err
	}
	return root.Rename(tmp, name)
}

// removeTree is RemoveAll; one that fails on a directory this user may not
// write is retried after making the directories it owns writable.
func removeTree(root *os.Root, p string) error {
	if root.RemoveAll(p) == nil {
		return nil
	}
	var widen func(q string)
	widen = func(q string) {
		fi, err := root.Lstat(q)
		if err != nil || !fi.IsDir() {
			return
		}
		root.Chmod(q, fi.Mode().Perm()|0o700)
		if d, err := root.Open(q); err == nil {
			names, _ := d.Readdirnames(-1)
			d.Close()
			for _, n := range names {
				widen(q + "/" + n)
			}
		}
	}
	widen(p)
	return root.RemoveAll(p)
}

// copyEntry copies src to the new dst within root, never following a
// symlink: modes, mtimes and symlinks kept, special files skipped. With dirs
// set, a directory lacking owner rwx is written with it and its mode recorded
// at rel, so the copy can always be removed.
func copyEntry(root *os.Root, src, dst string, dirs map[string]uint32, rel string) error {
	fi, err := root.Lstat(src)
	if err != nil {
		return err
	}
	mode := fi.Mode() & (fs.ModePerm | fs.ModeSetuid | fs.ModeSetgid | fs.ModeSticky)
	switch {
	case fi.Mode()&fs.ModeSymlink != 0:
		target, err := root.Readlink(src)
		if err != nil {
			return err
		}
		if err := root.Symlink(target, dst); err != nil {
			return err
		}
		d, err := root.Open(path.Dir(dst))
		if err != nil {
			return err
		}
		defer d.Close()
		mt := fi.ModTime()
		return treesync.Lutimes(d, path.Base(dst), mt.Unix(), int64(mt.Nanosecond()))
	case fi.IsDir():
		if err := root.Mkdir(dst, 0o700); err != nil {
			return err
		}
		d, err := root.Open(src)
		if err != nil {
			return err
		}
		names, err := d.Readdirnames(-1)
		d.Close()
		if err != nil {
			return &fs.PathError{Op: "read", Path: src, Err: err}
		}
		for _, n := range names {
			sub := n
			if rel != "" {
				sub = rel + "/" + n
			}
			if err := copyEntry(root, src+"/"+n, dst+"/"+n, dirs, sub); err != nil {
				return err
			}
		}
		if dirs != nil && mode&0o700 != 0o700 {
			dirs[rel] = uint32(mode)
			mode |= 0o700
		}
	case fi.Mode().IsRegular():
		in, err := root.OpenFile(src, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := root.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return err
		}
		_, cerr := io.Copy(out, in)
		if err := out.Close(); cerr == nil {
			cerr = err
		}
		if cerr != nil {
			return &fs.PathError{Op: "read", Path: src, Err: cerr}
		}
	default:
		return nil
	}
	if err := root.Chmod(dst, mode); err != nil {
		return err
	}
	return root.Chtimes(dst, fi.ModTime(), fi.ModTime())
}

// dropSnapshot removes PrevDir, its manifest first and through a signal:
// the files on disk are the live stack's.
func dropSnapshot(dir string) {
	release := atexit.Hold(func(os.Signal) {})
	defer release()
	if root, err := os.OpenRoot(dir); err == nil {
		root.Remove(snapManifest)
		removeTree(root, PrevDir)
		root.Close()
	}
}

// pinIDs is the :current ids a revert goes back to: the snapshot's where it
// has them, current's (recorded into it) where not; current's alone when the
// snapshot is not token's. A record that could not be written is said on warn.
func pinIDs(dir, token string, images []string, current map[string]string, warn io.Writer) map[string]string {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return current
	}
	defer root.Close()
	snap := loadSnapshot(root)
	if snap == nil || snap.Token != token {
		return current
	}
	if snap.IDs == nil {
		snap.IDs = map[string]string{}
	}
	ids, changed := map[string]string{}, false
	for _, img := range images {
		id, ok := snap.IDs[img]
		if !ok {
			id, changed = current[img], true
			snap.IDs[img] = id
		}
		if id != "" {
			ids[img] = id
		}
	}
	if changed {
		b, _ := json.Marshal(snap)
		if err := writeIn(root, snapManifest, b); err != nil {
			fmt.Fprintf(warn, "remote: could not record the :current ids in %s/%s (%v) — a revert in this run goes back to them, a later run's would not\n", dir, snapManifest, err)
		}
	}
	return ids
}

// Replaced is where a restore keeps the .env it replaced when that differs
// from the snapshot's: an operator's fix is never lost.
const Replaced = ".env.kasbah-replaced"

// restored is what a restore did: the targets put back, and Saved when the
// .env on disk was kept as Replaced.
type restored struct {
	Done []string
	// Partial is the directory targets a reconcile left half put back.
	Partial []string
	// Notes are what a restore that worked could not do exactly.
	Notes []string
	Saved string
}

// keepEnv saves the current .env as Replaced, unless it is the snapshot's.
func keepEnv(root *os.Root, t snapTarget) (bool, error) {
	cur, err := root.ReadFile(".env")
	if errors.Is(err, fs.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if t.Existed {
		if old, err := root.ReadFile(PrevDir + "/" + t.Copy); err == nil && string(old) == string(cur) {
			return false, nil
		}
	}
	tmp := Replaced + ".part"
	root.Remove(tmp)
	if err := root.WriteFile(tmp, cur, 0o660); err != nil {
		return false, err
	}
	if err := root.Chmod(tmp, 0o660); err != nil {
		return false, err
	}
	return true, root.Rename(tmp, Replaced)
}

// errForeign is a snapshot that is not this run's: nothing was put back.
var errForeign = errors.New("holds no snapshot of this run")

// restore puts the snapshot back if it is token's. Each target is staged
// beside itself; what is there is renamed aside, the stage renamed in, and
// the aside copy removed. Every target is tried; the first failure returns.
func restore(dir, token string) (*restored, error) {
	release := atexit.Hold(func(os.Signal) {})
	defer release()
	res := &restored{}
	root, err := os.OpenRoot(dir)
	if err != nil {
		return res, err
	}
	defer root.Close()
	snap := loadSnapshot(root)
	if snap == nil || token == "" || snap.Token != token {
		return res, fmt.Errorf("%s/%s %w, so nothing was put back", dir, PrevDir, errForeign)
	}
	var first error
	for i, t := range snap.Targets {
		if t.Path == ".env" {
			saved, err := keepEnv(root, t)
			if err != nil {
				// Never replaced unsaved.
				if first == nil {
					first = fmt.Errorf("could not keep the current .env as %s (%v), so .env was not put back", Replaced, err)
				}
				continue
			}
			if saved {
				res.Saved = dir + "/" + Replaced
			}
		}
		if t.Existed && isDir(root, t.Path) && isDir(root, PrevDir+"/"+t.Copy) {
			// In place: a container's bind mount holds the directory's inode.
			rc := &reconcile{root: root, dirs: t.Dirs, widened: map[string]fs.FileMode{}}
			err := rc.dir(PrevDir+"/"+t.Copy, t.Path, "")
			if err != nil {
				rc.narrow()
			}
			res.Notes = append(res.Notes, rc.notes...)
			if err != nil && errors.Is(err, fs.ErrPermission) {
				if aside, serr := swapWhole(root, t, i, true); serr == nil {
					res.Notes = append(res.Notes, fmt.Sprintf("%s could not be put back in place (%v), so it was replaced whole — the running container's mount still sees %s/%s, kept; remove it once that container is recreated", t.Path, err, dir, aside))
					res.Done = append(res.Done, t.Path)
					continue
				}
			}
			switch {
			case err == nil:
				res.Done = append(res.Done, t.Path)
			case rc.changed:
				res.Partial = append(res.Partial, t.Path)
				if first == nil {
					first = fmt.Errorf("could not put all of %s back: %v", t.Path, err)
				}
			case first == nil:
				first = fmt.Errorf("could not put %s back: %v", t.Path, err)
			}
			continue
		}
		if _, err := swapWhole(root, t, i, false); err != nil {
			if first == nil {
				first = fmt.Errorf("could not put %s back: %v", t.Path, err)
			}
		} else {
			res.Done = append(res.Done, t.Path)
		}
	}
	return res, first
}

// isDir is whether p is a directory, not a symlink to one.
func isDir(root *os.Root, p string) bool {
	fi, err := root.Lstat(p)
	return err == nil && fi.IsDir()
}

// swapWhole puts target i back by a rename beside it: its copy staged, the
// current one moved aside, then removed once the copy is in unless keep —
// a container's mount may hold it. It returns the aside's path.
func swapWhole(root *os.Root, t snapTarget, i int, keep bool) (string, error) {
	parent := path.Dir(t.Path)
	stage := path.Join(parent, fmt.Sprintf(".kasbah-restore.%d.%d", os.Getpid(), i))
	aside := path.Join(parent, fmt.Sprintf(".kasbah-aside.%d.%d", os.Getpid(), i))
	err := root.MkdirAll(parent, 0o770)
	if err == nil && t.Existed {
		removeTree(root, stage)
		err = copyEntry(root, PrevDir+"/"+t.Copy, stage, nil, "")
		for rel, m := range t.Dirs {
			if err == nil {
				err = root.Chmod(strings.TrimSuffix(stage+"/"+rel, "/"), fs.FileMode(m))
			}
		}
	}
	moved := false
	if err == nil {
		if _, lerr := root.Lstat(t.Path); lerr == nil {
			removeTree(root, aside)
			err, moved = root.Rename(t.Path, aside), true
		}
	}
	if err == nil && t.Existed {
		if err = root.Rename(stage, t.Path); err != nil && moved {
			root.Rename(aside, t.Path)
			moved = false
		}
	}
	if err == nil && moved && !keep {
		removeTree(root, aside)
	}
	if err != nil {
		removeTree(root, stage)
	}
	return aside, err
}

// restoreFault, set by tests, fails an operation of the in-place restore.
var restoreFault func(op, p string) error

// reconcile puts a directory target back inside the existing directory,
// keeping every directory's inode; changed says it has altered anything.
type reconcile struct {
	root    *os.Root
	dirs    map[string]uint32
	n       int
	changed bool
	notes   []string
	// widened is each directory given owner rwx and not yet settled, with
	// the mode it had.
	widened map[string]fs.FileMode
}

// narrow gives each directory widened and never settled its mode back.
func (rc *reconcile) narrow() {
	for _, p := range sortedKeys(rc.widened) {
		if err := rc.root.Chmod(p, rc.widened[p]); err != nil {
			rc.notes = append(rc.notes, fmt.Sprintf("%s was left mode %v, not %v: %v", p, rc.widened[p]|0o700, rc.widened[p], err))
		}
	}
}

func (rc *reconcile) fault(op, p string) error {
	if restoreFault != nil {
		return restoreFault(op, p)
	}
	return nil
}

// dir makes dst hold what src holds: every entry of src is brought back
// first — a directory on both sides reconciled, anything else staged beside
// its place and renamed over it — then entries src lacks are removed, then
// dst takes its mode and mtime, best-effort.
func (rc *reconcile) dir(src, dst, rel string) error {
	root := rc.root
	sfi, err := root.Lstat(src)
	if err != nil {
		return err
	}
	want, err := dirNames(root, src)
	if err != nil {
		return err
	}
	have, err := dirNames(root, dst)
	if err != nil {
		return err
	}
	for _, x := range sortedKeys(want) {
		from, to := src+"/"+x, dst+"/"+x
		sub := x
		if rel != "" {
			sub = rel + "/" + x
		}
		if isDir(root, from) && isDir(root, to) {
			if err := rc.dir(from, to, sub); err != nil {
				return err
			}
			continue
		}
		if fi, err := root.Lstat(to); err == nil && !fi.IsDir() && sameFile(root, from, to) {
			continue
		}
		if err := rc.writable(dst); err != nil {
			return err
		}
		if err := rc.put(from, to, dst); err != nil {
			return err
		}
	}
	for _, x := range sortedKeys(have) {
		if want[x] {
			continue
		}
		if err := rc.writable(dst); err != nil {
			return err
		}
		err := rc.fault("remove", dst+"/"+x)
		if err == nil {
			err = removeTree(root, dst+"/"+x)
		}
		if err != nil {
			return err
		}
		rc.changed = true
	}
	mode := sfi.Mode() & (fs.ModePerm | fs.ModeSetgid | fs.ModeSetuid | fs.ModeSticky)
	if m, ok := rc.dirs[rel]; ok {
		mode = fs.FileMode(m)
	}
	rc.settle(dst, mode, sfi.ModTime())
	return nil
}

// put stages from beside to and renames it over to; a directory swapped with
// a non-directory goes aside first, as a rename cannot replace it.
func (rc *reconcile) put(from, to, dst string) error {
	root := rc.root
	rc.n++
	stage := fmt.Sprintf("%s/.kasbah-restore.%d.%d", dst, os.Getpid(), rc.n)
	removeTree(root, stage)
	err := rc.fault("stage", stage)
	if err == nil {
		err = copyEntry(root, from, stage, nil, "")
	}
	if err != nil {
		removeTree(root, stage)
		return err
	}
	if _, lerr := root.Lstat(to); lerr == nil && (isDir(root, to) || isDir(root, stage)) {
		aside := fmt.Sprintf("%s/.kasbah-aside.%d.%d", dst, os.Getpid(), rc.n)
		err := rc.fault("rename", to)
		if err == nil {
			err = root.Rename(to, aside)
		}
		if err != nil {
			removeTree(root, stage)
			return err
		}
		if err := root.Rename(stage, to); err != nil {
			root.Rename(aside, to)
			removeTree(root, stage)
			return err
		}
		rc.changed = true
		if err := removeTree(root, aside); err != nil {
			rc.notes = append(rc.notes, fmt.Sprintf("could not remove %s, which the restore moved aside: %v", aside, err))
		}
		return nil
	}
	err = rc.fault("rename", to)
	if err == nil {
		err = root.Rename(stage, to)
	}
	if err != nil {
		removeTree(root, stage)
		return err
	}
	rc.changed = true
	return nil
}

// writable gives dst owner rwx when it lacks it, so entries can be put in
// it; settle sets the real mode back.
func (rc *reconcile) writable(dst string) error {
	fi, err := rc.root.Lstat(dst)
	if err != nil {
		return err
	}
	if fi.Mode().Perm()&0o700 == 0o700 {
		return nil
	}
	err = rc.fault("chmod", dst)
	if err == nil {
		err = rc.root.Chmod(dst, fi.Mode().Perm()|0o700)
	}
	if err == nil {
		rc.widened[dst] = fi.Mode().Perm()
	}
	return err
}

// settle gives dst its mode and mtime, each only where it differs, a failure
// only noted: the directory may be a container's, its contents still back.
func (rc *reconcile) settle(dst string, mode fs.FileMode, mtime time.Time) {
	fi, err := rc.root.Lstat(dst)
	if err != nil {
		return
	}
	delete(rc.widened, dst)
	if fi.Mode()&(fs.ModePerm|fs.ModeSetgid|fs.ModeSetuid|fs.ModeSticky) != mode {
		err := rc.fault("chmod", dst)
		if err == nil {
			err = rc.root.Chmod(dst, mode)
		}
		if err != nil {
			rc.notes = append(rc.notes, fmt.Sprintf("%s is back, and kept its mode %v rather than %v: %v", dst, fi.Mode().Perm(), mode.Perm(), err))
		}
	}
	if fi, err = rc.root.Lstat(dst); err == nil && !fi.ModTime().Equal(mtime) {
		err := rc.fault("chtimes", dst)
		if err == nil {
			err = rc.root.Chtimes(dst, mtime, mtime)
		}
		if err != nil {
			rc.notes = append(rc.notes, fmt.Sprintf("%s is back, and kept its modification time: %v", dst, err))
		}
	}
}

func dirNames(root *os.Root, p string) (map[string]bool, error) {
	d, err := root.Open(p)
	if err != nil {
		return nil, err
	}
	defer d.Close()
	l, err := d.Readdirnames(-1)
	m := map[string]bool{}
	for _, x := range l {
		m[x] = true
	}
	return m, err
}

// sameFile is rsync's quick check on two non-directories: type, mode, size,
// mtime and, for a symlink, its target. The snapshot keeps mtimes, so a file
// the run did not touch is left.
func sameFile(root *os.Root, a, b string) bool {
	fa, err1 := root.Lstat(a)
	fb, err2 := root.Lstat(b)
	if err1 != nil || err2 != nil || fa.Mode() != fb.Mode() || fa.Size() != fb.Size() || !fa.ModTime().Equal(fb.ModTime()) {
		return false
	}
	if fa.Mode()&fs.ModeSymlink != 0 {
		ta, _ := root.Readlink(a)
		tb, _ := root.Readlink(b)
		return ta == tb
	}
	return fa.Mode().IsRegular()
}

// what says which targets a restore put back.
func (r *restored) what() string {
	var parts []string
	if len(r.Done) > 0 {
		parts = append(parts, "put back: "+strings.Join(r.Done, ", "))
	}
	if len(r.Partial) > 0 {
		parts = append(parts, "partly put back: "+strings.Join(r.Partial, ", "))
	}
	if len(parts) == 0 {
		return "nothing was put back"
	}
	return strings.Join(parts, "; ")
}

// mixed says which targets are part prev's, part v's, "" for none; with no
// prev, part as they were before the run.
func (r *restored) mixed(prev, v string) string {
	was := "as it was before this run"
	if prev != "" {
		was = prev + "'s"
	}
	var out []string
	for _, p := range r.Partial {
		out = append(out, p+" is part "+was+", part "+v+"'s")
	}
	return strings.Join(out, ", ")
}
