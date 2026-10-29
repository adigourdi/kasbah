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
		Name string `json:"name"`
	} `json:"networks"`
	Services map[string]composeService `json:"services"`
}

type composeService struct {
	ContainerName string `json:"container_name"`
	Image         string `json:"image"`
	Healthcheck   *struct {
		Test    []string `json:"test"`
		Disable bool     `json:"disable"`
	} `json:"healthcheck"`
	Networks map[string]*struct {
		Aliases []string `json:"aliases"`
	} `json:"networks"`
	Ports []struct {
		Published string `json:"published"`
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
	out, err := e.query("compose", "-p", e.project, "config", "--format", "json")
	if err != nil {
		return nil, err
	}
	var m composeModel
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		return nil, err
	}
	return &m, nil
}

// routedBy is the fragment host svc answers on the project network, "" for
// none; a container_name answers on any network.
func routedBy(name string, s composeService, hosts []string) (host string, byContainerName bool) {
	for _, h := range hosts {
		if s.ContainerName != "" && h == s.ContainerName {
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
		if slices.Contains(names, h) {
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

// rolls picks the routed services the up swaps rather than recreates, and
// says why each other routed service is recreated in place. A service rolls
// only when every host the live fragment reaches it by is one its new
// replicas answer too: that fragment routes until the run's report.
func (e *engine) rolls() (*composeModel, []roll) {
	if len(e.sp.Routed) == 0 {
		return nil, nil
	}
	m, err := e.model()
	if err != nil {
		e.note("could not read the compose model (%v) — every service is recreated in place", err)
		return nil, nil
	}
	netName := e.project + "_" + projectNet
	if n, ok := m.Networks[projectNet]; ok && n.Name != "" {
		netName = n.Name
	}
	live := fragmentHosts(filepath.Join(filepath.Dir(e.dir), "traefik", "dynamic", e.project+".yml"))
	var out []roll
	for _, svc := range sortedKeys(m.Services) {
		s := m.Services[svc]
		host, byCN := routedBy(svc, s, e.sp.Routed)
		if host == "" {
			continue
		}
		inPlace := func(why string) {
			e.note("%s is recreated in place, %s — its route answers 502 until the new container is up", svc, why)
		}
		switch {
		case byCN:
			inPlace("as the fragment targets its container_name")
			continue
		case s.ContainerName != "":
			inPlace("as it sets container_name")
			continue
		case e.sp.NoHealthWait:
			inPlace("as --no-health-wait leaves nothing to swap on")
			continue
		case published(s):
			inPlace("as it publishes a host port a second replica cannot bind")
			continue
		case !e.healthchecked(s):
			inPlace("as it declares no healthcheck to swap on")
			continue
		case gated(s) != "":
			inPlace("as it depends_on " + gated(s) + ", a condition only a plain up waits for")
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
	return m, out
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

func published(s composeService) bool {
	for _, p := range s.Ports {
		if p.Published != "" {
			return true
		}
	}
	return false
}

// healthchecked is compose's healthcheck, else the image's.
func (e *engine) healthchecked(s composeService) bool {
	if h := s.Healthcheck; h != nil && (h.Disable || (len(h.Test) > 0 && h.Test[0] == "NONE")) {
		return false
	} else if h != nil && len(h.Test) > 0 {
		return true
	}
	if s.Image == "" {
		return false
	}
	out, err := e.query("image", "inspect", "-f", "{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}", s.Image)
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
// service then replica-number order.
func (e *engine) projectContainers() []ctr {
	out, err := e.query("ps", "-a", "--no-trunc",
		"--filter", "label=com.docker.compose.project="+e.project,
		"--filter", "label=com.docker.compose.oneoff=False",
		"--format", `{{.ID}}	{{.Names}}	{{.Label "com.docker.compose.service"}}	{{.Label "com.docker.compose.container-number"}}	{{.State}}`)
	if err != nil {
		return nil
	}
	var cs []ctr
	for _, l := range strings.Split(out, "\n") {
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
	return cs
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

// target is the container a manifest name means: the project's container of
// that name, else the service's first running replica (its first container
// when none runs), else the name itself; isSvc says it named a service.
func (e *engine) target(name string) (c string, isSvc bool) {
	cs := e.projectContainers()
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
	m, rs := e.rolls()
	if len(rs) == 0 {
		if e.up() != nil {
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
		if e.docker(args...).Run() != nil {
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
		if e.docker("rm", id).Run() != nil {
			return "up", failf("could not remove %s's stopped container %s, which the scale-up would restart on its old config", r.svc, short(id))
		}
		e.note("%s: removed the stopped old container %s", r.svc, short(id))
	}
	n := len(r.old) + r.replicas
	e.note("%s: starting %d new replica(s) beside the running one(s), which keep serving %s", r.svc, r.replicas, r.host)
	err := e.docker("compose", "-p", e.project, "up", "-d", "--no-deps", "--no-recreate", "--remove-orphans",
		"--scale", fmt.Sprintf("%s=%d", r.svc, n), r.svc).Run()
	var fresh []string
	for _, c := range e.serviceContainers(r.svc) {
		if !slices.Contains(r.old, c.id) {
			fresh = append(fresh, c.id)
		}
	}
	drop := func() {
		for _, id := range fresh {
			if e.docker("rm", "-f", id).Run() == nil {
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
		if e.docker("stop", id).Run() != nil || e.docker("rm", id).Run() != nil {
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
