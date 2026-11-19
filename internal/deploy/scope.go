package deploy

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/url"
	"os"
	"os/exec"
	"slices"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/trace"
	"go.yaml.in/yaml/v3"
)

// backend is one loadBalancer server's host in a rendered fragment: where
// names it for a message, val is its value and line its line, at the byte
// offset just past the host and end in val, bad why it cannot be scoped, hide
// that bad is told without the value, shape that the fix is in how the
// fragment is written. keys are the ${KEY}s that filled it, and via the
// aliases it is read through.
type backend struct {
	where, val, host, bad string
	hide, shape           bool
	line, at, end         int
	keys                  []string
	node                  *yaml.Node
	via                   []*yaml.Node
}

// owner is a name a project answers to on its kasbah network, and what of
// which service it is.
type owner struct{ name, svc, what string }

// backends reads every http loadBalancer server url, and every tcp or udp
// one's address, out of text, in document order. Each found once, an alias's
// target included.
func backends(text []byte) ([]backend, error) {
	norm := bytes.ReplaceAll(text, []byte("\r\n"), []byte("\n"))
	lines := lineStarts(text)
	dec := yaml.NewDecoder(bytes.NewReader(norm))
	var out []backend
	for {
		var doc yaml.Node
		err := dec.Decode(&doc)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("%s does not parse as YAML (%v) (kasbah help T01)", Fragment, err)
		}
		if len(doc.Content) == 0 {
			continue
		}
		parent, aliases := map[*yaml.Node]*yaml.Node{}, map[*yaml.Node][]*yaml.Node{}
		indexAnchors(&doc, parent, aliases)
		w, seen := via{}, map[*yaml.Node]int{}
		first := len(out)
		for _, proto := range []string{"http", "tcp", "udp"} {
			key := "address"
			if proto == "http" {
				key = "url"
			}
			pw := via{}
			svcs := pw.deref(pw.field(pw.field(doc.Content[0], proto), "services"))
			w.add(pw)
			if svcs == nil || svcs.Kind != yaml.MappingNode {
				continue
			}
			for i := 0; i+1 < len(svcs.Content); i += 2 {
				name := deref(svcs.Content[i]).Value
				sw := via{}
				servers := sw.deref(sw.field(sw.field(svcs.Content[i+1], "loadBalancer"), "servers"))
				w.add(sw)
				if servers == nil || servers.Kind != yaml.SequenceNode {
					continue
				}
				for j, s := range servers.Content {
					rw := via{}
					rs := rw.fields(s, key)
					w.add(rw)
					for _, r := range rs {
						vw := via{}
						v := vw.deref(r)
						w.add(vw)
						if v.Kind != yaml.ScalarNode {
							continue
						}
						path := slices.Concat(pw.list(), sw.list(), rw.list(), vw.list())
						if k, ok := seen[v]; ok {
							out[k].via = append(out[k].via, path...)
							continue
						}
						seen[v] = len(out)
						b := backend{where: fmt.Sprintf("%s.services.%s.loadBalancer.servers[%d].%s", proto, name, j, key), val: v.Value, line: v.Line, node: v, via: path}
						lo, hi, why, hide := hostSpan(b.val, proto == "http")
						b.host, b.bad, b.hide, b.end = b.val[lo:hi], why, hide, hi
						if hide {
							b.end = len(b.val)
						}
						// Traefik reads a block scalar's kept closing line break as part of the value.
						if v.Style&(yaml.LiteralStyle|yaml.FoldedStyle) != 0 && strings.HasSuffix(b.val, "\n") {
							b.host, b.bad, b.hide, b.shape, b.end = "", "is a block scalar (| or >) that keeps its closing line break, which Traefik reads as part of the "+key+" — strip it with |- or >-, or write it on one line", true, true, len(b.val)
						}
						if b.bad == "" {
							if at, ok := locate(text, lines, v, b.val[:hi]); ok {
								b.at = at
							} else {
								b.bad, b.shape = "is not written as one plain or quoted scalar kasbah can scope — write it on one line, as `"+key+": \"…\"`", true
							}
						}
						out = append(out, b)
					}
				}
			}
		}
		// Scoping rewrites a url in every copy of an anchor holding it, or
		// holding an alias it is read through.
	refuse:
		for i := first; i < len(out); i++ {
			for _, start := range append([]*yaml.Node{out[i].node}, out[i].via...) {
				for n := start; n != nil && out[i].bad == ""; n = parent[n] {
					for _, a := range aliases[n] {
						if w[a] {
							continue
						}
						what := "is inside anchor &"
						if n == out[i].node {
							what = "is anchor &"
						}
						out[i].bad, out[i].hide, out[i].shape = what+n.Anchor+", also used outside a backend, which scoping it would change too — write the URL out where the backend names it", true, true
						continue refuse
					}
				}
			}
		}
	}
	return out, nil
}

