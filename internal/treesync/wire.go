// Package treesync copies a file or a tree into a server directory through
// `kasbah remote sync` as `rsync -rlpt` (no --delete) did: a manifest out, the
// server's need list back, each needed file in chunks closed by size and sha256.
package treesync

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"strings"
)

const (
	magic = "kasbah-sync 1\n"
	// Kinds of entry.
	kindDir  = 'd'
	kindFile = 'f'
	kindLink = 'l'
	// Frame limits: a stream that breaks one is corrupt, not big.
	maxPath    = 1 << 16
	maxEntries = 1 << 24
	maxChunk   = 1 << 20
	// Per-file trailer status.
	statusOK    = 0
	statusAbort = 1
	endMark     = 'E'
)

// Entry is one manifest line: a path relative to the destination root ("."
// is the root itself), its type, permission bits (07777) and mtime.
type Entry struct {
	Kind   byte
	Path   string
	Mode   uint32
	Sec    int64
	Nsec   int64
	Size   int64
	Target string
	// local is the workstation's path, follow whether opening it may follow a
	// symlink; neither travels.
	local  string
	follow bool
}

// unixMode is m's permission bits with setuid, setgid and sticky as 07777.
func unixMode(m fs.FileMode) uint32 {
	u := uint32(m.Perm())
	if m&fs.ModeSetuid != 0 {
		u |= 0o4000
	}
	if m&fs.ModeSetgid != 0 {
		u |= 0o2000
	}
	if m&fs.ModeSticky != 0 {
		u |= 0o1000
	}
	return u
}

func fileMode(u uint32) fs.FileMode {
	m := fs.FileMode(u & 0o777)
	if u&0o4000 != 0 {
		m |= fs.ModeSetuid
	}
	if u&0o2000 != 0 {
		m |= fs.ModeSetgid
	}
	if u&0o1000 != 0 {
		m |= fs.ModeSticky
	}
	return m
}

type writer struct {
	*bufio.Writer
	buf [binary.MaxVarintLen64]byte
}

func newWriter(w io.Writer) *writer { return &writer{Writer: bufio.NewWriterSize(w, 256<<10)} }

func (w *writer) uvarint(v uint64) {
	w.Write(w.buf[:binary.PutUvarint(w.buf[:], v)])
}

func (w *writer) varint(v int64) {
	w.Write(w.buf[:binary.PutVarint(w.buf[:], v)])
}

func (w *writer) bytes(s string) {
	w.uvarint(uint64(len(s)))
	w.WriteString(s)
}

func writeManifest(w *writer, ents []Entry) {
	w.WriteString(magic)
	w.uvarint(uint64(len(ents)))
	for _, e := range ents {
		w.WriteByte(e.Kind)
		w.bytes(e.Path)
		w.uvarint(uint64(e.Mode))
		w.varint(e.Sec)
		w.uvarint(uint64(e.Nsec))
		switch e.Kind {
		case kindFile:
			w.uvarint(uint64(e.Size))
		case kindLink:
			w.bytes(e.Target)
		}
	}
}

// errCorrupt is a stream that does not parse: cut short, padded or garbled.
var errCorrupt = errors.New("the stream was cut short or is corrupt")

func corrupt(err error) error {
	if err == nil || errors.Is(err, errCorrupt) {
		return err
	}
	return fmt.Errorf("%w (%v)", errCorrupt, err)
}

func readUvarint(r *bufio.Reader, max uint64) (uint64, error) {
	v, err := binary.ReadUvarint(r)
	if err != nil {
		return 0, corrupt(err)
	}
	if v > max {
		return 0, fmt.Errorf("%w (a field of %d over its limit of %d)", errCorrupt, v, max)
	}
	return v, nil
}

func readBytes(r *bufio.Reader, max uint64) (string, error) {
	n, err := readUvarint(r, max)
	if err != nil {
		return "", err
	}
	var b strings.Builder
	if _, err := io.CopyN(&b, r, int64(n)); err != nil {
		return "", corrupt(err)
	}
	return b.String(), nil
}

func readMagic(r *bufio.Reader) error {
	b := make([]byte, len(magic))
	if _, err := io.ReadFull(r, b); err != nil {
		return corrupt(err)
	}
	if string(b) != magic {
		return fmt.Errorf("%w (no %q header)", errCorrupt, strings.TrimSpace(magic))
	}
	return nil
}

func readManifest(r *bufio.Reader) ([]Entry, error) {
	if err := readMagic(r); err != nil {
		return nil, err
	}
	n, err := readUvarint(r, maxEntries)
	if err != nil {
		return nil, err
	}
	ents := make([]Entry, 0, min(n, 4096))
	for range n {
		var e Entry
		if e.Kind, err = r.ReadByte(); err != nil {
			return nil, corrupt(err)
		}
		if e.Path, err = readBytes(r, maxPath); err != nil {
			return nil, err
		}
		m, err := readUvarint(r, 0o7777)
		if err != nil {
			return nil, err
		}
		e.Mode = uint32(m)
		if e.Sec, err = binary.ReadVarint(r); err != nil {
			return nil, corrupt(err)
		}
		ns, err := readUvarint(r, 999_999_999)
		if err != nil {
			return nil, err
		}
		e.Nsec = int64(ns)
		switch e.Kind {
		case kindDir:
		case kindFile:
			s, err := readUvarint(r, 1<<62)
			if err != nil {
				return nil, err
			}
			e.Size = int64(s)
		case kindLink:
			if e.Target, err = readBytes(r, 4096); err != nil {
				return nil, err
			}
		default:
			return nil, fmt.Errorf("%w (entry type %q)", errCorrupt, e.Kind)
		}
		ents = append(ents, e)
	}
	return ents, nil
}
