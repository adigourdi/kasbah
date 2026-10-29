package buildpush

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
)

// chainIDs are the ids both image stores key an applied layer by: a diffID
// is only reusable on top of the same parents.
func chainIDs(diffIDs []string) []string {
	out := make([]string, len(diffIDs))
	for i, d := range diffIDs {
		if i == 0 {
			out[i] = d
			continue
		}
		h := sha256.Sum256([]byte(out[i-1] + " " + d))
		out[i] = "sha256:" + hex.EncodeToString(h[:])
	}
	return out
}

func validID(s string) bool {
	h, ok := strings.CutPrefix(s, "sha256:")
	if !ok || len(h) != 64 {
		return false
	}
	_, err := hex.DecodeString(h)
	return err == nil && strings.ToLower(h) == h
}

// rootFS is each image's diffIDs, in argument order, from one inspect.
func rootFS(images []string) ([][]string, error) {
	cmd := exec.Command("docker", append([]string{"image", "inspect", "--format", "{{json .RootFS.Layers}}"}, images...)...)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var errb bytes.Buffer
	cmd.Stderr = &errb
	raw, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("docker image inspect exited %v: %s", err, strings.TrimSpace(errb.String()))
	}
	lines := strings.Split(strings.TrimRight(strings.ReplaceAll(string(raw), "\r", ""), "\n"), "\n")
	if len(lines) != len(images) {
		return nil, fmt.Errorf("docker image inspect answered %d lines for %d images", len(lines), len(images))
	}
	out := make([][]string, len(images))
	for i, l := range lines {
		if err := json.Unmarshal([]byte(l), &out[i]); err != nil {
			return nil, fmt.Errorf("unreadable layer list for %s: %q", images[i], l)
		}
		for _, d := range out[i] {
			if !validID(d) {
				return nil, fmt.Errorf("unreadable layer id %q in %s", d, images[i])
			}
		}
	}
	return out, nil
}

// skippable is the diffIDs that can stay off the wire: every chain they
// occur in, across the images, is already on the server.
func skippable(images [][]string, have map[string]bool) map[string]bool {
	skip, need := map[string]bool{}, map[string]bool{}
	for _, diffs := range images {
		for i, c := range chainIDs(diffs) {
			if have[c] {
				skip[diffs[i]] = true
			} else {
				need[diffs[i]] = true
			}
		}
	}
	for d := range need {
		delete(skip, d)
	}
	return skip
}

// answer is `remote layers`' reply, accepted only whole.
type answer struct {
	have map[string]bool
	// names is the blob names the server knows for its layers, by diffID.
	names map[string][]string
}

// parseHave reads `remote layers`' answer, accepting it only whole: a
// layers=<n> count matching its have= lines, each a chain that was asked, and
// name= lines only for the diffIDs asked about.
func parseHave(out []byte, asked []string, diffIDs map[string]bool) (answer, error) {
	want := map[string]bool{}
	for _, c := range asked {
		want[c] = true
	}
	a, count := answer{have: map[string]bool{}, names: map[string][]string{}}, -1
	for _, l := range strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n") {
		k, v, _ := strings.Cut(l, "=")
		switch k {
		case "have":
			if !want[v] {
				return answer{}, fmt.Errorf("it named a layer that was not asked about (%q)", v)
			}
			a.have[v] = true
		case "name":
			d, b, ok := strings.Cut(v, " ")
			if !ok || !validID(b) || !diffIDs[d] {
				return answer{}, fmt.Errorf("unreadable layer name %q", l)
			}
			a.names[d] = append(a.names[d], b)
		case "layers":
			n, err := strconv.Atoi(v)
			if err != nil {
				return answer{}, fmt.Errorf("unreadable count %q", l)
			}
			count = n
		}
	}
	if count != len(a.have) {
		return answer{}, fmt.Errorf("its answer was incomplete (layers=%d, %d have= lines)", count, len(a.have))
	}
	return a, nil
}

const layersUsage = "usage: kasbah remote layers APPS CHAINID... (prints have=<id> for each one this server's image store holds, name=<diffID> <blob> for the names it knows them by, then layers=<n>)"

// Layers is `kasbah remote layers APPS CHAINID...` on the server: which of
// those chains its images hold (one image ls, one inspect) and the names
// layers.map knows them by; then the map loses names no image's layer has.
func Layers(args []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: layers: "+format+"\n", a...)
		return 1
	}
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprintln(stdout, layersUsage)
		return 0
	}
	if len(args) == 0 || !strings.HasPrefix(args[0], "/") {
		return fail("no absolute apps path first — %s", layersUsage)
	}
	apps, chains := args[0], args[1:]
	for _, a := range chains {
		if !validID(a) {
			return fail("'%s' is not a sha256: layer chain id — %s", a, layersUsage)
		}
	}
	ls := exec.Command("docker", "image", "ls", "-aq", "--no-trunc")
	ls.Env = append(os.Environ(), "LC_ALL=C")
	ls.Stderr = stderr
	raw, err := ls.Output()
	if err != nil {
		return fail("docker image ls failed (%v)", err)
	}
	var ids []string
	seen := map[string]bool{}
	for _, id := range strings.Fields(string(raw)) {
		if !seen[id] {
			seen[id] = true
			ids = append(ids, id)
		}
	}
	m := readMap(apps)
	// chain → the diffID it ends in; held is every diffID on the server.
	have, held := map[string]string{}, map[string]bool{}
	if len(ids) > 0 && (len(chains) > 0 || len(m) > 0) {
		all, err := rootFS(ids)
		if err != nil {
			return fail("%v", err)
		}
		for _, diffs := range all {
			for i, c := range chainIDs(diffs) {
				have[c] = diffs[i]
				held[diffs[i]] = true
			}
		}
	}
	n, asked := 0, map[string]bool{}
	for _, a := range chains {
		if d, ok := have[a]; ok {
			fmt.Fprintf(stdout, "have=%s\n", a)
			delete(have, a)
			asked[d] = true
			n++
		}
	}
	byDiff := m.byDiff()
	for _, d := range slices.Sorted(maps.Keys(asked)) {
		for _, b := range byDiff[d] {
			fmt.Fprintf(stdout, "name=%s %s\n", d, b)
		}
	}
	fmt.Fprintf(stdout, "layers=%d\n", n)
	if len(m) > 0 {
		err := updateMap(apps, "build-push", func(n names) bool {
			changed := false
			for b, d := range n {
				if !held[d] {
					delete(n, b)
					changed = true
				}
			}
			return changed
		})
		if err != nil {
			fmt.Fprintf(stderr, "remote: layers: %s not pruned: %v\n", mapPath(apps), err)
		}
	}
	return 0
}
