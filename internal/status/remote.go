package status

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/probe"
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

// Project is one entry under <apps>. LogState is ok, missing, empty, notfile,
// unreadable, noaccess or notdir; FragState is ok, absent, empty, unreadable
// or notfile.
type Project struct {
	Name       string      `json:"name"`
	Total      int         `json:"total"`
	Running    int         `json:"running"`
	LogState   string      `json:"log_state"`
	Log        string      `json:"log"`
	FragState  string      `json:"frag_state"`
	Frag       string      `json:"frag_b64"`
	Containers []Container `json:"containers"`
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
	r := &Report{HaveDocker: probe.HaveDocker(), Projects: []Project{}}
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
	r.MailDMS = stack(docker, "mail", "mail-dms")
	r.MailWeb = stack(docker, "mail", "mail-cypht")

	r.Backup = backuprec.Collect(apps, data)
	r.Traefik = traefik(docker)
	if r.AppsState == "dir" {
		r.Projects = projects(apps, docker)
	}
	return r
}

func disk(path string) Disk {
	if path == "" {
		return Disk{State: "nopath"}
	}
	if _, err := os.Stat(path); err != nil {
		return Disk{State: "absent"}
	}
	out, err := exec.Command("df", "-Pk", path).Output()
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

func first(ids string) string {
	id, _, _ := strings.Cut(ids, "\n")
	return id
}

func stack(docker bool, project, service string) Stack {
	if !docker {
		return Stack{State: "nodocker"}
	}
	ids, rc := probe.Docker("ps", "-a", "--filter", "label=com.docker.compose.project="+project,
		"--filter", "label=com.docker.compose.service="+service, "--format", "{{.ID}}")
	id := ""
	if rc == 0 {
		id = first(ids)
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

func traefik(docker bool) Traefik {
	if !docker {
		return Traefik{}
	}
	ids, rc := probe.Docker("ps", "-a", "--filter", "label=com.docker.compose.project=traefik",
		"--filter", "label=com.docker.compose.service=traefik", "--format", "{{.ID}}")
	cid := ""
	if rc == 0 {
		cid = first(ids)
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
		p := Project{Name: name, LogState: "missing", FragState: "absent", Containers: []Container{}}

		frag := apps + "/traefik/dynamic/" + name + ".yml"
		if fi, err := os.Stat(frag); err == nil {
			switch {
			case !fi.Mode().IsRegular():
				p.FragState = "notfile"
			case !probe.Readable(frag):
				p.FragState = "unreadable"
			default:
				if p.Frag = probe.B64(frag); p.Frag != "" {
					p.FragState = "ok"
				} else {
					p.FragState = "empty"
				}
			}
		}

		if probe.DirState(path) != "dir" {
			p.LogState = "notdir"
			out = append(out, p)
			continue
		}
		if docker {
			label := "label=com.docker.compose.project=" + name
			all, _ := probe.Docker("ps", "-a", "--filter", label, "-q")
			ids := probe.Lines(all)
			p.Total = len(ids)
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
			running, _ := probe.Docker("ps", "--filter", label, "-q")
			p.Running = len(probe.Lines(running))
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
