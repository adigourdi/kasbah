package migrate

import (
	"archive/tar"
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/probe"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// Dir and Lock are the server's migration directory (snapshots) and lock,
// under <apps>/.kasbah.
const (
	Dir  = ".kasbah/migrate"
	Lock = ".kasbah/migrate.lock"
)

// Report is what a server run did.
type Report struct {
	Undo bool `json:"undo"`
	From int  `json:"from"`
	To   int  `json:"to"`
	// Nothing is a run that found the marker already at To.
	Nothing  bool   `json:"nothing"`
	Snapshot string `json:"snapshot"`
	// SnapshotReused is a rerun after a failed run: the first run's snapshot
	// holds the originals, so no second one is written over them.
	SnapshotReused bool         `json:"snapshot_reused"`
	Steps          []StepReport `json:"steps"`
	// Marker is updated, unchanged or restored.
	Marker   string   `json:"marker"`
	Restored []string `json:"restored"`
	// Gone is an undo's files left out because their directory is gone (a
	// dropped project).
	Gone []string `json:"gone"`
	// Left is an undo's steps' Left: what it did not put back live.
	Left []string `json:"left,omitempty"`
}

// Keys is what a report must carry to be one (remote.Decode).
var Keys = []string{"undo", "from", "to", "nothing", "snapshot", "snapshot_reused", "steps", "marker", "restored", "gone"}

// ExitPartway is `kasbah remote migrate`'s exit when the run stopped after
// it began rewriting: the same command, re-run once the cause is fixed,
// resumes. Every other failure exits 1.
const ExitPartway = 3

// partway is a failure after the first rewrite.
type partway struct{ error }

func (p partway) Unwrap() error { return p.error }

// ExitRefused is its exit when a run or an undo is refused, nothing changed,
// with a next step that names the command: the server cannot know USER@HOST,
// so it prints the cause alone and a Refusal on stdout for the workstation.
const ExitRefused = 5

// Refusal is what ExitRefused reports.
type Refusal struct {
	// Way is "finish" (a stopped run: forward at Major), "stay" (a finished
	// one: left at Major), "aside" (Snapshot does not read back), "busy" (a
	// lock is held), "second" (Snapshot, of this second, already exists) or
	// "fix" (a file a step cannot rewrite, named in the cause).
	Way      string `json:"refused"`
	Major    int    `json:"major"`
	Snapshot string `json:"snapshot"`
}

// RefusalKeys is what a Refusal must carry to be one (remote.Decode).
var RefusalKeys = []string{"refused", "major", "snapshot"}

// Step is the next step on target, for a run or (undo) an undo.
func (r Refusal) Step(target string, undo bool) string {
	again := "kasbah migrate server " + target
	same := again
	if undo {
		same += " --undo"
	}
	switch r.Way {
	case "finish":
		return fmt.Sprintf("Finish the run instead: re-run `%s` with a kasbah of major %d — it picks up where it stopped. Or restore by hand from %s.", again, r.Major, r.Snapshot)
	case "stay":
		return fmt.Sprintf("Leave %s on major %d, or restore by hand from %s.", target, r.Major, r.Snapshot)
	case "aside":
		return fmt.Sprintf("Move %s aside, out of %s, and re-run `%s --undo`: it then looks past it.", r.Snapshot, filepath.Dir(r.Snapshot), again)
	case "busy":
		return fmt.Sprintf("Re-run `%s` once it has finished.", same)
	case "second":
		return fmt.Sprintf("Re-run `%s` in a second.", same)
	case "fix":
		return fmt.Sprintf("Fix the file the cause above names, then re-run `%s`.", again)
	}
	// Both ends ship together: only a server of another build gets here.
	return fmt.Sprintf("This kasbah does not know the server's next step %q — the server runs another build of kasbah than this workstation; the cause above is its own.", r.Way)
}

// refused is a run's or an undo's failure that Remote reports as ExitRefused.
type refused struct {
	err *cli.Error
	Refusal
}

func (r refused) Error() string { return r.err.Error() }
func (r refused) Unwrap() error { return r.err }

// busy is a refusal while a lock is held.
func busy(format string, a ...any) error {
	return refused{cli.Fail(format, a...), Refusal{Way: "busy"}}
}

const stampLayout = "20060102T150405Z"

var reSnapshot = regexp.MustCompile(`^([0-9]+)-to-([0-9]+)-([0-9]{8}T[0-9]{6}Z)\.tar$`)

// Undone is the suffix of the empty note beside a snapshot that an undo
// finished with.
const Undone = ".undone"

// Begun is the suffix of the empty note beside a snapshot whose run went on
// to its steps, written before the first rewrite.
const Begun = ".begun"

// undone is whether an undo finished with the snapshot at path.
func undone(path string) (bool, error) { return noted(path + Undone) }

// begun is whether the run that took the snapshot at path began its steps.
func begun(path string) (bool, error) { return noted(path + Begun) }

func noted(path string) (bool, error) {
	_, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, fmt.Errorf("could not check for %s: %v", path, err)
	}
	return true, nil
}

