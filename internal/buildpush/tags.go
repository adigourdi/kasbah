package buildpush

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

// replacePair answers whether a server tag holding another build is replaced.
var replacePair = prompt.Pair{Yes: "replace-tag", No: "no-replace-tag"}

// identity is what tells one build of an image from another across two daemons.
type identity struct {
	// ID is docker's image ID on that daemon.
	ID      string
	Created string
	// Sum digests the inspect fields identify compares: created, platform, the
	// runtime config fields, layer IDs.
	Sum string
}

// same: an overlay2 store's ID is the config digest, a containerd store's the
// manifest's or index's, so one image saved and loaded across stores keeps
// neither ID — but its config, which save and load carry byte for byte.
func (b identity) same(o identity) bool { return b.ID == o.ID || b.Sum == o.Sum }

// imageConfig is the runtime config fields the sum covers, each omitted when
// empty: docker versions differ in which empty fields inspect prints.
type imageConfig struct {
	User         string              `json:",omitempty"`
	ExposedPorts map[string]struct{} `json:",omitempty"`
	Env          []string            `json:",omitempty"`
	Entrypoint   []string            `json:",omitempty"`
	Cmd          []string            `json:",omitempty"`
	Healthcheck  *struct {
		Test        []string `json:",omitempty"`
		Interval    int64    `json:",omitempty"`
		Timeout     int64    `json:",omitempty"`
		StartPeriod int64    `json:",omitempty"`
		// No StartInterval: Docker 24 (API 1.43) drops it from what it
		// reports, so a server on it would differ on every image that sets one.
		Retries int `json:",omitempty"`
	} `json:",omitempty"`
	ArgsEscaped bool                `json:",omitempty"`
	Volumes     map[string]struct{} `json:",omitempty"`
	WorkingDir  string              `json:",omitempty"`
	Labels      map[string]string   `json:",omitempty"`
	StopSignal  string              `json:",omitempty"`
	OnBuild     []string            `json:",omitempty"`
	Shell       []string            `json:",omitempty"`
}

// identify reads one `docker image inspect --format '{{json .}}'` object. Its
// sum: creation time, platform, imageConfig's fields, layer diffIDs — not the
// history, author, comment or the rest, which change nothing that runs.
func identify(raw []byte) (identity, error) {
	var in struct {
		Id, Created, Architecture, Os, Variant, OsVersion string
		Config                                            imageConfig
		RootFS                                            struct{ Layers []string }
	}
	if err := json.Unmarshal(raw, &in); err != nil {
		return identity{}, fmt.Errorf("unreadable docker image inspect output: %v", err)
	}
	if !validID(in.Id) {
		return identity{}, fmt.Errorf("unreadable image id %q", in.Id)
	}
	created := ""
	if in.Created != "" {
		t, err := time.Parse(time.RFC3339Nano, in.Created)
		if err != nil {
			return identity{}, fmt.Errorf("unreadable creation time %q", in.Created)
		}
		created = t.UTC().Format(time.RFC3339Nano)
	}
	canon, err := json.Marshal(struct {
		Created, Architecture, Os, Variant, OsVersion string
		Config                                        imageConfig
		Layers                                        []string
	}{created, in.Architecture, in.Os, in.Variant, in.OsVersion, in.Config, in.RootFS.Layers})
	if err != nil {
		return identity{}, err
	}
	h := sha256.Sum256(canon)
	return identity{ID: in.Id, Created: created, Sum: "sha256:" + hex.EncodeToString(h[:])}, nil
}

// inspectRef is ref's build on this daemon; found is false when no image has
// that name.
func inspectRef(ref string) (b identity, found bool, err error) {
	cmd := exec.Command("docker", "image", "inspect", "--format", "{{json .}}", ref)
	cmd.Env = append(os.Environ(), "LC_ALL=C")
	var errb bytes.Buffer
	cmd.Stderr = &tail{&errb, 4 << 10}
	raw, err := cmd.Output()
	if err != nil {
		if strings.Contains(errb.String(), "No such image") {
			return identity{}, false, nil
		}
		return identity{}, false, fmt.Errorf("docker image inspect %s failed: %s", ref, strings.TrimSpace(errb.String()))
	}
	b, err = identify(bytes.TrimSpace(raw))
	return b, err == nil, err
}

