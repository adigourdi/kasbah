package migrate

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"

	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/traefiknet"
	"go.yaml.in/yaml/v3"
)

const (
	dynamicDir   = "traefik/dynamic"
	mailFragment = dynamicDir + "/_mail.yml"
	traefikFile  = "traefik/compose.yml"
	sharedNet    = traefiknet.Shared
	// recreate is how Traefik gets off kasbah-net for good.
	recreate = "the next `kasbah server init` or `kasbah server upgrade-traefik` recreates Traefik off it, then removes " + sharedNet + " once no container is on it"
)

// scoped is the 1→2 step: every project fragment's backend hosts and
// _mail.yml's qualified with their project's network, kasbah-net out of
// Traefik's compose file, then the live Traefik disconnected from it. docker
// runs every docker command, compose a project's `docker compose` in its
// directory.
func scoped(docker traefiknet.Docker, compose func(dir string) func(...string) (string, error)) Step {
	return Step{
		From: 1, To: 2,
		Desc: "qualifies each backend host in " + dynamicDir + "/<name>.yml, for each project <name>, with <name>_kasbah and _mail.yml's with mail_kasbah, drops " + sharedNet + " from " + traefikFile + ", then disconnects Traefik from " + sharedNet + " live, keeping the network, which Traefik was created on (" + recreate + "); an undo puts the files back, not Traefik on " + sharedNet,
		Files: func(apps string) ([]string, error) {
			fr, _, err := fragments(apps)
			return append(fr, mailFragment, traefikFile), err
		},
		Major: func(rel string, body []byte) (int, error) {
			if rel == traefikFile {
				spans, err := sharedSpans(body)
				return major(len(spans) == 0), err
			}
			_, n, err := deploy.Qualify(fragmentProject(rel), body)
			return major(n == 0), err
		},
		Rewrite: func(rel string, body []byte) ([]byte, error) {
			if rel == traefikFile {
				return dropShared(body)
			}
			out, _, err := deploy.Qualify(fragmentProject(rel), body)
			return out, err
		},
		Warn: func(apps string) Cost { return lost(apps, docker, compose) },
		Act:  func(string) ([]string, error) { return detach(docker) },
		Left: func(string) []string { return reattach(docker) },
	}
}

func major(at2 bool) int {
	if at2 {
		return 2
	}
	return 1
}

// fragments is every project's installed fragment under apps, relative to
// it, in byte order, and every other <name>.yml there: a project has a
// directory under apps, as traefiknet.Served reads it, and kasbah's own
// (_-prefixed) are neither.
func fragments(apps string) (projects, others []string, err error) {
	ents, err := os.ReadDir(filepath.Join(apps, dynamicDir))
	if os.IsNotExist(err) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, fmt.Errorf("could not list %s: %v", filepath.Join(apps, dynamicDir), err)
	}
	for _, e := range ents {
		name, ok := strings.CutSuffix(e.Name(), ".yml")
		if !ok || !manifest.ValidName(name) || manifest.NameReserved(name) {
			continue
		}
		if fi, err := os.Stat(filepath.Join(apps, name)); err == nil && fi.IsDir() {
			projects = append(projects, dynamicDir+"/"+e.Name())
		} else {
			others = append(others, dynamicDir+"/"+e.Name())
		}
	}
	sort.Strings(projects)
	sort.Strings(others)
	return projects, others, nil
}

// fragmentProject is the project whose network a fragment's backends are
// scoped to: mail for _mail.yml, else the file's name.
func fragmentProject(rel string) string {
	if rel == mailFragment {
		return "mail"
	}
	return strings.TrimSuffix(filepath.Base(rel), ".yml")
}

// composeDoc is a compose file's lines, its root mapping, the traefik
// service and its networks: key and value, the top-level ones, and each
// node's parent.
type composeDoc struct {
	lines              [][]byte
	svc, snetK, snet   *yaml.Node
	top, topK, topNets *yaml.Node
	parent             map[*yaml.Node]*yaml.Node
}

