package release

import (
	"fmt"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/version"
)

// Bumps are --bump's answers, in the order they are offered.
var Bumps = []string{"patch", "minor", "major"}

// CheckBump refuses a --bump= value that is none of Bumps.
func CheckBump(cmd, v string) error {
	for _, b := range Bumps {
		if v == b {
			return nil
		}
	}
	return cli.Fail("%s: --bump=%s is not a bump — --bump=patch, --bump=minor or --bump=major", cmd, v)
}

// Bump is base with one part raised and the parts after it zeroed.
func Bump(base version.Version, part string) string {
	switch part {
	case "major":
		return fmt.Sprintf("%d.0.0", base.Major+1)
	case "minor":
		return fmt.Sprintf("%d.%d.0", base.Major, base.Minor+1)
	}
	return fmt.Sprintf("%d.%d.%d", base.Major, base.Minor, base.Patch+1)
}

// finalBase is the highest final version among names — pre-releases, dirty
// labels among them, ignored — and 0.0.0 with none.
func finalBase(names []string) version.Version {
	best, _ := version.Parse("0.0.0")
	for _, t := range version.Tags(names) {
		if len(t.Pre) == 0 && version.Compare(t, best) > 0 {
			best = t
		}
	}
	return best
}

// Tagging is what an untagged HEAD needs to be given a tag: Bump is --bump's
// answer, P asks without one, Push says origin's tags count as taken too, and
// Untagged, when set, may refuse the run before anything is asked.
type Tagging struct {
	Cmd, Retry, Bump string
	Push             bool
	P                *prompt.Prompter
	Untagged         func() error
}

// Head is the version a clean run ships; fresh means HEAD had no v-tag and v is
// the bump the operator chose, for the caller to Cut before reaching a server.
func Head(pwd string, t Tagging) (v string, fresh bool, err error) {
	if t.P == nil {
		return "", false, cli.Fail("internal: %s resolved HEAD's version with no prompter to report or ask on", t.Cmd)
	}
	if err := Repo(pwd); err != nil {
		return "", false, err
	}
	out, err := gitIn(".", "tag", "--points-at", "HEAD")
	if err != nil {
		return "", false, err
	}
	vs, other := split(string(out))
	if len(vs) > 0 {
		if v, err = Pick(string(out)); err != nil {
			return "", false, err
		}
		if t.Bump != "" {
			t.P.Out.Info("HEAD is already tagged v%s, so --bump=%s is not used", v, t.Bump)
		}
		return v, false, RequireClean(t.Cmd, v, t.Retry)
	}
	if len(other) > 0 {
		t.P.Out.Warn("HEAD is tagged %s, and kasbah versions are v-prefixed semver", strings.Join(other, " "))
	}
	if err := requireCommitted(t); err != nil {
		return "", false, err
	}
	if t.Untagged != nil {
		if err := t.Untagged(); err != nil {
			return "", false, err
		}
	}
	base, err := countFrom(t)
	if err != nil {
		return "", false, err
	}
	if v, err = choose(t, base); err != nil {
		return "", false, err
	}
	return v, true, taken(t, "v"+v)
}

func split(tags string) (vs, other []string) {
	for _, l := range strings.Split(tags, "\n") {
		l = strings.TrimSuffix(l, "\r")
		switch {
		case l == "":
		case len(l) > 1 && l[0] == 'v':
			vs = append(vs, l)
		default:
			other = append(other, l)
		}
	}
	return vs, other
}

// requireCommitted refuses an untagged HEAD whose tree is not HEAD's: the tag
// would name a commit that is not what ships.
func requireCommitted(t Tagging) error {
	if err := RequireVisible(t.Cmd); err != nil {
		return err
	}
	ch, err := Changes()
	if err != nil || len(ch) == 0 {
		return err
	}
	e := cli.Fail("%s: HEAD carries no version tag and the working tree differs from it — commit first, and kasbah tags that commit:", t.Cmd)
	list(e, ch)
	return e.Cont("or ship the tree as it stands as a labelled test build, which needs no tag:",
		"  "+t.Retry)
}

