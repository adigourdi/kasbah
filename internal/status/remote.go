package status

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/composefile"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/probe"
	"github.com/adigourdi/kasbah/internal/trace"
	"github.com/adigourdi/kasbah/internal/traefiknet"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// Stack is one container of a compose stack: State is absent, nodocker,
// unknown or docker's own status.
type Stack struct {
	State    string `json:"state"`
	Health   string `json:"health"`
	Restarts string `json:"restarts"`
}

// Traefik is the proxy container, Present false when there is none.
type Traefik struct {
	Present   bool   `json:"present"`
	State     string `json:"state"`
	Health    string `json:"health"`
	Image     string `json:"image"`
	ImageID   string `json:"image_id"`
	Container string `json:"container"`
}

// Container is one container of a project.
type Container struct {
	Name   string `json:"name"`
	State  string `json:"state"`
	Health string `json:"health"`
}

// Project is one entry under <apps>. LogState: ok missing empty notfile unreadable
// noaccess notdir; FragState: ok unparsed absent empty unreadable notfile. Hosts
// is an ok fragment's hosts: it may hold secrets, so it stays on the server.
type Project struct {
	Name       string      `json:"name"`
	Total      int         `json:"total"`
	Running    int         `json:"running"`
	LogState   string      `json:"log_state"`
	Log        string      `json:"log"`
	FragState  string      `json:"frag_state"`
	Hosts      []FragHost  `json:"frag_hosts"`
	Containers []Container `json:"containers"`
	// Leftovers is what runs left in the directory that may hold .env.
	Leftovers deploy.Leftovers `json:"leftovers"`
	// Serviceless: compose.yml declares no service, so no container is expected.
	Serviceless bool `json:"serviceless"`
}

// FragHost is one host a fragment's routers name: Plain when Traefik serves
// it over plain HTTP only, else the resolver whose store holds its certificate.
type FragHost struct {
	Host     string `json:"host"`
	Plain    bool   `json:"plain,omitempty"`
	Resolver string `json:"resolver,omitempty"`
}

// fragmentFacts is an installed fragment's state and its hosts.
func fragmentFacts(path string) (string, []FragHost) {
	raw, err := os.ReadFile(path)
	switch {
	case err != nil:
		return "unreadable", nil
	case len(raw) == 0:
		return "empty", nil
	}
	return FragmentHosts(raw)
}

// FragmentHosts is a fragment's state, ok or unparsed, and what it says of
// each host it routes, in router order.
func FragmentHosts(raw []byte) (string, []FragHost) {
	root, ok := ParseFragment(raw)
	if !ok {
		return "unparsed", nil
	}
	routes := acme.Routes(root)
	hosts := []FragHost{}
	for _, h := range acme.Hosts(routes) {
		if acme.PlainHTTP(raw, root, h) {
			hosts = append(hosts, FragHost{Host: h, Plain: true})
		} else {
			hosts = append(hosts, FragHost{Host: h, Resolver: acme.ResolverFor(routes, h)})
		}
	}
	return "ok", hosts
}

// Foreign is a container kasbah does not manage; Health is none without a
// healthcheck.
type Foreign struct {
	Name   string `json:"name"`
	Image  string `json:"image"`
	State  string `json:"state"`
	Health string `json:"health"`
}

// Disk is `df -Pk`'s last line for a path: State ok, absent, nopath or error.
type Disk struct {
	State string `json:"state"`
	Line  string `json:"line"`
}