func readCompose(body []byte) (*composeDoc, error) {
	norm := bytes.ReplaceAll(body, []byte("\r\n"), []byte("\n"))
	var root yaml.Node
	if err := yaml.NewDecoder(bytes.NewReader(norm)).Decode(&root); err != nil && err != io.EOF {
		return nil, fmt.Errorf("does not parse as YAML (%v)", err)
	}
	d := &composeDoc{lines: bytes.SplitAfter(body, []byte("\n")), parent: map[*yaml.Node]*yaml.Node{}}
	if len(root.Content) == 0 || root.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("is not a compose file (no mapping at its top)")
	}
	d.top = root.Content[0]
	index(d.top, d.parent)
	d.topK, d.topNets = mapEntry(d.top, "networks")
	_, services := mapEntry(d.top, "services")
	if _, d.svc = mapEntry(services, "traefik"); d.svc == nil {
		return nil, fmt.Errorf("has no services.traefik")
	}
	if !bytes.Contains(norm, []byte(sharedNet)) {
		return d, nil
	}
	if d.svc.Kind == yaml.AliasNode {
		return nil, fmt.Errorf("writes services.traefik on line %d as an alias, so its networks: cannot be edited in place — write the service out, then re-run", d.svc.Line)
	}
	d.snetK, d.snet = mapEntry(d.svc, "networks")
	if mk, mv := mapEntry(d.svc, "<<"); d.snet == nil && mk != nil && merged(mv, "networks") {
		return nil, fmt.Errorf("gives services.traefik its networks: through the merge on line %d, which kasbah cannot edit in place — write networks: on the service itself, then re-run", mk.Line)
	}
	for _, n := range []*yaml.Node{d.topNets, d.snet} {
		if n != nil && (n.Kind == yaml.AliasNode || n.Style&yaml.FlowStyle != 0 || n.Kind == yaml.ScalarNode && n.Tag != "!!null") {
			return nil, fmt.Errorf("writes networks: on line %d in a shape kasbah cannot edit in place — write it as a block list or mapping, then re-run", n.Line)
		}
	}
	if n := indirect(d.snet, true); n != nil {
		return nil, fmt.Errorf("writes an alias or a merge on line %d in services.traefik's networks:, which kasbah cannot edit in place — write each network out by name, then re-run", n.Line)
	}
	if n := indirect(d.topNets, false); n != nil {
		return nil, fmt.Errorf("writes an alias or a merge on line %d as a key of the top-level networks:, which kasbah cannot edit in place — write each network out by name, then re-run", n.Line)
	}
	return d, nil
}

// indirect is the first alias or merge key in n: anywhere beneath it when
// deep, else among its own keys.
func indirect(n *yaml.Node, deep bool) *yaml.Node {
	if n == nil {
		return nil
	}
	for i, c := range n.Content {
		if !deep && n.Kind == yaml.MappingNode && i%2 == 1 {
			continue
		}
		if c.Kind == yaml.AliasNode || n.Kind == yaml.MappingNode && i%2 == 0 && c.ShortTag() == "!!merge" {
			return c
		}
		if deep {
			if x := indirect(c, true); x != nil {
				return x
			}
		}
	}
	return nil
}

// deref is n, or the node an alias n stands for.
func deref(n *yaml.Node) *yaml.Node {
	for n != nil && n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

// merged is whether a merge's value v, a mapping or a list of them, gives key.
func merged(v *yaml.Node, key string) bool {
	if v != nil && v.Kind == yaml.AliasNode {
		v = v.Alias
	}
	if v != nil && v.Kind == yaml.SequenceNode {
		return slices.ContainsFunc(v.Content, func(n *yaml.Node) bool { return merged(n, key) })
	}
	k, _ := mapEntry(v, key)
	return k != nil
}

func index(n *yaml.Node, parent map[*yaml.Node]*yaml.Node) {
	for _, c := range n.Content {
		parent[c] = n
		index(c, parent)
	}
}

// mapEntry is the key and value of key in mapping m, as written (no merge).
func mapEntry(m *yaml.Node, key string) (*yaml.Node, *yaml.Node) {
	if m == nil || m.Kind != yaml.MappingNode {
		return nil, nil
	}
	for i := len(m.Content) - 2; i >= 0; i -= 2 {
		if m.Content[i].Value == key {
			return m.Content[i], m.Content[i+1]
		}
	}
	return nil, nil
}

// shared is the top-level network keys that are kasbah-net: by key, or by name.
func (d *composeDoc) shared() []string {
	keys := []string{sharedNet}
	if d.topNets != nil && d.topNets.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(d.topNets.Content); i += 2 {
			if _, n := mapEntry(deref(d.topNets.Content[i+1]), "name"); n != nil && deref(n).Value == sharedNet {
				keys = append(keys, deref(d.topNets.Content[i]).Value)
			}
		}
	}
	return keys
}