// countFrom is the version the bumps start at, refused when this clone may
// not hold the tags to count from: shallow, or none while origin has some.
func countFrom(t Tagging) (version.Version, error) {
	var none version.Version
	if sh, _ := gitIn(".", "rev-parse", "--is-shallow-repository"); strings.TrimSpace(string(sh)) == "true" {
		return none, cli.Fail("%s: HEAD carries no version tag, and this is a shallow clone — the release tags to count from may not be in it", t.Cmd).Cont(
			"fetch the whole history and the tags, then retry:  git fetch --unshallow --tags")
	}
	merged, err := gitIn(".", "tag", "--merged", "HEAD", "--list", "v*")
	if err != nil {
		return none, err
	}
	base := finalBase(strings.Split(string(merged), "\n"))
	if base.String() != "0.0.0" || !HasOrigin() {
		return base, nil
	}
	t.P.Out.Info("asking origin for its version tags — none here to count from…")
	r := origin("ls-remote", "--tags", "--refs", "origin")
	if r.rc != 0 {
		t.P.Out.Warn("could not ask origin for its version tags, so counting from 0.0.0 regardless:")
		for _, l := range r.failure() {
			t.P.Out.Warn("%s", l)
		}
		return base, nil
	}
	// Origin's v-tags that are here already, merged elsewhere, leave 0.0.0 the
	// base for this history; one missing here may be what it should count from.
	local, err := gitIn(".", "tag", "--list", "v*")
	if err != nil {
		return none, err
	}
	have := map[string]bool{}
	for _, n := range strings.Split(string(local), "\n") {
		have[strings.TrimSpace(n)] = true
	}
	var missing []string
	for _, l := range strings.Split(string(r.out), "\n") {
		if _, ref, ok := strings.Cut(l, "\t"); ok {
			if n := strings.TrimPrefix(ref, "refs/tags/"); !have[n] && len(version.Tags([]string{n})) == 1 {
				missing = append(missing, n)
			}
		}
	}
	if len(missing) > 0 {
		return none, cli.Fail("%s: HEAD carries no version tag and none is merged into it here, but origin has version tags this clone lacks (%s among them)", t.Cmd, missing[0]).Cont(
			"this clone would count from 0.0.0 — fetch them and retry:  git fetch --tags")
	}
	return base, nil
}

func choose(t Tagging, base version.Version) (string, error) {
	from := fmt.Sprintf("bumping v%d.%d.%d, the highest release tag merged into HEAD", base.Major, base.Minor, base.Patch)
	if base.String() == "0.0.0" {
		from = "no release tag is merged into HEAD, so counting from 0.0.0"
	}
	labels := make([]string, len(Bumps))
	for i, b := range Bumps {
		labels[i] = fmt.Sprintf("%-6s v%s", b, Bump(base, b))
	}
	q := fmt.Sprintf("%s: HEAD carries no version tag — tag it as which release? (%s)", t.Cmd, from)
	b, ok, err := t.P.Select("bump", q, Bumps, labels, t.Bump)
	if err != nil {
		return "", err
	}
	if !ok {
		return "", cli.Fail("%s: aborted — HEAD was not tagged and nothing ran", t.Cmd)
	}
	return Bump(base, b), nil
}

// taken refuses a tag that exists already — on another commit here, or on
// origin when the run will push there. An origin that cannot be asked is
// warned about, and the push at the end tells.
func taken(t Tagging, tag string) error {
	if exec.Command("git", "rev-parse", "-q", "--verify", "refs/tags/"+tag).Run() == nil {
		at, _ := gitIn(".", "rev-parse", "--short", tag+"^{commit}")
		return cli.Fail("%s: %s already exists, on commit %s — kasbah will not move or reuse a release tag", t.Cmd, tag, strings.TrimSpace(string(at))).Cont(
			"tag HEAD yourself with an unused version and retry:  git tag v<version>")
	}
	if !t.Push || !HasOrigin() {
		return nil
	}
	there, r := onOrigin(t.P.Out, tag)
	switch {
	case there:
		return cli.Fail("%s: %s already exists on origin, though not here — kasbah will not move or reuse a release tag", t.Cmd, tag).Cont(
			"fetch the tags (git fetch --tags) and retry, or tag HEAD yourself with an unused version")
	case r.rc != 2:
		t.P.Out.Warn("could not ask origin whether %s exists, so tagging it regardless — the push at the end will tell:", tag)
		for _, l := range r.failure() {
			t.P.Out.Warn("%s", l)
		}
	}
	return nil
}

// Cut tags HEAD v<v>, lightweight whatever tag.gpgSign says. A run that fails
// after it leaves the tag, and the next run finds HEAD tagged.
func Cut(out *cli.Output, v string) error {
	if _, err := gitIn(".", "-c", "tag.gpgSign=false", "tag", "v"+v); err != nil {
		return err
	}
	out.Info("Tagged HEAD v%s", v)
	out.Info("  if this run fails from here, the tag stays and the next run ships HEAD as v%s (git tag -d v%s to choose again)", v, v)
	return nil
}
