package backup

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"slices"
	"sort"
	"strings"
	"time"
)

// DumpKey starts the line restore-dump announces its stream with: the bytes'
// count and sha256, before the bytes.
const DumpKey = "kasbah_dump"

// TarballStem is a backup tarball's name less ".tar.gz": the version, then
// the UTC stamp, each a group.
const TarballStem = `^([0-9A-Za-z][0-9A-Za-z.+_-]*)-([0-9]{8}-[0-9]{6})`

var (
	// ReTarball is a backup tarball's name, as the deploy engine writes it.
	ReTarball = regexp.MustCompile(TarballStem + `\.tar\.gz$`)
	// ReSnapshotID is a restic snapshot id; a prefix of one chooses it, as
	// restic's own do.
	ReSnapshotID = regexp.MustCompile(`^[0-9a-f]{4,64}$`)
)

// FromPath is whether p can name a directory in a snapshot: absolute, clean,
// printable ASCII.
func FromPath(p string) bool {
	for _, c := range p {
		if c <= ' ' || c > '~' {
			return false
		}
	}
	return strings.HasPrefix(p, "/") && path.Clean(p) == p && p != "/"
}

// Snapshot is one restic snapshot of a project's repository.
type Snapshot struct {
	ID    string `json:"id"`
	Time  string `json:"time"`
	full  string
	at    time.Time
	path  string
	paths []string
}

// Tarball is one backup in a snapshot's copy of the project's backups/.
type Tarball struct {
	Name string `json:"name"`
	Size int64  `json:"size"`
}

// RestoreList is restore-list's report: the snapshots holding backups/ at a
// path looked at, oldest first, and the chosen one's tarballs; with none,
// elsewhere is each path in the snapshots that holds tarballs.
type RestoreList struct {
	Repo      string     `json:"repo"`
	Snapshots []Snapshot `json:"snapshots"`
	Snapshot  string     `json:"snapshot"`
	Path      string     `json:"path"`
	Backups   []Tarball  `json:"backups"`
	Looked    []string   `json:"looked"`
	Elsewhere []string   `json:"elsewhere"`
}

// restoreArgv is `--project NAME`, then `--snapshot ID` and `--from-path P`
// in any order, each at most once, then the rest.
type restoreArgv struct {
	project, snapshot, from string
	rest                    []string
}

func restoreArgs(args []string) (restoreArgv, bool) {
	var a restoreArgv
	if len(args) < 2 || args[0] != "--project" || !reRepo.MatchString(args[1]) {
		return a, false
	}
	a.project, args = args[1], args[2:]
	for len(args) >= 2 && (args[0] == "--snapshot" || args[0] == "--from-path") {
		switch {
		case args[0] == "--snapshot" && a.snapshot == "" && ReSnapshotID.MatchString(args[1]):
			a.snapshot = args[1]
		case args[0] == "--from-path" && a.from == "" && FromPath(args[1]):
			a.from = args[1]
		default:
			return a, false
		}
		args = args[2:]
	}
	a.rest = args
	return a, true
}

// repoOf is the repository project files into and the candidate paths of
// its backups/ in a snapshot: from alone when set, else as resolved now,
// then as named.
func (r *Runner) repoOf(project, from string) (string, []string, bool) {
	p, ok := r.plan().only(project)
	if !ok || len(p.repos) == 0 {
		r.warn("no project '%s' under %s — deploy it first, then restore", project, r.Apps)
		return "", nil, false
	}
	if from != "" {
		return p.repos[0].name, []string{from}, true
	}
	at := r.Apps + "/" + project + "/backups"
	cands := []string{}
	if real, ok := r.resolve(at); ok && real != at {
		cands = append(cands, real)
	}
	return p.repos[0].name, append(cands, at), true
}

