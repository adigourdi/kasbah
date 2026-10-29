package check

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
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
	services := keysOf(opt(x.root, "services"))

	top, end, ci := t.locateTop("services"), -1, 0
	if top >= 0 {
		end = t.blockEnd(top)
		ci, _ = t.childIndent(top)
	}
	anyHN, anyPN := false, false
	defaultHN := x.at("networks", "default", "name") == "kasbah-net"
	routed := x.c.routedHosts()

	for _, svc := range services {
		if top < 0 {
			x.leftf("compose: cannot find the top-level services: key in the file's text — --fix edits block mappings, not a flow-style document")
			break
		}
		idx := t.locateChild(svc, top, end, ci)
		if idx < 0 {
			x.leftf("compose: cannot find service '%s' in the file's text — left untouched", svc)
			continue
		}
		if raw := t.rawValue(idx); raw != "" {
			x.leftf("compose: service '%s' is written inline (%s) — --fix edits block mappings only", svc, raw)
			continue
		}
		s := svcBlock{name: svc, idx: idx, end: t.blockEnd(idx)}
		s.ci, x.svcStep = t.childIndent(idx)
		s.at = s.end
		if s.at < 0 {
			s.at = idx
		}
		s.pre = spaces(s.ci)

		x.c01(s)
		x.c08(s)

		nets := opt(x.root, "services", svc, "networks")
		hn := joinsNet(nets, "kasbah-net") || (defaultHN && !x.has("networks", "services", svc))
		pn := joinsNet(nets, projectNet)
		anyHN, anyPN = anyHN || hn, anyPN || pn
		if x.c.routes(svc, routed) && !hn && !pn {
			if x.c03(s) {
				anyPN = true
			}
		}

		x.r01r02(s)
		x.c02(s)
		x.r03(s)
	}
	made := x.c04Project(anyPN)
	x.c04(anyHN, defaultHN, made)
	x.c05()
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
		line, cr := t.lines[n], ""
		if strings.HasSuffix(line, "\r") {
			line, cr = line[:len(line)-1], "\r"
		}
		m := reFlowSeq.FindStringSubmatch(line)
		if m == nil {
			x.leftf("C03 %s — its networks: list spans more than one line; add kasbah by hand", s.name)
			return false
		}
		sep := ", "
		if reBlank.MatchString(m[2]) {
			sep = ""
		}
		t.rep[n] = m[1] + m[2] + sep + projectNet + m[3] + cr
		t.hasRep[n] = true
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
// and nothing does; true when that created the top-level networks:.
func (x *fixer) c04Project(anyPN bool) bool {
	t := x.t
	if !anyPN || x.has(projectNet, "networks") {
		return false
	}
	top := t.locateTop("networks")
	if top < 0 {
		n := len(t.lines)
		if n == 0 {
			x.leftf("C04 — compose.prod.yml is empty")
			return false
		}
		step := 2
		if i := t.locateTop("services"); i >= 0 {
			_, step = t.childIndent(i)
		}
		t.insertAfter(n-1, "\nnetworks:\n"+spaces(step)+projectNet+": {}")
		x.set(obj(), "networks", projectNet)
		x.planf("C04 — add a top-level networks: with the project's kasbah: {}")
		return true
	}
	if t.inline(top) {
		x.leftf("C04 — the top-level networks: is written inline; declare kasbah: {} by hand")
		return false
	}
	at := t.blockEnd(top)
	if at < 0 {
		at = top
	}
	tci, _ := t.childIndent(top)
	t.insertAfter(at, spaces(tci)+projectNet+": {}")
	x.set(obj(), "networks", projectNet)
	x.planf("C04 — declare the project's kasbah: {} network")
	return false
}