// Report is everything `server status` reads, in one round trip, with
// nothing written. File bodies are base64.
type Report struct {
	HaveDocker     bool   `json:"have_docker"`
	DockerServer   string `json:"docker_server"`
	DockerError    string `json:"docker_error"`
	ComposeVersion string `json:"compose_version"`

	AppsState   string `json:"apps_state"`
	MarkerState string `json:"marker_state"`
	Marker      string `json:"marker_b64"`
	DataPath    string `json:"data_path"`

	AppsDisk Disk `json:"apps_df"`
	DataDisk Disk `json:"data_df"`

	AcmeState   string `json:"acme_state"`
	Acme        string `json:"acme_b64"`
	SharedState string `json:"shared_state"`
	Shared      string `json:"shared_b64"`

	MailDir       string `json:"mail_dir"`
	RegistryState string `json:"registry_state"`
	Registry      string `json:"registry_b64"`
	MailDMS       Stack  `json:"mail_dms"`
	MailWeb       Stack  `json:"mail_web"`

	Backup   backuprec.Facts `json:"backup"`
	Traefik  Traefik         `json:"traefik"`
	Projects []Project       `json:"projects"`
	Foreign  []Foreign       `json:"foreign"`
	// ForeignError is docker's answer when it could not list the containers.
	ForeignError string `json:"foreign_error,omitempty"`
}

// Remote is `kasbah remote status APPS`, run by the server binary.
func Remote(args []string, stdout, stderr io.Writer) int {
	if len(args) != 1 || !strings.HasPrefix(args[0], "/") {
		fmt.Fprintln(stderr, "remote: usage: kasbah remote status APPS")
		return 1
	}
	if err := json.NewEncoder(stdout).Encode(Collect(args[0])); err != nil {
		fmt.Fprintf(stderr, "remote: %v\n", err)
		return 1
	}
	return 0
}

// Collect reads the server it runs on.
func Collect(apps string) *Report {
	r := &Report{HaveDocker: probe.HaveDocker(), Projects: []Project{}, Foreign: []Foreign{}}
	out, rc := probe.DockerAll("version", "--format", "{{.Server.Version}}")
	docker := rc == 0
	if docker {
		r.DockerServer = probe.Flat(out)
	} else {
		r.DockerError = probe.Flat(out)
		if !r.HaveDocker {
			r.DockerError = ""
		}
	}
	cv, _ := probe.Docker("compose", "version", "--short")
	r.ComposeVersion = probe.Flat(cv)

	r.AppsState = probe.DirState(apps)
	marker := apps + "/.kasbah/server.json"
	r.MarkerState = "absent"
	if fi, err := os.Stat(marker); err == nil {
		switch {
		case !fi.Mode().IsRegular():
			r.MarkerState = "notfile"
		case fi.Size() == 0:
			r.MarkerState = "empty"
		default:
			if r.Marker = probe.B64(marker); r.Marker != "" {
				r.MarkerState = "ok"
			} else {
				r.MarkerState = "unreadable"
			}
		}
	}
	if r.MarkerState == "ok" {
		if b, err := os.ReadFile(marker); err == nil {
			if m, err := tree.ParseOne(b); err == nil {
				if v, ok := tree.Lookup(m, "data_path"); ok {
					if s, ok := v.(string); ok {
						r.DataPath = s
					}
				}
			}
		}
	}
	data := r.DataPath

	r.AppsDisk = disk(apps)
	r.DataDisk = disk(data)
	acme := ""
	if data != "" {
		acme = data + "/traefik/letsencrypt/acme.json"
	}
	r.AcmeState, r.Acme = probe.FState(acme), probe.B64(acme)
	shared := apps + "/traefik/dynamic/_shared.yml"
	r.SharedState, r.Shared = probe.FState(shared), probe.B64(shared)

	r.MailDir = probe.DirState(apps + "/mail")
	reg := apps + "/mail/kasbah.yml"
	r.RegistryState, r.Registry = probe.FState(reg), probe.B64(reg)
	stacks := Stacks(apps, data)
	r.MailDMS = stack(docker, stacks[mail.Project], mail.Project, "mail-dms")
	r.MailWeb = stack(docker, stacks[mail.Project], mail.Project, "mail-cypht")

	r.Backup = backuprec.Collect(apps, data)
	r.Traefik = traefik(docker, stacks[traefiknet.Project])
	if r.AppsState == "dir" {
		r.Projects = projects(apps, docker)
	}
	if docker {
		r.Foreign, r.ForeignError = foreign(stacks, probe.DockerAll)
	}
	return r
}

// RoleLabel is the label key kasbah's own short-lived containers carry.
const RoleLabel = "kasbah.role"

