package check

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/udiff"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// `check --fix` is docs/compliance.md → `--fix` behavior: C01–C05, C08,
// R01–R03 and the kasbah_version backfill, in compose.prod.yml and kasbah.yml
// only, as targeted edits over the existing bytes — never a YAML round trip,
// which would drop the comments compose files carry. Every verdict comes from
// the parsed document; the line scanner only finds where a key is written. A
// staged candidate must parse, keep its keys and re-plan to nothing before it
// is shown.

// fixer plans the edits to one file.
type fixer struct {
	c       *checker
	root    tree.Value
	t       *text
	collect bool
	plan    []string
	left    *[]string
	version string
	// edits is what the plan does to the parsed tree, for the guard.
	edits []edit
	// svcStep is the step between the service being planned and its keys:
	// what a key two levels under it is nested by.
	svcStep int
}

func (x *fixer) planf(format string, a ...any) { x.plan = append(x.plan, fmt.Sprintf(format, a...)) }

func (x *fixer) leftf(format string, a ...any) {
	if x.collect {
		*x.left = append(*x.left, fmt.Sprintf(format, a...))
	}
}

// at is the text at path, "" where the document has none.
func (x *fixer) at(p ...string) string { return scalar(opt(x.root, p...)) }

// has is whether the mapping at path holds key.
func (x *fixer) has(key string, p ...string) bool { return hasKey(opt(x.root, p...), key) }

// --- The compose planner ------------------------------------------------------

func (x *fixer) planCompose() {
	t := x.t
	// Routing is judged on the tree being planned, as check judges it.
	defer func(d yamlDoc) { x.c.compose = d }(x.c.compose)
	x.c.compose = yamlDoc{file: composeFile, root: x.root}
	services := keysOf(opt(x.root, "services"))

	top, end, ci := t.locateTop("services"), -1, 0
	if top >= 0 {
		end = t.blockEnd(top)
		ci, _ = t.childIndent(top)
	}
	anyPN := false
	routed := x.c.routedHosts()
	decl, movable, named, sole := x.sharedDecl()
	_, unread := x.c.fragment()
	if x.c.m.Unrouted && !isFile(traefikFile) {
		unread = ""
	}
	onShared := 0
	// --fix moves every service off kasbah-net or none: one left on it would
	// share no network with those moved to default.
	var stays []string
	if movable && !inList(named, "default") {
		stays = x.sharedStays(services, top, end, ci, routed, unread, named)
	}
	for _, l := range stays {
		x.leftf("%s", l)
	}

	for _, svc := range services {
		if top < 0 {
			x.leftf("compose: cannot find the top-level services: key in the file's text — --fix edits block mappings, not a flow-style document")
			break
		}
		s, why := x.block(svc, top, end, ci)
		if why != "" {
			x.leftf("%s", why)
			continue
		}
		x.c01(s)
		x.c08(s)

		nets := opt(x.root, "services", svc, "networks")
		hn := joinsNet(nets, sharedNet)
		pn := joinsNet(nets, projectNet)
		anyPN = anyPN || pn
		switch {
		case hn:
			onShared++
			isRouted := x.c.routes(svc, routed)
			switch {
			case !movable || inList(named, "default") || len(stays) > 0:
				// sharedDecl or sharedStays said why; with default named
				// kasbah-net, joining default would rejoin it.
			case x.c03Shared(s, pn, isRouted):
				anyPN = anyPN || isRouted
			}
		case x.c.routes(svc, routed) && !pn && !joinsAny(opt(x.root, "services", svc), named):
			if x.c03(s) {
				anyPN = true
			}
		}

		x.r01r02(s)
		x.c02(s)
		x.r03(s)
	}
	x.c04Project(anyPN)
	after, ok := applied(x.root, x.edits)
	keep := decl < 0 || !ok || joinsShared(after)
	switch {
	case keep:
	case sole && !anyPN:
		// A networks: left empty is null, which compose refuses.
		x.t.deleteKey(x.t.locateTop("networks"))
		x.del("networks")
	default:
		x.t.deleteKey(decl)
		x.del("networks", sharedNet)
	}
	switch {
	case keep:
	case onShared == 0:
		x.planf("C04 — drop the top-level %s network no service joins", sharedNet)
	default:
		x.planf("C03 — drop the top-level %s network no service joins any more", sharedNet)
	}
	x.c05()
}

// block is where service svc is written, or why it cannot be edited.
func (x *fixer) block(svc string, top, end, ci int) (svcBlock, string) {
	t := x.t
	idx := t.locateChild(svc, top, end, ci)
	if idx < 0 {
		return svcBlock{}, fmt.Sprintf("compose: cannot find service '%s' in the file's text — left untouched", svc)
	}
	if raw := t.rawValue(idx); raw != "" {
		return svcBlock{}, fmt.Sprintf("compose: service '%s' is written inline (%s) — --fix edits block mappings only", svc, raw)
	}
	s := svcBlock{name: svc, idx: idx, end: t.blockEnd(idx)}
	s.ci, x.svcStep = t.childIndent(idx)
	s.at = s.end
	if s.at < 0 {
		s.at = idx
	}
	s.pre = spaces(s.ci)
	return s, ""
}

// svcBlock is where one service is written: its key line, last content line,
// the indentation of its keys, and the line a new key goes after.
type svcBlock struct {
	name             string
	idx, end, ci, at int
	pre              string
}

func (x *fixer) svcQ(s svcBlock, p ...string) string {
	return x.at(append([]string{"services", s.name}, p...)...)
}

func (x *fixer) svcV(s svcBlock, p ...string) tree.Value {
	return opt(x.root, append([]string{"services", s.name}, p...)...)
}

