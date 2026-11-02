package deploy

import (
	"archive/tar"
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
	"strconv"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// UnpackedPrefix names, inside the project, the directory a rollback extracts
// the target's backup into for its hooks: UnpackedPrefix<pid>.
const UnpackedPrefix = ".kasbah-unpacked."

// snapEnv is where a backup holds the outgoing .env.
const snapEnv = SnapDir + "/.env"

// maxBackupEnv bounds the .env read out of a backup into memory.
const maxBackupEnv = 8 << 20

var reEnvKey = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// BackupFacts is `deploy backup-probe`'s report: the target's newest backup
// ("" for none), whether it holds a .env (yes, no, unreadable), and the names,
// never the values, of the keys its .env and the server's disagree on.
type BackupFacts struct {
	Backup     string   `json:"backup"`
	Env        string   `json:"env"`
	Changed    []string `json:"changed"`
	OnlyBackup []string `json:"only_backup"`
	OnlyLive   []string `json:"only_live"`
}

// newestBackup is, of names, the newest backup of version: the latest stamp,
// the greater name on a tie; "" for none.
func newestBackup(names []string, version string) string {
	best, stamp := "", ""
	for _, n := range names {
		g := reBackup.FindStringSubmatch(n)
		if g == nil || g[1] != version {
			continue
		}
		if g[2] > stamp || g[2] == stamp && n > best {
			best, stamp = n, g[2]
		}
	}
	return best
}

// backupNames is the regular files in root.
func backupNames(root *os.Root) ([]string, error) {
	d, err := root.Open(".")
	if err != nil {
		return nil, err
	}
	es, err := d.ReadDir(-1)
	d.Close()
	var out []string
	for _, e := range es {
		if e.Type().IsRegular() {
			out = append(out, e.Name())
		}
	}
	return out, err
}

// openBackup opens backups/<name>, a regular file never reached through a
// symlink, as a tar stream.
func openBackup(root *os.Root, name string) (*tar.Reader, func(), error) {
	f, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, nil, err
	}
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		f.Close()
		return nil, nil, fmt.Errorf("%s is not a regular file", name)
	}
	gz, err := gzip.NewReader(f)
	if err != nil {
		f.Close()
		return nil, nil, err
	}
	return tar.NewReader(gz), func() { gz.Close(); f.Close() }, nil
}

// backupEnv is the .env a backup holds; nil with no error when it holds none.
func backupEnv(root *os.Root, name string) ([]byte, error) {
	tr, done, err := openBackup(root, name)
	if err != nil {
		return nil, err
	}
	defer done()
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		if path.Clean(strings.TrimPrefix(h.Name, "./")) != snapEnv {
			continue
		}
		if h.Typeflag != tar.TypeReg {
			return nil, nil
		}
		b, err := io.ReadAll(io.LimitReader(tr, maxBackupEnv+1))
		if err != nil {
			return nil, err
		}
		if len(b) > maxBackupEnv {
			return nil, fmt.Errorf("its %s is over %d bytes", snapEnv, maxBackupEnv)
		}
		return b, nil
	}
}

// backupProbe is `deploy backup-probe DIR VERSION`, read-only: which backup
// a rollback to VERSION restores from, and how its .env differs from DIR's.
func backupProbe(dir, version string, stdout, stderr io.Writer) int {
	if !strings.HasPrefix(dir, "/") {
		fmt.Fprintln(stderr, "remote: usage: backup-probe DIR VERSION (DIR absolute)")
		return 1
	}
	f := BackupFacts{Env: "no", Changed: []string{}, OnlyBackup: []string{}, OnlyLive: []string{}}
	at := filepath.Join(dir, Backups)
	root, err := os.OpenRoot(at)
	switch {
	case errors.Is(err, fs.ErrNotExist):
	case err != nil:
		fmt.Fprintf(stderr, "remote: could not open %s: %v\n", at, err)
		return 1
	default:
		defer root.Close()
		names, err := backupNames(root)
		if err != nil {
			fmt.Fprintf(stderr, "remote: could not list %s: %v\n", at, err)
			return 1
		}
		f.Backup = newestBackup(names, version)
	}
	if f.Backup != "" {
		old, err := backupEnv(root, f.Backup)
		cur, cerr := os.ReadFile(filepath.Join(dir, ".env"))
		if errors.Is(cerr, fs.ErrNotExist) {
			cur, cerr = nil, nil
		}
		switch {
		case err != nil:
			fmt.Fprintf(stderr, "remote: could not read %s/%s: %v\n", at, f.Backup, err)
			f.Env = "unreadable"
		case old == nil:
		case cerr != nil:
			fmt.Fprintf(stderr, "remote: could not read %s/.env: %v\n", dir, cerr)
			f.Env = "unreadable"
		default:
			f.Env = "yes"
			c, o, l := env.EnvDiff(cur, old)
			f.Changed, f.OnlyBackup, f.OnlyLive = append(f.Changed, c...), append(f.OnlyBackup, o...), append(f.OnlyLive, l...)
		}
	}
	b, _ := json.Marshal(f)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}

