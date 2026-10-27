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

	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/probe"
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
}

// Keys is what a report must carry to be one (remote.Decode).
var Keys = []string{"undo", "from", "to", "nothing", "snapshot", "snapshot_reused", "steps", "marker", "restored"}

const stampLayout = "20060102T150405Z"

var reSnapshot = regexp.MustCompile(`^([0-9]+)-to-([0-9]+)-([0-9]{8}T[0-9]{6}Z)\.tar$`)

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
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE, 0o666)
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

// lockAll takes the migration lock, then every project's .deploy.lock — the
// one deploy, rollback and drop hold — so no project changes under a run.
func lockAll(apps string) (locks, error) {
	var held locks
	f, err := flock(filepath.Join(apps, Lock), func(p string) error {
		return fmt.Errorf("a migration is running on this server — it holds the lock on %s", p)
	})
	if err != nil {
		return nil, err
	}
	held = append(held, f)
	projects, err := Projects(apps)
	if err != nil {
		held.release()
		return nil, err
	}
	for _, p := range projects {
		f, err := flock(filepath.Join(apps, p, ".deploy.lock"), func(path string) error {
			return fmt.Errorf("a deploy, rollback or drop is running in %s — it holds the lock on %s; migrate once it has finished", p, path)
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
		return "", fmt.Errorf("%s already exists — a snapshot of this second was already written", path)
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

// Run is the server side of `kasbah migrate server`: under the locks, a
// snapshot, every step from the marker's major to ours, and the marker last.
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
	r := &Report{From: from, To: to, Steps: []StepReport{}, Marker: "unchanged", Restored: []string{}}
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
	// A failed run's snapshot holds the originals; a rerun keeps it so that
	// an undo restores those, never the half-migrated tree.
	if r.Snapshot, _, err = Find(apps, from, to); err != nil {
		return nil, err
	}
	if r.Snapshot != "" {
		r.SnapshotReused = true
	} else if r.Snapshot, err = snapshot(apps, SnapshotName(from, to, now), rel); err != nil {
		return nil, err
	}
	for _, s := range plan {
		sr, err := apply(apps, s)
		r.Steps = append(r.Steps, sr)
		if err != nil {
			return nil, fmt.Errorf("%v — the marker still says major %d; the files are in %s, and a rerun picks up where this stopped", err, from, r.Snapshot)
		}
	}
	own := tree.NewMap()
	own.Set("kasbah_version", ours)
	if err := writeAtomic(marker.Path(apps), marker.Render(tree.Merge(m, own)), marker.Mode); err != nil {
		return nil, err
	}
	r.Marker = "updated"
	return r, nil
}

// Find is the newest snapshot under apps from major from to major to, and
// its stamp; "" when there is none. A to of -1 matches any.
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

// Undo restores the newest snapshot, the marker last, unless a project has
// deployed since it was taken.
func Undo(apps string) (*Report, error) {
	held, err := lockAll(apps)
	if err != nil {
		return nil, err
	}
	defer held.release()
	m, _, err := readMarker(apps)
	if err != nil {
		return nil, err
	}
	// The snapshot to restore is the one whose move ended at the major the
	// marker is at now; a newest file from another move is someone else's.
	to, _, err := Majors(m, "0.0.0")
	if err != nil {
		return nil, err
	}
	path, at, err := findTo(apps, to)
	if err != nil {
		return nil, err
	}
	if path == "" {
		return nil, fmt.Errorf("nothing to undo: no migration snapshot ending at major %d under %s", to, filepath.Join(apps, Dir))
	}
	from, _ := strconv.Atoi(reSnapshot.FindStringSubmatch(filepath.Base(path))[1])
	r := &Report{Undo: true, From: from, To: to, Snapshot: path, Steps: []StepReport{}, Marker: "unchanged", Restored: []string{}}
	project, stamp, err := DeployedSince(apps, at)
	if err != nil {
		return nil, err
	}
	if project != "" {
		return nil, fmt.Errorf("%s was deployed at %s, after the snapshot %s was taken — an undo would put files from before that deploy under it; restore by hand from the tarball, or leave the server on major %d", project, stamp, path, to)
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("could not open %s: %v", path, err)
	}
	defer f.Close()
	tr := tar.NewReader(f)
	var mk []byte
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%s is not a tarball kasbah wrote: %v", path, err)
		}
		if h.Typeflag != tar.TypeReg || strings.HasPrefix(h.Name, "/") || strings.Contains(h.Name, "..") {
			return nil, fmt.Errorf("%s holds %q, which is not a file under the apps path — nothing was restored", path, h.Name)
		}
		body, err := io.ReadAll(tr)
		if err != nil {
			return nil, fmt.Errorf("could not read %s out of %s: %v", h.Name, path, err)
		}
		if h.Name == marker.Path("")[1:] {
			mk = body
			continue
		}
		if err := writeAtomic(filepath.Join(apps, h.Name), body, os.FileMode(h.Mode).Perm()); err != nil {
			return nil, err
		}
		r.Restored = append(r.Restored, h.Name)
	}
	if mk == nil {
		return nil, fmt.Errorf("%s carries no marker — nothing is restored without one", path)
	}
	if err := writeAtomic(marker.Path(apps), mk, marker.Mode); err != nil {
		return nil, err
	}
	r.Marker = "restored"
	return r, nil
}
