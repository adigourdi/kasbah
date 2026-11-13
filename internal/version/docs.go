package version

// RepoURL is where kasbah's source, and so its docs, live.
const RepoURL = "https://github.com/adigourdi/kasbah"

// Released is whether stamp is exactly a release tag's build: it parses, and
// carries neither Stamp's commit count and build time nor build metadata.
func Released(stamp string) bool {
	v, err := Parse(stamp)
	return err == nil && v.Meta == "" && !stamped(v.Pre)
}

// DocsRef is the git ref whose docs/ match this build: the tag v<stamp> for a
// release, main for a dev or unstamped build, which no tag names.
func DocsRef(stamp string) string {
	if Released(stamp) {
		return "v" + stamp
	}
	return "main"
}

// DocsURL is docs/<file> at DocsRef on GitHub; file "" is the docs/ tree.
func DocsURL(stamp, file string) string {
	if file == "" {
		return RepoURL + "/tree/" + DocsRef(stamp) + "/docs"
	}
	return RepoURL + "/blob/" + DocsRef(stamp) + "/docs/" + file
}
