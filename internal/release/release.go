// Package release is the one version contract build-push and deploy share:
// HEAD's single v-tag is what a release is called (docs/build-deploy.md →
// versioning contract).
package release

import (
	"os"
	"os/exec"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/version"
)

var reVersion = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$`)

// Pick is the version in `git tag --points-at HEAD`'s output, without its v:
// zero v-tags and two are different mistakes, refused differently.
func Pick(tags string) (string, error) {
	vs, other := split(tags)
	if len(vs) == 0 {
		e := cli.Fail("HEAD carries no version tag, so this release has nothing to label itself with")
		if len(other) > 0 {
			e.Cont("HEAD is tagged " + strings.Join(other, " ") + ", and kasbah versions are v-prefixed semver")
		}
		return "", e.Cont("tag the commit and retry:  git tag v1.0.0")
	}
	if len(vs) > 1 {
		return "", cli.Fail("HEAD carries %d version tags — %s", len(vs), strings.Join(vs, " ")).Cont(
			"exactly one is required: the tag is the version that goes into versions.log",
			"and onto the images, and kasbah will not choose between them")
	}
	// A space would break versions.log, whose fields are space-delimited.
	if !reVersion.MatchString(vs[0]) {
		return "", cli.Fail("HEAD's tag '%s' is not a version kasbah can use", vs[0]).Cont(
			"expected v<major>.<minor>.<patch> (docs/build-deploy.md → versioning contract)")
	}
	if version.IsDirty(vs[0][1:]) {
		return "", cli.Fail("HEAD's tag '%s' is shaped like a --dirty build's label, which no release may carry", vs[0]).Cont(
			"every reader treats a -dirty.<14 digits> version as untagged and never a rollback target —",
			"tag the release plainly, or ship this tree with --dirty")
	}
	return vs[0][1:], nil
}

// Repo is what every read of the checkout needs: git, a repository, a HEAD.
func Repo(pwd string) error {
	if _, err := exec.LookPath("git"); err != nil {
		return cli.Fail("git is required — kasbah resolves the version from HEAD's tag")
	}
	if exec.Command("git", "rev-parse", "--git-dir").Run() != nil {
		return cli.Fail("%s is not a git repository — kasbah resolves the version from HEAD's tag", pwd)
	}
	if exec.Command("git", "rev-parse", "-q", "--verify", "HEAD").Run() != nil {
		return cli.Fail("this repository has no commits yet, so there is no HEAD to read a version tag from")
	}
	return nil
}

// Resolve reads HEAD's version in the current directory's repository.
func Resolve(pwd string) (string, error) {
	if err := Repo(pwd); err != nil {
		return "", err
	}
	cmd := exec.Command("git", "tag", "--points-at", "HEAD")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return "", cli.Fail("could not list the tags on HEAD (see git's error above)")
	}
	return Pick(string(out))
}