// restoreEnv is `deploy restore-env DIR BACKUP --all | KEY…`: DIR's .env
// written from the backup's, whole or for the named keys only.
func restoreEnv(dir, name string, args []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	if !strings.HasPrefix(dir, "/") {
		return fail("usage: restore-env DIR BACKUP --all|KEY… (DIR absolute)")
	}
	if !reBackup.MatchString(name) {
		return fail("'%s' is not a backup's name", name)
	}
	var keys []string
	if len(args) != 1 || args[0] != "--all" {
		keys = []string{}
		for _, k := range args {
			if !reEnvKey.MatchString(k) || strings.HasPrefix(k, "KASBAH_") {
				return fail("'%s' is not a key a rollback restores", k)
			}
			keys = append(keys, k)
		}
		if len(keys) == 0 {
			return fail("no keys given — pass --all or the keys to restore")
		}
	}
	at := filepath.Join(dir, Backups)
	root, err := os.OpenRoot(at)
	if err != nil {
		return fail("could not open %s: %v — .env left untouched", at, err)
	}
	defer root.Close()
	old, err := backupEnv(root, name)
	if err != nil {
		return fail("could not read %s/%s: %v — .env left untouched", at, name, err)
	}
	if old == nil {
		return fail("%s/%s holds no %s — .env left untouched", at, name, snapEnv)
	}
	if err := env.RestoreEnv(dir, old, keys); err != nil {
		return fail("%v", err)
	}
	fmt.Fprintln(stdout, "env=restored")
	return 0
}

// undoEnv is `deploy restore-env DIR --undo TOKEN`, under .deploy.lock: DIR's
// .env put back from TOKEN's snapshot as a revert puts it back, the .env it
// replaces kept as Replaced when it differs.
func undoEnv(dir, token string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	if !strings.HasPrefix(dir, "/") || !validToken(token) {
		return fail("usage: restore-env DIR --undo TOKEN (DIR absolute)")
	}
	lock, holder, err := serverlock.Project(dir)
	if err != nil {
		return fail("could not open the lock file %s/.deploy.lock — .env left untouched", dir)
	}
	if lock == nil {
		return fail("%s is running in %s — it holds %s/.deploy.lock. .env left untouched; re-run once it has finished.", holder, dir, dir)
	}
	defer lock.Close()
	release := atexit.Hold(func(os.Signal) {})
	defer release()
	root, err := os.OpenRoot(dir)
	if err != nil {
		return fail("cannot open %s: %v — .env left untouched", dir, err)
	}
	defer root.Close()
	snap := loadSnapshot(root)
	if snap == nil || snap.Token != token {
		return fail("%s/%s %v — .env left untouched", dir, PrevDir, errForeign)
	}
	for i, t := range snap.Targets {
		if t.Path != ".env" {
			continue
		}
		saved, err := keepEnv(root, t)
		if err != nil {
			return fail("could not keep the current .env as %s (%v) — .env left untouched", Replaced, err)
		}
		if _, err := swapWhole(root, t, i, false); err != nil {
			return fail("could not put %s/.env back from %s/%s: %v", dir, PrevDir, t.Copy, err)
		}
		fmt.Fprintln(stdout, "env=put-back")
		if saved {
			fmt.Fprintf(stdout, "saved=%s/%s\n", dir, Replaced)
		}
		return 0
	}
	return fail("%s/%s holds no copy of .env — .env left untouched", dir, PrevDir)
}

// removeRestore removes dir/name, widening what it owns when it must.
func removeRestore(dir, name string) error {
	root, err := os.OpenRoot(dir)
	if err != nil {
		return err
	}
	defer root.Close()
	return removeTree(root, name)
}

// clearRestores removes every extraction a killed rollback left behind; the
// project's lock is held, so none is in use.
func (e *engine) clearRestores() {
	es, err := os.ReadDir(e.dir)
	if err != nil {
		return
	}
	for _, en := range es {
		if !strings.HasPrefix(en.Name(), UnpackedPrefix) {
			continue
		}
		if err := removeRestore(e.dir, en.Name()); err != nil {
			e.note("could not remove %s/%s, a backup an interrupted rollback extracted: %v", e.dir, en.Name(), err)
			continue
		}
		e.note("removed %s/%s, a backup an interrupted rollback extracted", e.dir, en.Name())
	}
}

// needsRestoreDir is whether a hook this run runs is handed the extraction.
func (e *engine) needsRestoreDir() bool {
	sp := e.sp
	hooks := !sp.SkipHooks && (len(sp.Pre) > 0 && e.history || len(sp.Post) > 0)
	return sp.RestoreFrom != "" && (hooks || sp.RestoreData && len(sp.Restore) > 0)
}

