// Package traefiknet attaches the shared Traefik to the compose networks its
// routes reach: each project's own and the mail stack's, all declared under
// the key kasbah and found by compose's labels (docs/traefik.md → Network).
package traefiknet

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const (
	// Key is the compose network key Traefik joins; compose names the
	// network <project>_kasbah and labels it com.docker.compose.network=kasbah.
	Key = "kasbah"
	// Container is the shared Traefik's container_name.
	Container = "traefik"
)

// ErrNoTraefik is a host with no traefik container to attach.
var ErrNoTraefik = errors.New("there is no traefik container on this host")

// Docker runs one docker command and returns its stdout; its error carries
// docker's stderr. A caller's own runner is how its tests stub docker.
type Docker func(args ...string) (string, error)

// Exec is the docker on PATH, under LC_ALL=C.
func Exec(args ...string) (string, error) {
	c := exec.Command("docker", args...)
	c.Env = append(os.Environ(), "LC_ALL=C")
	var out, errb bytes.Buffer
	c.Stdout, c.Stderr = &out, &errb
	if err := c.Run(); err != nil {
		msg := strings.TrimSpace(errb.String())
		if msg == "" {
			msg = err.Error()
		}
		return out.String(), errors.New(msg)
	}
	return out.String(), nil
}

// list is each network compose created under Key, with its compose project:
// one project's, or every one when project is "".
func (docker Docker) list(project string) (map[string]string, error) {
	args := []string{"network", "ls", "--filter", "label=com.docker.compose.network=" + Key}
	if project != "" {
		args = append(args, "--filter", "label=com.docker.compose.project="+project)
	}
	out, err := docker(append(args, "--format", `{{.Name}} {{.Label "com.docker.compose.project"}}`)...)
	if err != nil {
		return nil, fmt.Errorf("docker network ls failed: %v", err)
	}
	nets := map[string]string{}
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		if f := strings.Fields(l); len(f) > 0 {
			nets[f[0]] = strings.Join(f[1:], " ")
		}
	}
	return nets, nil
}

// Networks are the names of one project's networks under Key.
func (docker Docker) Networks(project string) ([]string, error) {
	nets, err := docker.list(project)
	var names []string
	for n := range nets {
		names = append(names, n)
	}
	sort.Strings(names)
	return names, err
}

var reProject = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]*$`)

// Served are the networks under Key that kasbah routes to: the mail stack's,
// and each project's with a directory under apps. A compose project run by
// hand elsewhere on the host is never one.
func (docker Docker) Served(apps string) ([]string, error) {
	nets, err := docker.list("")
	if err != nil {
		return nil, err
	}
	var names []string
	for n, p := range nets {
		if p == "mail" {
			names = append(names, n)
			continue
		}
		if !reProject.MatchString(p) {
			continue
		}
		if fi, err := os.Stat(filepath.Join(apps, p)); err == nil && fi.IsDir() {
			names = append(names, n)
		}
	}
	sort.Strings(names)
	return names, nil
}

// attached is the networks Traefik is on; ErrNoTraefik when it is absent.
func (docker Docker) attached() (map[string]bool, error) {
	out, err := docker("inspect", "-f", "{{range $k, $v := .NetworkSettings.Networks}}{{$k}}\n{{end}}", Container)
	if err != nil {
		if strings.Contains(err.Error(), "No such") {
			return nil, ErrNoTraefik
		}
		return nil, fmt.Errorf("docker inspect %s failed: %v", Container, err)
	}
	on := map[string]bool{}
	for _, n := range fields(out) {
		on[n] = true
	}
	return on, nil
}

// Join connects Traefik to each of nets it is not on yet and returns those
// it connected; one already attached is left as it is.
func (docker Docker) Join(nets []string) ([]string, error) {
	if len(nets) == 0 {
		return nil, nil
	}
	on, err := docker.attached()
	if err != nil {
		return nil, err
	}
	var done []string
	for _, n := range nets {
		if on[n] {
			continue
		}
		if _, err := docker("network", "connect", n, Container); err != nil {
			// Lost a race with another run: what was asked for holds.
			if now, aerr := docker.attached(); aerr == nil && now[n] {
				continue
			}
			return done, fmt.Errorf("docker network connect %s %s failed: %v", n, Container, err)
		}
		done = append(done, n)
	}
	return done, nil
}

// JoinAll is Join over every network Served: the Traefik start step.
func (docker Docker) JoinAll(apps string) (all, joined []string, err error) {
	all, err = docker.Served(apps)
	if err != nil {
		return nil, nil, err
	}
	joined, err = docker.Join(all)
	return all, joined, err
}

// Leave disconnects Traefik from each of nets it is on and returns those it
// disconnected; no traefik container leaves nothing to do.
func (docker Docker) Leave(nets []string) ([]string, error) {
	if len(nets) == 0 {
		return nil, nil
	}
	on, err := docker.attached()
	if errors.Is(err, ErrNoTraefik) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var done []string
	for _, n := range nets {
		if !on[n] {
			continue
		}
		if _, err := docker("network", "disconnect", n, Container); err != nil {
			return done, fmt.Errorf("docker network disconnect %s %s failed: %v", n, Container, err)
		}
		done = append(done, n)
	}
	return done, nil
}

func fields(s string) []string {
	f := strings.Fields(strings.ReplaceAll(s, "\r", ""))
	sort.Strings(f)
	return f
}
