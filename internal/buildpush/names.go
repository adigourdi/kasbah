package buildpush

import (
	"archive/tar"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"path"
	"path/filepath"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// MapName is <apps>/.kasbah/layers.map: the blob names this server's loads
// carried layers under — a containerd-store save's compressed digest, or the
// diffID itself where a save named the layer by it.
const MapName = "layers.map"

// MapMode is the map's: every operator's load rewrites it.
const MapMode = 0o664

func mapPath(apps string) string {
	return filepath.Join(apps, ".kasbah", MapName)
}

// names is blob digest → diffID; one diffID may go by several names.
type names map[string]string

// byDiff is the names of each diffID, sorted.
func (n names) byDiff() map[string][]string {
	out := map[string][]string{}
	for b, d := range n {
		out[d] = append(out[d], b)
	}
	for _, bs := range out {
		slices.Sort(bs)
	}
	return out
}

// parseMap reads `<blob> <diffID>` lines; a map with any line it cannot
// read is no map at all.
func parseMap(b []byte) names {
	n := names{}
	for _, l := range strings.Split(strings.ReplaceAll(string(b), "\r", ""), "\n") {
		if l == "" {
			continue
		}
		f := strings.Split(l, " ")
		if len(f) != 2 || !validID(f[0]) || !validID(f[1]) {
			return names{}
		}
		n[f[0]] = f[1]
	}
	return n
}

func (n names) encode() []byte {
	var b bytes.Buffer
	for _, k := range slices.Sorted(maps.Keys(n)) {
		fmt.Fprintf(&b, "%s %s\n", k, n[k])
	}
	return b.Bytes()
}

func readMap(apps string) names {
	b, err := os.ReadFile(mapPath(apps))
	if err != nil {
		return names{}
	}
	return parseMap(b)
}

// writeMap replaces the map whole, beside it, at MapMode.
func writeMap(apps string, n names) error {
	dst := mapPath(apps)
	f, err := os.CreateTemp(filepath.Dir(dst), "."+MapName+".*")
	if err != nil {
		return err
	}
	tmp := f.Name()
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	_, err = f.Write(n.encode())
	if err == nil {
		err = f.Chmod(MapMode)
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, dst)
	}
	if err != nil {
		os.Remove(tmp)
	}
	return err
}

// updateMap rewrites the map through change under the shared server lock,
// only when change altered it. The map is a cache: a busy lock or a failed
// write leaves it as it was.
func updateMap(apps, what string, change func(names) bool) error {
	lock, err := serverlock.Take(apps, serverlock.Shared, what)
	var busy *serverlock.Busy
	if errors.As(err, &busy) {
		return fmt.Errorf("%s holds the server lock", busy.Holder)
	}
	if err != nil || lock == nil {
		return err
	}
	defer lock.Close()
	n := readMap(apps)
	if !change(n) {
		return nil
	}
	return writeMap(apps, n)
}

// smallBlob bounds what learn buffers: configs and manifests, never layers.
const smallBlob = 1 << 20

// learn reads a `docker save` tar to its end and pairs every layer blob name
// with its diffID, from manifest.json and the configs it names
// (rootfs.diff_ids, in Layers order).
func learn(r io.Reader) (names, error) {
	defer io.Copy(io.Discard, r)
	tr := tar.NewReader(r)
	small := map[string][]byte{}
	var manifest []byte
	head := make([]byte, 1)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, err
		}
		if hdr.Typeflag != tar.TypeReg || hdr.Size > smallBlob {
			continue
		}
		name := path.Clean(hdr.Name)
		if name != "manifest.json" && blobID(name) == "" {
			continue
		}
		// JSON only — manifest.json an array, a config an object: a layer,
		// compressed or not, starts otherwise.
		open := byte('{')
		if name == "manifest.json" {
			open = '['
		}
		if _, err := io.ReadFull(tr, head); err != nil || head[0] != open {
			continue
		}
		rest, err := io.ReadAll(tr)
		if err != nil {
			return nil, err
		}
		b := append([]byte{open}, rest...)
		if name == "manifest.json" {
			manifest = b
		} else {
			small[name] = b
		}
	}
	if manifest == nil {
		return nil, errors.New("the export had no manifest.json")
	}
	var entries []struct {
		Config string
		Layers []string
	}
	if err := json.Unmarshal(manifest, &entries); err != nil {
		return nil, fmt.Errorf("unreadable manifest.json: %v", err)
	}
	n := names{}
	for _, e := range entries {
		var cfg struct {
			RootFS struct {
				DiffIDs []string `json:"diff_ids"`
			} `json:"rootfs"`
		}
		if json.Unmarshal(small[path.Clean(e.Config)], &cfg) != nil || len(cfg.RootFS.DiffIDs) != len(e.Layers) {
			continue
		}
		for i, l := range e.Layers {
			b, d := blobID(path.Clean(l)), cfg.RootFS.DiffIDs[i]
			if validID(b) && validID(d) {
				n[b] = d
			}
		}
	}
	return n, nil
}