// indexAnchors records under root each node's parent and the aliases pointing at it.
func indexAnchors(root *yaml.Node, parent map[*yaml.Node]*yaml.Node, aliases map[*yaml.Node][]*yaml.Node) {
	if root.Kind == yaml.AliasNode {
		aliases[root.Alias] = append(aliases[root.Alias], root)
	}
	for _, c := range root.Content {
		parent[c] = root
		indexAnchors(c, parent, aliases)
	}
}

// hostSpan is where the host Traefik dials lies in s, a url as Go's net/url
// reads it or a tcp/udp host:port. why says what keeps s from having one
// kasbah can scope, and hide that it is told without the value.
func hostSpan(s string, isURL bool) (lo, hi int, why string, hide bool) {
	if strings.ContainsFunc(s, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return 0, 0, "holds a control character (a tab or a line break) — write it on one line, nothing around it", true
	}
	if !isURL {
		h, _, err := net.SplitHostPort(s)
		switch {
		case err == nil && strings.HasPrefix(s, "["):
			return 0, len(h) + 2, "", false
		case err == nil:
			return 0, len(h), "", false
		case !strings.Contains(s, ":"):
			return 0, len(s), "", false
		case net.ParseIP(s) != nil:
			return 0, len(s), "", false
		}
		return 0, 0, "is not a host:port address — write it as <service>:<port>", true
	}
	u, err := url.Parse(s)
	m := urlScheme.FindStringIndex(s)
	if err != nil || m == nil {
		return 0, 0, "is not a URL as Traefik reads it — write it as http://<service>:<port>", true
	}
	lo = m[1]
	auth := s[lo:]
	if i := strings.IndexAny(auth, "/?#"); i >= 0 {
		auth = auth[:i]
	}
	if u.User != nil || strings.Contains(auth, "@") {
		return 0, 0, "names a user or password before its host (…@), and Traefik dials what follows the @ — drop it and name the service alone", true
	}
	hi = lo + len(auth)
	if strings.HasPrefix(auth, "[") {
		return lo, lo + strings.IndexByte(auth, ']') + 1, "", false
	}
	if i := strings.IndexByte(auth, ':'); i >= 0 {
		hi = lo + i
	}
	if s[lo:hi] != u.Hostname() {
		return lo, hi, "is not the host Go's URL parser reads, which Traefik dials — write it as http://<service>:<port>", false
	}
	return lo, hi, "", false
}

// lineStarts is the byte offset each line of text starts at.
func lineStarts(text []byte) []int {
	starts := []int{0}
	for i, c := range text {
		if c == '\n' {
			starts = append(starts, i+1)
		}
	}
	return starts
}

