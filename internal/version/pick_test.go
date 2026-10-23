package version

import (
	"errors"
	"testing"
)

func TestPick(t *testing.T) {
	names := []string{
		"v1.0.0", "v1.0.1", "v1.1.0-rc.1", "v1.1.0-rc.2", "v1.2.0-rc.1",
		"v2.0.0-rc.1", "v2.0.0", "v2.0.10", "v2.0.9", "v2.1.0-rc.1\r",
		"v3.0.0-rc.1", "latest", "v1.x", "1.9.0", "v01.0.0", "", "  v4.0.0  ",
	}
	tags := Tags(names)
	tests := []struct {
		arg      string
		pre      bool
		want     string
		noMatch  bool
		skipped  int
		badInput bool
	}{
		{arg: "v1", want: "1.0.1"},
		{arg: "1", want: "1.0.1"},
		{arg: "v1", pre: true, want: "1.2.0-rc.1"},
		{arg: "v2", want: "2.0.10"}, // numeric, not lexical
		{arg: "v2", pre: true, want: "2.1.0-rc.1"},
		{arg: "v2.0", want: "2.0.10"},
		{arg: "v2.0", pre: true, want: "2.0.10"}, // a release outranks its rc
		{arg: "v1.0", want: "1.0.1"},
		{arg: "v1.1", noMatch: true, skipped: 2},
		{arg: "v1.1", pre: true, want: "1.1.0-rc.2"},
		{arg: "v1.0.0", want: "1.0.0"},
		{arg: "1.0.0", want: "1.0.0"},
		{arg: "v1.1.0-rc.1", want: "1.1.0-rc.1"}, // named exactly, no --pre needed
		{arg: "v1.1.0", pre: true, noMatch: true},
		{arg: "v3", noMatch: true, skipped: 1},
		{arg: "v3", pre: true, want: "3.0.0-rc.1"},
		{arg: "v4", want: "4.0.0"},
		{arg: "v5", noMatch: true},
		{arg: "v1.9", noMatch: true}, // "1.9.0" lacks the v: not a tag
		{arg: "v1.0.0\r", want: "1.0.0"},
		{arg: "", badInput: true},
		{arg: "v", badInput: true},
		{arg: "vx", badInput: true},
		{arg: "v01", badInput: true},
		{arg: "v1.", badInput: true},
		{arg: "v1.0-rc.1", badInput: true},
		{arg: "v1.0.0.0", badInput: true},
		{arg: "--pre", badInput: true},
		{arg: "vv1", badInput: true},
	}
	for _, tt := range tests {
		got, err := Pick(tt.arg, tags, tt.pre)
		var nm *NoMatch
		switch {
		case tt.badInput:
			if err == nil || errors.As(err, &nm) {
				t.Errorf("Pick(%q, pre=%v) = %v, %v; want a malformed-argument refusal", tt.arg, tt.pre, got, err)
			}
		case tt.noMatch:
			if !errors.As(err, &nm) || nm.Skipped != tt.skipped {
				t.Errorf("Pick(%q, pre=%v) = %v, %v; want no match, %d skipped", tt.arg, tt.pre, got, err, tt.skipped)
			}
		default:
			if err != nil || got.String() != tt.want {
				t.Errorf("Pick(%q, pre=%v) = %v, %v; want %s", tt.arg, tt.pre, got, err, tt.want)
			}
		}
	}
	if _, err := Pick("v1", nil, true); err == nil {
		t.Error("no tags at all is no match")
	}
	if err := (&NoMatch{Want: "v1.1", Skipped: 2}).Error(); err != "no tag matches v1.1 (2 pre-release tag(s) skipped — --pre takes them)" {
		t.Errorf("NoMatch reads %q", err)
	}
}