// extract unpacks the target's backup into UnpackedPrefix<pid> in the project,
// 770 to the group, for the rollback hooks; it is removed on every way out.
func (e *engine) extract() error {
	name := e.sp.RestoreFrom
	if g := reBackup.FindStringSubmatch(name); g == nil || g[1] != e.sp.Version {
		return failf("'%s' is not a backup of %s, so there is nothing to extract", name, e.sp.Version)
	}
	if err := e.openBackups(); err != nil {
		return err
	}
	src := filepath.Join(e.dir, Backups, name)
	tr, done, err := openBackup(e.broot, name)
	if err != nil {
		return failf("could not open the backup %s: %v", src, err)
	}
	defer done()
	rname := UnpackedPrefix + strconv.Itoa(os.Getpid())
	at := filepath.Join(e.dir, rname)
	removeRestore(e.dir, rname)
	if err := os.Mkdir(at, 0o770); err != nil {
		return failf("could not create %s to extract %s into: %v", at, src, err)
	}
	dir := e.dir
	e.rdir = at
	e.rpop = atexit.Push(func() { removeRestore(dir, rname) })
	root, err := os.OpenRoot(at)
	if err == nil {
		if err = groupDir(root, "."); err == nil {
			err = untarSafe(root, tr)
		}
		root.Close()
	}
	if err != nil {
		e.dropRestore()
		return failf("could not extract the backup %s into %s: %v", src, at, err)
	}
	e.note("extracted %s into %s for the rollback hooks ($KASBAH_BACKUP_DIR)", src, at)
	return nil
}

// dropRestore removes the extraction, if any.
func (e *engine) dropRestore() {
	if e.rdir == "" {
		return
	}
	if e.rpop != nil {
		e.rpop()
		e.rpop = nil
	}
	if err := removeRestore(e.dir, filepath.Base(e.rdir)); err != nil {
		e.note("could not remove %s: %v — the next deploy or rollback of %s removes it", e.rdir, err, e.project)
	}
	e.rdir = ""
}

// untarSafe unpacks tr into root, refusing an absolute name, a `..` or a path
// through a non-directory; symlinks stay links, other types are skipped.
// Directories are 770 (groupDir), files their own mode within 600–660.
func untarSafe(root *os.Root, tr *tar.Reader) error {
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name, err := safeMember(h.Name)
		if err != nil {
			return err
		}
		if name == "." {
			continue
		}
		if err := realParents(root, name); err != nil {
			return err
		}
		perm := fs.FileMode(h.Mode).Perm()
		switch h.Typeflag {
		case tar.TypeDir:
			fi, err := root.Lstat(name)
			switch {
			case errors.Is(err, fs.ErrNotExist):
				if err := root.Mkdir(name, 0o770); err != nil {
					return err
				}
				if err := groupDir(root, name); err != nil {
					return err
				}
			case err != nil:
				return err
			case !fi.IsDir():
				return fmt.Errorf("archive member %q is a directory over something that is not", h.Name)
			}
		case tar.TypeReg:
			f, err := root.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, (perm|0o600)&0o660)
			if err != nil {
				return err
			}
			_, cerr := io.Copy(f, tr)
			if err := f.Close(); cerr != nil || err != nil {
				return errors.Join(cerr, err)
			}
		case tar.TypeSymlink:
			if err := root.Symlink(h.Linkname, name); err != nil {
				return err
			}
		}
	}
}

// safeMember is a member's name made relative, or why it cannot be one.
func safeMember(n string) (string, error) {
	if n == "" || strings.HasPrefix(n, "/") || strings.ContainsRune(n, 0) {
		return "", fmt.Errorf("refusing archive member %q: not a relative path", n)
	}
	for _, seg := range strings.Split(n, "/") {
		if seg == ".." {
			return "", fmt.Errorf("refusing archive member %q: it climbs out with ..", n)
		}
	}
	return path.Clean(n), nil
}

// realParents makes name's missing parents and refuses one that exists as
// anything but a directory: a symlink in the way is never written through.
func realParents(root *os.Root, name string) error {
	segs := strings.Split(name, "/")
	for i := 1; i < len(segs); i++ {
		p := strings.Join(segs[:i], "/")
		fi, err := root.Lstat(p)
		switch {
		case errors.Is(err, fs.ErrNotExist):
			if err := root.Mkdir(p, 0o770); err != nil {
				return err
			}
			if err := groupDir(root, p); err != nil {
				return err
			}
		case err != nil:
			return err
		case !fi.IsDir():
			return fmt.Errorf("refusing archive member %q: %s in its path is not a directory", name, p)
		}
	}
	return nil
}

// groupDir gives the directory name rwx to its owner and group, nothing to
// others, its setgid bit kept: any operator's next run can remove it.
func groupDir(root *os.Root, name string) error {
	fi, err := root.Lstat(name)
	if err != nil {
		return err
	}
	return root.Chmod(name, 0o770|fi.Mode()&fs.ModeSetgid)
}
