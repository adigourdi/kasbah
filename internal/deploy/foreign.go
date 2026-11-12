package deploy

import (
	"fmt"
	"net/netip"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/traefiknet"
)

// Bind is a host port range published on an address: "" for every address
// of both families, 0.0.0.0 every IPv4 one, :: every IPv6 one.
type Bind struct {
	IP    string `json:"ip,omitempty"`
	Lo    int    `json:"lo"`
	Hi    int    `json:"hi"`
	Proto string `json:"proto"`
	// Any is a range mapped to one container port: compose takes a free one.
	Any bool `json:"-"`
	// Svc is the compose service publishing it, for a project's own binds.
	Svc string `json:"-"`
}

func (b Bind) String() string {
	s := strconv.Itoa(b.Lo)
	if b.Hi != b.Lo {
		s += "-" + strconv.Itoa(b.Hi)
	}
	if b.IP != "" {
		ip := b.IP
		if strings.Contains(ip, ":") {
			ip = "[" + ip + "]"
		}
		s = ip + ":" + s
	}
	return s + "/" + b.Proto
}

// collides is whether a and b claim one port: same protocol, overlapping
// ranges, and an address in common.
func (a Bind) collides(b Bind) bool {
	return a.Proto == b.Proto && a.Lo <= b.Hi && b.Lo <= a.Hi && addrsMeet(a.IP, b.IP)
}

// addrsMeet: none given is both wildcards, which meet every address; a
// wildcard meets its own family's addresses; any other only itself.
func addrsMeet(a, b string) bool {
	wild := func(ip string) bool { return ip == "0.0.0.0" || ip == "::" }
	v6 := func(ip string) bool { return strings.Contains(ip, ":") }
	return a == "" || b == "" || a == b || (wild(a) || wild(b)) && v6(a) == v6(b)
}

// canonAddr is ip without brackets, in netip's canonical form when it parses.
func canonAddr(ip string) string {
	ip = strings.TrimSuffix(strings.TrimPrefix(ip, "["), "]")
	if a, err := netip.ParseAddr(ip); err == nil {
		return a.Unmap().String()
	}
	return ip
}

// ParseBind is a published host port (a port or a "lo-hi" range) on ip,
// false when it names none.
func ParseBind(ip, published, proto string) (Bind, bool) {
	lo, hi, ok := portRange(published)
	if !ok {
		return Bind{}, false
	}
	if proto == "" {
		proto = "tcp"
	}
	return Bind{IP: canonAddr(ip), Lo: lo, Hi: hi, Proto: strings.ToLower(proto)}, true
}

// ParseShortPort reads "[ip:]host[-range]:container[-range][/proto]": ok is
// false for a bare container port or an ip with no host port (they publish
// none), err for a host port that is not one.
func ParseShortPort(s string) (b Bind, ok bool, err error) {
	s, proto, _ := strings.Cut(strings.TrimSpace(s), "/")
	ip := ""
	if strings.HasPrefix(s, "[") {
		end := strings.Index(s, "]:")
		if end < 0 {
			return Bind{}, false, fmt.Errorf("%q has no ]: after its address", s)
		}
		ip, s = s[1:end], s[end+2:]
	}
	f := strings.Split(s, ":")
	switch {
	case len(f) < 2:
		return Bind{}, false, nil
	case ip == "" && len(f) > 2:
		ip = strings.Join(f[:len(f)-2], ":")
	}
	host := f[len(f)-2]
	if strings.TrimSpace(host) == "" {
		return Bind{}, false, nil
	}
	if b, ok = ParseBind(ip, host, proto); !ok {
		return Bind{}, false, fmt.Errorf("%q is not a host port or range", host)
	}
	b.Any = b.Lo < b.Hi && !strings.Contains(f[len(f)-1], "-")
	return b, true, nil
}

func portRange(s string) (int, int, bool) {
	a, b, isRange := strings.Cut(strings.TrimSpace(s), "-")
	lo, err := strconv.Atoi(a)
	if err != nil || lo <= 0 || lo > 65535 {
		return 0, 0, false
	}
	hi := lo
	if isRange {
		if hi, err = strconv.Atoi(b); err != nil || hi < lo || hi > 65535 {
			return 0, 0, false
		}
	}
	return lo, hi, true
}

// Holder is a container outside the project that may collide with it, as
// `docker ps -a` reads it; Ports only while it runs.
type Holder struct {
	Name    string `json:"name"`
	Project string `json:"project,omitempty"`
	Dir     string `json:"working_dir,omitempty"`
	Config  string `json:"config_files,omitempty"`
	Ports   []Bind `json:"ports,omitempty"`
}

const holderFormat = `{{.Names}}	{{.State}}	{{.Label "com.docker.compose.project"}}	{{.Label "com.docker.compose.project.working_dir"}}	{{.Label "com.docker.compose.project.config_files"}}	{{.Ports}}`

