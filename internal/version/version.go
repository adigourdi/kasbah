// Package version computes the build stamp kasbah reports as its version, and
// orders two stamps the way the server binary's same-build rule needs.
package version

import (
	"fmt"
	"strconv"
	"strings"
	"time"
)

// Stamp derives the build from VERSION: a pre-release gains the commit count
// and the unix build time, so a later build outranks any earlier one of the
// same or a lower count (not a history rewritten shorter); a release is as written.
func Stamp(base string, commits int, now time.Time) string {
	base = strings.TrimSpace(base)
	core, meta, hasMeta := strings.Cut(base, "+")
	if !strings.Contains(core, "-") {
		return base
	}
	v := core + "." + strconv.Itoa(commits) + "." + strconv.FormatInt(now.Unix(), 10)
	if hasMeta {
		v += "+" + meta
	}
	return v
}

// Version is a parsed semantic version. Build metadata is kept for printing
// and ignored by Compare, as semver says.
type Version struct {
	Major, Minor, Patch uint64
	Pre                 []string
	Meta                string
	raw                 string
}

func (v Version) String() string { return v.raw }

// Parse reads a semver 2.0 version. A leading `v` is not accepted: no stamp
// kasbah makes carries one.
func Parse(s string) (Version, error) {
	v := Version{raw: s}
	rest, meta, hasMeta := strings.Cut(s, "+")
	if hasMeta {
		if !idents(meta, false) {
			return Version{}, fmt.Errorf("%q is not a version: bad build metadata", s)
		}
		v.Meta = meta
	}
	core, pre, hasPre := strings.Cut(rest, "-")
	parts := strings.Split(core, ".")
	if len(parts) != 3 {
		return Version{}, fmt.Errorf("%q is not a version (expected MAJOR.MINOR.PATCH)", s)
	}
	nums := make([]uint64, 3)
	for i, p := range parts {
		n, ok := numeric(p)
		if !ok {
			return Version{}, fmt.Errorf("%q is not a version: %q is not a number", s, p)
		}
		nums[i] = n
	}
	v.Major, v.Minor, v.Patch = nums[0], nums[1], nums[2]
	if hasPre {
		if !idents(pre, true) {
			return Version{}, fmt.Errorf("%q is not a version: bad pre-release", s)
		}
		v.Pre = strings.Split(pre, ".")
	}
	return v, nil
}

// numeric is a semver numeric identifier: digits, no leading zero.
func numeric(s string) (uint64, bool) {
	if s == "" || (len(s) > 1 && s[0] == '0') {
		return 0, false
	}
	for _, c := range s {
		if c < '0' || c > '9' {
			return 0, false
		}
	}
	n, err := strconv.ParseUint(s, 10, 64)
	return n, err == nil
}

func idents(s string, pre bool) bool {
	for _, id := range strings.Split(s, ".") {
		if id == "" {
			return false
		}
		allDigits := true
		for _, c := range id {
			switch {
			case c >= '0' && c <= '9':
			case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c == '-':
				allDigits = false
			default:
				return false
			}
		}
		if pre && allDigits && len(id) > 1 && id[0] == '0' {
			return false
		}
	}
	return true
}

// stamped is whether pre ends in Stamp's .<commits>.<build time>: at least one
// identifier before two numeric ones.
func stamped(pre []string) bool {
	n := len(pre)
	if n < 3 {
		return false
	}
	for _, id := range pre[n-2:] {
		if _, ok := numeric(id); !ok {
			return false
		}
	}
	return true
}

func cmpU(a, b uint64) int {
	switch {
	case a < b:
		return -1
	case a > b:
		return 1
	}
	return 0
}

// Compare is semver precedence: -1, 0 or 1 as a is lower than, equal to or
// higher than b.
func Compare(a, b Version) int {
	if c := cmpU(a.Major, b.Major); c != 0 {
		return c
	}
	if c := cmpU(a.Minor, b.Minor); c != 0 {
		return c
	}
	if c := cmpU(a.Patch, b.Patch); c != 0 {
		return c
	}
	switch {
	case len(a.Pre) == 0 && len(b.Pre) == 0:
		return 0
	case len(a.Pre) == 0:
		return 1
	case len(b.Pre) == 0:
		return -1
	}
	for i := 0; i < len(a.Pre) && i < len(b.Pre); i++ {
		x, y := a.Pre[i], b.Pre[i]
		xn, xNum := numeric(x)
		yn, yNum := numeric(y)
		var c int
		switch {
		case xNum && yNum:
			c = cmpU(xn, yn)
		case xNum:
			c = -1
		case yNum:
			c = 1
		default:
			c = strings.Compare(x, y)
		}
		if c != 0 {
			return c
		}
	}
	return cmpU(uint64(len(a.Pre)), uint64(len(b.Pre)))
}

// Base is the VERSION a stamp was made from — what files kasbah writes record:
// a stamped pre-release loses the commit count and build time Stamp added, an
// exact one (a release build of an -rc.N tag) is itself, and build metadata
// (`+g<sha>[.dirty]`) is dropped either way.
func Base(stamp string) (string, error) {
	v, err := Parse(stamp)
	if err != nil {
		return "", err
	}
	pre := v.Pre
	if stamped(pre) {
		pre = pre[:len(pre)-2]
	}
	s := fmt.Sprintf("%d.%d.%d", v.Major, v.Minor, v.Patch)
	if len(pre) > 0 {
		s += "-" + strings.Join(pre, ".")
	}
	return s, nil
}
