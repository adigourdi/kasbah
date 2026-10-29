package buildpush

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
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

// parseHave reads `remote layers`' answer, accepting it only whole: a
// layers=<n> count matching its have= lines, each a chain that was asked.
func parseHave(out []byte, asked []string) (map[string]bool, error) {
	want := map[string]bool{}
	for _, c := range asked {
		want[c] = true
	}
	have, count := map[string]bool{}, -1
	for _, l := range strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n") {
		k, v, _ := strings.Cut(l, "=")
		switch k {
		case "have":
			if !want[v] {
				return nil, fmt.Errorf("it named a layer that was not asked about (%q)", v)
			}
			have[v] = true
		case "layers":
			n, err := strconv.Atoi(v)
			if err != nil {
				return nil, fmt.Errorf("unreadable count %q", l)
			}
			count = n
		}
	}
	if count != len(have) {
		return nil, fmt.Errorf("its answer was incomplete (layers=%d, %d have= lines)", count, len(have))
	}
	return have, nil
}

const layersUsage = "usage: kasbah remote layers CHAINID... (prints have=<id> for each one this server's image store holds, then layers=<n>)"

// Layers is `kasbah remote layers CHAINID...` on the server: which of those
// layer chains any image on this box already has, from one `docker image ls`
// and one inspect of everything it lists. Read-only.
func Layers(args []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: layers: "+format+"\n", a...)
		return 1
	}
	if len(args) == 1 && (args[0] == "-h" || args[0] == "--help") {
		fmt.Fprintln(stdout, layersUsage)
		return 0
	}
	for _, a := range args {
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
	have := map[string]bool{}
	if len(ids) > 0 && len(args) > 0 {
		all, err := rootFS(ids)
		if err != nil {
			return fail("%v", err)
		}
		for _, diffs := range all {
			for _, c := range chainIDs(diffs) {
				have[c] = true
			}
		}
	}
	n := 0
	for _, a := range args {
		if have[a] {
			fmt.Fprintf(stdout, "have=%s\n", a)
			delete(have, a)
			n++
		}
	}
	fmt.Fprintf(stdout, "layers=%d\n", n)
	return 0
}
