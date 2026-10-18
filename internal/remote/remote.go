// Package remote is the workstation↔server protocol: what `kasbah remote …`
// answers on a server, and what the workstation accepts from it.
//
// `kasbah remote version` is the protocol's fixed point and never changes
// shape across majors: one line of space-separated key=value pairs, at least
// build=, protocol= and min_protocol=. Readers ignore keys they do not know.
// Every other `remote` subcommand is versioned by Protocol.
package remote

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/version"
)

// Protocol is the protocol this binary speaks as a workstation, and the newest
// it serves as a server. MinProtocol is the oldest it still serves: raising it
// is a major change, so a server binary serves every older workstation of its
// own major.
const (
	Protocol    = 1
	MinProtocol = 1
)

// Info is what `kasbah remote version` reports.
type Info struct {
	Build       string
	Protocol    int
	MinProtocol int
}

// Line is Info as `remote version` prints it.
func (i Info) Line() string {
	return fmt.Sprintf("build=%s protocol=%d min_protocol=%d", i.Build, i.Protocol, i.MinProtocol)
}

// Self is this binary's own Info.
func Self(build string) Info {
	return Info{Build: build, Protocol: Protocol, MinProtocol: MinProtocol}
}

// ParseInfo reads a `remote version` line.
func ParseInfo(line string) (Info, error) {
	line = strings.TrimSpace(strings.ReplaceAll(line, "\r", ""))
	var i Info
	var haveP, haveMin bool
	for _, f := range strings.Fields(line) {
		k, v, ok := strings.Cut(f, "=")
		if !ok {
			continue
		}
		switch k {
		case "build":
			i.Build = v
		case "protocol", "min_protocol":
			n, err := strconv.Atoi(v)
			if err != nil || n < 1 {
				return Info{}, fmt.Errorf("%s=%q is not a protocol number", k, v)
			}
			if k == "protocol" {
				i.Protocol, haveP = n, true
			} else {
				i.MinProtocol, haveMin = n, true
			}
		}
	}
	switch {
	case i.Build == "":
		return Info{}, fmt.Errorf("no build= in %q", line)
	case !haveP || !haveMin:
		return Info{}, fmt.Errorf("no protocol= or min_protocol= in %q", line)
	case i.MinProtocol > i.Protocol:
		return Info{}, fmt.Errorf("min_protocol %d is above protocol %d in %q", i.MinProtocol, i.Protocol, line)
	}
	return i, nil
}

// Negotiate is the protocol a workstation speaking ours uses with a server
// reporting srv, or the refusal naming both builds.
func Negotiate(ours, srv Info) (int, error) {
	if ours.Protocol < srv.MinProtocol || ours.Protocol > srv.Protocol {
		return 0, cli.Fail("the kasbah on the server (%s) speaks protocol %d–%d, and this kasbah (%s) speaks %d",
			srv.Build, srv.MinProtocol, srv.Protocol, ours.Build, ours.Protocol).Cont(
			"upgrade kasbah on this workstation to one of the server's major")
	}
	return ours.Protocol, nil
}

// Action is what to do with the server's binary.
type Action int

const (
	// Ship: absent, not runnable, or older.
	Ship Action = iota
	// Keep: the same build or a newer one of our major.
	Keep
)

// Decide is the newer-wins rule; srv nil means nothing to keep (absent or not
// runnable). Refusals: a newer major on the server, a server build that is not
// a version, a workstation build that cannot be ordered.
func Decide(ours Info, srv *Info) (Action, error) {
	ov, err := version.Parse(ours.Build)
	if err != nil {
		return 0, cli.Fail("this kasbah's build stamp is '%s', which is not a version — it cannot be ordered against the server's binary", ours.Build).Cont(
			"build it with `docker compose run --rm build`, which stamps it")
	}
	if srv == nil {
		return Ship, nil
	}
	sv, err := version.Parse(srv.Build)
	if err != nil {
		return 0, cli.Fail("the kasbah on the server reports build '%s', which is not a version — this kasbah (%s) will not replace what it cannot order", srv.Build, ours.Build)
	}
	if sv.Major > ov.Major {
		return 0, cli.Fail("the server runs kasbah %s, a newer major than this kasbah %s", srv.Build, ours.Build).Cont(
			"a newer major on the server speaks a protocol this binary does not know",
			"upgrade kasbah on this workstation, or point at a server this version manages")
	}
	if version.Compare(sv, ov) < 0 {
		return Ship, nil
	}
	if _, err := Negotiate(ours, *srv); err != nil {
		return 0, err
	}
	return Keep, nil
}