// c01: every service sets a restart policy.
func (x *fixer) c01(s svcBlock) {
	r := x.svcQ(s, "restart")
	if restartOK.MatchString(r) {
		return
	}
	if x.has("restart", "services", s.name) {
		i := x.t.locateChild("restart", s.idx, s.end, s.ci)
		if i < 0 || !x.t.setValue(i, "unless-stopped", true) {
			x.leftf("C01 %s — its restart: is written in a shape --fix cannot rewrite", s.name)
			return
		}
		x.mask("services", s.name, "restart")
		x.planf("C01 %s — restart: %s → unless-stopped", s.name, orEmpty(r))
		return
	}
	x.t.insertAfter(s.at, s.pre+"restart: unless-stopped")
	x.set("unless-stopped", "services", s.name, "restart")
	x.planf("C01 %s — add restart: unless-stopped", s.name)
}

func orEmpty(s string) string {
	if s == "" {
		return "(empty)"
	}
	return s
}

// c02: json-file with rotation, repaired part by part so a comment inside
// someone's logging: survives.
func (x *fixer) c02(s svcBlock) {
	t := x.t
	drv := x.svcQ(s, "logging", "driver")
	ms := rotationSet(x.svcV(s, "logging", "options", "max-size"))
	mf := rotationSet(x.svcV(s, "logging", "options", "max-file"))
	if drv == "json-file" && ms && mf {
		return
	}
	if !x.has("logging", "services", s.name) {
		p2, p4 := spaces(s.ci+x.svcStep), spaces(s.ci+2*x.svcStep)
		t.insertAfter(s.at, s.pre+"logging:\n"+p2+"driver: json-file\n"+p2+"options:\n"+
			p4+"max-size: \"10m\"\n"+p4+"max-file: \"3\"")
		x.set(obj("driver", "json-file", "options", rotation()), "services", s.name, "logging")
		x.planf("C02 %s — add json-file logging with max-size 10m, max-file 3", s.name)
		return
	}
	l := t.locateChild("logging", s.idx, s.end, s.ci)
	if l < 0 || t.inline(l) {
		x.leftf("C02 %s — its logging: is written in a shape --fix cannot edit; set driver json-file with max-size and max-file by hand", s.name)
		return
	}
	lEnd := t.blockEnd(l)
	lci, lstep := t.childIndent(l)
	lAt := lEnd
	if lAt < 0 {
		lAt = l
	}
	lpre := spaces(lci)

	if drv != "json-file" {
		if x.has("driver", "services", s.name, "logging") {
			i := t.locateChild("driver", l, lEnd, lci)
			if i < 0 || !t.setValue(i, "json-file", true) {
				x.leftf("C02 %s — its logging.driver is written in a shape --fix cannot rewrite", s.name)
				return
			}
			x.mask("services", s.name, "logging", "driver")
			x.planf("C02 %s — logging.driver: %s → json-file", s.name, orEmpty(drv))
		} else {
			t.insertAfter(lAt, lpre+"driver: json-file")
			x.set("json-file", "services", s.name, "logging", "driver")
			x.planf("C02 %s — add logging.driver: json-file", s.name)
		}
	}
	if ms && mf {
		return
	}
	if !x.has("options", "services", s.name, "logging") {
		o2 := spaces(lci + lstep)
		t.insertAfter(lAt, lpre+"options:\n"+o2+"max-size: \"10m\"\n"+o2+"max-file: \"3\"")
		x.set(rotation(), "services", s.name, "logging", "options")
		x.planf("C02 %s — add logging.options max-size 10m, max-file 3", s.name)
		return
	}
	o := t.locateChild("options", l, lEnd, lci)
	if o < 0 || t.inline(o) {
		x.leftf("C02 %s — its logging.options is written in a shape --fix cannot edit; add max-size and max-file by hand", s.name)
		return
	}
	oEnd := t.blockEnd(o)
	oci, _ := t.childIndent(o)
	oAt := oEnd
	if oAt < 0 {
		oAt = o
	}
	opre := spaces(oci)
	for _, k := range []string{"max-size", "max-file"} {
		v, nv := ms, "10m"
		if k == "max-file" {
			v, nv = mf, "3"
		}
		if v {
			continue
		}
		if x.has(k, "services", s.name, "logging", "options") {
			i := t.locateChild(k, o, oEnd, oci)
			if i < 0 || !t.setValue(i, nv, true) {
				x.leftf("C02 %s — its logging.options.%s is written in a shape --fix cannot rewrite", s.name, k)
				continue
			}
			x.mask("services", s.name, "logging", "options", k)
			x.planf("C02 %s — logging.options.%s → %s", s.name, k, nv)
		} else {
			t.insertAfter(oAt, opre+k+": \""+nv+"\"")
			x.set(nv, "services", s.name, "logging", "options", k)
			x.planf("C02 %s — add logging.options.%s: \"%s\"", s.name, k, nv)
		}
	}
}