// spans is the lines (1-based, inclusive) that hold kasbah-net in d, an
// alias read as the value it stands for.
func (d *composeDoc) spans() [][2]int {
	keys := d.shared()
	var out [][2]int
	drop := func(k *yaml.Node, items []*yaml.Node) {
		var hit [][2]int
		for _, it := range items {
			if slices.Contains(keys, deref(it).Value) {
				hit = append(hit, d.span(it))
			}
		}
		switch {
		case len(hit) == 0:
		case len(hit) == len(items):
			out = append(out, d.span(k))
		default:
			out = append(out, hit...)
		}
	}
	for _, x := range []struct{ k, v *yaml.Node }{{d.snetK, d.snet}, {d.topK, d.topNets}} {
		if x.v == nil {
			continue
		}
		switch x.v.Kind {
		case yaml.SequenceNode:
			drop(x.k, x.v.Content)
		case yaml.MappingNode:
			var ks []*yaml.Node
			for i := 0; i < len(x.v.Content); i += 2 {
				ks = append(ks, x.v.Content[i])
			}
			drop(x.k, ks)
		}
	}
	return out
}

// span is the lines of n, a mapping key (with its value) or a sequence item,
// from its head comment to its last line: the last a node starts on, then
// every line indented deeper than n's own, a block scalar's among them.
func (d *composeDoc) span(n *yaml.Node) [2]int {
	start := n.Line
	indent := n.Column - 1
	if p := d.parent[n]; p != nil && p.Kind == yaml.SequenceNode {
		indent = -1
	}
	for start > 1 {
		l := strings.TrimRight(string(d.lines[start-2]), "\r\n")
		t := strings.TrimLeft(l, " ")
		if !strings.HasPrefix(t, "#") || (indent >= 0 && len(l)-len(t) != indent) {
			break
		}
		start--
	}
	end := last(n)
	if p := d.parent[n]; p != nil && p.Kind == yaml.MappingNode {
		for i := 0; i+1 < len(p.Content); i += 2 {
			if p.Content[i] == n {
				end = max(end, last(p.Content[i+1]))
			}
		}
	}
	ind := indentOf(d.lines[n.Line-1])
	for l := end + 1; l <= len(d.lines); l++ {
		if len(bytes.TrimSpace(d.lines[l-1])) == 0 {
			continue
		}
		if indentOf(d.lines[l-1]) <= ind {
			break
		}
		end = l
	}
	return [2]int{start, end}
}

func indentOf(line []byte) int { return len(line) - len(bytes.TrimLeft(line, " ")) }

// last is the last line a node or its descendants start on.
func last(n *yaml.Node) int {
	l := n.Line
	for _, c := range n.Content {
		l = max(l, last(c))
	}
	return l
}

// sharedSpans is where body, Traefik's compose file, still names kasbah-net:
// none is a file at major 2.
func sharedSpans(body []byte) ([][2]int, error) {
	d, err := readCompose(body)
	if err != nil {
		return nil, err
	}
	return d.spans(), nil
}