// locate is the offset in text just past prefix, the start of n's value as
// its source spells it; false when the source does not spell it so.
func locate(text []byte, lines []int, n *yaml.Node, prefix string) (int, bool) {
	if n.Line < 1 || n.Line > len(lines) {
		return 0, false
	}
	off := lines[n.Line-1]
	if n.Line == 1 && bytes.HasPrefix(text, []byte("\uFEFF")) {
		off += len("\uFEFF")
	}
	for c := 1; c < n.Column && off < len(text) && text[off] != '\n'; c++ {
		_, w := utf8.DecodeRune(text[off:])
		off += w
	}
	switch {
	case n.Style&(yaml.LiteralStyle|yaml.FoldedStyle) != 0:
		nl := bytes.IndexByte(text[off:], '\n')
		if nl < 0 {
			return 0, false
		}
		off += nl
		for off < len(text) && (text[off] == ' ' || text[off] == '\t' || text[off] == '\r' || text[off] == '\n') {
			off++
		}
	case n.Style&(yaml.SingleQuotedStyle|yaml.DoubleQuotedStyle) != 0:
		off = props(text, off) + 1
	default:
		off = props(text, off)
	}
	if !bytes.HasPrefix(text[off:], []byte(prefix)) {
		return 0, false
	}
	return off + len(prefix), true
}

// props is off past any anchor and tag written before a scalar there.
func props(text []byte, off int) int {
	for off < len(text) && (text[off] == '&' || text[off] == '!') {
		for off < len(text) && text[off] != ' ' && text[off] != '\t' && text[off] != '\n' {
			off++
		}
		for off < len(text) && (text[off] == ' ' || text[off] == '\t') {
			off++
		}
	}
	return off
}

// via is the aliases a backend is read through.
type via map[*yaml.Node]bool

// add notes in w every alias o holds.
func (w via) add(o via) {
	for a := range o {
		w[a] = true
	}
}

// list is w's aliases in document order.
func (w via) list() []*yaml.Node {
	out := make([]*yaml.Node, 0, len(w))
	for a := range w {
		out = append(out, a)
	}
	sort.Slice(out, func(i, j int) bool {
		return out[i].Line < out[j].Line || out[i].Line == out[j].Line && out[i].Column < out[j].Column
	})
	return out
}

// field is the value of key in mapping n as yamlx reads it: its own last,
// else the first a merge gives.
func (w via) field(n *yaml.Node, key string) *yaml.Node {
	if f := w.fields(n, key); len(f) > 0 {
		return f[len(f)-1]
	}
	return nil
}

// fields is every value n gives key: each own entry, or else the merged one.
func (w via) fields(n *yaml.Node, key string) []*yaml.Node {
	n = w.deref(n)
	if n == nil || n.Kind != yaml.MappingNode {
		return nil
	}
	var own []*yaml.Node
	var merge *yaml.Node
	for i := 0; i+1 < len(n.Content); i += 2 {
		k := deref(n.Content[i])
		switch {
		case k.Kind == yaml.ScalarNode && k.ShortTag() == "!!merge":
			merge = n.Content[i+1]
		case k.Kind == yaml.ScalarNode && k.Value == key:
			own = append(own, n.Content[i+1])
		}
	}
	if len(own) > 0 || merge == nil {
		return own
	}
	srcs := []*yaml.Node{merge}
	if deref(merge).Kind == yaml.SequenceNode {
		srcs = w.deref(merge).Content
	}
	for _, s := range srcs {
		if v := w.field(s, key); v != nil {
			return []*yaml.Node{v}
		}
	}
	return nil
}

// deref is the node n aliases, each alias on the way noted in w.
func (w via) deref(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		w[n] = true
		n = n.Alias
	}
	return n
}

