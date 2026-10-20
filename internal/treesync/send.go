package treesync

import (
	"bufio"
	"crypto/sha256"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"syscall"
)

// Source is what one sync sends: a manifest, and whether it is a tree (the
// destination is a directory) or one file (the destination names it).
type Source struct {
	Tree bool
	Ents []Entry
	// Errs counts what could not be listed; the rest is still sent.
	Errs int
}

func entryOf(path, rel string, fi os.FileInfo) Entry {
	t := fi.ModTime()
	return Entry{Path: rel, Mode: unixMode(fi.Mode()), Sec: t.Unix(), Nsec: int64(t.Nanosecond()), local: path}
}

// Dir is `rsync -rlpt src/`: the directory src resolves to, its contents
// recursively, symlinks as links. Anything else (fifos, sockets, devices) is
// skipped with rsync's message on warn.
func Dir(src string, warn io.Writer) (*Source, error) {
	fi, err := os.Stat(src)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v", src, err)
	}
	if !fi.IsDir() {
		return nil, fmt.Errorf("%s is not a directory", src)
	}
	s := &Source{Tree: true}
	root := entryOf(src, ".", fi)
	root.Kind = kindDir
	s.Ents = append(s.Ents, root)
	s.walk(src, "", warn)
	return s, nil
}

func (s *Source) walk(dir, rel string, warn io.Writer) {
	f, err := os.Open(dir)
	var names []string
	if err == nil {
		names, err = f.Readdirnames(-1)
		f.Close()
	}
	if err != nil {
		fmt.Fprintf(warn, "sync: cannot read the directory %s: %v\n", dir, unwrap(err))
		s.Errs++
		return
	}
	slices.Sort(names)
	for _, n := range names {
		path, r := dir+"/"+n, n
		if rel != "" {
			r = rel + "/" + n
		}
		fi, err := os.Lstat(path)
		if err != nil {
			fmt.Fprintf(warn, "sync: cannot read %s: %v\n", path, unwrap(err))
			s.Errs++
			continue
		}
		e, ok := s.one(path, r, fi, true, warn)
		if !ok {
			continue
		}
		s.Ents = append(s.Ents, e)
		if e.Kind == kindDir {
			s.walk(path, r, warn)
		}
	}
}

// one is fi as an entry; ok is false for what rsync skips without -D.
func (s *Source) one(path, rel string, fi os.FileInfo, links bool, warn io.Writer) (Entry, bool) {
	e := entryOf(path, rel, fi)
	switch m := fi.Mode(); {
	case m.IsDir():
		e.Kind = kindDir
	case m.IsRegular():
		e.Kind, e.Size = kindFile, fi.Size()
	case m&os.ModeSymlink != 0 && links:
		t, err := os.Readlink(path)
		if err != nil {
			fmt.Fprintf(warn, "sync: cannot read the link %s: %v\n", path, unwrap(err))
			s.Errs++
			return e, false
		}
		e.Kind, e.Target = kindLink, t
	default:
		fmt.Fprintf(warn, "sync: skipping non-regular file %s\n", strconv.Quote(rel))
		return e, false
	}
	return e, true
}

// File is `rsync -lpt src`: one file or symlink, landing on the destination
// (or inside it, when the destination is a directory).
func File(src string, warn io.Writer) (*Source, error) {
	fi, err := os.Lstat(src)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v", src, unwrap(err))
	}
	if fi.IsDir() {
		return nil, fmt.Errorf("%s is a directory", src)
	}
	s := &Source{}
	if e, ok := s.one(src, filepath.Base(src), fi, true, warn); ok {
		s.Ents = append(s.Ents, e)
	}
	return s, nil
}

// Fixed is `rsync -pt --chmod=F<mode> src`, except that a symlinked src is
// followed where rsync without -l skipped it: what src resolves to, at mode.
func Fixed(src string, mode uint32) (*Source, error) {
	fi, err := os.Stat(src)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v", src, unwrap(err))
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", src)
	}
	e := entryOf(src, filepath.Base(src), fi)
	e.Kind, e.Size, e.Mode, e.follow = kindFile, fi.Size(), mode, true
	return &Source{Ents: []Entry{e}}, nil
}

func unwrap(err error) error {
	var pe *os.PathError
	if errors.As(err, &pe) {
		return pe.Err
	}
	return err
}