// dropShared is body without kasbah-net under the traefik service's networks
// and the top-level ones, a key left empty dropped with it, every other line
// kept as written.
func dropShared(body []byte) ([]byte, error) {
	d, err := readCompose(body)
	if err != nil {
		return nil, err
	}
	cut := make([]bool, len(d.lines)+1)
	for _, s := range d.spans() {
		for l := s[0]; l <= s[1] && l <= len(d.lines); l++ {
			cut[l] = true
		}
	}
	// Blank lines left at the end of the file go with what followed them.
	tail := true
	for l := len(d.lines); l >= 1; l-- {
		blank := len(bytes.TrimSpace(d.lines[l-1])) == 0
		if !cut[l] && !blank {
			tail = false
		}
		if tail && blank {
			cut[l] = true
		}
	}
	var out []byte
	for l, line := range d.lines {
		if !cut[l+1] {
			out = append(out, line...)
		}
	}
	rest, err := sharedSpans(out)
	switch {
	case err != nil:
		return nil, fmt.Errorf("no longer reads as a compose file once %s's lines are cut (it %v) — take it out of the traefik service's networks: and the top-level networks: by hand, then re-run", sharedNet, err)
	case len(rest) > 0:
		return nil, fmt.Errorf("still names %s on line %d once its lines are cut — take it out of the traefik service's networks: and the top-level networks: by hand, then re-run", sharedNet, rest[0][0])
	}
	return out, nil
}

// detach takes the live Traefik off kasbah-net, and says what it did. The
// network stays: Traefik was created on it, and cannot start again without
// it until it is recreated. One on no other network stays on it, which would
// leave its ports unpublished.
func detach(docker traefiknet.Docker) ([]string, error) {
	on, err := docker.Attached()
	if errors.Is(err, traefiknet.ErrNoTraefik) {
		return []string{"there is no " + traefiknet.Container + " container: nothing was disconnected from " + sharedNet}, nil
	}
	if err != nil {
		return nil, err
	}
	switch {
	case !on[sharedNet]:
		return []string{traefiknet.Container + " is not on " + sharedNet + ": nothing was disconnected"}, nil
	case len(on) == 1:
		return []string{fmt.Sprintf("%s is on no network but %s, so it stays on it — %s", traefiknet.Container, sharedNet, recreate)}, nil
	}
	done, err := docker.Leave([]string{sharedNet})
	if err != nil {
		return nil, err
	}
	if len(done) == 0 {
		return []string{traefiknet.Container + " was off " + sharedNet + " by the time it was disconnected: nothing was disconnected"}, nil
	}
	return []string{fmt.Sprintf("%s disconnected from %s, which is kept: %s was created on it and needs it to start — %s", traefiknet.Container, sharedNet, traefiknet.Container, recreate)}, nil
}

// reattach is what an undo of scoped leaves live: Traefik off kasbah-net.
func reattach(docker traefiknet.Docker) []string {
	on, err := docker.Attached()
	if errors.Is(err, traefiknet.ErrNoTraefik) {
		return nil
	}
	if err != nil {
		return []string{"whether " + traefiknet.Container + " is still on " + sharedNet + " is unjudged: " + err.Error()}
	}
	if on[sharedNet] {
		return nil
	}
	_, err = docker("network", "inspect", "-f", "{{.Name}}", sharedNet)
	switch {
	case err == nil:
		return []string{fmt.Sprintf("%s is still off %s, so a restored backend reached only through it answers 502: `docker network connect %s %s` on the server puts it back", traefiknet.Container, sharedNet, sharedNet, traefiknet.Container)}
	case traefiknet.NoNetwork(err, sharedNet):
		return []string{fmt.Sprintf("%s is off %s, which is gone: no container was left on it to route to", traefiknet.Container, sharedNet)}
	}
	return []string{fmt.Sprintf("whether %s still exists is unjudged: docker network inspect failed: %v", sharedNet, err)}
}

// container is one running container as lost reads it.
type container struct {
	name, project string
	nets          map[string][]string
}

// containers is every running container: its name, compose project, and
// the names it answers on each network — its aliases, and its hostname.
func containers(docker traefiknet.Docker) ([]container, error) {
	ids, err := docker("ps", "-q")
	if err != nil {
		return nil, fmt.Errorf("docker ps failed: %v", err)
	}
	if len(strings.Fields(ids)) == 0 {
		return nil, nil
	}
	out, err := docker(append([]string{"inspect", "-f", `{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Config.Hostname}}|{{range $k, $v := .NetworkSettings.Networks}}{{$k}}={{join $v.Aliases ","}} {{end}}`}, strings.Fields(ids)...)...)
	if err != nil {
		return nil, fmt.Errorf("docker inspect failed: %v", err)
	}
	var cs []container
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		f := strings.SplitN(l, "|", 4)
		if len(f) < 4 {
			continue
		}
		c := container{name: strings.TrimPrefix(f[0], "/"), project: f[1], nets: map[string][]string{}}
		for _, n := range strings.Fields(f[3]) {
			k, as, _ := strings.Cut(n, "=")
			c.nets[k] = strings.FieldsFunc(as, func(r rune) bool { return r == ',' })
			if f[2] != "" {
				c.nets[k] = append(c.nets[k], f[2])
			}
		}
		cs = append(cs, c)
	}
	sort.Slice(cs, func(i, j int) bool { return cs[i].name < cs[j].name })
	return cs, nil
}