// snapshots is the repository's snapshots holding one of cands, oldest
// first, each with the path it holds the project's backups/ at; all is
// every snapshot, oldest first.
func (r *Runner) snapshots(env []string, base, repo string, cands []string) (ss, all []Snapshot, ok bool) {
	var out bytes.Buffer
	if rc := r.restic(env, base, repo, &out, r.Stderr, "snapshots", "--json"); rc != 0 {
		r.warn("%s: restic snapshots failed (exit %d)", repo, rc)
		return nil, nil, false
	}
	var raw []struct {
		ID    string   `json:"id"`
		Time  string   `json:"time"`
		Paths []string `json:"paths"`
	}
	if err := json.Unmarshal(out.Bytes(), &raw); err != nil {
		r.warn("%s: restic snapshots printed no list kasbah can read (%v)", repo, err)
		return nil, nil, false
	}
	for _, s := range raw {
		at, err := time.Parse(time.RFC3339Nano, s.Time)
		if err != nil || len(s.ID) < 8 {
			continue
		}
		sn := Snapshot{ID: s.ID[:8], Time: at.UTC().Format("2006-01-02T15:04:05Z"), full: s.ID, at: at, paths: s.Paths}
		all = append(all, sn)
		for _, c := range cands {
			if slices.Contains(s.Paths, c) {
				sn.path = c
				ss = append(ss, sn)
				break
			}
		}
	}
	byTime := func(l []Snapshot) {
		sort.SliceStable(l, func(i, j int) bool { return l[i].at.Before(l[j].at) })
	}
	byTime(ss)
	byTime(all)
	return ss, all, true
}

// elsewhere is each path a snapshot in all was given that holds backup
// tarballs directly, as the newest snapshot given it holds them.
func (r *Runner) elsewhere(env []string, base, repo string, all []Snapshot) []string {
	seen := map[string]bool{}
	found := []string{}
	for i := len(all) - 1; i >= 0; i-- {
		for _, p := range all[i].paths {
			if seen[p] || path.Base(p) == ".env" {
				continue
			}
			seen[p] = true
			s := all[i]
			s.path = p
			if ts, ok := r.tarballs(env, base, repo, s); ok && len(ts) > 0 {
				found = append(found, p)
			}
		}
	}
	sort.Strings(found)
	return found
}