// Outsiders is every container on the host that is not the project name's
// at dir and could collide with it — one publishing a port while it runs,
// and any, running or not, of a compose project called name — by name.
func Outsiders(name, dir string, query func(...string) (string, error)) ([]Holder, error) {
	out, err := query("ps", "-a", "--format", holderFormat)
	if err != nil {
		return nil, err
	}
	ours := []string{dir}
	if real, err := filepath.EvalSymlinks(dir); err == nil && real != dir {
		ours = append(ours, real)
	}
	hs := []Holder{}
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		f := strings.Split(l, "\t")
		if len(f) != 6 {
			continue
		}
		h := Holder{Name: f[0], Project: f[2], Dir: f[3], Config: f[4]}
		if h.Project == name && slices.Contains(ours, h.Dir) {
			continue
		}
		if f[1] == "running" || f[1] == "paused" || f[1] == "restarting" {
			h.Ports = dockerPorts(f[5])
		}
		if h.Project == name || len(h.Ports) > 0 {
			hs = append(hs, h)
		}
	}
	sort.SliceStable(hs, func(i, j int) bool { return hs[i].Name < hs[j].Name })
	return hs, nil
}

// dockerPorts reads `docker ps`'s Ports column ("0.0.0.0:8080->80/tcp,
// [::]:8080->80/tcp, 80/tcp"): the published ones alone, a range on both
// wildcards as one on every address.
func dockerPorts(s string) []Bind {
	var bs []Bind
	for _, p := range strings.Split(s, ",") {
		host, ctr, ok := strings.Cut(strings.TrimSpace(p), "->")
		if !ok {
			continue
		}
		_, proto, _ := strings.Cut(ctr, "/")
		i := strings.LastIndex(host, ":")
		if i < 0 {
			continue
		}
		if b, ok := ParseBind(host[:i], host[i+1:], proto); ok && !slices.Contains(bs, b) {
			bs = append(bs, b)
		}
	}
	for i := 0; i < len(bs); i++ {
		if bs[i].IP != "0.0.0.0" {
			continue
		}
		v6 := bs[i]
		v6.IP = "::"
		if j := slices.Index(bs, v6); j >= 0 {
			bs[i].IP = ""
			bs = slices.Delete(bs, j, j+1)
		}
	}
	return bs
}

// ownStacks is kasbah's own compose projects on every server, by name.
var ownStacks = map[string]string{traefiknet.Project: "Traefik", mail.Project: "mail", backup.Project: "backup"}

// Collisions is why the project name at dir, publishing binds, cannot come
// up beside the holders: each other compose project of its name, then each
// port a holder already publishes. Empty when it can.
func Collisions(name, dir string, binds []Bind, hs []Holder) []string {
	var out []string
	type stack struct {
		dir, config string
		names       []string
	}
	var named []*stack
	for _, h := range hs {
		if h.Project != name {
			continue
		}
		i := slices.IndexFunc(named, func(s *stack) bool { return s.dir == h.Dir })
		if i < 0 {
			named = append(named, &stack{dir: h.Dir, config: h.Config})
			i = len(named) - 1
		}
		named[i].names = append(named[i].names, h.Name)
	}
	for _, s := range named {
		from, down := "with no working directory recorded", "where it was started"
		if s.dir != "" {
			from, down = "from "+s.dir, "in "+s.dir
		}
		if s.config != "" {
			from += " (" + s.config + ")"
		}
		head := fmt.Sprintf("a compose project named %s already exists outside %s: %s, started %s — ", name, dir, strings.Join(s.names, ", "), from)
		if own, ok := ownStacks[name]; ok {
			out = append(out, head+fmt.Sprintf("it is kasbah's own %s stack, and Docker keys compose projects by name, so this project's up would take its containers for its own; rename this project", own))
			continue
		}
		out = append(out, head+fmt.Sprintf("Docker keys compose projects by name, so this project's up would take its containers for its own; run `docker compose -p %s down` %s, or rename this project", name, down))
	}
	for _, b := range binds {
		if b.Any {
			if held := rangeHeld(b, hs); held != nil {
				out = append(out, fmt.Sprintf("every port of %s, the range service %s of this project publishes one port from, is taken: %s — stop or move one of those containers, or change the range %s publishes",
					b, b.Svc, strings.Join(held, ", "), b.Svc))
			}
			continue
		}
		for _, h := range hs {
			i := slices.IndexFunc(h.Ports, b.collides)
			if i < 0 {
				continue
			}
			out = append(out, fmt.Sprintf("container %s (%s) publishes %s, which service %s of this project publishes too — stop or move that container, or change the port %s publishes",
				h.Name, whose(h), h.Ports[i], b.Svc, b.Svc))
		}
	}
	return out
}

// rangeHeld names who holds the ports of b, nil when one of them is free.
func rangeHeld(b Bind, hs []Holder) []string {
	var held []string
	for p := b.Lo; p <= b.Hi; p++ {
		one := b
		one.Lo, one.Hi = p, p
		taken := false
		for _, h := range hs {
			for _, hb := range h.Ports {
				if one.collides(hb) {
					taken = true
					if w := fmt.Sprintf("container %s (%s) publishes %s", h.Name, whose(h), hb); !slices.Contains(held, w) {
						held = append(held, w)
					}
				}
			}
		}
		if !taken {
			return nil
		}
	}
	return held
}

func whose(h Holder) string {
	if h.Project != "" {
		return "compose project " + h.Project
	}
	return "not a compose container"
}
