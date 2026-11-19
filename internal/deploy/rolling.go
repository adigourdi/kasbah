package deploy

import (
	"encoding/json"
	"fmt"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/composefile"
	"github.com/adigourdi/kasbah/internal/trace"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

var (
	urlScheme = regexp.MustCompile(`^[A-Za-z0-9+.-]+://`)
	urlTail   = regexp.MustCompile(`[:/].*$`)
	blankURL  = regexp.MustCompile(`^[ \t]*$`)
)

// RoutedHosts is the host of every string loadBalancer server URL in a
// fragment's tree, in file order.
func RoutedHosts(root tree.Value) []string {
	svcs, _ := tree.Lookup(root, "http", "services")
	m, _ := svcs.(*tree.Map)
	if m == nil {
		return nil
	}
	var out []string
	for _, k := range m.Keys() {
		v, _ := m.Get(k)
		servers, _ := tree.Lookup(v, "loadBalancer", "servers")
		l, _ := servers.([]tree.Value)
		for _, s := range l {
			u, _ := tree.Lookup(s, "url")
			str, _ := u.(string)
			host := urlTail.ReplaceAllString(urlScheme.ReplaceAllString(str, ""), "")
			if !blankURL.MatchString(host) {
				out = append(out, host)
			}
		}
	}
	return out
}

// fragmentHosts is RoutedHosts of the fragment file, none when it cannot be read.
func fragmentHosts(path string) []string {
	docs, err := yamlx.LoadFile(path)
	if err != nil || len(docs) != 1 {
		return nil
	}
	return RoutedHosts(docs[0])
}

// projectNet is the compose key of the network a project's routed services
// join and Traefik is connected to.
const projectNet = "kasbah"

// composeModel is what the engine reads of `docker compose config`.
type composeModel struct {
	Networks map[string]struct {
		Name     string   `json:"name"`
		External external `json:"external"`
	} `json:"networks"`
	Services map[string]composeService `json:"services"`
}

// external is a network's external:, true or the old {name: …} mapping.
type external bool

func (x *external) UnmarshalJSON(b []byte) error {
	s := strings.TrimSpace(string(b))
	*x = external(s == "true" || strings.HasPrefix(s, "{"))
	return nil
}

type composeService struct {
	ContainerName string            `json:"container_name"`
	Hostname      string            `json:"hostname"`
	Labels        map[string]string `json:"labels"`
	Image         string            `json:"image"`
	Healthcheck   *struct {
		Test    []string `json:"test"`
		Disable bool     `json:"disable"`
	} `json:"healthcheck"`
	Networks map[string]*struct {
		Aliases []string `json:"aliases"`
	} `json:"networks"`
	Ports []struct {
		Published string `json:"published"`
		HostIP    string `json:"host_ip"`
		Protocol  string `json:"protocol"`
	} `json:"ports"`
	DependsOn map[string]struct {
		Condition string `json:"condition"`
	} `json:"depends_on"`
	Scale  *int `json:"scale"`
	Deploy *struct {
		Replicas *int `json:"replicas"`
	} `json:"deploy"`
}

// roll is one routed service the up swaps beside its running containers;
// stale is its stopped ones, which a scale-up would restart on their old config.
type roll struct {
	svc        string
	host       string
	replicas   int
	old, stale []string
}

// model reads the compose file as compose resolves it, profiles and
// interpolation applied.
func (e *engine) model() (*composeModel, error) {
	return readModel(e.project, e.query)
}

// routedBy is the fragment host svc answers on the project network, "" for
// none, matched in any case as DNS does; a container_name answers on any network.
func routedBy(name string, s composeService, hosts []string) (host string, byContainerName bool) {
	for _, h := range hosts {
		if s.ContainerName != "" && strings.EqualFold(h, s.ContainerName) {
			return h, true
		}
	}
	n, joined := s.Networks[projectNet]
	if !joined {
		return "", false
	}
	names := []string{name}
	if n != nil {
		names = append(names, n.Aliases...)
	}
	for _, h := range hosts {
		if slices.ContainsFunc(names, func(n string) bool { return strings.EqualFold(n, h) }) {
			return h, false
		}
	}
	return "", false
}

// gated is a depends_on entry with a condition only a plain up waits for,
// "" for none.
func gated(s composeService) string {
	for _, d := range sortedKeys(s.DependsOn) {
		if c := s.DependsOn[d].Condition; c != "" && c != "service_started" {
			return d + " (" + c + ")"
		}
	}
	return ""
}

// stay is a routed service the up leaves to compose rather than rolls, and
// why, as "as it sets container_name".
type stay struct{ svc, why string }

// rolls picks the routed services the up swaps rather than recreates, and
// says why each other routed service is left to compose's in-place
// recreate. A service rolls only when every host the live fragment reaches it
// by is one its new replicas answer too: that fragment routes until the run's
// report.
func (e *engine) rolls() (*composeModel, []roll, []stay) {
	if len(e.sp.Routed) == 0 {
		return nil, nil, nil
	}
	m, err := e.model()
	if err != nil {
		e.note("could not read the compose model (%v) — every service is recreated in place", err)
		return nil, nil, nil
	}
	netName := m.netName(e.project)
	live := liveHosts(fragmentHosts(filepath.Join(filepath.Dir(e.dir), "traefik", "dynamic", e.project+".yml")), netName)
	var out []roll
	var stays []stay
	for _, svc := range sortedKeys(m.Services) {
		s := m.Services[svc]
		host, byCN := routedBy(svc, s, e.sp.Routed)
		if host == "" {
			continue
		}
		inPlace := func(why string) { stays = append(stays, stay{svc, why}) }
		shape := shapeOf(s, byCN)
		why := ""
		for _, st := range shape.Stays(e.sp.NoHealthWait) {
			if st == StayNoHealthcheck && shape.Health == HealthUnset && e.imageHealthchecked(s.Image) {
				continue
			}
			why = shape.Why(st)
			break
		}
		if why != "" {
			inPlace("as " + why)
			continue
		}
		old := e.serviceContainers(svc)
		var running, stale []string
		busy := ""
		for _, c := range old {
			switch c.state {
			case "running":
				running = append(running, c.id)
			case "exited", "created", "dead":
				stale = append(stale, c.id)
			default:
				busy = c.name + " is " + c.state
			}
		}
		if len(running) == 0 {
			continue
		}
		if busy != "" {
			inPlace("as its old replica " + busy + ", which the swap would leave behind")
			continue
		}
		if why := e.noRollRunning(old); why != "" {
			inPlace("as " + why)
			continue
		}
		reached := e.reached(running, netName, live)
		if len(reached) == 0 {
			inPlace("as the live route does not reach its running container on " + netName)
			continue
		}
		answers := []string{svc}
		if n := s.Networks[projectNet]; n != nil {
			answers = append(answers, n.Aliases...)
		}
		if h := missing(reached, answers); h != "" {
			inPlace("as the live route targets " + h + ", which its new replicas will not answer")
			continue
		}
		r := roll{svc: svc, host: host, replicas: 1, old: running, stale: stale}
		if s.Deploy != nil && s.Deploy.Replicas != nil {
			r.replicas = *s.Deploy.Replicas
		} else if s.Scale != nil {
			r.replicas = *s.Scale
		}
		if r.replicas < 1 {
			continue
		}
		out = append(out, r)
	}
	return m, out, stays
}

// running is each service's running containers, id to start time; ok is
// false when docker cannot read them.
func (e *engine) running() (map[string]map[string]string, bool) {
	cs, err := containers(e.project, e.query)
	if err != nil {
		return nil, false
	}
	var ids []string
	svcOf := map[string]string{}
	for _, c := range cs {
		if c.running {
			ids = append(ids, c.id)
			svcOf[c.id] = c.svc
		}
	}
	out := map[string]map[string]string{}
	if len(ids) == 0 {
		return out, true
	}
	txt, err := e.query(append([]string{"inspect", "-f", "{{.Id}} {{.State.StartedAt}}"}, ids...)...)
	if err != nil {
		return nil, false
	}
	for _, l := range strings.Split(strings.ReplaceAll(txt, "\r", ""), "\n") {
		id, at, ok := strings.Cut(l, " ")
		if svc := svcOf[id]; ok && svc != "" {
			if out[svc] == nil {
				out[svc] = map[string]string{}
			}
			out[svc][id] = at
		}
	}
	return out, true
}

// noteRecreated names each stay the up took down, whether it succeeded or
// not: one none of whose containers running before it still runs unchanged
// (same id, same start). Every one gone is a recreate, a survivor started
// again a restart; nothing running before is no outage. When docker cannot
// read either side, every stay is named a recreate: the line warns of a 502,
// which is not left unsaid on a guess.
func (e *engine) noteRecreated(stays []stay, before map[string]map[string]string, ok bool) {
	if len(stays) == 0 {
		return
	}
	after, okAfter := e.running()
	for _, st := range stays {
		if ok && okAfter {
			was, now := before[st.svc], after[st.svc]
			kept, gone := false, 0
			for id, at := range was {
				switch started, still := now[id]; {
				case !still:
					gone++
				case started == at:
					kept = true
				}
			}
			if kept || len(was) == 0 {
				continue
			}
			if gone < len(was) {
				e.note("%s was restarted in place, %s — its route answered 502 while it restarted", st.svc, st.why)
				continue
			}
		}
		e.note("%s was recreated in place, %s — its route answered 502 while it was replaced", st.svc, st.why)
	}
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// binds is every host port the model's services publish, by service name.
// compose config splits a range mapped to a range, so a range left is one
// container port's: compose takes a free port of it.
func (m *composeModel) binds() []Bind {
	var bs []Bind
	for _, name := range sortedKeys(m.Services) {
		for _, p := range m.Services[name].Ports {
			if b, ok := ParseBind(p.HostIP, p.Published, p.Protocol); ok {
				b.Svc, b.Any = name, b.Lo < b.Hi
				bs = append(bs, b)
			}
		}
	}
	return bs
}

// containerNames is every container_name the model's services set, by
// service name.
func (m *composeModel) containerNames() []ContainerName {
	var out []ContainerName
	for _, name := range sortedKeys(m.Services) {
		if cn := m.Services[name].ContainerName; cn != "" {
			out = append(out, ContainerName{cn, name})
		}
	}
	return out
}

func published(s composeService) bool {
	for _, p := range s.Ports {
		if p.Published != "" {
			return true
		}
	}
	return false
}

// noRollRunning is why svc's running containers keep it from rolling, "" for
// nothing: one whose own labels ask for no roll, as a version labelled
// kasbah.noRoll is not rolled out of either, whatever the files now in place
// say; or one whose labels cannot be read, which is not rolled on a guess.
func (e *engine) noRollRunning(cs []ctr) string {
	for _, c := range cs {
		if c.state != "running" {
			continue
		}
		out, err := e.query("inspect", "-f", "{{json .Config.Labels}}", c.id)
		var labels map[string]string
		if err == nil {
			err = json.Unmarshal([]byte(out), &labels)
		}
		switch {
		case err != nil:
			return "the labels of its running container " + c.name + " cannot be read (" + err.Error() + ")"
		case NoRoll(labels) != "":
			return "its running container " + c.name + " is labelled " + NoRollLabel
		}
	}
	return ""
}

// shapeOf is the static half of the roll predicate, read off the compose model.
func shapeOf(s composeService, byCN bool) RollShape {
	r := RollShape{ByContainerName: byCN, ContainerName: s.ContainerName != "", Published: published(s), Gated: gated(s)}
	r.NoRoll = NoRoll(s.Labels)
	switch h := s.Healthcheck; {
	case h != nil && (h.Disable || (len(h.Test) > 0 && h.Test[0] == "NONE")):
		r.Health = HealthOff
	case h != nil && len(h.Test) > 0:
		r.Health = HealthDeclared
	case s.Image == "":
		r.Health = HealthOff
	}
	return r
}

// imageHealthchecked is whether the image declares a HEALTHCHECK of its own.
func (e *engine) imageHealthchecked(image string) bool {
	out, err := e.query("image", "inspect", "-f", "{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}", image)
	if err != nil || out == "" || out == "null" {
		return false
	}
	var test []string
	return json.Unmarshal([]byte(out), &test) == nil && len(test) > 0 && test[0] != "NONE"
}

// reached is the live hosts any of the running containers answers on the
// network.
func (e *engine) reached(ids []string, netName string, live []string) []string {
	var out []string
	for _, id := range ids {
		raw, err := e.query("inspect", "-f", "{{json .NetworkSettings.Networks}}", id)
		if err != nil {
			continue
		}
		var nets map[string]struct {
			Aliases  []string `json:"Aliases"`
			DNSNames []string `json:"DNSNames"`
		}
		if json.Unmarshal([]byte(raw), &nets) != nil {
			continue
		}
		n := nets[netName]
		for _, h := range live {
			if (slices.Contains(n.Aliases, h) || slices.Contains(n.DNSNames, h)) && !slices.Contains(out, h) {
				out = append(out, h)
			}
		}
	}
	return out
}

// missing is the first of hosts not among names, "" for none.
func missing(hosts, names []string) string {
	for _, h := range hosts {
		if !slices.Contains(names, h) {
			return h
		}
	}
	return ""
}

// ctr is one container of the compose project, read off its labels.
type ctr struct {
	id, name, svc, state string
	num                  int
	running              bool
}

// projectContainers is the project's containers, one-off runs aside, in
// service then replica-number order; none when docker cannot list them.
func (e *engine) projectContainers() []ctr {
	cs, _ := containers(e.project, e.query)
	return cs
}

// containers lists a compose project's containers through query, a
// `docker ps` read.
func containers(project string, query func(...string) (string, error)) ([]ctr, error) {
	out, err := query("ps", "-a", "--no-trunc",
		"--filter", "label=com.docker.compose.project="+project,
		"--filter", "label=com.docker.compose.oneoff=False",
		"--format", `{{.ID}}	{{.Names}}	{{.Label "com.docker.compose.service"}}	{{.Label "com.docker.compose.container-number"}}	{{.State}}`)
	if err != nil {
		return nil, err
	}
	var cs []ctr
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		f := strings.Split(l, "\t")
		if len(f) != 5 {
			continue
		}
		n, _ := strconv.Atoi(f[3])
		cs = append(cs, ctr{id: f[0], name: f[1], svc: f[2], state: f[4], num: n, running: f[4] == "running"})
	}
	sort.SliceStable(cs, func(i, j int) bool {
		if cs[i].svc != cs[j].svc {
			return cs[i].svc < cs[j].svc
		}
		if cs[i].num != cs[j].num {
			return cs[i].num < cs[j].num
		}
		return cs[i].name < cs[j].name
	})
	return cs, nil
}

func (e *engine) serviceContainers(svc string) []ctr {
	var out []ctr
	for _, c := range e.projectContainers() {
		if c.svc == svc {
			out = append(out, c)
		}
	}
	return out
}

func (e *engine) target(name string) (c string, isSvc bool) {
	return pick(e.projectContainers(), name)
}

// Target is the container a manifest name means in a compose project: that
// container, else the service's lowest-numbered running replica (else its
// first), else the name itself — also when the `docker ps` query fails.
func Target(project, name string, query func(...string) (string, error)) (c string, isSvc bool, err error) {
	cs, err := containers(project, query)
	if err != nil {
		return name, false, err
	}
	c, isSvc = pick(cs, name)
	return c, isSvc, nil
}

func pick(cs []ctr, name string) (string, bool) {
	for _, x := range cs {
		if x.name == name {
			return name, false
		}
	}
	var first string
	for _, x := range cs {
		if x.svc != name {
			continue
		}
		if x.running {
			return x.name, true
		}
		if first == "" {
			first = x.name
		}
	}
	if first != "" {
		return first, true
	}
	return name, false
}

// upStack brings the stack up: every service but the rolled ones in place, then
// each rolled one beside its old containers. The reason names the failure.
func (e *engine) upStack() (string, error) {
	if e.noSvc = composefile.Serviceless(e.dir); e.noSvc {
		return "up", e.up()
	}
	m, rs, stays := e.rolls()
	var before map[string]map[string]string
	listed := false
	if len(stays) > 0 {
		before, listed = e.running()
	}
	if len(rs) == 0 {
		err := e.up()
		e.noteRecreated(stays, before, listed)
		if err != nil {
			return "up", failf("docker compose -p %s up -d --remove-orphans failed in %s", e.project, e.dir)
		}
		return "", nil
	}
	var rest []string
	for _, svc := range sortedKeys(m.Services) {
		if !slices.ContainsFunc(rs, func(r roll) bool { return r.svc == svc }) {
			rest = append(rest, svc)
		}
	}
	if len(rest) > 0 {
		args := append([]string{"compose", "-p", e.project, "up", "-d", "--no-deps", "--remove-orphans"}, rest...)
		err := trace.Run(e.docker(args...))
		e.noteRecreated(stays, before, listed)
		if err != nil {
			return "up", failf("docker compose -p %s up -d --no-deps --remove-orphans %s failed in %s", e.project, strings.Join(rest, " "), e.dir)
		}
	}
	for _, r := range rs {
		if reason, err := e.roll(r); err != nil {
			return reason, err
		}
	}
	return "", nil
}

// roll removes r's stopped containers, starts its new replicas beside the
// running ones, waits on them, then stops and removes the old ones by id. A
// new replica that fails is removed and the running old ones are left as they were.
func (e *engine) roll(r roll) (string, error) {
	for _, id := range r.stale {
		if trace.Run(e.docker("rm", id)) != nil {
			return "up", failf("could not remove %s's stopped container %s, which the scale-up would restart on its old config", r.svc, short(id))
		}
		e.note("%s: removed the stopped old container %s", r.svc, short(id))
	}
	n := len(r.old) + r.replicas
	e.note("%s: starting %d new replica(s) beside the running one(s), which keep serving %s", r.svc, r.replicas, r.host)
	err := trace.Run(e.docker("compose", "-p", e.project, "up", "-d", "--no-deps", "--no-recreate", "--remove-orphans",
		"--scale", fmt.Sprintf("%s=%d", r.svc, n), r.svc))
	var fresh []string
	for _, c := range e.serviceContainers(r.svc) {
		if !slices.Contains(r.old, c.id) {
			fresh = append(fresh, c.id)
		}
	}
	drop := func() {
		for _, id := range fresh {
			if trace.Run(e.docker("rm", "-f", id)) == nil {
				e.note("%s: removed the new replica %s; the old container(s) were not touched", r.svc, short(id))
			}
		}
	}
	if err != nil || len(fresh) != r.replicas {
		drop()
		return "up", failf("docker compose -p %s up --scale %s=%d did not start %d new %s replica(s) in %s", e.project, r.svc, n, r.replicas, r.svc, e.dir)
	}
	if err := e.healthWait(fresh); err != nil {
		drop()
		return "health", err
	}
	for _, id := range r.old {
		if trace.Run(e.docker("stop", id)) != nil || trace.Run(e.docker("rm", id)) != nil {
			return "up", failf("could not stop and remove %s's old container %s — both versions of %s may be serving", r.svc, short(id), r.host)
		}
		e.note("%s: stopped and removed the old container %s", r.svc, short(id))
	}
	return "", nil
}

func short(id string) string {
	if len(id) > 12 {
		return id[:12]
	}
	return id
}
