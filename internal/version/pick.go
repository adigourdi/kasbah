package version

import (
	"fmt"
	"strings"
)

// NoMatch is Pick's refusal when no tag answers the argument; Skipped counts
// the pre-releases that would have, given pre.
type NoMatch struct {
	Want    string
	Skipped int
}

func (e *NoMatch) Error() string {
	s := "no tag matches " + e.Want
	if e.Skipped > 0 {
		s += fmt.Sprintf(" (%d pre-release tag(s) skipped — --pre takes them)", e.Skipped)
	}
	return s
}

// Tags reads tag names (`git tag -l` lines, CRLF tolerated) as versions:
// `v<semver>` only, anything else ignored.
func Tags(names []string) []Version {
	var out []Version
	for _, n := range names {
		s, ok := strings.CutPrefix(strings.TrimSpace(n), "v")
		if !ok {
			continue
		}
		if v, err := Parse(s); err == nil {
			out = append(out, v)
		}
	}
	return out
}

// Pick is the tag arg names: `vN` the newest of N, `vN.M` the newest of N.M,
// `vN.M.P[-rc.K]` that one exactly (v optional); rcs count for vN and vN.M only with pre.
func Pick(arg string, tags []Version, pre bool) (Version, error) {
	s := strings.TrimPrefix(strings.TrimSpace(arg), "v")
	bad := fmt.Errorf("'%s' is not a version: expected vN, vN.M or vN.M.P", strings.TrimSpace(arg))
	if strings.Count(s, ".") >= 2 {
		want, err := Parse(s)
		if err != nil {
			return Version{}, bad
		}
		for _, t := range tags {
			if t.String() == want.String() {
				return t, nil
			}
		}
		return Version{}, &NoMatch{Want: "v" + s}
	}
	parts := strings.Split(s, ".")
	nums := make([]uint64, len(parts))
	for i, p := range parts {
		n, ok := numeric(p)
		if !ok {
			return Version{}, bad
		}
		nums[i] = n
	}
	var best *Version
	skipped := 0
	for i, t := range tags {
		if t.Major != nums[0] || (len(nums) == 2 && t.Minor != nums[1]) {
			continue
		}
		if len(t.Pre) > 0 && !pre {
			skipped++
			continue
		}
		if best == nil || Compare(t, *best) > 0 {
			best = &tags[i]
		}
	}
	if best == nil {
		return Version{}, &NoMatch{Want: "v" + s, Skipped: skipped}
	}
	return *best, nil
}