// pick is the snapshot id chooses, the newest for ""; false when none is.
func pick(ss []Snapshot, id string) (Snapshot, bool) {
	if id == "" {
		if len(ss) == 0 {
			return Snapshot{}, false
		}
		return ss[len(ss)-1], true
	}
	var found []Snapshot
	for _, s := range ss {
		if strings.HasPrefix(s.full, id) {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		return Snapshot{}, false
	}
	return found[0], true
}

// tarballs is the backups in snapshot s's copy of the project's backups/,
// read with `restic ls` on that directory.
func (r *Runner) tarballs(env []string, base, repo string, s Snapshot) ([]Tarball, bool) {
	var out bytes.Buffer
	if rc := r.restic(env, base, repo, &out, r.Stderr, "ls", "--json", s.full, s.path); rc != 0 {
		r.warn("%s: restic ls %s failed (exit %d)", repo, s.ID, rc)
		return nil, false
	}
	ts := []Tarball{}
	for _, l := range strings.Split(out.String(), "\n") {
		var n struct {
			Name string `json:"name"`
			Type string `json:"type"`
			Path string `json:"path"`
			Size int64  `json:"size"`
		}
		if json.Unmarshal([]byte(l), &n) != nil || n.Type != "file" || path.Dir(n.Path) != s.path || !ReTarball.MatchString(n.Name) {
			continue
		}
		ts = append(ts, Tarball{Name: n.Name, Size: n.Size})
	}
	sort.Slice(ts, func(i, j int) bool { return ts[i].Name < ts[j].Name })
	return ts, true
}

// restoreList is `restore-list --project NAME [--snapshot ID] [--from-path
// P]`, read-only: the project's snapshots and the backups in the chosen one,
// as one JSON line.
func (r *Runner) restoreList(args []string) int {
	a, ok := restoreArgs(args)
	if !ok || len(a.rest) != 0 {
		r.warn("usage: restore-list --project NAME [--snapshot ID] [--from-path PATH]")
		return 1
	}
	project, id := a.project, a.snapshot
	env, base, ok := r.loadEnv()
	if !ok || base == "" {
		r.warn("no repository base in %s — re-run kasbah server init --with-backup", r.envfile())
		return 1
	}
	repo, cands, ok := r.repoOf(project, a.from)
	if !ok {
		return 1
	}
	ss, all, ok := r.snapshots(env, base, repo, cands)
	if !ok {
		return 1
	}
	if a.from != "" && len(ss) == 0 {
		r.warn("%s: no snapshot holds %s", repo, a.from)
		return 1
	}
	rep := RestoreList{Repo: repo, Snapshots: append([]Snapshot{}, ss...), Backups: []Tarball{}, Looked: cands, Elsewhere: []string{}}
	if len(ss) == 0 {
		rep.Elsewhere = r.elsewhere(env, base, repo, all)
	}
	if s, found := pick(ss, id); found {
		ts, ok := r.tarballs(env, base, repo, s)
		if !ok {
			return 1
		}
		rep.Snapshot, rep.Path, rep.Backups = s.ID, s.path, ts
	} else if id != "" {
		r.warn("%s: no snapshot holding %s's backups matches '%s'", repo, project, id)
		return 1
	}
	b, _ := json.Marshal(rep)
	fmt.Fprintf(r.Stdout, "%s\n", b)
	return 0
}

// restoreDump is `restore-dump --project NAME [--from-path P] SNAPSHOT
// BACKUP`: the tarball out of the snapshot's copy of backups/ on stdout,
// after one line giving its size and sha256 — read whole before any goes.
func (r *Runner) restoreDump(args []string) int {
	a, ok := restoreArgs(args)
	rest := a.rest
	if !ok || a.snapshot != "" || len(rest) != 2 || !ReSnapshotID.MatchString(rest[0]) || !ReTarball.MatchString(rest[1]) {
		r.warn("usage: restore-dump --project NAME [--from-path PATH] SNAPSHOT BACKUP (BACKUP a backup's name)")
		return 1
	}
	project := a.project
	env, base, ok := r.loadEnv()
	if !ok || base == "" {
		r.warn("no repository base in %s — re-run kasbah server init --with-backup", r.envfile())
		return 1
	}
	repo, cands, ok := r.repoOf(project, a.from)
	if !ok {
		return 1
	}
	ss, _, ok := r.snapshots(env, base, repo, cands)
	if !ok {
		return 1
	}
	s, found := pick(ss, rest[0])
	if !found {
		r.warn("%s: no snapshot holding %s's backups matches '%s'", repo, project, rest[0])
		return 1
	}
	f, err := os.CreateTemp("", "kasbah-restore-dump.*")
	if err != nil {
		r.warn("could not create a file to dump %s into: %v", rest[1], err)
		return 1
	}
	// Unlinked at once, the fd kept: a SIGPIPE on a broken stdout exits
	// without running any cleanup.
	os.Remove(f.Name())
	defer f.Close()
	if rc := r.restic(env, base, repo, f, r.Stderr, "dump", s.full, s.path+"/"+rest[1]); rc != 0 {
		r.warn("%s: restic dump of %s/%s from %s failed (exit %d)", repo, s.path, rest[1], s.ID, rc)
		return 1
	}
	h := sha256.New()
	if _, err := f.Seek(0, io.SeekStart); err != nil {
		r.warn("could not read the dump back: %v", err)
		return 1
	}
	n, err := io.Copy(h, f)
	if err == nil {
		_, err = f.Seek(0, io.SeekStart)
	}
	if err != nil || n == 0 {
		r.warn("the dump of %s is empty or unreadable (%v)", rest[1], err)
		return 1
	}
	fmt.Fprintf(r.Stdout, "%s size=%d sha256=%s\n", DumpKey, n, hex.EncodeToString(h.Sum(nil)))
	if _, err := io.Copy(r.Stdout, f); err != nil {
		r.warn("could not stream %s: %v", rest[1], err)
		return 1
	}
	return 0
}
