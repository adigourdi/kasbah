package deploy

import (
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// reProject is a project's name, the manifest's rule.
var reProject = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// IsProject is whether apps/name is a project directory: a project's name,
// not one kasbah reserves, and a directory or a symlink to one — what
// destroy treats as a project.
func IsProject(apps, name string) bool {
	// .kasbah, reserved too, fails the name rule.
	if !reProject.MatchString(name) || slices.Contains(manifest.Reserved, name) {
		return false
	}
	fi, err := os.Stat(filepath.Join(apps, name))
	return err == nil && fi.IsDir()
}

// Leftovers is what runs left behind in a project directory, each perhaps
// holding a copy of .env, by name: backup directories under Backups whose
// tarball was not written, KeptPrefix snapshots and UnpackedPrefix extractions.
type Leftovers struct {
	Backups  []string `json:"backups"`
	Kept     []string `json:"kept"`
	Unpacked []string `json:"unpacked"`
	// Holder names the run holding .deploy.lock, "" for none seen: a backup
	// directory or extraction may be its own.
	Holder string `json:"holder"`
	// Error is why the directory or its backups/ could not be listed.
	Error string `json:"error"`
}

// NoLeftovers is a scan that found nothing.
func NoLeftovers() Leftovers {
	return Leftovers{Backups: []string{}, Kept: []string{}, Unpacked: []string{}}
}

// ScanLeftovers reads dir's leftovers by name; a backups/ symlinked to a
// directory is followed, a symlink inside it is no backup directory. An
// absent backups/ is none; one that cannot be listed sets Error.
func ScanLeftovers(dir string) Leftovers {
	l := NoLeftovers()
	es, err := os.ReadDir(dir)
	if err != nil {
		l.Error = "the project directory could not be listed: " + errText(err)
		return l
	}
	for _, e := range es {
		switch n := e.Name(); {
		case strings.HasPrefix(n, KeptPrefix):
			l.Kept = append(l.Kept, n)
		case strings.HasPrefix(n, UnpackedPrefix):
			l.Unpacked = append(l.Unpacked, n)
		}
	}
	es, err = os.ReadDir(filepath.Join(dir, Backups))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		l.Error = Backups + "/ could not be listed: " + errText(err)
	}
	for _, e := range es {
		if e.IsDir() && reBackupDir.MatchString(e.Name()) {
			l.Backups = append(l.Backups, e.Name())
		}
	}
	return l
}

// ScanAgainstLock is ScanLeftovers with Holder set from dir's .deploy.lock,
// read without taking it, and the holder's own extraction left out.
func ScanAgainstLock(dir string) Leftovers {
	l := ScanLeftovers(dir)
	hs := serverlock.ProjectWriters(dir)
	if len(hs) == 0 {
		return l
	}
	var what []string
	for _, h := range hs {
		what = append(what, h.What)
		l.Unpacked = slices.DeleteFunc(l.Unpacked, func(n string) bool { return n == UnpackedPrefix+strconv.Itoa(h.PID) })
	}
	l.Holder = strings.Join(what, "; ")
	return l
}

// errText is err without the path it names.
func errText(err error) string {
	var pe *fs.PathError
	if errors.As(err, &pe) {
		return pe.Err.Error()
	}
	return err.Error()
}

// Any is whether there is a leftover of any kind.
func (l Leftovers) Any() bool { return len(l.Backups)+len(l.Kept)+len(l.Unpacked) > 0 }

// Report is whether there is anything to say: a leftover, or why none can be
// known.
func (l Leftovers) Report() bool { return l.Any() || l.Error != "" }

// Running is the leftovers a run holding the lock may own: its backup
// directories and extractions; none when no run holds it.
func (l Leftovers) Running() Leftovers {
	if l.Holder == "" {
		return NoLeftovers()
	}
	r := NoLeftovers()
	r.Backups, r.Unpacked = l.Backups, l.Unpacked
	return r
}

// Settled is the leftovers no run can own: all of them when no run holds the
// lock, else the kept-aside snapshots alone.
func (l Leftovers) Settled() Leftovers {
	if l.Holder == "" {
		return l
	}
	r := NoLeftovers()
	r.Kept = l.Kept
	return r
}

// Paths is every leftover's path under dir.
func (l Leftovers) Paths(dir string) []string {
	var out []string
	for _, n := range l.Backups {
		out = append(out, filepath.Join(dir, Backups, n))
	}
	for _, n := range append(append([]string{}, l.Kept...), l.Unpacked...) {
		out = append(out, filepath.Join(dir, n))
	}
	return out
}

// NewestStamp is the name among names whose trailing UTC stamp is the
// latest, and that stamp as Unix seconds; ok false when none carries one.
func NewestStamp(names []string) (name string, at int64, ok bool) {
	for _, n := range names {
		if len(n) < len(stampLayout) {
			continue
		}
		t, err := time.Parse(stampLayout, n[len(n)-len(stampLayout):])
		if err != nil {
			continue
		}
		if !ok || t.Unix() > at {
			name, at, ok = n, t.Unix(), true
		}
	}
	return name, at, ok
}