// c03: a routed service on neither network joins the project's kasbah one,
// and only ever gains it: a service on compose's implicit default keeps it,
// spelled out. True when an edit was planned.
func (x *fixer) c03(s svcBlock) bool {
	t := x.t
	p2 := spaces(s.ci + x.svcStep)
	if !x.has("networks", "services", s.name) {
		t.insertAfter(s.at, s.pre+"networks:\n"+p2+"- default\n"+p2+"- "+projectNet)
		x.app("default", "services", s.name, "networks")
		x.app(projectNet, "services", s.name, "networks")
		x.planf("C03 %s — add networks: [default, kasbah] (default spelled out so the service keeps the network it had implicitly)", s.name)
		return true
	}
	n := t.locateChild("networks", s.idx, s.end, s.ci)
	if n < 0 {
		x.leftf("C03 %s — cannot find its networks: in the file's text", s.name)
		return false
	}
	if raw := t.rawValue(n); raw != "" {
		// A flow sequence gets one more member; a flow mapping's members carry
		// options this would have to invent.
		if len(raw) < 2 || raw[0] != '[' || raw[len(raw)-1] != ']' {
			x.leftf("C03 %s — its networks: is written inline as %s; add kasbah by hand", s.name, raw)
			return false
		}
		if !t.appendFlow(n, projectNet) {
			x.leftf("C03 %s — its networks: list spans more than one line; add kasbah by hand", s.name)
			return false
		}
		x.app(projectNet, "services", s.name, "networks")
		x.planf("C03 %s — add kasbah to its networks list", s.name)
		return true
	}
	nEnd := t.blockEnd(n)
	nci, _ := t.childIndent(n)
	if nEnd < 0 {
		t.insertAfter(n, p2+"- default\n"+p2+"- "+projectNet)
		x.app("default", "services", s.name, "networks")
		x.app(projectNet, "services", s.name, "networks")
		x.planf("C03 %s — fill its empty networks: with default and kasbah", s.name)
		return true
	}
	npre := spaces(nci)
	if _, isMap := x.svcV(s, "networks").(*tree.Map); isMap {
		t.insertAfter(nEnd, npre+projectNet+":")
		x.set(nil, "services", s.name, "networks", projectNet)
		x.planf("C03 %s — add kasbah to its networks mapping", s.name)
	} else {
		t.insertAfter(nEnd, npre+"- "+projectNet)
		x.app(projectNet, "services", s.name, "networks")
		x.planf("C03 %s — add kasbah to its networks list", s.name)
	}
	return true
}

// c04Project declares the project's kasbah network where a service joins it
// and nothing does.
func (x *fixer) c04Project(anyPN bool) {
	t := x.t
	if !anyPN || x.has(projectNet, "networks") {
		return
	}
	top := t.locateTop("networks")
	if top < 0 {
		n := len(t.lines)
		if n == 0 {
			x.leftf("C04 — compose.prod.yml is empty")
			return
		}
		step := 2
		if i := t.locateTop("services"); i >= 0 {
			_, step = t.childIndent(i)
		}
		t.insertAfter(n-1, "\nnetworks:\n"+spaces(step)+projectNet+": {}")
		x.set(obj(), "networks", projectNet)
		x.planf("C04 — add a top-level networks: with the project's kasbah: {}")
		return
	}
	if t.inline(top) {
		x.leftf("C04 — the top-level networks: is written inline; declare kasbah: {} by hand")
		return
	}
	at := t.blockEnd(top)
	if at < 0 {
		at = top
	}
	tci, _ := t.childIndent(top)
	t.insertAfter(at, spaces(tci)+projectNet+": {}")
	x.set(obj(), "networks", projectNet)
	x.planf("C04 — declare the project's kasbah: {} network")
}

// sharedNet is the network every project once shared, which Traefik no longer
// routes over; C03 moves a service on it to the project's kasbah network.
const sharedNet = "kasbah-net"

// sharedDecl is the line declaring kasbah-net under the top-level networks:,
// -1 for none, and whether services can be moved off it: not when that
// declaration cannot be found in the file's text. named is the other keys of
// a network named kasbah-net, left as they are, said so; sole that kasbah-net
// is the only network declared.
func (x *fixer) sharedDecl() (decl int, movable bool, named []string, sole bool) {
	t := x.t
	nets, _ := opt(x.root, "networks").(*tree.Map)
	for _, k := range keysOf(nets) {
		if k != sharedNet && realNet(k, opt(nets, k)) == sharedNet {
			named = append(named, k)
			if k == "default" {
				x.leftf("C03 — the network 'default' is named %s; drop its name: and external: by hand, so compose names it %s_default, and move only the routed services to kasbah", sharedNet, orProject(x.c.m.Name))
			} else {
				x.leftf("C03 — the network '%s' is named %s; take its services off it by hand, onto the project's default network, the routed ones onto kasbah too, and drop it", k, sharedNet)
			}
		}
	}
	joined := false
	for _, svc := range keysOf(opt(x.root, "services")) {
		joined = joined || joinsNet(opt(x.root, "services", svc, "networks"), sharedNet)
	}
	if !x.has(sharedNet, "networks") {
		return -1, true, named, false
	}
	top := t.locateTop("networks")
	if top < 0 || t.inline(top) {
		if joined {
			x.leftf("C03 — the top-level networks: is written inline; move the services on %s to kasbah by hand", sharedNet)
		} else {
			x.leftf("C04 — the top-level networks: is written inline; drop %s, which no service joins, by hand", sharedNet)
		}
		return -1, false, named, false
	}
	tci, _ := t.childIndent(top)
	k := t.locateChild(sharedNet, top, t.blockEnd(top), tci)
	if k < 0 {
		x.leftf("C03 — cannot find the %s network in the file's text; move its services to kasbah by hand", sharedNet)
		return -1, false, named, false
	}
	return k, true, named, len(keysOf(nets)) == 1
}

// joinsShared is whether a service in root joins kasbah-net: by that key, by
// another key named it, or on a default named it.
func joinsShared(root tree.Value) bool {
	nets, _ := opt(root, "networks").(*tree.Map)
	keys := []string{sharedNet}
	for _, k := range keysOf(nets) {
		if k != sharedNet && realNet(k, opt(nets, k)) == sharedNet {
			keys = append(keys, k)
		}
	}
	for _, svc := range keysOf(opt(root, "services")) {
		if joinsAny(opt(root, "services", svc), keys) {
			return true
		}
	}
	return false
}

func orProject(name string) string {
	if name == "" {
		return "<project>"
	}
	return name
}