// c04: kasbah-net is external — asked only when something is on it, and never
// under the default-alias shape C07 fails, which external: true would entrench.
func (x *fixer) c04(anyOn, defaultHN, made bool) {
	t := x.t
	if !anyOn {
		return
	}
	if defaultHN {
		if opt(x.root, "networks", "default", "external") == true {
			return
		}
		x.leftf("C04 — the default network aliases kasbah-net (C07). Making it external: true would entrench that shape; join kasbah-net per routed service instead")
		return
	}
	ext := opt(x.root, "networks", "kasbah-net", "external")
	if ext == true {
		return
	}
	top := t.locateTop("networks")
	if top < 0 && made {
		x.leftf("C04 — declare kasbah-net external: true by hand, beside the kasbah network this run adds")
		return
	}
	if top < 0 {
		n := len(t.lines)
		if n == 0 {
			x.leftf("C04 — compose.prod.yml is empty")
			return
		}
		// Indented by the step services: uses: a 4-space file gains no
		// 2-space corner.
		step := 2
		if i := t.locateTop("services"); i >= 0 {
			_, step = t.childIndent(i)
		}
		t.insertAfter(n-1, "\nnetworks:\n"+spaces(step)+"kasbah-net:\n"+spaces(2*step)+"external: true")
		x.set(obj("external", true), "networks", "kasbah-net")
		x.planf("C04 — add a top-level networks: with kasbah-net external: true")
		return
	}
	if t.inline(top) {
		x.leftf("C04 — the top-level networks: is written inline; declare kasbah-net external: true by hand")
		return
	}
	tEnd := t.blockEnd(top)
	tci, tstep := t.childIndent(top)
	tpre := spaces(tci)
	if !x.has("kasbah-net", "networks") {
		at := tEnd
		if at < 0 {
			at = top
		}
		t.insertAfter(at, tpre+"kasbah-net:\n"+spaces(tci+tstep)+"external: true")
		x.set(obj("external", true), "networks", "kasbah-net")
		x.planf("C04 — declare kasbah-net external: true")
		return
	}
	k := t.locateChild("kasbah-net", top, tEnd, tci)
	if k < 0 {
		x.leftf("C04 — cannot find the kasbah-net network in the file's text")
		return
	}
	if raw := t.rawValue(k); raw != "" {
		if raw == "{}" && t.setValue(k, "{external: true}", false) {
			x.set(obj("external", true), "networks", "kasbah-net")
			x.planf("C04 — kasbah-net: {} → {external: true}")
			return
		}
		x.leftf("C04 — kasbah-net is declared inline as %s; set external: true by hand", raw)
		return
	}
	kEnd := t.blockEnd(k)
	kci, _ := t.childIndent(k)
	if x.has("external", "networks", "kasbah-net") {
		i := t.locateChild("external", k, kEnd, kci)
		if i < 0 || !t.setValue(i, "true", false) {
			x.leftf("C04 — kasbah-net's external: is written in a shape --fix cannot rewrite")
			return
		}
		x.mask("networks", "kasbah-net", "external")
		x.planf("C04 — kasbah-net external: %s → true", tree.Compact(ext))
		return
	}
	at := kEnd
	if at < 0 {
		at = k
	}
	t.insertAfter(at, spaces(kci)+"external: true")
	x.set(true, "networks", "kasbah-net", "external")
	x.planf("C04 — add external: true to kasbah-net")
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

// verifyCompose: the same top-level keys but for version: leaving and
// networks: arriving, and the same services. An edit at the wrong indentation
// can parse; it cannot keep both.
func verifyCompose(a, b tree.Value) bool {
	ka, kb := keysOf(a), keysOf(b)
	for _, k := range ka {
		if !inList(kb, k) && k != "version" {
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
	if err != nil {
		c.out.Err("check --fix: cannot read %s — it was left alone", file)
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
			c.out.Err("check --fix: cannot resolve the symlink %s — it was left alone", file)
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
		c.out.Err("check --fix: cannot write beside %s — nothing was changed", file)
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

// readRegular reads a file that is a regular one (through a symlink).
func readRegular(file string) ([]byte, error) {
	if !isFile(file) {
		return nil, os.ErrNotExist
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
	fmt.Fprintln(w, "  and Mail claims are by hand — see docs/compliance.md → `--fix` behavior.")
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