// SnapshotName is the tarball a run from major from to major to writes at t.
func SnapshotName(from, to int, t time.Time) string {
	return fmt.Sprintf("%d-to-%d-%s.tar", from, to, t.UTC().Format(stampLayout))
}

type locks []*os.File

func (l locks) release() {
	for _, f := range l {
		f.Close()
	}
}

// flock takes path exclusively without waiting; held is the holder's refusal.
func flock(path string, held func(path string) error) (*os.File, error) {
	f, err := serverlock.Open(path)
	if err != nil {
		return nil, fmt.Errorf("could not open the lock file %s: %v", path, err)
	}
	rc, err := f.SyscallConn()
	if err != nil {
		f.Close()
		return nil, fmt.Errorf("could not open the lock file %s: %v", path, err)
	}
	var lerr error
	rc.Control(func(fd uintptr) { lerr = syscall.Flock(int(fd), syscall.LOCK_EX|syscall.LOCK_NB) })
	if lerr != nil {
		f.Close()
		return nil, held(path)
	}
	return f, nil
}

// Projects is every project directory under apps, in byte order: a directory
// that is not reserved and not hidden.
func Projects(apps string) ([]string, error) {
	ents, err := os.ReadDir(apps)
	if err != nil {
		return nil, fmt.Errorf("could not list %s: %v", apps, err)
	}
	var out []string
	for _, e := range ents {
		n := e.Name()
		if !e.IsDir() || probe.IsReserved(n) || strings.HasPrefix(n, ".") {
			continue
		}
		out = append(out, n)
	}
	sort.Strings(out)
	return out, nil
}

// lockAll takes the migration lock, the server lock exclusive, then every
// project's .deploy.lock, so nothing changes under a run.
func lockAll(apps string) (locks, error) {
	var held locks
	f, err := flock(filepath.Join(apps, Lock), func(p string) error {
		return busy("a migration is running on this server — it holds the lock on %s", p)
	})
	if err != nil {
		return nil, err
	}
	held = append(held, f)
	sl, err := serverlock.Take(apps, serverlock.Exclusive, "kasbah migrate")
	if err != nil {
		held.release()
		if b := (*serverlock.Busy)(nil); errors.As(err, &b) {
			return nil, busy("%s is running on this server — it holds %s", b.Holder, b.Path)
		}
		return nil, err
	}
	if sl != nil {
		held = append(held, sl)
	}
	projects, err := Projects(apps)
	if err != nil {
		held.release()
		return nil, err
	}
	for _, p := range projects {
		f, err := flock(filepath.Join(apps, p, ".deploy.lock"), func(path string) error {
			return busy("a deploy, rollback or drop is running in %s — it holds the lock on %s", p, path)
		})
		if err != nil {
			held.release()
			return nil, err
		}
		held = append(held, f)
	}
	return held, nil
}