// fix is how a project gets its route back under 2.x.
const fix = "until the project is moved to `kasbah: {}` with `kasbah check --fix` and redeployed with this kasbah"

// lost is what 1→2 will cost, read-only. Lost: each project fragment's
// backend that is not one of its project's own names on <name>_kasbah, which
// it reached only through kasbah-net, and each name on a project network
// shaped like a scoped one (<a>.<b>_kasbah), which could take another's route. Notes: an IP or outside host,
// left as written; a <name>.yml that is no project's; who stays on kasbah-net.
func lost(apps string, docker traefiknet.Docker, compose func(dir string) func(...string) (string, error)) Cost {
	var c Cost
	fr, others, err := fragments(apps)
	if err != nil {
		c.Lost = append(c.Lost, "the installed fragments are unjudged: "+err.Error())
	}
	for _, rel := range fr {
		name := fragmentProject(rel)
		body, err := os.ReadFile(filepath.Join(apps, rel))
		if err != nil {
			c.Lost = append(c.Lost, fmt.Sprintf("%s is unjudged: %v", name, err))
			continue
		}
		dir := filepath.Join(apps, name)
		gone, outside, err := deploy.Strays(name, body, compose(dir))
		if err != nil {
			c.Lost = append(c.Lost, fmt.Sprintf("%s is unjudged: its %s could not be read against `docker compose -p %s config` in %s (%v)", name, rel, name, dir, err))
			continue
		}
		for _, h := range gone {
			c.Lost = append(c.Lost, fmt.Sprintf("%s: backend %s in %s is not one of its own names on %s_kasbah, so its route answers 502 %s", name, h, rel, name, fix))
		}
		for _, h := range outside {
			c.Notes = append(c.Notes, fmt.Sprintf("%s: backend %s in %s is left as written; the next deploy with this kasbah refuses it (kasbah help T07)", name, h, rel))
		}
	}
	for _, rel := range others {
		c.Notes = append(c.Notes, fmt.Sprintf("%s is left as written: no %s/ under the apps path, so it is no project's fragment", rel, fragmentProject(rel)))
	}
	cs, err := containers(docker)
	if err != nil {
		c.Lost = append(c.Lost, "the running containers are unjudged: "+err.Error())
	}
	var shared []string
	traefikOn := false
	for _, ct := range cs {
		if _, on := ct.nets[sharedNet]; on {
			if ct.name == traefiknet.Container {
				traefikOn = true
			} else {
				shared = append(shared, ct.name)
			}
		}
		for _, n := range sortedKeys(ct.nets) {
			if !strings.HasSuffix(n, "_kasbah") {
				continue
			}
			// Only a name whose last label ends in _kasbah can stand for a
			// scoped backend, <svc>.<project>_kasbah.
			for _, a := range append([]string{ct.name}, ct.nets[n]...) {
				if i := strings.LastIndex(a, "."); i >= 0 && strings.HasSuffix(strings.ToLower(a[i+1:]), "_kasbah") {
					c.Lost = append(c.Lost, fmt.Sprintf("%s answers the dotted name %s on %s, so it could hijack another project's scoped backend until it is renamed without a dot and its project redeployed with this kasbah (kasbah help C16)", ct.name, a, n))
				}
			}
		}
	}
	if traefikOn && len(shared) > 0 {
		c.Notes = append(c.Notes, fmt.Sprintf("%s leaves %s, which %s stay on; a route to them is lost only as listed above", traefiknet.Container, sharedNet, strings.Join(shared, ", ")))
	}
	return c
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