// Stacks is every compose project kasbah runs under apps, by name: the
// Traefik, mail and backup stacks and each entry that is not reserved or the
// data path, each run from its own directory.
func Stacks(apps, data string) map[string]func(project, wdir string) bool {
	st := map[string]func(string, string) bool{
		traefiknet.Project: probe.Owns(traefiknet.Project, apps+"/traefik"),
		mail.Project:       probe.Owns(mail.Project, apps+"/mail"),
		backup.Project:     probe.Owns(backup.Project, apps+"/.kasbah/backup"),
	}
	ents, _ := os.ReadDir(apps)
	for _, e := range ents {
		if n := e.Name(); !probe.IsReserved(n) && apps+"/"+n != data {
			st[n] = probe.Owns(n, apps+"/"+n)
		}
	}
	return st
}

const foreignFormat = `{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.State}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Label "` +
	backup.LauncherLabel + `"}}\t{{.Label "` + RoleLabel + `"}}`

// foreign is every container, in any state, that is neither of a stack
// kasbah runs nor one of its labelled short-lived ones.
func foreign(stacks map[string]func(string, string) bool, docker func(...string) (string, int)) ([]Foreign, string) {
	out, rc := docker("ps", "-a", "--no-trunc", "--format", foreignFormat)
	if rc != 0 {
		return []Foreign{}, or(probe.Flat(out), fmt.Sprintf("docker ps exited %d", rc))
	}
	var ids []string
	byID := map[string]*Foreign{}
	for _, l := range probe.Lines(strings.ReplaceAll(out, "\r", "")) {
		f := strings.Split(l, "\t")
		if len(f) != 8 || f[0] == "" {
			continue
		}
		if own, ok := stacks[f[4]]; f[4] != "" && ok && own(f[4], f[5]) || f[6] != "" || f[7] != "" {
			continue
		}
		ids = append(ids, f[0])
		byID[f[0]] = &Foreign{Name: f[1], Image: f[2], State: f[3], Health: "none"}
	}
	fs := []Foreign{}
	if len(ids) == 0 {
		return fs, ""
	}
	info, _ := docker(append([]string{"inspect", "-f", "{{.Id}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"}, ids...)...)
	for _, l := range probe.Lines(strings.ReplaceAll(info, "\r", "")) {
		if id, h, ok := strings.Cut(l, " "); ok && byID[id] != nil && h != "" {
			byID[id].Health = h
		}
	}
	for _, id := range ids {
		fs = append(fs, *byID[id])
	}
	return fs, ""
}

// owned is project's containers (of service, when given) in any state, newest
// first, that own says are kasbah's stack and not one sharing its label, and
// how many of them run.
func owned(project string, own func(string, string) bool, service string) (ids []string, running int) {
	svc := "label=com.docker.compose.service"
	if service != "" {
		svc += "=" + service
	}
	out, rc := probe.Docker("ps", "-a", "--no-trunc", "--filter", "label=com.docker.compose.project="+project, "--filter", svc,
		"--format", `{{.ID}}\t{{.State}}\t{{.Label "com.docker.compose.project.working_dir"}}`)
	if rc != 0 || own == nil {
		return nil, 0
	}
	for _, l := range probe.Lines(strings.ReplaceAll(out, "\r", "")) {
		f := strings.Split(l, "\t")
		if len(f) != 3 || f[0] == "" || !own(project, f[2]) {
			continue
		}
		ids = append(ids, f[0])
		if f[1] == "running" || f[1] == "paused" || f[1] == "restarting" {
			running++
		}
	}
	return ids, running
}

func disk(path string) Disk {
	if path == "" {
		return Disk{State: "nopath"}
	}
	if _, err := os.Stat(path); err != nil {
		return Disk{State: "absent"}
	}
	out, err := trace.Output(exec.Command("df", "-Pk", path))
	last := ""
	if err == nil {
		for _, l := range strings.Split(string(out), "\n") {
			if l != "" {
				last = l
			}
		}
	}
	if last == "" || strings.HasPrefix(last, "Filesystem") {
		return Disk{State: "error"}
	}
	return Disk{State: "ok", Line: last}
}

