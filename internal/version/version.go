// Package version computes the build stamp kasbah reports as its version.
package version

import (
	"strconv"
	"strings"
	"time"
)

// Stamp derives the reported build from the VERSION file's content. A
// pre-release gains the commit count, and a dirty tree the build time. Under
// semver pre-release ordering a build therefore outranks every build from
// fewer commits, and a dirty build outranks the clean one it started from —
// but not a later clean build of the same count, and an amended or rewritten
// history can repeat or lower the count. A release is reported as written.
func Stamp(base string, commits int, dirty bool, now time.Time) string {
	base = strings.TrimSpace(base)
	core, meta, hasMeta := strings.Cut(base, "+")
	if !strings.Contains(core, "-") {
		return base
	}
	v := core + "." + strconv.Itoa(commits)
	if dirty {
		v += "." + strconv.FormatInt(now.Unix(), 10)
	}
	if hasMeta {
		v += "+" + meta
	}
	return v
}