// sharedStays is the left lines for the services --fix cannot take off
// kasbah-net, by its key or another naming it, and why; nil when it can take
// every one. Each c03Shared it tries is planned on a copy and thrown away.
func (x *fixer) sharedStays(services []string, top, end, ci int, routed []string, unread string, named []string) []string {
	if top < 0 {
		return nil
	}
	var why []string
	p := *x
	p.t, p.plan, p.edits, p.collect, p.left = x.t.clone(), nil, nil, true, &why
	var left []string
	movers := 0
	for _, svc := range services {
		v := opt(x.root, "services", svc)
		nets := opt(v, "networks")
		hn := joinsNet(nets, sharedNet)
		if !hn && !joinsAny(v, named) {
			continue
		}
		isRouted := x.c.routes(svc, routed)
		s, bad := p.block(svc, top, end, ci)
		switch {
		case !hn:
			for _, k := range named {
				if joinsNet(nets, k) {
					p.stay(svc, isRouted, "it joins '"+k+"', which is named "+sharedNet)
					break
				}
			}
		case bad != "":
			p.stay(svc, isRouted, "--fix cannot edit it as written")
		case !isRouted && unread != "":
			p.leftf("C03 %s — %s, so whether it is routed is unknown; take it off %s by hand, onto the project's default network, and onto kasbah if it is routed", svc, unread, sharedNet)
		case !p.c03Shared(s, joinsNet(nets, projectNet), isRouted):
		default:
			movers++
			continue
		}
		left = append(left, svc)
	}
	if len(left) > 0 && movers > 0 {
		why = append(why, fmt.Sprintf("C03 — --fix takes no service off %s while it must leave %s on it: one left there would share no network with those moved", sharedNet, strings.Join(left, ", ")))
	}
	return why
}

// stay says why svc stays on kasbah-net, and how to take it off by hand: onto
// the project's default network too, which every service --fix moves shares.
func (x *fixer) stay(svc string, routed bool, why string) {
	rule, onto := "C04", "the project's default network"
	if routed {
		rule, onto = "C03", "kasbah and the project's default network"
	}
	x.leftf("%s %s — %s; take it off %s by hand, onto %s", rule, svc, why, sharedNet, onto)
}

// reSharedEntry is a block list's `- kasbah-net`, bare or quoted, with what
// precedes and follows it.
var reSharedEntry = regexp.MustCompile(`^(` + envtpl.Space + `*-` + envtpl.Space + `+)(?:kasbah-net|"kasbah-net"|'kasbah-net')(` + envtpl.Space + `*(?:#.*)?)$`)

// c03Shared takes a service off kasbah-net. A routed one moves to kasbah: the
// entry's key becomes kasbah, its options kept, or its aliases join the kasbah
// entry it has already. An unrouted one gets default in its place: Traefik has
// no business reaching it. Either way it ends on the project's default network,
// which every service taken off kasbah-net shares; an unrouted one left on
// default alone loses its networks:. True when an edit was planned.
func (x *fixer) c03Shared(s svcBlock, pn, routed bool) bool {
	t := x.t
	nets := x.svcV(s, "networks")
	n := t.locateChild("networks", s.idx, s.end, s.ci)
	rule := "C03"
	if !routed {
		rule = "C04"
	}
	if n < 0 {
		x.stay(s.name, routed, "cannot find its networks: in the file's text")
		return false
	}
	move := routed && !pn
	what := "move it from " + sharedNet + " to kasbah"
	switch {
	case pn:
		what = "drop " + sharedNet + ", it is on kasbah already"
	case !routed:
		what = "drop " + sharedNet + ", which nothing routes to it over"
	}
	var merge []string
	if m, ok := nets.(*tree.Map); ok && pn && routed {
		if v, _ := m.Get(sharedNet); !emptyEntry(v) {
			if merge, ok = x.sharedAliases(s, m, v); !ok {
				return false
			}
		}
	}
	if len(merge) > 0 {
		what += ", its aliases " + strings.Join(merge, " ") + " joining its kasbah entry"
	}
	left := movedNets(nets, move, merge)
	if onlyDefault(left) {
		t.deleteKey(n)
		x.del("services", s.name, "networks")
		x.planf("%s %s — drop its networks: %s, leaving it on the project's default network, over which it keeps reaching its former %s peers", rule, s.name, sharedNet, sharedNet)
		return true
	}
	// repl stands where kasbah-net's entry did, "" for nothing; default joins
	// last where it does not.
	onDefault := joinsNet(nets, "default")
	repl := ""
	switch {
	case move:
		repl = projectNet
	case !onDefault:
		repl = "default"
	}
	tail := move && !onDefault
	if raw := t.rawValue(n); raw != "" {
		if !x.swapFlow(n, repl, tail) {
			x.stay(s.name, routed, "its networks: is written inline as "+raw)
			return false
		}
	} else {
		nEnd := t.blockEnd(n)
		nci, _ := t.childIndent(n)
		if _, isMap := nets.(*tree.Map); isMap {
			k := t.locateChild(sharedNet, n, nEnd, nci)
			if k < 0 {
				x.stay(s.name, routed, "cannot find "+sharedNet+" in its networks: in the file's text")
				return false
			}
			swapped := false
			if len(merge) > 0 {
				var ok bool
				if swapped, ok = x.mergeAliases(s, n, nEnd, nci, merge); !ok {
					return false
				}
			}
			if move || swapped {
				line, _ := strings.CutPrefix(t.lines[k], spaces(nci))
				_, rest, _ := strings.Cut(line, ":")
				t.rep[k], t.hasRep[k] = spaces(nci)+projectNet+":"+rest, true
				if !onDefault {
					t.insertAfter(nEnd, spaces(nci)+"default:")
				}
			} else {
				t.deleteKey(k)
				if repl != "" {
					t.insertAfter(k, spaces(nci)+repl+":")
				}
			}
		} else {
			k := -1
			for i := n + 1; i <= nEnd; i++ {
				if indent(t.lines[i]) == nci && reSharedEntry.MatchString(noCR(t.lines[i])) {
					k = i
					break
				}
			}
			if k < 0 {
				x.stay(s.name, routed, "cannot find "+sharedNet+" in its networks: in the file's text")
				return false
			}
			line, cr := noCR(t.lines[k]), ""
			if len(line) < len(t.lines[k]) {
				cr = "\r"
			}
			m := reSharedEntry.FindStringSubmatch(line)
			if repl == "" {
				t.del[k] = true
			} else {
				t.rep[k], t.hasRep[k] = m[1]+repl+m[2]+cr, true
			}
			if tail {
				t.insertAfter(nEnd, m[1]+"default")
			}
		}
	}
	x.set(left, "services", s.name, "networks")
	x.planf("%s %s — %s; it keeps reaching its former %s peers over the project's default network", rule, s.name, what, sharedNet)
	return true
}

