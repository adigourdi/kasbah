package treesync

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/remote"
)

// RemoteUsage names `kasbah remote sync`'s modes.
const RemoteUsage = "usage: kasbah remote sync dir DEST | file DEST (the stream on stdin, from a kasbah workstation)"

// Remote is `kasbah remote sync dir|file DEST`: stdout is the protocol. A
// dropped session ends the stream and discards the file in flight (SIGHUP and
// SIGPIPE ignored, so the cleanup runs); SIGINT/SIGTERM remove it via atexit.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) != 2 || (args[0] != "dir" && args[0] != "file") {
		fmt.Fprintln(stderr, RemoteUsage)
		return 1
	}
	w, done := remote.Outlive(stderr)
	defer done()
	rc := newReceiver(args[0] == "dir", w)
	defer atexit.Push(rc.dropTemp)()
	return rc.run(args[1], bufio.NewReaderSize(stdin, 256<<10), stdout)
}

func newReceiver(tree bool, stderr io.Writer) *receiver {
	return &receiver{stderr: stderr, tree: tree, pid: os.Getpid()}
}

type receiver struct {
	stderr io.Writer
	tree   bool
	pid    int
	root   *os.Root
	ents   []Entry
	// at is each entry's path under root; the file mode renames its one entry.
	at []string
	// bad holds directories that could not be made.
	bad       map[string]bool
	seq       int
	failed    int
	synced    int
	unchanged int

	mu  sync.Mutex
	tmp string
}

func (rc *receiver) errorf(format string, a ...any) {
	fmt.Fprintf(rc.stderr, "remote: sync: "+format+"\n", a...)
}

func (rc *receiver) fail(format string, a ...any) {
	rc.errorf(format, a...)
	rc.failed++
}

// setTemp records the staging name a signal must remove ("" once renamed).
func (rc *receiver) setTemp(p string) {
	rc.mu.Lock()
	rc.tmp = p
	rc.mu.Unlock()
}

func (rc *receiver) dropTemp() {
	rc.mu.Lock()
	defer rc.mu.Unlock()
	if rc.tmp != "" && rc.root != nil {
		rc.root.Remove(rc.tmp)
		rc.tmp = ""
	}
}

// tempName is a fresh staging name beside p, where rsync stages too; Traefik's
// file provider reads *.yml only, so it never loads one.
func (rc *receiver) tempName(p string) string {
	rc.seq++
	return join(path.Dir(p), fmt.Sprintf(".kasbah-sync.%d.%d", rc.pid, rc.seq))
}

func join(dir, name string) string {
	if dir == "." {
		return name
	}
	return dir + "/" + name
}

func (rc *receiver) run(dest string, in *bufio.Reader, stdout io.Writer) int {
	if !filepath.IsAbs(dest) || strings.IndexByte(dest, 0) >= 0 {
		rc.errorf("the destination '%s' is not an absolute path", dest)
		return 1
	}
	ents, err := readManifest(in)
	if err == nil {
		err = rc.validate(ents)
	}
	if err != nil {
		rc.errorf("the manifest: %v — nothing was changed", err)
		return 1
	}
	rc.ents, rc.bad = ents, map[string]bool{}
	if err := rc.openRoot(dest); err != nil {
		rc.errorf("%v", err)
		return 1
	}
	defer rc.root.Close()

	var need []int
	for i, e := range ents {
		if rc.prepare(i, e) {
			need = append(need, i)
		}
	}
	out := newWriter(stdout)
	out.WriteString(magic)
	out.uvarint(uint64(len(need)))
	for _, i := range need {
		out.uvarint(uint64(i))
	}
	if err := out.Flush(); err != nil {
		rc.errorf("the workstation stopped reading (%v)", unwrap(err))
		rc.finish()
		return 1
	}
	if err := rc.receive(in, need); err != nil {
		rc.errorf("%v", err)
		rc.finish()
		return 1
	}
	rc.finish()
	fmt.Fprintf(stdout, "synced=%d unchanged=%d failed=%d\n", rc.synced, rc.unchanged, rc.failed)
	if rc.failed > 0 {
		return 1
	}
	return 0
}