func readMarker(apps string) (*tree.Map, []byte, error) {
	path := marker.Path(apps)
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, nil, fmt.Errorf("could not read %s: %v", path, err)
	}
	v, perr := tree.ParseOne(body)
	m, ok := v.(*tree.Map)
	if perr != nil || !ok {
		return nil, nil, fmt.Errorf("%s is not a JSON object", path)
	}
	return m, body, nil
}

// Majors is a marker's major and ours as integers; a version that cannot be
// compared is an error here, never a guess.
func Majors(m *tree.Map, ours string) (from, to int, err error) {
	version := strings.TrimRight(tree.TextAt(m, "kasbah_version"), "\n")
	from, err1 := strconv.Atoi(marker.Major(version))
	to, err2 := strconv.Atoi(marker.Major(ours))
	if err1 != nil || from < 0 {
		return 0, 0, fmt.Errorf("the marker records kasbah_version '%s', which has no major to migrate from", version)
	}
	if err2 != nil || to < 0 {
		return 0, 0, fmt.Errorf("this kasbah's version '%s' has no major", ours)
	}
	return from, to, nil
}

// snapshot writes the files (relative to apps) and the marker, last, to
// <apps>/Dir/name, beside its name and renamed; absent files are left out.
func snapshot(apps, name string, rel []string) (string, error) {
	dir := filepath.Join(apps, Dir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", fmt.Errorf("could not create %s: %v", dir, err)
	}
	path := filepath.Join(dir, name)
	if _, err := os.Stat(path); err == nil {
		return "", refused{cli.Fail("%s already exists — a snapshot of this second was already written", path), Refusal{Way: "second", Snapshot: path}}
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	add := func(rel string) error {
		p := filepath.Join(apps, rel)
		fi, err := os.Stat(p)
		if os.IsNotExist(err) {
			return nil
		}
		if err != nil {
			return err
		}
		body, err := os.ReadFile(p)
		if err != nil {
			return err
		}
		h := &tar.Header{Name: rel, Mode: int64(fi.Mode().Perm()), Size: int64(len(body)), ModTime: fi.ModTime(), Typeflag: tar.TypeReg}
		if err := tw.WriteHeader(h); err != nil {
			return err
		}
		_, err = tw.Write(body)
		return err
	}
	for _, r := range append(append([]string{}, rel...), marker.Path("")[1:]) {
		if err := add(r); err != nil {
			return "", fmt.Errorf("could not snapshot %s: %v", r, err)
		}
	}
	if err := tw.Close(); err != nil {
		return "", err
	}
	if err := writeAtomic(path, buf.Bytes(), 0o644); err != nil {
		return "", err
	}
	return path, nil
}

// Run is the server side of `kasbah migrate server`: under the locks, every
// step's files judged, a snapshot, every step from the marker's major to
// ours, and the marker last.
func Run(apps, ours string, steps []Step, now time.Time) (*Report, error) {
	held, err := lockAll(apps)
	if err != nil {
		return nil, err
	}
	defer held.release()
	m, _, err := readMarker(apps)
	if err != nil {
		return nil, err
	}
	from, to, err := Majors(m, ours)
	if err != nil {
		return nil, err
	}
	r := &Report{From: from, To: to, Steps: []StepReport{}, Marker: "unchanged", Restored: []string{}, Gone: []string{}}
	if from == to {
		r.Nothing = true
		return r, nil
	}
	plan, err := Plan(steps, from, to)
	if err != nil {
		return nil, err
	}
	rel, err := files(apps, plan)
	if err != nil {
		return nil, err
	}
	// Every step's files are judged as they are now, before any snapshot:
	// exact while no step before the last rewrites a file.
	for _, s := range plan {
		_, _, err := prepare(apps, s)
		if st := (stop{}); errors.As(err, &st) {
			f := cli.Fail("step %d->%d cannot rewrite %s: it %s — this run changed nothing and took no snapshot", s.From, s.To, st.path, st.why)
			if prior, err := stopped(apps, from, to); err == nil && prior != "" {
				f = cli.Fail("step %d->%d cannot rewrite %s: it %s — this run changed nothing, but an earlier one stopped partway and %s holds the originals of what it rewrote", s.From, s.To, st.path, st.why, prior)
			}
			return nil, refused{f, Refusal{Way: "fix", Major: from}}
		}
		if err != nil {
			return nil, err
		}
	}
	// A run that began its steps and stopped left the originals in its
	// snapshot; a rerun keeps it so that an undo restores those, never the
	// half-migrated tree. One an undo has finished with is history, and one
	// whose run never began its steps rewrote nothing, so the live files are
	// the originals: either way a fresh one is taken.
	if r.Snapshot, err = stopped(apps, from, to); err != nil {
		return nil, err
	}
	if r.Snapshot != "" {
		r.SnapshotReused = true
	} else {
		if r.Snapshot, err = snapshot(apps, SnapshotName(from, to, now), rel); err != nil {
			return nil, err
		}
		if err := writeAtomic(r.Snapshot+Begun, nil, 0o644); err != nil {
			return nil, fmt.Errorf("%v — nothing was rewritten; a rerun takes a fresh snapshot", err)
		}
	}
	for _, s := range plan {
		var cost Cost
		if s.Warn != nil {
			cost = s.Warn(apps)
		}
		sr, err := apply(apps, s)
		sr.Warnings, sr.Notes = cost.Lost, cost.Notes
		if err == nil && s.Act != nil {
			if sr.Done, err = s.Act(apps); err != nil {
				err = fmt.Errorf("step %d->%d rewrote its files, then failed: %v", s.From, s.To, err)
			}
		}
		r.Steps = append(r.Steps, sr)
		// The report so far goes with the failure: what was done before it.
		if err != nil {
			return r, partway{fmt.Errorf("%v — the marker still says major %d; the originals are in %s", err, from, r.Snapshot)}
		}
	}
	own := tree.NewMap()
	own.Set("kasbah_version", ours)
	if err := writeAtomic(marker.Path(apps), marker.Render(tree.Merge(m, own)), marker.Mode); err != nil {
		return nil, partway{err}
	}
	r.Marker = "updated"
	return r, nil
}

// Find is the newest snapshot under apps from major from to major to, and
// its stamp; "" when there is none. A to of -1 matches any. It reads names
// alone: the notes beside one (Begun, Undone) are its caller's to weigh.
func Find(apps string, from, to int) (path string, at time.Time, err error) {
	ents, err := os.ReadDir(filepath.Join(apps, Dir))
	if errors.Is(err, os.ErrNotExist) {
		return "", time.Time{}, nil
	}
	if err != nil {
		return "", time.Time{}, fmt.Errorf("could not list %s: %v", filepath.Join(apps, Dir), err)
	}
	name, stamp := "", ""
	for _, e := range ents {
		m := reSnapshot.FindStringSubmatch(e.Name())
		if m == nil || !e.Type().IsRegular() {
			continue
		}
		f, _ := strconv.Atoi(m[1])
		t, _ := strconv.Atoi(m[2])
		if f != from || (to >= 0 && t != to) || m[3] < stamp {
			continue
		}
		name, stamp = e.Name(), m[3]
	}
	if name == "" {
		return "", time.Time{}, nil
	}
	at, _ = time.Parse(stampLayout, stamp)
	return filepath.Join(apps, Dir, name), at, nil
}

// findTo is the newest snapshot whose move ended at major to.
func findTo(apps string, to int) (string, time.Time, error) {
	best, at := "", time.Time{}
	for from := to - 1; from >= 0; from-- {
		p, t, err := Find(apps, from, to)
		if err != nil {
			return "", time.Time{}, err
		}
		if p != "" && (best == "" || t.After(at)) {
			best, at = p, t
		}
	}
	return best, at, nil
}

// DeployedSince is the first project whose versions.log has an entry newer
// than t, and that entry's stamp; "" when none has. A log that is absent or
// unreadable is a project never deployed.
func DeployedSince(apps string, t time.Time) (project, stamp string, err error) {
	projects, err := Projects(apps)
	if err != nil {
		return "", "", err
	}
	for _, p := range projects {
		data, err := os.ReadFile(filepath.Join(apps, p, vlog.Log))
		if err != nil {
			continue
		}
		for _, e := range vlog.Entries(string(data)) {
			if !e.OK {
				continue
			}
			if et, err := time.Parse(time.RFC3339, e.Time); err == nil && et.After(t) {
				return p, e.Time, nil
			}
		}
	}
	return "", "", nil
}

// Undo puts back the newest unfinished or finished migration, unless a
// project has deployed since its snapshot was taken; steps are the chain it
// was run from, whose Left the report carries.
func Undo(apps string, steps []Step) (r *Report, err error) {
	defer func() {
		if err == nil {
			r.Left = left(apps, steps, r.From, r.To)
		}
	}()
	return undo(apps)
}

// left is what an undo of the steps from major from to major to leaves live.
func left(apps string, steps []Step, from, to int) []string {
	plan, err := Plan(steps, from, to)
	if err != nil {
		return nil
	}
	var out []string
	for _, s := range plan {
		if s.Left != nil {
			out = append(out, s.Left(apps)...)
		}
	}
	return out
}

func undo(apps string) (*Report, error) {
	held, err := lockAll(apps)
	if err != nil {
		return nil, err
	}
	defer held.release()
	m, _, err := readMarker(apps)
	if err != nil {
		return nil, err
	}
	cur, _, err := Majors(m, "0.0.0")
	if err != nil {
		return nil, err
	}
	// A run that stopped partway left the marker where it started and its
	// snapshot, with no note, starting there.
	partial, at, err := Find(apps, cur, -1)
	if err != nil {
		return nil, err
	}
	if partial != "" {
		done, err := undone(partial)
		if err != nil {
			return nil, err
		}
		if !done {
			return undoPartial(apps, cur, partial, at)
		}
	}
	// Otherwise the snapshot whose move ended at the marker's major; a newest
	// file from another move is someone else's.
	path, at, err := findTo(apps, cur)
	if err != nil {
		return nil, err
	}
	if path == "" {
		if partial != "" {
			return nil, fmt.Errorf("nothing to undo: no migration snapshot ending at major %d under %s, and %s, the newest starting there, was already undone", cur, filepath.Join(apps, Dir), partial)
		}
		return nil, fmt.Errorf("nothing to undo: no migration snapshot ending at major %d under %s", cur, filepath.Join(apps, Dir))
	}
	from, _ := strconv.Atoi(reSnapshot.FindStringSubmatch(filepath.Base(path))[1])
	r := &Report{Undo: true, From: from, To: cur, Snapshot: path, Steps: []StepReport{}, Marker: "unchanged", Restored: []string{}, Gone: []string{}}
	if err := deployedSince(apps, path, at, Refusal{"stay", cur, path}); err != nil {
		return nil, err
	}
	var mk []byte
	done := func() string {
		if len(r.Restored) == 0 {
			return "nothing was restored"
		}
		return "already restored: " + strings.Join(r.Restored, ", ") + "; the marker was not"
	}
	err = walk(path, done, func(e entry) error {
		if e.name == marker.Path("")[1:] {
			mk = e.body
			return nil
		}
		if gone(apps, e.name) {
			r.Gone = append(r.Gone, e.name)
			return nil
		}
		if err := writeAtomic(filepath.Join(apps, e.name), e.body, e.mode); err != nil {
			return partway{err}
		}
		r.Restored = append(r.Restored, e.name)
		return nil
	})
	if err != nil {
		return nil, err
	}
	if mk == nil {
		return nil, fmt.Errorf("%s carries no marker, which an undo restores last — %s", path, done())
	}
	// The note before the marker: until the marker moves, a re-run picks this
	// snapshot again by its major.
	if err := note(path); err != nil {
		return nil, err
	}
	if err := writeAtomic(marker.Path(apps), mk, marker.Mode); err != nil {
		return nil, partway{err}
	}
	r.Marker = "restored"
	return r, nil
}

// undoPartial puts back the files of a run that stopped partway, those that
// differ from the snapshot (maybe none), then notes it done. The marker stays:
// it already says cur, and the snapshot's copy would drop a key written since.
func undoPartial(apps string, cur int, path string, at time.Time) (*Report, error) {
	sm := reSnapshot.FindStringSubmatch(filepath.Base(path))
	to, _ := strconv.Atoi(sm[2])
	r := &Report{Undo: true, From: cur, To: to, Snapshot: path, Steps: []StepReport{}, Marker: "unchanged", Restored: []string{}, Gone: []string{}}
	diff, err := differs(apps, path, r)
	if err != nil {
		return nil, refused{cli.Fail("%v", err), Refusal{"aside", cur, path}}
	}
	if len(diff) > 0 {
		if err := deployedSince(apps, path, at, Refusal{"finish", to, path}); err != nil {
			return nil, err
		}
	}
	for _, e := range diff {
		if err := writeAtomic(filepath.Join(apps, e.name), e.body, e.mode); err != nil {
			return nil, partway{err}
		}
		r.Restored = append(r.Restored, e.name)
	}
	if err := note(path); err != nil {
		return nil, err
	}
	return r, nil
}

// note records that an undo finished with the snapshot at path.
func note(path string) error {
	if err := writeAtomic(path+Undone, nil, 0o644); err != nil {
		return partway{err}
	}
	return nil
}

// gone is whether the directory a snapshot's file goes back into is gone.
func gone(apps, name string) bool {
	_, err := os.Stat(filepath.Dir(filepath.Join(apps, name)))
	return errors.Is(err, os.ErrNotExist)
}

// deployedSince refuses an undo of the snapshot at path, taken at at, once a
// project has deployed since; way is the way on.
func deployedSince(apps, path string, at time.Time, way Refusal) error {
	project, stamp, err := DeployedSince(apps, at)
	if err != nil {
		return err
	}
	if project != "" {
		return refused{cli.Fail("%s was deployed at %s, after the snapshot %s was taken — an undo would put files from before that deploy under it", project, stamp, path), way}
	}
	return nil
}

type entry struct {
	name string
	mode os.FileMode
	body []byte
}

// walk reads a snapshot's files in order; a read failure says what done
// reports was already restored.
func walk(path string, done func() string, each func(entry) error) error {
	f, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("could not open %s: %v", path, err)
	}
	defer f.Close()
	tr := tar.NewReader(f)
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return fmt.Errorf("%s is not a tarball kasbah wrote: %v — %s", path, err, done())
		}
		if h.Typeflag != tar.TypeReg || strings.HasPrefix(h.Name, "/") || strings.Contains(h.Name, "..") {
			return fmt.Errorf("%s holds %q, which is not a file under the apps path — %s", path, h.Name, done())
		}
		body, err := io.ReadAll(tr)
		if err != nil {
			return fmt.Errorf("could not read %s out of %s: %v — %s", h.Name, path, err, done())
		}
		if err := each(entry{h.Name, os.FileMode(h.Mode).Perm(), body}); err != nil {
			return err
		}
	}
}

// differs is the files in a snapshot, the marker aside, whose live copy is
// absent or not the snapshot's bytes; those whose directory is gone go to
// r.Gone instead.
func differs(apps, path string, r *Report) ([]entry, error) {
	var out []entry
	err := walk(path, func() string { return "nothing was restored" }, func(e entry) error {
		if e.name == marker.Path("")[1:] {
			return nil
		}
		if gone(apps, e.name) {
			r.Gone = append(r.Gone, e.name)
			return nil
		}
		if live, err := os.ReadFile(filepath.Join(apps, e.name)); err != nil || !bytes.Equal(live, e.body) {
			out = append(out, e)
		}
		return nil
	})
	return out, err
}

// stopped is the snapshot of a from→to run that began its steps and stopped,
// one an undo has not finished with; "" for none.
func stopped(apps string, from, to int) (string, error) {
	snap, _, err := Find(apps, from, to)
	if err != nil || snap == "" {
		return "", err
	}
	done, err := undone(snap)
	if err != nil {
		return "", err
	}
	started, err := begun(snap)
	if err != nil || done || !started {
		return "", err
	}
	return snap, nil
}
