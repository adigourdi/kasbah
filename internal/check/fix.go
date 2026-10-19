package check

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// `check --fix` is docs/compliance.md → `--fix` behavior: C01–C05, C08,
// R01–R03 and the kasbah_version backfill, in compose.prod.yml and kasbah.yml
// only, as targeted edits over the existing bytes — never a YAML round trip,
// which would drop the comments compose files carry. Every verdict comes from
// the parsed documents, asked with jq's semantics; the line
// scanner only finds where a key is written. A staged candidate must parse,
// keep its keys and re-plan to nothing before it is shown.

// fixer plans the edits to one file.
type fixer struct {
	c       *checker
	docs    []jv.Value
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

// yq is `_cf_yq`: the filter's output with errors ignored, `null` as empty.
func (x *fixer) yq(g gen, ok bool) string {
	if !ok {
		return ""
	}
	s := run(x.docs, g).sub()
	if s == "null" {
		s = ""
	}
	return strings.TrimRight(strings.TrimSuffix(s, "\r"), "\n")
}

// at is `_cf_yq` of `.[a][b]… // def`.
func (x *fixer) at(def jv.Value, p ...string) string {
	return x.yq(pathThen(func(v jv.Value) (jv.Value, error) { return jv.Alt(v, def), nil }, p...))
}

// has is `_cf_has`: `PATH | has(KEY)` printing exactly true.
func (x *fixer) has(key string, p ...string) bool {
	g, ok := pathThen(hasKey(key), p...)
	if !ok {
		return false
	}
	return strings.TrimSuffix(run(x.docs, g).or("false"), "\r") == "true"
}

// keyList is `PATH | keys | .[]` (with `// {}` when alt), errors ignored.
func keyList(docs []jv.Value, alt bool, p ...string) string {
	return run(docs, func(d jv.Value, emit func(jv.Value)) error {
		v, err := path(d, p...)
		if err != nil {
			return err
		}
		if alt {
			v = jv.Alt(v, jv.NewMap())
		}
		ks, err := keys(v)
		for _, k := range ks {
			emit(k)
		}
		return err
	}).sub()
}

// --- The compose planner ------------------------------------------------------

func (x *fixer) planCompose() {
	t := x.t
	services := x.yq(func(d jv.Value, emit func(jv.Value)) error {
		s, err := index(d, "services")
		if err != nil {
			return err
		}
		ks, err := keys(jv.Alt(s, jv.NewMap()))
		for _, k := range ks {
			emit(k)
		}
		return err
	}, true)

	top, end, ci := t.locateTop("services"), -1, 0
	if top >= 0 {
		end = t.blockEnd(top)
		ci, _ = t.childIndent(top)
	}
	anyOn := false
	defaultHN := x.at("", "networks", "default", "name") == "kasbah-net"
	routed := strings.Join(envtpl.SortUniq(x.c.routedHosts()), "\n")

	for _, svc := range lines(services) {
		if svc == "" {
			continue
		}
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

		joined := false
		hn, ok := pathThen(func(v jv.Value) (jv.Value, error) {
			switch m := v.(type) {
			case nil:
				v = []jv.Value{}
			case *jv.Map:
				ks, _ := keys(m)
				v = ks
			}
			return anyEq(v, "kasbah-net")
		}, "services", svc, "networks")
		if x.yq(hn, ok) == "true" {
			joined = true
		} else if defaultHN && !x.has("networks", "services", svc) {
			joined = true
		}
		if joined {
			anyOn = true
		}
		cn := x.at("", "services", svc, "container_name")
		if cn != "" && routed != "" && grepX(routed, cn) && !joined {
			if x.c03(s) {
				anyOn = true
			}
		}

		x.r01r02(s)
		x.c02(s)
		x.r03(s)
	}
	x.c04(anyOn, defaultHN)
	x.c05()
}

// svcBlock is where one service is written: its key line, last content line,
// the indentation of its keys, and the line a new key goes after.
type svcBlock struct {
	name             string
	idx, end, ci, at int
	pre              string
}

func (x *fixer) svcQ(def jv.Value, s svcBlock, p ...string) string {
	return x.at(def, append([]string{"services", s.name}, p...)...)
}

// c01: every service sets a restart policy.
func (x *fixer) c01(s svcBlock) {
	r := x.svcQ("", s, "restart")
	if restartOK.MatchString(r) {
		return
	}
	if x.has("restart", "services", s.name) {
		i := x.t.locateChild("restart", s.idx, s.end, s.ci)
		if i < 0 || !x.t.setValue(i, "unless-stopped") {
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
	drv := x.svcQ("", s, "logging", "driver")
	ms := x.svcQ("", s, "logging", "options", "max-size")
	mf := x.svcQ("", s, "logging", "options", "max-file")
	if drv == "json-file" && ms != "" && mf != "" {
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
			if i < 0 || !t.setValue(i, "json-file") {
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
	if ms != "" && mf != "" {
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
		if v != "" {
			continue
		}
		if x.has(k, "services", s.name, "logging", "options") {
			i := t.locateChild(k, o, oEnd, oci)
			if i < 0 || !t.setValue(i, nv) {
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

// c03: a routed service joins kasbah-net, and only ever gains it: a service
// on compose's implicit default keeps it, spelled out. True when an edit was
// planned.
func (x *fixer) c03(s svcBlock) bool {
	t := x.t
	p2 := spaces(s.ci + x.svcStep)
	if !x.has("networks", "services", s.name) {
		t.insertAfter(s.at, s.pre+"networks:\n"+p2+"- default\n"+p2+"- kasbah-net")
		x.app("default", "services", s.name, "networks")
		x.app("kasbah-net", "services", s.name, "networks")
		x.planf("C03 %s — add networks: [default, kasbah-net] (default spelled out so the service keeps the network it had implicitly)", s.name)
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
			x.leftf("C03 %s — its networks: is written inline as %s; add kasbah-net by hand", s.name, raw)
			return false
		}
		line, cr := t.lines[n], ""
		if strings.HasSuffix(line, "\r") {
			line, cr = line[:len(line)-1], "\r"
		}
		m := reFlowSeq.FindStringSubmatch(line)
		if m == nil {
			x.leftf("C03 %s — its networks: list spans more than one line; add kasbah-net by hand", s.name)
			return false
		}
		sep := ", "
		if reBlank.MatchString(m[2]) {
			sep = ""
		}
		t.rep[n] = m[1] + m[2] + sep + "kasbah-net" + m[3] + cr
		t.hasRep[n] = true
		x.app("kasbah-net", "services", s.name, "networks")
		x.planf("C03 %s — add kasbah-net to its networks list", s.name)
		return true
	}
	nEnd := t.blockEnd(n)
	nci, _ := t.childIndent(n)
	if nEnd < 0 {
		t.insertAfter(n, p2+"- default\n"+p2+"- kasbah-net")
		x.app("default", "services", s.name, "networks")
		x.app("kasbah-net", "services", s.name, "networks")
		x.planf("C03 %s — fill its empty networks: with default and kasbah-net", s.name)
		return true
	}
	npre := spaces(nci)
	kind, ok := pathThen(func(v jv.Value) (jv.Value, error) { return jv.Type(v), nil }, "services", s.name, "networks")
	if x.yq(kind, ok) == "object" {
		t.insertAfter(nEnd, npre+"kasbah-net:")
		x.set(nil, "services", s.name, "networks", "kasbah-net")
		x.planf("C03 %s — add kasbah-net to its networks mapping", s.name)
	} else {
		t.insertAfter(nEnd, npre+"- kasbah-net")
		x.app("kasbah-net", "services", s.name, "networks")
		x.planf("C03 %s — add kasbah-net to its networks list", s.name)
	}
	return true
}

// c04: kasbah-net is external — asked only when something is on it, and never
// under the default-alias shape C07 fails, which external: true would entrench.
func (x *fixer) c04(anyOn, defaultHN bool) {
	t := x.t
	if !anyOn {
		return
	}
	if defaultHN {
		if x.at(false, "networks", "default", "external") == "true" {
			return
		}
		x.leftf("C04 — the default network aliases kasbah-net (C07). Making it external: true would entrench that shape; join kasbah-net per routed service instead")
		return
	}
	ext := x.at(false, "networks", "kasbah-net", "external")
	if ext == "true" {
		return
	}
	top := t.locateTop("networks")
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
		if raw == "{}" && t.setValue(k, "{external: true}") {
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
		if i < 0 || !t.setValue(i, "true") {
			x.leftf("C04 — kasbah-net's external: is written in a shape --fix cannot rewrite")
			return
		}
		x.mask("networks", "kasbah-net", "external")
		x.planf("C04 — kasbah-net external: %s → true", ext)
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
	v := x.at("", "version")
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
	img := x.svcQ("", s, "image")
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
	if i < 0 || !x.t.setValue(i, base+":current") {
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

// r01r02: the limits, as the KASBAH_* references.
func (x *fixer) r01r02(s svcBlock) {
	for _, k := range []struct{ key, want, rule string }{
		{"cpus", "${KASBAH_CPU_LIMIT}", "R01"},
		{"mem_limit", "${KASBAH_MEM_LIMIT}", "R02"},
	} {
		cur := x.svcQ("", s, k.key)
		if cur == k.want {
			continue
		}
		if x.has(k.key, "services", s.name) {
			i := x.t.locateChild(k.key, s.idx, s.end, s.ci)
			if i < 0 || !x.t.setValue(i, k.want) {
				x.leftf("%s %s — its %s: is written in a shape --fix cannot rewrite", k.rule, s.name, k.key)
				continue
			}
			x.mask("services", s.name, k.key)
			x.planf("%s %s — %s: %s → %s", k.rule, s.name, k.key, orEmpty(cur), k.want)
		} else {
			x.t.insertAfter(s.at, s.pre+k.key+": "+k.want)
			x.set(k.want, "services", s.name, k.key)
			x.planf("%s %s — add %s: %s", k.rule, s.name, k.key, k.want)
		}
	}
}

// r03: reservations go, and a resources: or deploy: they leave empty with them.
func (x *fixer) r03(s svcBlock) {
	t := x.t
	if x.svcQ("", s, "mem_reservation") != "" {
		if i := t.locateChild("mem_reservation", s.idx, s.end, s.ci); i < 0 {
			x.leftf("R03 %s — cannot find its mem_reservation: in the file's text", s.name)
		} else {
			t.deleteKey(i)
			x.del("services", s.name, "mem_reservation")
			x.planf("R03 %s — remove mem_reservation", s.name)
		}
	}
	if x.svcQ("", s, "deploy", "resources", "reservations") == "" {
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
	count := func(p ...string) string {
		return x.yq(pathThen(func(v jv.Value) (jv.Value, error) {
			ks, err := keys(v)
			if err != nil {
				return nil, err
			}
			return length(ks)
		}, append([]string{"services", s.name}, p...)...))
	}
	resKeys, depKeys := count("deploy", "resources"), count("deploy")
	target := "deploy.resources.reservations"
	switch {
	case resKeys == "1" && depKeys == "1":
		t.deleteKey(d)
		x.del("services", s.name, "deploy")
		target = "deploy (it held nothing else)"
	case resKeys == "1":
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
func verifyCompose(a, b []jv.Value) bool {
	ka, kb := keyList(a, false), keyList(b, false)
	for _, k := range lines(ka) {
		if k != "" && !inLines(kb, k) && k != "version" {
			return false
		}
	}
	for _, k := range lines(kb) {
		if k != "" && !inLines(ka, k) && k != "networks" {
			return false
		}
	}
	return keyList(a, true, "services") == keyList(b, true, "services")
}

// verifyManifest: the same top-level keys, kasbah_version aside.
func verifyManifest(a, b []jv.Value) bool {
	strip := func(s string) string {
		var out []string
		for _, l := range lines(s) {
			if l != "kasbah_version" {
				out = append(out, l)
			}
		}
		return strings.TrimRight(strings.Join(out, "\n"), "\n")
	}
	return strip(keyList(a, false)) == strip(keyList(b, false))
}

// --- Staging, showing, writing --------------------------------------------------

type fixRun struct {
	c     *checker
	left  []string
	temps []string
}

type staged struct {
	file, target, tmp, plan string
}

// stage plans FILE and writes the candidate beside it, proven to parse, keep
// its keys and settle. nil with nothing to do or when refused (said why).
func (r *fixRun) stage(file string, docs []jv.Value, planner func(*fixer), verify func(a, b []jv.Value) bool, version string) *staged {
	c := r.c
	data, err := readRegular(file)
	if err != nil {
		c.out.Err("check --fix: cannot read %s — it was left alone", file)
		r.leftf("%s — could not be read; it was left exactly as it was", file)
		return nil
	}
	x := &fixer{c: c, docs: docs, t: readText(data), collect: true, left: &r.left, version: version}
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
	newDocs = yamlx.Reread(newDocs)
	if err != nil {
		os.Remove(tmp)
		c.out.Err("check --fix: the edited %s would not parse as YAML — nothing was written", file)
		r.leftf("%s — the edited file would not have parsed as YAML; it was left exactly as it was", file)
		return nil
	}
	if !verify(docs, newDocs) {
		os.Remove(tmp)
		c.out.Err("check --fix: the edited %s no longer declares the same keys — nothing was written", file)
		r.leftf("%s — the edited file no longer declared the same keys; it was left exactly as it was", file)
		return nil
	}
	if !guard(docs, newDocs, x.edits) {
		os.Remove(tmp)
		c.out.Err("check --fix: the edited %s would change values the fix did not plan to — nothing was written", file)
		r.leftf("%s — the edit would have changed more than the fix planned; it was left exactly as it was", file)
		return nil
	}
	again := &fixer{c: c, docs: newDocs, t: readText(out), left: &r.left, version: version}
	planner(again)
	if len(again.plan) != 0 {
		os.Remove(tmp)
		c.out.Err("check --fix: the fix to %s did not settle — a second run would change it again (%s). Nothing was written", file, strings.Join(again.plan, " "))
		r.leftf("%s — the fix did not settle, so a second run would change it again; it was left exactly as it was", file)
		return nil
	}
	return &staged{file: file, target: target, tmp: tmp, plan: plan}
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
	if _, err := exec.LookPath("diff"); err != nil {
		return cli.Fail("check --fix: diff is required (install diffutils and retry)")
	}
	r := &fixRun{c: c}
	pop := atexit.Push(r.cleanup)
	defer func() { r.cleanup(); pop() }()

	var files []*staged
	if isFile(composeFile) {
		if f := c.cache.Get(composeFile); f.Err != nil {
			r.leftf("compose.prod.yml does not parse as YAML — --fix will not pattern-match its way through a file it cannot read")
		} else if s := r.stage(composeFile, f.Docs, (*fixer).planCompose, verifyCompose, e.Version); s != nil {
			files = append(files, s)
		}
	}
	m := c.cache.Get(manifest.File)
	if s := r.stage(manifest.File, m.Docs, (*fixer).planManifest, verifyManifest, e.Version); s != nil {
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
		c.showDiff(s.file, s.tmp)
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

// showDiff prints a unified diff with the real path on both sides, under the C
// locale so its own lines do not vary with the operator's.
func (c *checker) showDiff(file, tmp string) {
	run := func(args ...string) int {
		cmd := exec.Command("diff", args...)
		cmd.Stdout, cmd.Stderr = c.w, c.out.Stderr
		cmd.Env = append(os.Environ(), "LC_ALL=C")
		err := cmd.Run()
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return ee.ExitCode()
		}
		if err != nil {
			return 2
		}
		return 0
	}
	if run("-u", "--label", "a/"+file, "--label", "b/"+file, "--", file, tmp) > 1 {
		run("-u", "--", file, tmp)
	}
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