// validate refuses any path that could leave the root, and any entry whose
// directory was not sent before it.
func (rc *receiver) validate(ents []Entry) error {
	if !rc.tree {
		if len(ents) != 1 || ents[0].Kind == kindDir || !validName(ents[0].Path) {
			return errors.New("a file sync carries exactly one file or symlink, named without a slash")
		}
		return nil
	}
	if len(ents) == 0 || ents[0].Kind != kindDir || ents[0].Path != "." {
		return errors.New("a directory sync starts with its root")
	}
	dirs := map[string]bool{".": true}
	seen := map[string]bool{".": true}
	for _, e := range ents[1:] {
		p := e.Path
		for _, seg := range strings.Split(p, "/") {
			if !validName(seg) {
				return fmt.Errorf("the path %q has an empty, '.' or '..' segment, or a NUL", p)
			}
		}
		if seen[p] {
			return fmt.Errorf("the path %q is listed twice", p)
		}
		if !dirs[path.Dir(p)] {
			return fmt.Errorf("the path %q comes before its directory", p)
		}
		seen[p] = true
		if e.Kind == kindDir {
			dirs[p] = true
		}
	}
	return nil
}

func validName(s string) bool {
	return s != "" && s != "." && s != ".." && !strings.ContainsAny(s, "/\x00")
}

// openRoot is rsync's receiver: a directory destination is created when only
// its last component is missing; a file lands inside a destination that is a
// directory (a symlink to one included), and on the name otherwise.
func (rc *receiver) openRoot(dest string) error {
	dir := dest
	rc.at = make([]string, len(rc.ents))
	if rc.tree {
		fi, err := os.Stat(dest)
		switch {
		case err == nil && !fi.IsDir():
			return fmt.Errorf("the destination %s exists and is not a directory", dest)
		case errors.Is(err, fs.ErrNotExist):
			if _, lerr := os.Lstat(dest); lerr == nil {
				return fmt.Errorf("the destination %s is a symlink to nothing", dest)
			}
			if err := os.Mkdir(dest, 0o700); err != nil {
				return fmt.Errorf("could not create the destination %s: %v", dest, unwrap(err))
			}
		case err != nil:
			return fmt.Errorf("cannot read the destination %s: %v", dest, unwrap(err))
		}
		for i, e := range rc.ents {
			rc.at[i] = e.Path
		}
	} else {
		rc.at[0] = rc.ents[0].Path
		if fi, err := os.Stat(dest); err != nil || !fi.IsDir() {
			dir, rc.at[0] = filepath.Dir(dest), filepath.Base(dest)
		}
	}
	r, err := os.OpenRoot(dir)
	if err != nil {
		return fmt.Errorf("cannot open the directory %s: %v", dir, unwrap(err))
	}
	rc.root = r
	return nil
}