// rePlainAlias is an alias --fix writes bare.
var rePlainAlias = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]*$`)

// sharedAliases is the aliases a routed service's kasbah-net entry v carries
// that its kasbah entry lacks; false, said why, when v sets more than aliases,
// an alias would need quoting, or one is listed twice.
func (x *fixer) sharedAliases(s svcBlock, nets *tree.Map, v tree.Value) ([]string, bool) {
	e, _ := v.(*tree.Map)
	al, isList := opt(e, "aliases").([]tree.Value)
	if e == nil || slices.ContainsFunc(e.Keys(), func(k string) bool { return k != "aliases" }) || !isList && opt(e, "aliases") != nil {
		x.stay(s.name, true, "it is on kasbah already, and its "+sharedNet+" entry sets more than aliases")
		return nil, false
	}
	have := asList(opt(nets, projectNet, "aliases"))
	var out []string
	for i, a := range al {
		str, ok := a.(string)
		if !ok || !rePlainAlias.MatchString(str) {
			x.stay(s.name, true, "it is on kasbah already, and its "+sharedNet+" alias "+tree.Compact(a)+" needs quoting")
			return nil, false
		}
		if slices.Index(al, a) < i {
			// kasbah-net's entry swapped in whole for kasbah's would keep it twice.
			x.leftf("C03 %s — its %s aliases list %s twice; remove the duplicate alias %s from %s's %s entry", s.name, sharedNet, str, str, s.name, sharedNet)
			return nil, false
		}
		if !slices.Contains(have, tree.Value(str)) {
			out = append(out, str)
		}
	}
	return out, true
}

// mergeAliases writes merge into the kasbah entry of the networks: mapping at
// n: kasbah-net's entry takes the place of a kasbah entry that is one empty
// line (swapped), else the aliases join kasbah's. False, said why, for a
// kasbah entry written in a shape a line edit cannot extend.
func (x *fixer) mergeAliases(s svcBlock, n, nEnd, nci int, merge []string) (swapped, ok bool) {
	t := x.t
	if kl := t.locateChild(projectNet, n, nEnd, nci); kl >= 0 {
		raw, kEnd := t.rawValue(kl), t.blockEnd(kl)
		switch {
		case emptyEntry(opt(x.svcV(s, "networks"), projectNet)) && kEnd < 0 && (raw == "" || raw == "{}"):
			t.del[kl] = true
			return true, true
		case raw == "" && kEnd >= 0:
			kci, _ := t.childIndent(kl)
			al := t.locateChild("aliases", kl, kEnd, kci)
			switch {
			case al < 0:
				t.insertAfter(kEnd, spaces(kci)+"aliases: ["+strings.Join(merge, ", ")+"]")
				return false, true
			case t.rawValue(al) != "":
				if t.appendFlow(al, strings.Join(merge, ", ")) {
					return false, true
				}
			case t.blockEnd(al) >= 0:
				aci, _ := t.childIndent(al)
				var lines []string
				for _, a := range merge {
					lines = append(lines, spaces(aci)+"- "+a)
				}
				t.insertAfter(t.blockEnd(al), strings.Join(lines, "\n"))
				return false, true
			}
		}
	}
	x.stay(s.name, true, "it is on kasbah already, and its "+sharedNet+" aliases cannot be added to its kasbah entry as written")
	return false, false
}

// appendFlow adds s to the one-line flow sequence at idx; false for any other
// shape.
func (t *text) appendFlow(idx int, s string) bool {
	raw := t.rawValue(idx)
	line, cr := t.lines[idx], ""
	if strings.HasSuffix(line, "\r") {
		line, cr = line[:len(line)-1], "\r"
	}
	m := reFlowSeq.FindStringSubmatch(line)
	if m == nil || len(raw) < 2 || raw[0] != '[' || raw[len(raw)-1] != ']' {
		return false
	}
	sep := ", "
	if reBlank.MatchString(m[2]) {
		sep = ""
	}
	t.rep[idx], t.hasRep[idx] = m[1]+m[2]+sep+s+m[3]+cr, true
	return true
}

// swapFlow does c03Shared's edit to a one-line flow sequence: kasbah-net's
// entry becomes repl, or goes for "", and default joins last on tail. False
// for any other inline shape.
func (x *fixer) swapFlow(n int, repl string, tail bool) bool {
	t := x.t
	line, cr := t.lines[n], ""
	if strings.HasSuffix(line, "\r") {
		line, cr = line[:len(line)-1], "\r"
	}
	raw := t.rawValue(n)
	m := reFlowSeq.FindStringSubmatch(line)
	if m == nil || len(raw) < 2 || raw[0] != '[' || raw[len(raw)-1] != ']' {
		return false
	}
	parts := strings.Split(m[2], ",")
	for i, p := range parts {
		v := strings.Trim(strings.TrimSpace(p), `"'`)
		if v != sharedNet {
			continue
		}
		if repl == "" {
			parts = slices.Delete(parts, i, i+1)
			if i == 0 && len(parts) > 0 {
				parts[0] = p[:len(p)-len(strings.TrimLeft(p, " \t"))] + strings.TrimLeft(parts[0], " \t")
			}
		} else {
			parts[i] = strings.Replace(p, strings.TrimSpace(p), repl, 1)
		}
		if tail {
			last := parts[len(parts)-1]
			body := strings.TrimRight(last, " \t")
			parts[len(parts)-1] = body + ", default" + last[len(body):]
		}
		t.rep[n], t.hasRep[n] = m[1]+strings.Join(parts, ",")+m[3]+cr, true
		return true
	}
	return false
}

