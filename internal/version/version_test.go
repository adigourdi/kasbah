package version

import (
	"testing"
	"time"
)

func TestStamp(t *testing.T) {
	at := time.Unix(1760790000, 0)
	tests := []struct {
		name    string
		base    string
		commits int
		want    string
	}{
		{"pre-release", "0.1.0-dev", 142, "0.1.0-dev.142.1760790000"},
		{"trailing newline from the file", "0.1.0-dev\n", 7, "0.1.0-dev.7.1760790000"},
		{"CRLF from the file", "0.1.0-dev\r\n", 7, "0.1.0-dev.7.1760790000"},
		{"release", "1.0.0", 142, "1.0.0"},
		{"release with a newline", "1.0.0\n", 142, "1.0.0"},
		{"dotted pre-release", "1.1.0-rc.1", 300, "1.1.0-rc.1.300.1760790000"},
		{"release with build metadata", "1.0.0+exp-sha.5114f85", 142, "1.0.0+exp-sha.5114f85"},
		{"pre-release with build metadata", "0.1.0-dev+meta", 142, "0.1.0-dev.142.1760790000+meta"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Stamp(tt.base, tt.commits, at); got != tt.want {
				t.Errorf("Stamp(%q, %d) = %q, want %q", tt.base, tt.commits, got, tt.want)
			}
			if _, err := Parse(Stamp(tt.base, tt.commits, at)); err != nil {
				t.Errorf("the stamp does not parse: %v", err)
			}
		})
	}
}

// Every pair of builds D1 has to order, built with Stamp itself.
func TestStampOrdering(t *testing.T) {
	t0 := time.Unix(1760790000, 0)
	later := t0.Add(time.Minute)
	tests := []struct {
		name          string
		earlier, next string
	}{
		{"a rebuild of the same commit", Stamp("0.1.0-dev", 142, t0), Stamp("0.1.0-dev", 142, later)},
		{"the clean rebuild after a dirty build", Stamp("0.1.0-dev", 142, t0), Stamp("0.1.0-dev", 142, later)},
		{"an amend keeps the count", Stamp("0.1.0-dev", 142, t0), Stamp("0.1.0-dev", 142, later)},
		{"one more commit, even built with an older clock", Stamp("0.1.0-dev", 142, later), Stamp("0.1.0-dev", 143, t0)},
		{"a count with more digits", Stamp("0.1.0-dev", 99, t0), Stamp("0.1.0-dev", 100, t0)},
		{"the release after its pre-releases", Stamp("1.0.0-dev", 900, later), Stamp("1.0.0", 900, t0)},
		{"a pre-D1 clean stamp", "0.1.0-dev.142", Stamp("0.1.0-dev", 142, t0)},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a, b := mustParse(t, tt.earlier), mustParse(t, tt.next)
			if Compare(a, b) != -1 || Compare(b, a) != 1 {
				t.Errorf("%s does not order below %s", tt.earlier, tt.next)
			}
		})
	}
}

func mustParse(t *testing.T, s string) Version {
	t.Helper()
	v, err := Parse(s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

func TestCompare(t *testing.T) {
	tests := []struct {
		a, b string
		want int
	}{
		// semver.org §11's own chain, pairwise.
		{"1.0.0-alpha", "1.0.0-alpha.1", -1},
		{"1.0.0-alpha.1", "1.0.0-alpha.beta", -1},
		{"1.0.0-alpha.beta", "1.0.0-beta", -1},
		{"1.0.0-beta", "1.0.0-beta.2", -1},
		{"1.0.0-beta.2", "1.0.0-beta.11", -1},
		{"1.0.0-beta.11", "1.0.0-rc.1", -1},
		{"1.0.0-rc.1", "1.0.0", -1},
		{"1.0.0", "2.0.0", -1},
		{"2.0.0", "2.1.0", -1},
		{"2.1.0", "2.1.1", -1},
		{"1.9.0", "1.10.0", -1},
		{"0.1.0-dev.142.1760790000", "0.1.0-dev.142.1760790000", 0},
		{"1.0.0+a", "1.0.0+b", 0},
		{"0.1.0-dev.142+x", "0.1.0-dev.142", 0},
		{"0.1.0-dev.9.1760790000", "0.1.0-dev.10.1", -1},
		{"0.1.0-dev.142.1760790000", "0.1.0-dev.142.1760790001", -1},
		{"0.1.0-dev.142", "0.1.0-dev.142.1760790000", -1},
		{"0.0.0-0", "0.1.0-dev.1.1", -1},
		{"0.999999.0", "1.0.0-dev.1.1", -1},
	}
	for _, tt := range tests {
		a, b := mustParse(t, tt.a), mustParse(t, tt.b)
		if got := Compare(a, b); got != tt.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", tt.a, tt.b, got, tt.want)
		}
		if got := Compare(b, a); got != -tt.want {
			t.Errorf("Compare(%s, %s) = %d, want %d", tt.b, tt.a, got, -tt.want)
		}
	}
}

func TestParse(t *testing.T) {
	good := map[string]Version{
		"1.2.3":                    {Major: 1, Minor: 2, Patch: 3},
		"0.1.0-dev.142.1760790000": {Minor: 1, Pre: []string{"dev", "142", "1760790000"}},
		"1.0.0-x-y.0+sha.5114f85":  {Major: 1, Pre: []string{"x-y", "0"}, Meta: "sha.5114f85"},
	}
	for s, want := range good {
		v, err := Parse(s)
		if err != nil {
			t.Errorf("Parse(%q): %v", s, err)
			continue
		}
		if v.Major != want.Major || v.Minor != want.Minor || v.Patch != want.Patch ||
			len(v.Pre) != len(want.Pre) || v.Meta != want.Meta || v.String() != s {
			t.Errorf("Parse(%q) = %+v, want %+v", s, v, want)
		}
	}
	for _, s := range []string{
		"", "1", "1.2", "1.2.3.4", "v1.2.3", "01.2.3", "1.2.3-", "1.2.3-01",
		"1.2.3-a..b", "1.2.3+", "1.2.3-a b", "x.y.z", "-1.2.3", "1.2.3\n",
		"99999999999999999999.0.0",
	} {
		if _, err := Parse(s); err == nil {
			t.Errorf("Parse(%q) accepted it", s)
		}
	}
}

func TestBase(t *testing.T) {
	at := time.Unix(1760790000, 0)
	for _, base := range []string{"1.0.0", "0.1.0-dev", "1.1.0-rc.1", "1.0.0+exp-sha.5114f85", "0.1.0-dev+meta"} {
		got, err := Base(Stamp(base, 142, at))
		if err != nil || got != base {
			t.Errorf("Base(Stamp(%q)) = %q, %v", base, got, err)
		}
	}
	for _, bad := range []string{"", "devel", "0.1.0-dev", "0.1.0-dev.x.1"} {
		if got, err := Base(bad); err == nil {
			t.Errorf("Base(%q) = %q, want an error", bad, got)
		}
	}
}

// A release workstation meets servers left by pre-release builds.
func TestReleaseOrdering(t *testing.T) {
	rel, _ := Parse(Stamp("1.0.0", 300, time.Unix(1760790000, 0)))
	dev, _ := Parse("0.1.0-dev.66.1792355995")
	pre, _ := Parse("1.0.0-dev.299.1792355995")
	if Compare(dev, rel) >= 0 || Compare(pre, rel) >= 0 {
		t.Errorf("a pre-release build does not rank below 1.0.0")
	}
}