// prepare is rsync's generator for one entry: directories and symlinks are
// made here, a file is needed unless the quick check (size and whole-second
// mtime) says it is current, in which case only its mode is corrected.
func (rc *receiver) prepare(i int, e Entry) bool {
	p := rc.at[i]
	parent := path.Dir(p)
	if rc.bad[parent] {
		if e.Kind == kindDir {
			rc.bad[p] = true
		}
		rc.failed++
		return false
	}
	fi, err := rc.root.Lstat(p)
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		rc.fail("cannot read %s: %v", p, unwrap(err))
		if e.Kind == kindDir {
			rc.bad[p] = true
		}
		return false
	}
	exists := err == nil
	switch e.Kind {
	case kindDir:
		if exists && fi.IsDir() {
			// Writable for the run, as rsync makes it; finish sets the mode.
			if fi.Mode().Perm()&0o700 != 0o700 && owned(fi) {
				rc.root.Chmod(p, fi.Mode()&(fs.ModePerm|fs.ModeSetuid|fs.ModeSetgid|fs.ModeSticky)|0o700)
			}
			return false
		}
		if exists {
			if err := rc.root.Remove(p); err != nil {
				rc.fail("could not make way for new directory: %s (%v)", p, unwrap(err))
				rc.bad[p] = true
				return false
			}
		}
		if err := rc.root.Mkdir(p, 0o700); err != nil {
			rc.fail("could not create the directory %s: %v", p, unwrap(err))
			rc.bad[p] = true
			return false
		}
		return false
	case kindFile:
		if exists && fi.Mode().IsRegular() && fi.Size() == e.Size && fi.ModTime().Unix() == e.Sec {
			if unixMode(fi.Mode()) != e.Mode && !owned(fi) {
				// Another operator's file: only its owner may chmod it, so
				// it is sent again and renamed over.
				return true
			}
			if unixMode(fi.Mode()) != e.Mode {
				if err := rc.root.Chmod(p, fileMode(e.Mode)); err != nil {
					rc.fail("could not set the mode of %s: %v", p, unwrap(err))
					return false
				}
			}
			rc.unchanged++
			return false
		}
		if exists && fi.IsDir() && !rc.makeWay(p, "regular file") {
			return false
		}
		return true
	default:
		if exists && fi.Mode()&fs.ModeSymlink != 0 {
			if t, err := rc.root.Readlink(p); err == nil && t == e.Target && (fi.ModTime().Unix() == e.Sec || owned(fi)) {
				if fi.ModTime().Unix() != e.Sec {
					rc.linkTimes(p, e)
				}
				rc.unchanged++
				return false
			}
		}
		if exists && fi.IsDir() && !rc.makeWay(p, "symlink") {
			return false
		}
		rc.symlink(p, e)
		return false
	}
}

// makeWay removes an empty directory standing where a non-directory goes;
// a non-empty one is refused, as rsync without --force refuses it.
func (rc *receiver) makeWay(p, what string) bool {
	if err := rc.root.Remove(p); err != nil {
		if errors.Is(err, syscall.ENOTEMPTY) || errors.Is(err, syscall.EEXIST) {
			rc.fail("cannot delete non-empty directory: %s — could not make way for new %s", p, what)
		} else {
			rc.fail("could not make way for new %s: %s (%v)", what, p, unwrap(err))
		}
		return false
	}
	return true
}

func (rc *receiver) symlink(p string, e Entry) {
	tmp := rc.tempName(p)
	rc.setTemp(tmp)
	defer rc.dropTemp()
	if err := rc.root.Symlink(e.Target, tmp); err != nil {
		rc.fail("could not create the symlink %s: %v", p, unwrap(err))
		return
	}
	if err := rc.linkTimes(tmp, e); err != nil {
		return
	}
	if err := rc.root.Rename(tmp, p); err != nil {
		rc.fail("could not install the symlink %s: %v", p, unwrap(err))
		return
	}
	rc.setTemp("")
	rc.synced++
}

func (rc *receiver) linkTimes(p string, e Entry) error {
	d, err := rc.root.Open(path.Dir(p))
	if err == nil {
		err = lutimes(d, path.Base(p), e.Sec, e.Nsec)
		d.Close()
	}
	if err != nil {
		rc.fail("could not set the mtime of the symlink %s: %v", p, unwrap(err))
	}
	return err
}

// receive reads the needed files in order, each staged beside its target,
// checked against its size and sha256, then renamed into place. A frame that
// does not parse ends the run: what was in flight is removed.
func (rc *receiver) receive(in *bufio.Reader, need []int) error {
	buf := make([]byte, maxChunk)
	for _, i := range need {
		got, err := readUvarint(in, uint64(len(rc.ents)))
		if err == nil && int(got) != i {
			err = fmt.Errorf("%w (entry %d where %d was due)", errCorrupt, got, i)
		}
		if err == nil {
			err = rc.file(in, i, buf)
		}
		if err != nil {
			return fmt.Errorf("%v at %s — nothing was installed for it, and the run stopped there", err, rc.at[i])
		}
	}
	b, err := in.ReadByte()
	if err != nil || b != endMark {
		return fmt.Errorf("%w (no end mark after the last file)", errCorrupt)
	}
	return nil
}

