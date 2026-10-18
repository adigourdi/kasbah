package remote

import (
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

func TestInfoRoundTrip(t *testing.T) {
	in := Self("0.1.0-dev.142.1760790000")
	if want := "build=0.1.0-dev.142.1760790000 protocol=1 min_protocol=1"; in.Line() != want {
		t.Errorf("Line() = %q, want %q", in.Line(), want)
	}
	got, err := ParseInfo(in.Line() + "\r\n")
	if err != nil || got != in {
		t.Errorf("ParseInfo(Line()) = %+v, %v", got, err)
	}
}

func TestParseInfo(t *testing.T) {
	got, err := ParseInfo("min_protocol=2 future=yes build=2.0.0 protocol=3 junk")
	if err != nil || got != (Info{Build: "2.0.0", Protocol: 3, MinProtocol: 2}) {
		t.Errorf("unknown keys and order: got %+v, %v", got, err)
	}
	for _, bad := range []string{
		"", "kasbah 0.1.0", "protocol=1 min_protocol=1", "build=1.0.0",
		"build=1.0.0 protocol=x min_protocol=1", "build=1.0.0 protocol=0 min_protocol=0",
		"build=1.0.0 protocol=1 min_protocol=2",
	} {
		if _, err := ParseInfo(bad); err == nil {
			t.Errorf("ParseInfo(%q) accepted it", bad)
		}
	}
}

func TestNegotiate(t *testing.T) {
	tests := []struct {
		name        string
		ours        int
		srvMin, srv int
		ok          bool
	}{
		{"same", 1, 1, 1, true},
		{"server serves a range", 2, 1, 3, true},
		{"server's oldest", 1, 1, 3, true},
		{"server dropped ours", 1, 2, 3, false},
		{"server older than ours", 3, 1, 2, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ours := Info{Build: "1.0.0", Protocol: tt.ours, MinProtocol: 1}
			srv := Info{Build: "1.5.0", Protocol: tt.srv, MinProtocol: tt.srvMin}
			p, err := Negotiate(ours, srv)
			if tt.ok && (err != nil || p != tt.ours) {
				t.Errorf("got %d, %v; want protocol %d", p, err, tt.ours)
			}
			if !tt.ok {
				if err == nil {
					t.Fatalf("negotiated %d, want a refusal", p)
				}
				if !strings.Contains(err.Error(), "1.5.0") || !strings.Contains(err.Error(), "1.0.0") {
					t.Errorf("the refusal does not name both builds: %v", err)
				}
			}
		})
	}
}

func TestDecide(t *testing.T) {
	const ours = "0.1.0-dev.142.1760790000"
	info := func(b string) *Info { return &Info{Build: b, Protocol: 1, MinProtocol: 1} }
	tests := []struct {
		name   string
		srv    *Info
		want   Action
		refuse bool
	}{
		{"absent", nil, Ship, false},
		{"older count", info("0.1.0-dev.141.1760799999"), Ship, false},
		{"older build of the same count", info("0.1.0-dev.142.1760789999"), Ship, false},
		{"pre-D1 clean stamp of the same count", info("0.1.0-dev.142"), Ship, false},
		{"older major", info("0.0.0-0"), Ship, false},
		{"unversioned", info("devel"), 0, true},
		{"same", info(ours), Keep, false},
		{"same but different metadata", info(ours + "+x"), Keep, false},
		{"newer build", info("0.1.0-dev.142.1760790001"), Keep, false},
		{"newer release of our major", info("0.9.0"), Keep, false},
		{"newer major", info("1.0.0"), 0, true},
		{"newer major pre-release", info("1.0.0-dev.1.1"), 0, true},
		{"newer, no protocol for us", &Info{Build: "0.9.0", Protocol: 3, MinProtocol: 2}, 0, true},
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
				if e, _ = err.(*cli.Error); e == nil || e.Code != cli.ExitFailure {
					t.Errorf("the refusal is not exit 1: %#v", err)
				}
				return
			}
			if err != nil || got != tt.want {
				t.Errorf("got %v, %v; want %v", got, err, tt.want)
			}
		})
	}
	for _, bad := range []string{"", "0.1.0-dev"[:3]} {
		if _, err := Decide(Self(bad), nil); err == nil {
			t.Errorf("an unorderable workstation build %q was allowed to ship", bad)
		}
	}
}