// emptyEntry is whether a service's networks: entry sets nothing: null or {}.
func emptyEntry(v tree.Value) bool {
	m, ok := v.(*tree.Map)
	return v == nil || ok && (m == nil || m.Len() == 0)
}

// onlyDefault is whether a networks: value joins compose's default network
// alone and sets nothing on it, as having no networks: does.
func onlyDefault(v tree.Value) bool {
	switch x := v.(type) {
	case *tree.Map:
		d, _ := x.Get("default")
		return x.Len() == 1 && x.Has("default") && emptyEntry(d)
	case []tree.Value:
		return len(x) == 1 && x[0] == "default"
	}
	return false
}

// movedNets is a service's networks: off kasbah-net, as c03Shared writes it:
// the entry under kasbah where move says so, merge joining kasbah's aliases,
// and default joined, in kasbah-net's place for a list that does not move.
func movedNets(nets tree.Value, move bool, merge []string) tree.Value {
	switch v := nets.(type) {
	case *tree.Map:
		m := v.Clone()
		old, _ := m.Get(sharedNet)
		m.Delete(sharedNet)
		if move {
			m.Set(projectNet, old)
		}
		if len(merge) > 0 {
			kv, _ := m.Get(projectNet)
			k := tree.NewMap()
			if km, _ := kv.(*tree.Map); km != nil {
				k = km.Clone()
			}
			al := slices.Clone(asList(opt(k, "aliases")))
			for _, a := range merge {
				al = append(al, a)
			}
			k.Set("aliases", al)
			m.Set(projectNet, k)
		}
		if !m.Has("default") {
			m.Set("default", nil)
		}
		return m
	case []tree.Value:
		on := listHas(v, "default")
		var out []tree.Value
		for _, e := range v {
			switch {
			case e != sharedNet:
				out = append(out, e)
			case move:
				out = append(out, projectNet)
			case !on:
				out, on = append(out, "default"), true
			}
		}
		if !on {
			out = append(out, "default")
		}
		return out
	}
	return nets
}

// c05: the deprecated top-level version: goes, and nothing around it.
func (x *fixer) c05() {
	v := x.at("version")
	if v == "" {
		return
	}
	i := x.t.locateTop("version")
	if i < 0 {
		x.leftf("C05 — cannot find the top-level version: in the file's text")
		return
	}
	x.t.deleteKey(i)
	x.del("version")
	x.planf("C05 — remove the deprecated top-level version: %s", v)
}

// c08: a built service's image is retagged :current. One naming no image is
// left alone: kasbah will not invent an image name.
func (x *fixer) c08(s svcBlock) {
	if !x.has("build", "services", s.name) {
		return
	}
	img := x.svcQ(s, "image")
	if img == "" {
		x.leftf("C08 %s — builds an image but names no image:, and kasbah will not invent one. Add 'image: <name>:current'", s.name)
		return
	}
	if strings.HasSuffix(img, ":current") {
		return
	}
	if strings.Contains(img, "@") {
		x.leftf("C08 %s — its image: is pinned by digest (%s); retag it <name>:current by hand", s.name, img)
		return
	}
	base := imageBase(img)
	i := x.t.locateChild("image", s.idx, s.end, s.ci)
	if i < 0 || !x.t.setValue(i, base+":current", true) {
		x.leftf("C08 %s — its image: is written in a shape --fix cannot rewrite", s.name)
		return
	}
	x.mask("services", s.name, "image")
	x.planf("C08 %s — image: %s → %s:current", s.name, img, base)
}

// imageBase is the reference without its tag; a colon before the last `/` is
// a registry port, not a tag.
func imageBase(ref string) string {
	last := ref[strings.LastIndex(ref, "/")+1:]
	if strings.Contains(last, ":") {
		return ref[:strings.LastIndex(ref, ":")]
	}
	return ref
}

// r01r02: a missing or malformed limit becomes the KASBAH_* reference; a
// literal is the author's per-service choice and stays, and so does the
// deploy.resources.limits form, which --fix does not edit.
func (x *fixer) r01r02(s svcBlock) {
	for _, k := range limitKeys {
		cur := x.svcQ(s, k.key)
		kind, _, deploy := limitOf(x.svcV(s), k.key, k.deploy, k.ref)
		if kind == "ref" || kind == "literal" {
			continue
		}
		if deploy {
			x.leftf("%s %s — deploy.resources.limits.%s is malformed or differs from %s:; fix it by hand — --fix writes no %s: beside it", k.rule, s.name, k.deploy, k.key, k.key)
			continue
		}
		if x.has(k.key, "services", s.name) {
			i := x.t.locateChild(k.key, s.idx, s.end, s.ci)
			if i < 0 || !x.t.setValue(i, k.ref, true) {
				x.leftf("%s %s — its %s: is written in a shape --fix cannot rewrite", k.rule, s.name, k.key)
				continue
			}
			x.mask("services", s.name, k.key)
			x.planf("%s %s — %s: %s → %s", k.rule, s.name, k.key, orEmpty(cur), k.ref)
		} else {
			x.t.insertAfter(s.at, s.pre+k.key+": "+k.ref)
			x.set(k.ref, "services", s.name, k.key)
			x.planf("%s %s — add %s: %s", k.rule, s.name, k.key, k.ref)
		}
	}
}

