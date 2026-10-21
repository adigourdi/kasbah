package remote

import (
	"errors"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

func TestInfoRoundTrip(t *testing.T) {
	in := Self("0.1.0-dev.142.1760790000")
	if want := "build=0.1.0-dev.142.1760790000"; in.Line() != want {
		t.Errorf("Line() = %q, want %q", in.Line(), want)
	}
	got, err := ParseInfo(in.Line() + "\r\n")
	if err != nil || got != in {
		t.Errorf("ParseInfo(Line()) = %+v, %v", got, err)
	}
}

func TestParseInfo(t *testing.T) {
	for _, line := range []string{
		"build=2.0.0",
		"min_protocol=2 future=yes build=2.0.0 protocol=3 junk",
		"build=2.0.0 protocol=x",
	} {
		got, err := ParseInfo(line)
		if err != nil || got != (Info{Build: "2.0.0"}) {
			t.Errorf("ParseInfo(%q) = %+v, %v; want build 2.0.0 and unknown keys ignored", line, got, err)
		}
	}
	for _, bad := range []string{"", "kasbah 0.1.0", "protocol=1 min_protocol=1", "build="} {
		if _, err := ParseInfo(bad); err == nil {
			t.Errorf("ParseInfo(%q) accepted it", bad)
		}
	}
}

func TestDecide(t *testing.T) {
	const ours = "0.1.0-dev.142.1760790000"
	info := func(b string) *Info { return &Info{Build: b} }
	tests := []struct {
		name   string
		srv    *Info
		want   Action
		refuse bool
		// newer: the refusal is a *Newer naming the server's build as wanted.
		newer bool
	}{
		{"absent", nil, Ship, false, false},
		{"older count", info("0.1.0-dev.141.1760799999"), Ship, false, false},
		{"older build of the same count", info("0.1.0-dev.142.1760789999"), Ship, false, false},
		{"pre-D1 clean stamp of the same count", info("0.1.0-dev.142"), Ship, false, false},
		{"older major", info("0.0.0-0"), Ship, false, false},
		{"unversioned", info("devel"), 0, true, false},
		{"same", info(ours), Keep, false, false},
		{"same but different metadata", info(ours + "+x"), Keep, false, false},
		{"newer build", info("0.1.0-dev.142.1760790001"), 0, true, true},
		{"newer release of our major", info("0.9.0"), 0, true, true},
		{"newer major", info("1.0.0"), 0, true, false},
		{"newer major pre-release", info("1.0.0-dev.1.1"), 0, true, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Decide(Self(ours), tt.srv)
			if tt.refuse {
				var e *cli.Error
				if err == nil {
					t.Fatalf("got %v, want a refusal", got)
				}
				if !strings.Contains(err.Error(), tt.srv.Build) || !strings.Contains(err.Error(), ours) {
					t.Errorf("the refusal does not name both versions: %v", err)
				}
				if !errors.As(err, &e) || e.Code != cli.ExitFailure {
					t.Errorf("the refusal is not exit 1: %#v", err)
				}
				var n *Newer
				if errors.As(err, &n) != tt.newer {
					t.Errorf("a *Newer refusal: %v, want %v (%v)", !tt.newer, tt.newer, err)
				}
				if tt.newer && (n.Server != tt.srv.Build || n.Ours != ours) {
					t.Errorf("Newer = %+v", n)
				}
				return
			}
			if err != nil || got != tt.want {
				t.Errorf("got %v, %v; want %v", got, err, tt.want)
			}
		})
	}
	// A release workstation against what pre-release builds and later releases left.
	for _, tt := range []struct {
		srv    string
		want   Action
		refuse bool
	}{
		{"0.1.0-dev.66.1792355995", Ship, false},
		{"1.0.0-dev.300.1792355995", Ship, false},
		{"1.0.0", Keep, false},
		{"1.2.0", 0, true},
		{"2.0.0", 0, true},
	} {
		got, err := Decide(Self("1.0.0"), info(tt.srv))
		if (err != nil) != tt.refuse || got != tt.want {
			t.Errorf("1.0.0 against %s: got %v, %v", tt.srv, got, err)
		}
	}
	for _, bad := range []string{"", "0.1.0-dev"[:3]} {
		if _, err := Decide(Self(bad), nil); err == nil {
			t.Errorf("an unorderable workstation build %q was allowed to ship", bad)
		}
	}
}
