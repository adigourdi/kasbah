package buildpush

import (
	"archive/tar"
	"errors"
	"io"
	"path"
	"strings"
)

// filter copies a `docker save` tar minus the layer blobs in skip, by name:
// docker ≥25 names an uncompressed layer blobs/sha256/<diffID>. Everything
// else, the legacy <id>/layer.tar format included, passes through.
type filter struct {
	tw           *tar.Writer
	skip         map[string]bool
	known        map[string]bool
	matched      int
	skipped      int
	skippedBytes int64
	buf          []byte
}

// known is every diffID of the images and every name a layer of theirs is
// known by: matched counts the blobs it names, and none at all means the save
// named its layers some way the run did not learn.
func newFilter(dst io.Writer, skip, known map[string]bool) *filter {
	return &filter{tw: tar.NewWriter(dst), skip: skip, known: known, buf: make([]byte, 1<<20)}
}

// dropped says whether the blob at name (a cleaned tar path) is a skipped layer.
func (f *filter) dropped(name string) bool {
	return f.skip[blobID(name)]
}

// blobID is the sha256: id a blobs/sha256/<hex> path names, else "".
func blobID(name string) string {
	hex, ok := strings.CutPrefix(name, "blobs/sha256/")
	if !ok || hex == "" || strings.Contains(hex, "/") {
		return ""
	}
	return "sha256:" + hex
}

// run copies every entry of src, then reads it to EOF. It never writes the
// end-of-archive marker: close does, once the caller knows save exited 0.
func (f *filter) run(src io.Reader) error {
	tr := tar.NewReader(src)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
		name := path.Clean(hdr.Name)
		// A docker 25 save links <id>/layer.tar to its blob; a link left
		// dangling makes containerd's import refuse the whole archive.
		if hdr.Typeflag == tar.TypeSymlink && f.dropped(path.Join(path.Dir(name), hdr.Linkname)) {
			continue
		}
		if hdr.Typeflag == tar.TypeReg && f.known[blobID(name)] {
			f.matched++
		}
		if hdr.Typeflag == tar.TypeReg && f.dropped(name) {
			f.skipped++
			f.skippedBytes += hdr.Size
			continue
		}
		if err := f.tw.WriteHeader(hdr); err != nil {
			return err
		}
		if _, err := io.CopyBuffer(f.tw, tr, f.buf); err != nil {
			return err
		}
	}
	if err := f.tw.Flush(); err != nil {
		return err
	}
	_, err := io.CopyBuffer(io.Discard, src, f.buf)
	return err
}

func (f *filter) close() error { return f.tw.Close() }