// r03: reservations go, and a resources: or deploy: they leave empty with them.
func (x *fixer) r03(s svcBlock) {
	t := x.t
	if x.svcV(s, "mem_reservation") != nil {
		if i := t.locateChild("mem_reservation", s.idx, s.end, s.ci); i < 0 {
			x.leftf("R03 %s — cannot find its mem_reservation: in the file's text", s.name)
		} else {
			t.deleteKey(i)
			x.del("services", s.name, "mem_reservation")
			x.planf("R03 %s — remove mem_reservation", s.name)
		}
	}
	if x.svcV(s, "deploy", "resources", "reservations") == nil {
		return
	}
	d := t.locateChild("deploy", s.idx, s.end, s.ci)
	if d < 0 || t.inline(d) {
		x.leftf("R03 %s — its deploy: is written in a shape --fix cannot edit; remove the reservations by hand", s.name)
		return
	}
	dEnd := t.blockEnd(d)
	dci, _ := t.childIndent(d)
	rs := t.locateChild("resources", d, dEnd, dci)
	if rs < 0 || t.inline(rs) {
		x.leftf("R03 %s — its deploy.resources is written in a shape --fix cannot edit; remove the reservations by hand", s.name)
		return
	}
	rsEnd := t.blockEnd(rs)
	rsci, _ := t.childIndent(rs)
	rv := t.locateChild("reservations", rs, rsEnd, rsci)
	if rv < 0 {
		x.leftf("R03 %s — cannot find deploy.resources.reservations in the file's text", s.name)
		return
	}
	resKeys, depKeys := len(keysOf(x.svcV(s, "deploy", "resources"))), len(keysOf(x.svcV(s, "deploy")))
	target := "deploy.resources.reservations"
	switch {
	case resKeys == 1 && depKeys == 1:
		t.deleteKey(d)
		x.del("services", s.name, "deploy")
		target = "deploy (it held nothing else)"
	case resKeys == 1:
		t.deleteKey(rs)
		x.del("services", s.name, "deploy", "resources")
		target = "deploy.resources (it held nothing else)"
	default:
		t.deleteKey(rv)
		x.del("services", s.name, "deploy", "resources", "reservations")
	}
	x.planf("R03 %s — remove %s", s.name, target)
}

// planManifest backfills kasbah_version when absent, and only then: a version
// already written is the author's statement.
func (x *fixer) planManifest() {
	if x.has("kasbah_version") {
		return
	}
	i := x.t.locateTop("schema")
	if i < 0 {
		x.leftf("kasbah.yml — cannot find the schema: line to write kasbah_version after; add 'kasbah_version: %s' by hand", x.version)
		return
	}
	x.t.insertAfter(i, "kasbah_version: "+x.version)
	x.mask("kasbah_version")
	x.planf("kasbah.yml — add kasbah_version: %s", x.version)
}

// --- Verifying ----------------------------------------------------------------

// verifyCompose: the same top-level keys but for version: leaving, networks:
// arriving or leaving with only kasbah-net in it, and the same services. An
// edit at the wrong indentation can parse; it cannot keep both.
func verifyCompose(a, b tree.Value) bool {
	ka, kb := keysOf(a), keysOf(b)
	for _, k := range ka {
		gone := k == "version" || k == "networks" && slices.Equal(keysOf(opt(a, k)), []string{sharedNet})
		if !inList(kb, k) && !gone {
			return false
		}
	}
	for _, k := range kb {
		if !inList(ka, k) && k != "networks" {
			return false
		}
	}
	return slices.Equal(keysOf(opt(a, "services")), keysOf(opt(b, "services")))
}

// verifyManifest: the same top-level keys, kasbah_version aside.
func verifyManifest(a, b tree.Value) bool {
	strip := func(ks []string) []string {
		return slices.DeleteFunc(ks, func(k string) bool { return k == "kasbah_version" })
	}
	return slices.Equal(strip(keysOf(a)), strip(keysOf(b)))
}

// --- Staging, showing, writing --------------------------------------------------

type fixRun struct {
	c     *checker
	left  []string
	temps []string
}

type staged struct {
	file, target, tmp, plan string
	before, after           []byte
}

