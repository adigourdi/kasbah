package version

import (
	"regexp"
	"strings"
	"time"
)

// DirtySuffix introduces a working-tree build's label; a Docker tag cannot
// hold `+`, so it is a pre-release, not build metadata.
const DirtySuffix = "-dirty."

var reDirty = regexp.MustCompile(`-dirty\.[0-9]{14}$`)

// DirtyLabel is `<base>-dirty.<UTC yyyymmddhhmmss>`, what a --dirty build is
// called in its image tag, versions.log and report.
func DirtyLabel(base string, now time.Time) string {
	return base + DirtySuffix + now.UTC().Format("20060102150405")
}

// IsDirty is whether a version is a DirtyLabel: a build no tag names, so never
// a rollback target nor one of prune's kept three.
func IsDirty(v string) bool { return reDirty.MatchString(strings.TrimSuffix(v, "\r")) }

// DirtyBase is the version a dirty label was made from, and any other version
// itself — the tag a changelog compares a dirty endpoint as.
func DirtyBase(v string) string {
	v = strings.TrimSuffix(v, "\r")
	if loc := reDirty.FindStringIndex(v); loc != nil {
		return v[:loc[0]]
	}
	return v
}