func deref(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

// owners is every name m's services answer to on its kasbah network: a
// service joined to it, its kasbah aliases, its container_name.
func (m *composeModel) owners() []owner {
	var out []owner
	for _, svc := range sortedKeys(m.Services) {
		s := m.Services[svc]
		n, joined := s.Networks[projectNet]
		if !joined {
			continue
		}
		out = append(out, owner{svc, svc, ""})
		if n != nil {
			for _, a := range n.Aliases {
				out = append(out, owner{a, svc, "a " + projectNet + " alias of " + svc})
			}
		}
		if s.ContainerName != "" {
			out = append(out, owner{s.ContainerName, svc, svc + "'s container_name"})
		}
	}
	return out
}

// netName is the name compose gives project's kasbah network.
func (m *composeModel) netName(project string) string {
	if n, ok := m.Networks[projectNet]; ok && n.Name != "" {
		return n.Name
	}
	return project + "_" + projectNet
}

// scoping is the run a fragment is scoped for: the project, the deploy
// target its next steps name, the run it is in, and its compose model.
type scoping struct {
	project, target, run string
	model                func() (*composeModel, error)
}

// scopeFragment qualifies each backend host of text, the fragment tmpl
// renders to, with the project's kasbah network, every other byte kept, and
// refuses a host that is not the project's own name there. A refusal of a
// host a ${KEY} filled names the key, never the value. The model is read
// only when the fragment has a backend.
func scopeFragment(tmpl, text []byte, sc scoping) ([]byte, error) {
	bs, err := backends(text)
	if err != nil || len(bs) == 0 {
		return text, err
	}
	m, err := sc.model()
	if err != nil {
		return nil, fmt.Errorf("%s names backends, and `docker compose -p %s config` could not be read to tell they are this project's (%v) — fix what compose reports, then re-run the %s; the route is never installed unscoped (kasbah help T07)", Fragment, sc.project, err, sc.run)
	}
	fromKeys(bs, tmpl)
	netName, own := m.netName(sc.project), m.owners()
	var bad []string
	for _, b := range bs {
		why := b.bad
		switch h := b.host; {
		case why != "":
		case h == "":
			why = "names no host"
		case strings.HasPrefix(h, "[") || net.ParseIP(h) != nil:
			why = "is an IP address, which reaches whatever holds it"
		case strings.Trim(h, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.") != "":
			why = "is not a host name"
		case strings.Contains(h, "."):
			why = "is a qualified name — name the service alone, and the deploy scopes it to " + netName
		case !slices.ContainsFunc(own, func(o owner) bool { return strings.EqualFold(o.name, h) }):
			why = "is not a name of this project on its kasbah network (" + netName + "), so Traefik would reach whatever answers it on another network it is on"
		}
		if why == "" {
			continue
		}
		subject := b.where
		if !b.hide {
			subject += "'s host"
		}
		switch {
		case len(b.keys) > 0 && b.shape:
			bad = append(bad, fmt.Sprintf("%s, filled from ${%s} on line %d, %s", subject, strings.Join(b.keys, "} ${"), b.line, why))
		case len(b.keys) > 0:
			sets := make([]string, len(b.keys))
			for i, k := range b.keys {
				sets[i] = "`" + strings.TrimSpace("kasbah env set "+k+" "+sc.target) + "`"
			}
			bad = append(bad, fmt.Sprintf("%s, filled from ${%s} on line %d, %s — %s sets another", subject, strings.Join(b.keys, "} ${"), b.line, why, strings.Join(sets, " or ")))
		case b.hide:
			bad = append(bad, subject+" "+why)
		default:
			bad = append(bad, fmt.Sprintf("%s %s %s", subject, strconv.Quote(b.host), why))
		}
	}
	if len(bad) > 0 {
		return nil, fmt.Errorf("%s targets a backend that is not this project's: %s — target %s (kasbah help T07)", Fragment, strings.Join(bad, "; "), ownList(own))
	}
	sort.SliceStable(bs, func(i, j int) bool { return bs[i].at < bs[j].at })
	out := make([]byte, 0, len(text)+len(bs)*(len(netName)+1))
	last := 0
	for _, b := range bs {
		out = append(append(append(out, text[last:b.at]...), '.'), netName...)
		last = b.at
	}
	return append(out, text[last:]...), nil
}

// fromKeys sets each backend's keys: the ${KEY}s of tmpl's same backend
// written before the end of its host, read from tmpl's own line. A tmpl whose
// backends do not pair with them gives each every key tmpl names.
func fromKeys(bs []backend, tmpl []byte) {
	all := FragmentKeys(tmpl)
	if len(all) == 0 {
		return
	}
	tb, err := backends(tmpl)
	if err != nil || len(tb) != len(bs) {
		for i := range bs {
			bs[i].keys = all
		}
		return
	}
	for i, t := range tb {
		if ref := fragRef.FindStringIndex(t.val); ref != nil && ref[0] < bs[i].end {
			bs[i].keys, bs[i].line = FragmentKeys([]byte(t.val)), t.line
		}
	}
}

// dotted refuses a name with a dot on m's kasbah network: Docker answers a
// whole dotted name on every network the asker is on, so web.<other>_kasbah
// would answer for another project's backend before that project's web does.
func (m *composeModel) dotted(project string) error {
	var bad []string
	for _, o := range m.owners() {
		if strings.Contains(o.name, ".") {
			what := o.what
			if what == "" {
				what = "a service"
			}
			bad = append(bad, o.name+" ("+what+")")
		}
	}
	if len(bad) == 0 {
		return nil
	}
	return fmt.Errorf("compose puts a name with a dot on this project's kasbah network (%s): %s — Docker answers a dotted name on every network Traefik is on, so it could answer for another project's backend; rename it without a dot, and the fragment's backend with it (kasbah help C16)", m.netName(project), strings.Join(bad, ", "))
}

// foreign refuses a network compose would take from outside the project: an
// external one, or one whose name: is not compose's own <project>_<key>.
// Whatever else joins it shares it, a kasbah alias or another project's
// backend name among them, and a deploy runs no check to catch it.
func (m *composeModel) foreign(project string) error {
	var bad []string
	for _, k := range sortedKeys(m.Networks) {
		n := m.Networks[k]
		switch {
		case bool(n.External):
			bad = append(bad, k+" (external "+n.Name+")")
		case n.Name != "" && n.Name != project+"_"+k:
			bad = append(bad, k+" (named "+n.Name+")")
		}
	}
	if len(bad) == 0 {
		return nil
	}
	return fmt.Errorf("compose joins this project to a network from outside it: %s — a network outside the project is shared with whatever else joins it, which can then answer for this project's names or reach its services; drop it, or drop its external: and name: so compose creates %s_<key> (kasbah help C04)", strings.Join(bad, ", "), project)
}

// ownList names what a backend may target, or how to get something to.
func ownList(own []owner) string {
	if len(own) == 0 {
		return "a service joined to the kasbah network — no service of this project joins it"
	}
	names := make([]string, len(own))
	for i, o := range own {
		names[i] = o.name
		if o.what != "" {
			names[i] += " (" + o.what + ")"
		}
	}
	return "one of this project's own names there: " + strings.Join(names, ", ")
}

// liveHosts is the fragment's backend hosts as the project's services answer
// them on netName: <h>.<netName> is h, and any other qualified host matches
// none of them.
func liveHosts(hosts []string, netName string) []string {
	var out []string
	for _, h := range hosts {
		if b, ok := strings.CutSuffix(h, "."+netName); ok {
			h = b
		}
		if !strings.Contains(h, ".") {
			out = append(out, h)
		}
	}
	return out
}

// composeQuery is docker run in dir, its output as engine.query returns it
// and a failure carrying docker's first line of stderr that is no compose
// warning, else its last.
func composeQuery(dir string) func(...string) (string, error) {
	return func(args ...string) (string, error) {
		c := exec.Command("docker", args...)
		c.Env = append(os.Environ(), "LC_ALL=C")
		c.Dir = dir
		out, err := trace.Output(c)
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			if l := causeLine(string(ee.Stderr)); l != "" {
				err = fmt.Errorf("%w: %s", err, l)
			}
		}
		return strings.TrimRight(strings.ReplaceAll(string(out), "\r", ""), "\n"), err
	}
}

// causeLine is the first line of stderr that is no `level=warning` line of
// compose's, else its last.
func causeLine(stderr string) string {
	var last string
	for _, l := range strings.Split(strings.ReplaceAll(stderr, "\r", ""), "\n") {
		if l = strings.TrimSpace(l); l == "" {
			continue
		}
		if !strings.Contains(l, "level=warning") {
			return l
		}
		last = l
	}
	return last
}

// readModel is `docker compose -p project config` through query.
func readModel(project string, query func(...string) (string, error)) (*composeModel, error) {
	out, err := query("compose", "-p", project, "config", "--format", "json")
	if err != nil {
		return nil, err
	}
	var m composeModel
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		return nil, fmt.Errorf("its output does not read as JSON: %v", err)
	}
	return &m, nil
}