func (rc *receiver) file(in *bufio.Reader, i int, buf []byte) error {
	e, p := rc.ents[i], rc.at[i]
	tmp := rc.tempName(p)
	rc.setTemp(tmp)
	defer rc.dropTemp()
	f, werr := rc.root.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if f != nil {
		defer f.Close()
	}
	h := sha256.New()
	var total uint64
	for {
		n, err := readUvarint(in, maxChunk)
		if err != nil {
			return err
		}
		if n == 0 {
			break
		}
		if _, err := io.ReadFull(in, buf[:n]); err != nil {
			return corrupt(err)
		}
		h.Write(buf[:n])
		total += n
		if werr == nil {
			_, werr = f.Write(buf[:n])
		}
	}
	status, err := in.ReadByte()
	if err != nil {
		return corrupt(err)
	}
	if status == statusAbort {
		rc.failed++
		return nil
	}
	if status != statusOK {
		return fmt.Errorf("%w (file status %d)", errCorrupt, status)
	}
	size, err := readUvarint(in, 1<<62)
	if err != nil {
		return err
	}
	sum := make([]byte, sha256.Size)
	if _, err := io.ReadFull(in, sum); err != nil {
		return corrupt(err)
	}
	if size != total {
		return fmt.Errorf("%w (%d bytes arrived, %d sent)", errCorrupt, total, size)
	}
	if !bytes.Equal(sum, h.Sum(nil)) {
		return fmt.Errorf("%w (the sha256 of what arrived is not what was sent)", errCorrupt)
	}
	if werr == nil {
		werr = f.Chmod(fileMode(e.Mode))
	}
	if werr == nil {
		werr = f.Close()
	}
	if werr == nil {
		werr = rc.root.Chtimes(tmp, time.Time{}, time.Unix(e.Sec, e.Nsec))
	}
	if werr == nil {
		werr = rc.root.Rename(tmp, p)
	}
	if werr != nil {
		rc.fail("could not write %s: %v", p, unwrap(werr))
		return nil
	}
	rc.setTemp("")
	rc.synced++
	return nil
}

// finish sets each directory's mode, deepest first, and its mtime when the
// whole second differs — rsync's comparison, so a directory changed within
// the source's own second keeps the time the change gave it, as with rsync.
func (rc *receiver) finish() {
	for i := len(rc.ents) - 1; i >= 0; i-- {
		e, p := rc.ents[i], rc.at[i]
		if e.Kind != kindDir || rc.bad[p] {
			continue
		}
		fi, err := rc.root.Lstat(p)
		if err != nil || !fi.IsDir() {
			continue
		}
		// A directory another operator owns keeps its mode and mtime: only
		// its owner may set them, and its group bits already let this run in.
		if !owned(fi) {
			continue
		}
		if m := dirMode(e.Mode, fi.Mode()); unixMode(fi.Mode()) != m {
			if err := rc.root.Chmod(p, fileMode(m)); err != nil {
				rc.fail("could not set the mode of %s: %v", p, unwrap(err))
			}
		}
		want := time.Unix(e.Sec, e.Nsec)
		if fi.ModTime().Unix() != e.Sec {
			if err := rc.root.Chtimes(p, time.Time{}, want); err != nil {
				rc.fail("could not set the mtime of %s: %v", p, unwrap(err))
			}
		}
	}
}

// dirMode is a directory's mode on the server: the source's, with the group
// given the owner's bits so every operator can write into it, and the
// setgid bit the apps tree hands down kept.
func dirMode(src uint32, cur fs.FileMode) uint32 {
	m := src | (src&0o700)>>3
	if cur&fs.ModeSetgid != 0 {
		m |= 0o2000
	}
	return m
}

// owned is whether this process's user owns the entry: only the owner may
// chmod it or set its times, whatever its group bits allow.
func owned(fi fs.FileInfo) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == selfUID()
}

// selfUID is os.Getuid, replaced by tests to play another operator.
var selfUID = os.Getuid