// printTag is one `image=` line of `remote layers`: ref's build, or absent.
func printTag(ref string, b identity, found bool) string {
	if !found {
		return "image=" + ref + " absent\n"
	}
	created := b.Created
	if created == "" {
		created = "-"
	}
	return "image=" + ref + " " + b.Sum + " " + b.ID + " " + created + "\n"
}

// parseTags reads the `image=` lines of `remote layers`, accepted only whole:
// each asked ref answered once, then images=<n> counting them.
func parseTags(out []byte, refs []string) (map[string]identity, error) {
	asked := map[string]bool{}
	for _, r := range refs {
		asked[r] = true
	}
	held, answered, count := map[string]identity{}, map[string]bool{}, -1
	for _, l := range strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n") {
		k, v, _ := strings.Cut(l, "=")
		switch k {
		case "image":
			f := strings.Fields(v)
			if len(f) == 0 || !asked[f[0]] || answered[f[0]] {
				return nil, fmt.Errorf("it answered for an image that was not asked about, or twice (%q)", l)
			}
			answered[f[0]] = true
			switch {
			case len(f) == 2 && f[1] == "absent":
			case len(f) == 4 && validID(f[1]) && validID(f[2]):
				b := identity{Sum: f[1], ID: f[2], Created: f[3]}
				if b.Created == "-" {
					b.Created = ""
				}
				held[f[0]] = b
			default:
				return nil, fmt.Errorf("unreadable image line %q", l)
			}
		case "images":
			n, err := strconv.Atoi(v)
			if err != nil {
				return nil, fmt.Errorf("unreadable count %q", l)
			}
			count = n
		}
	}
	if count != len(refs) || len(answered) != len(refs) {
		return nil, fmt.Errorf("its answer was incomplete (images=%d, %d of %d images answered)", count, len(answered), len(refs))
	}
	return held, nil
}

// short is an image ID as `docker image ls` prints it.
func short(id string) string {
	h := strings.TrimPrefix(id, "sha256:")
	return h[:min(12, len(h))]
}

func describe(b identity) string {
	if b.Created == "" {
		return short(b.ID)
	}
	return short(b.ID) + " (created " + b.Created + ")"
}

// tagPlan is which images go: those the server lacks or holds as another
// build it may replace. Same is the images it already holds as this build.
type tagPlan struct {
	send     []string
	same     map[string]bool
	replaced map[string]identity
}

// planTags compares each image the server holds under its tag with this
// build: the same build is not sent; another is replaced only on a yes.
// again is how to ship this build under another version instead.
func planTags(out *cli.Output, p *prompt.Prompter, target string, refs []string, local, there map[string]identity, given prompt.Given, again []string) (tagPlan, error) {
	pl := tagPlan{same: map[string]bool{}, replaced: map[string]identity{}}
	var differ, lines []string
	for _, r := range refs {
		b, ok := there[r]
		switch {
		case !ok:
			pl.send = append(pl.send, r)
		case b.same(local[r]):
			pl.same[r] = true
		default:
			pl.send = append(pl.send, r)
			pl.replaced[r] = b
			differ = append(differ, r)
			lines = append(lines, "  "+r+": "+target+" has "+describe(b)+", this build is "+describe(local[r]))
		}
	}
	if len(differ) == 0 {
		return pl, nil
	}
	if given == prompt.Unset {
		out.Warn("%s already holds %s as another build", target, strings.Join(differ, ", "))
		for _, l := range lines {
			out.Info("%s", l)
		}
	}
	yes, err := p.Choice(replacePair, "replace "+strings.Join(differ, ", ")+" on "+target+" with this build?", given)
	if e := (*cli.Error)(nil); errors.As(err, &e) {
		return pl, e.Cont("nothing was sent to " + target)
	}
	if err != nil {
		return pl, err
	}
	if !yes {
		e := cli.Fail("%s already holds %s as another build — nothing was sent", target, strings.Join(differ, ", "))
		if given != prompt.Unset {
			e.Cont(lines...)
		}
		return pl, e.Cont(again...).Cont("to replace the server's, re-run with --replace-tag")
	}
	return pl, nil
}