// stage plans FILE and writes the candidate beside it, proven to parse, keep
// its keys and settle. nil with nothing to do or when refused (said why).
func (r *fixRun) stage(file string, root tree.Value, planner func(*fixer), verify func(a, b tree.Value) bool, version string) *staged {
	c := r.c
	data, err := readRegular(file)
	if errors.Is(err, errNotRegular) {
		c.out.Err("check --fix: %s is not a regular file — it was left alone", file)
		r.leftf("%s — not a regular file; it was left exactly as it was", file)
		return nil
	}
	if err != nil {
		c.out.Err("check --fix: cannot read %s: %v — it was left alone", file, cli.OSCause(err))
		r.leftf("%s — could not be read; it was left exactly as it was", file)
		return nil
	}
	x := &fixer{c: c, root: root, t: readText(data), collect: true, left: &r.left, version: version}
	planner(x)
	if len(x.plan) == 0 {
		return nil
	}
	var pt strings.Builder
	for _, p := range x.plan {
		pt.WriteString("    " + p + "\n")
	}
	plan := strings.TrimRight(pt.String(), "\n")

	// Beside what the file resolves to, so the rename that commits it is
	// atomic even through a symlink; every way out removes it.
	target := file
	if fi, err := os.Lstat(file); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		if target, err = filepath.EvalSymlinks(file); err != nil {
			c.out.Err("check --fix: cannot resolve the symlink %s: %v — it was left alone", file, cli.OSCause(err))
			r.leftf("%s — its symlink could not be resolved; it was left exactly as it was", file)
			return nil
		}
	}
	tmp := fmt.Sprintf("%s.kasbah-fix.%d", target, os.Getpid())
	os.Remove(tmp)
	r.temps = append(r.temps, tmp)
	out := x.t.render()
	if err := writeNew(tmp, out); err != nil {
		os.Remove(tmp)
		c.out.Err("check --fix: cannot write beside %s: %v — nothing was changed", file, cli.OSCause(err))
		r.leftf("%s — nothing could be written beside it, so it was left exactly as it was", file)
		return nil
	}
	if fi, err := os.Stat(file); err == nil {
		os.Chmod(tmp, fi.Mode()&(os.ModePerm|os.ModeSetuid|os.ModeSetgid|os.ModeSticky))
	}

	newDocs, err := yamlx.Load(out)
	if err != nil {
		os.Remove(tmp)
		c.out.Err("check --fix: the edited %s would not parse as YAML — nothing was written", file)
		r.leftf("%s — the edited file would not have parsed as YAML; it was left exactly as it was", file)
		return nil
	}
	var newRoot tree.Value
	if len(newDocs) == 1 {
		newRoot = newDocs[0]
	}
	if !verify(root, newRoot) {
		os.Remove(tmp)
		c.out.Err("check --fix: the edited %s no longer declares the same keys — nothing was written", file)
		r.leftf("%s — the edited file no longer declared the same keys; it was left exactly as it was", file)
		return nil
	}
	if len(newDocs) != 1 || !guard(root, newRoot, x.edits) {
		os.Remove(tmp)
		c.out.Err("check --fix: the edited %s would change values the fix did not plan to — nothing was written", file)
		r.leftf("%s — the edit would have changed more than the fix planned; it was left exactly as it was", file)
		return nil
	}
	again := &fixer{c: c, root: newRoot, t: readText(out), left: &r.left, version: version}
	planner(again)
	if len(again.plan) != 0 {
		os.Remove(tmp)
		c.out.Err("check --fix: the fix to %s did not settle — a second run would change it again (%s). Nothing was written", file, strings.Join(again.plan, " "))
		r.leftf("%s — the fix did not settle, so a second run would change it again; it was left exactly as it was", file)
		return nil
	}
	return &staged{file: file, target: target, tmp: tmp, plan: plan, before: data, after: out}
}

func (r *fixRun) leftf(format string, a ...any) { r.left = append(r.left, fmt.Sprintf(format, a...)) }

func (r *fixRun) cleanup() {
	for _, t := range r.temps {
		os.Remove(t)
	}
}

var errNotRegular = errors.New("not a regular file")

// readRegular reads a file that is a regular one (through a symlink).
func readRegular(file string) ([]byte, error) {
	if fi, err := os.Stat(file); err != nil {
		return nil, err
	} else if !fi.Mode().IsRegular() {
		return nil, errNotRegular
	}
	return os.ReadFile(file)
}

// writeNew creates file 0600 and writes data to it.
func writeNew(file string, data []byte) error {
	f, err := os.OpenFile(file, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	if err := f.Chmod(0o600); err != nil {
		f.Close()
		return err
	}
	if _, err := f.Write(data); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// fix is the whole of --fix, before the report, so the report describes the
// project as it now is. The diff is a decision: unless --yes, it is asked.
func (c *checker) fix(e Env) error {
	r := &fixRun{c: c}
	pop := atexit.Push(r.cleanup)
	defer func() { r.cleanup(); pop() }()

	var files []*staged
	if isFile(composeFile) {
		if d := c.load(composeFile); d.bad != "" {
			r.leftf("compose.prod.yml %s — --fix will not pattern-match its way through a file it cannot read", d.bad)
		} else if s := r.stage(composeFile, d.root, (*fixer).planCompose, verifyCompose, e.Version); s != nil {
			files = append(files, s)
		}
	}
	if s := r.stage(manifest.File, c.load(manifest.File).root, (*fixer).planManifest, verifyManifest, e.Version); s != nil {
		files = append(files, s)
	}

	w := c.w
	fmt.Fprintln(w, "Fix:")
	if len(files) == 0 && len(r.left) == 0 {
		fmt.Fprintln(w, "  nothing --fix can change")
	}
	for _, s := range files {
		fmt.Fprintf(w, "  %s\n%s\n", s.file, s.plan)
	}
	if len(r.left) > 0 {
		fmt.Fprintln(w, "  Left alone:")
		for _, l := range r.left {
			fmt.Fprintf(w, "    %s\n", l)
		}
	}
	fmt.Fprintln(w, "  --fix applies C01–C05, C08, R01–R03 and the kasbah_version backfill, to")
	fmt.Fprintln(w, "  compose.prod.yml and kasbah.yml only. C07, C09, every Traefik rule, Hooks")
	fmt.Fprintln(w, "  and Mail claims are by hand: `kasbah help <id>` says how, and `kasbah help")
	fmt.Fprintln(w, "  rules` lists them.")
	fmt.Fprintln(w)
	if len(files) == 0 {
		return nil
	}
	for _, s := range files {
		w.Write(udiff.Unified("a/"+s.file, "b/"+s.file, s.before, s.after))
	}
	fmt.Fprintln(w)

	ok, err := e.prompter().Confirm("yes", "Apply these edits?", e.Yes)
	if err != nil {
		return err
	}
	if !ok {
		fmt.Fprintln(w, "  nothing was written")
		fmt.Fprintln(w)
		return nil
	}
	for _, s := range files {
		if c.commit(s) {
			fmt.Fprintf(w, "  wrote %s\n", s.file)
		}
	}
	fmt.Fprintln(w)
	return nil
}

// commit renames the candidate over what the file resolves to, from beside
// it: a reader sees the old file or the new one, never half, and a symlink is
// written through rather than replaced.
func (c *checker) commit(s *staged) bool {
	if err := os.Rename(s.tmp, s.target); err != nil {
		os.Remove(s.tmp)
		fmt.Fprintf(c.out.Stderr, "mv: %v\n", err)
		c.out.Err("check --fix: could not replace %s", s.file)
		return false
	}
	c.cache.Forget(s.file)
	c.cache.Forget(s.target)
	return true
}