func stack(docker bool, own func(string, string) bool, project, service string) Stack {
	if !docker {
		return Stack{State: "nodocker"}
	}
	ids, _ := owned(project, own, service)
	id := ""
	if len(ids) > 0 {
		id = ids[0]
	}
	if id == "" {
		return Stack{State: "absent"}
	}
	line, _ := probe.Docker("inspect", "-f",
		"{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}}", id)
	f := strings.Fields(probe.Flat(line))
	s := Stack{State: "unknown"}
	if len(f) > 0 {
		s.State = f[0]
	}
	if len(f) > 1 {
		s.Health = f[1]
	}
	if len(f) > 2 {
		s.Restarts = strings.Join(f[2:], " ")
	}
	return s
}

func traefik(docker bool, own func(string, string) bool) Traefik {
	if !docker {
		return Traefik{}
	}
	ids, _ := owned(traefiknet.Project, own, "traefik")
	cid := ""
	if len(ids) > 0 {
		cid = ids[0]
	}
	if cid == "" {
		return Traefik{}
	}
	q := func(format string) string {
		out, _ := probe.Docker("inspect", "-f", format, cid)
		return probe.Flat(out)
	}
	return Traefik{
		Present:   true,
		State:     q("{{.State.Status}}"),
		Health:    q("{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"),
		Image:     q("{{.Config.Image}}"),
		ImageID:   q("{{.Image}}"),
		Container: strings.TrimPrefix(q("{{.Name}}"), "/"),
	}
}

func projects(apps string, docker bool) []Project {
	ents, err := os.ReadDir(apps)
	if err != nil {
		return []Project{}
	}
	out := []Project{}
	for _, e := range ents {
		name := e.Name()
		if probe.IsReserved(name) {
			continue
		}
		path := apps + "/" + name
		p := Project{Name: name, LogState: "missing", FragState: "absent", Containers: []Container{}, Leftovers: deploy.NoLeftovers()}

		frag := apps + "/traefik/dynamic/" + name + ".yml"
		if fi, err := os.Stat(frag); err == nil {
			switch {
			case !fi.Mode().IsRegular():
				p.FragState = "notfile"
			case !probe.Readable(frag):
				p.FragState = "unreadable"
			default:
				p.FragState, p.Hosts = fragmentFacts(frag)
			}
		}

		if probe.DirState(path) != "dir" {
			p.LogState = "notdir"
			out = append(out, p)
			continue
		}
		if deploy.IsProject(apps, name) {
			p.Leftovers = deploy.ScanAgainstLock(path)
		}
		p.Serviceless = composefile.Serviceless(path)
		if docker {
			ids, running := owned(name, probe.Owns(name, path), "")
			p.Total, p.Running = len(ids), running
			if len(ids) > 0 {
				info, _ := probe.Docker(append([]string{"inspect", "-f",
					"{{.Name}} {{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"}, ids...)...)
				for _, l := range probe.Lines(info) {
					f := strings.SplitN(l, " ", 3)
					c := Container{Name: strings.TrimPrefix(f[0], "/"), State: "unknown", Health: "none"}
					if c.Name == "" {
						continue
					}
					if len(f) > 1 && f[1] != "" {
						c.State = f[1]
					}
					if len(f) > 2 && f[2] != "" {
						c.Health = f[2]
					}
					p.Containers = append(p.Containers, c)
				}
			}
		}

		log := path + "/versions.log"
		switch fi, err := os.Stat(log); {
		case !probe.Enterable(path):
			p.LogState = "noaccess"
		case err != nil:
		case !fi.Mode().IsRegular():
			p.LogState = "notfile"
		case !probe.Readable(log):
			p.LogState = "unreadable"
		default:
			b, err := os.ReadFile(log)
			if err != nil {
				p.LogState = "unreadable"
				break
			}
			if p.Log = vlog.Last(b); p.Log != "" {
				p.LogState = "ok"
			} else {
				p.LogState = "empty"
			}
		}
		out = append(out, p)
	}
	return out
}