// Send drives one transfer: the manifest out, the server's need list in, the
// needed files out, then the server's report. r and w are the far side's
// stdout and stdin; w is closed once everything is sent.
func (s *Source) Send(w io.WriteCloser, r io.Reader, warn io.Writer) (Report, error) {
	bw := newWriter(w)
	writeManifest(bw, s.Ents)
	if err := bw.Flush(); err != nil {
		w.Close()
		return Report{}, fmt.Errorf("the server stopped reading the manifest (%v)", unwrap(err))
	}
	br := bufio.NewReader(r)
	need, err := readNeed(br, s.Ents)
	if err != nil {
		w.Close()
		return Report{}, err
	}
	buf := make([]byte, 256<<10)
	for _, i := range need {
		if err := sendFile(bw, i, s.Ents[i], buf, warn); err != nil {
			w.Close()
			return Report{}, fmt.Errorf("the server stopped reading at %s (%v)", s.Ents[i].local, unwrap(err))
		}
	}
	bw.WriteByte(endMark)
	ferr := bw.Flush()
	w.Close()
	if ferr != nil {
		return Report{}, fmt.Errorf("the server stopped reading before the end of the stream (%v)", unwrap(ferr))
	}
	rest, _ := io.ReadAll(br)
	rep, err := parseReport(rest)
	if err != nil {
		return Report{}, err
	}
	rep.Failed += s.Errs
	return rep, nil
}

func readNeed(r *bufio.Reader, ents []Entry) ([]int, error) {
	if err := readMagic(r); err != nil {
		return nil, errors.New("the server's kasbah did not answer the manifest (see its error above)")
	}
	n, err := readUvarint(r, uint64(len(ents)))
	if err != nil {
		return nil, fmt.Errorf("the server's need list: %v", err)
	}
	need := make([]int, n)
	last := -1
	for k := range need {
		i, err := readUvarint(r, uint64(len(ents)))
		if err != nil {
			return nil, fmt.Errorf("the server's need list: %v", err)
		}
		if int(i) <= last || int(i) >= len(ents) || ents[i].Kind != kindFile {
			return nil, fmt.Errorf("the server asked for entry %d, which is not a file it can need", i)
		}
		need[k], last = int(i), int(i)
	}
	return need, nil
}

// sendFile writes one file frame; a file that cannot be read is sent as an
// abort, which the server discards and counts. err is the stream's own failure.
func sendFile(w *writer, i int, e Entry, buf []byte, warn io.Writer) error {
	w.uvarint(uint64(i))
	flags := os.O_RDONLY | syscall.O_NOFOLLOW
	if e.follow {
		flags = os.O_RDONLY
	}
	f, oerr := os.OpenFile(e.local, flags, 0)
	if oerr == nil {
		if fi, serr := f.Stat(); serr != nil || !fi.Mode().IsRegular() {
			f.Close()
			f, oerr = nil, errors.New("no longer a regular file")
		}
	}
	h := sha256.New()
	var total uint64
	var rerr error
	if f != nil {
		for {
			n, err := f.Read(buf)
			if n > 0 {
				w.uvarint(uint64(n))
				w.Write(buf[:n])
				h.Write(buf[:n])
				total += uint64(n)
			}
			if err == io.EOF {
				break
			}
			if err != nil {
				rerr = err
				break
			}
			if werr := w.err(); werr != nil {
				f.Close()
				return werr
			}
		}
		f.Close()
	}
	w.uvarint(0)
	if oerr != nil || rerr != nil {
		fmt.Fprintf(warn, "sync: cannot read %s: %v — not sent\n", e.local, unwrap(errors.Join(oerr, rerr)))
		w.WriteByte(statusAbort)
		return w.err()
	}
	w.WriteByte(statusOK)
	w.uvarint(total)
	w.Write(h.Sum(nil))
	return w.err()
}

// err is the writer's sticky error: bufio keeps the first failed write.
func (w *writer) err() error {
	_, err := w.Write(nil)
	return err
}

// Report is the server's closing line.
type Report struct{ Synced, Unchanged, Failed int }

func parseReport(b []byte) (Report, error) {
	line := strings.TrimSpace(string(b))
	var r Report
	have := 0
	for _, f := range strings.Fields(line) {
		k, v, _ := strings.Cut(f, "=")
		n, err := strconv.Atoi(v)
		if err != nil {
			continue
		}
		switch k {
		case "synced":
			r.Synced, have = n, have+1
		case "unchanged":
			r.Unchanged, have = n, have+1
		case "failed":
			r.Failed, have = n, have+1
		}
	}
	if have != 3 {
		return r, errors.New("the server's sync ended without its report (see its error above)")
	}
	return r, nil
}
