// Package remote is the workstation↔server protocol: what `kasbah remote …`
// answers on a server, and what the workstation accepts from it.
//
// `kasbah remote version` is the protocol's fixed point and never changes
// shape across majors: one line of space-separated key=value pairs, build=
// among them. Readers ignore keys they do not know. Both ends run the same
// build (Decide), so every other `remote` subcommand is versioned by the build.
package remote

import (
	"fmt"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/version"
)

// Info is what `kasbah remote version` reports.
type Info struct {
	Build string
}

// Line is Info as `remote version` prints it.
func (i Info) Line() string {
	return "build=" + i.Build
}

// Self is this binary's own Info.
func Self(build string) Info {
	return Info{Build: build}
}

// ParseInfo reads a `remote version` line.
func ParseInfo(line string) (Info, error) {
	line = strings.TrimSpace(strings.ReplaceAll(line, "\r", ""))
	var i Info
	for _, f := range strings.Fields(line) {
		if k, v, ok := strings.Cut(f, "="); ok && k == "build" {
			i.Build = v
		}
	}
	if i.Build == "" {
		return Info{}, fmt.Errorf("no build= in %q", line)
	}
	return i, nil
}

// Action is what to do with the server's binary.
type Action int

const (
	// Ship: absent, not runnable, or older.
	Ship Action = iota
	// Keep: the same build.
	Keep
)

// Newer is the refusal of a server build newer than ours within our major:
// the build the workstation must run instead is Server.
type Newer struct {
	Server, Ours string
	err          *cli.Error
}

func (n *Newer) Error() string { return n.err.Error() }
func (n *Newer) Unwrap() error { return n.err }

// Decide is the same-build rule; srv nil means nothing to keep (absent or not
// runnable). Refusals: a newer build on the server (*Newer within our major),
// a server build that is not a version, a workstation build that cannot be
// ordered.
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
	switch {
	case version.Compare(sv, ov) == 0:
		return Keep, nil
	case Replaces(ov, sv):
		return Ship, nil
	}
	return 0, &Newer{Server: srv.Build, Ours: ours.Build, err: cli.Fail(
		"the server runs kasbah %s, newer than this kasbah %s — both ends run the server's build", srv.Build, ours.Build)}
}

// Replaces is whether build a goes over build b on a server: a is the higher,
// or a is a release and b a pre-release of the same major whatever their
// order — a dev build some checkout left on the server never locks the
// line's release out.
func Replaces(a, b version.Version) bool {
	if version.Compare(a, b) > 0 {
		return true
	}
	return a.Major == b.Major && len(a.Pre) == 0 && len(b.Pre) > 0
}
