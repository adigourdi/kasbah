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
	"slices"
	"sort"
	"strings"

	"github.com/adigourdi/kasbah/internal/trace"
)

const (
	// Key is the compose network key Traefik joins; compose names the
	// network <project>_kasbah and labels it com.docker.compose.network=kasbah.
	Key = "kasbah"
	// Container is the shared Traefik's container_name; Project its compose project.
	Container = "traefik"
	Project   = "traefik"
	// Shared is the network every project shared before each had its own;
	// this kasbah never creates Traefik on it.
	Shared = "kasbah-net"
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
	if err := trace.Run(c); err != nil {
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

// Attached is the networks Traefik is on; ErrNoTraefik when it is absent.
func (docker Docker) Attached() (map[string]bool, error) {
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
	on, err := docker.Attached()
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
			if now, aerr := docker.Attached(); aerr == nil && now[n] {
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
	on, err := docker.Attached()
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

// NoNetwork is whether err is docker's own answer that network name does not
// exist, in either of the wordings its daemons use.
func NoNetwork(err error, name string) bool {
	m := err.Error()
	return strings.Contains(m, "network "+name+" not found") || strings.Contains(m, "No such network: "+name)
}

// OnShared is every container, running or stopped, attached to Shared or
// created on it, in byte order: a stopped one is not in `docker network
// inspect`, and one created on it cannot start once it is gone.
func (docker Docker) OnShared() ([]string, error) {
	ids, err := docker("ps", "-aq")
	if err != nil {
		return nil, fmt.Errorf("docker ps -a failed: %v", err)
	}
	if len(fields(ids)) == 0 {
		return nil, nil
	}
	out, err := docker(append([]string{"inspect", "-f", "{{.Name}} {{.HostConfig.NetworkMode}} {{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}"}, fields(ids)...)...)
	if err != nil {
		return nil, fmt.Errorf("docker inspect failed: %v", err)
	}
	var on []string
	for _, l := range strings.Split(strings.ReplaceAll(out, "\r", ""), "\n") {
		if f := strings.Fields(l); len(f) > 1 && slices.Contains(f[1:], Shared) {
			on = append(on, strings.TrimPrefix(f[0], "/"))
		}
	}
	sort.Strings(on)
	return on, nil
}

// DropShared removes Shared once no container is on it or created on it, and
// says what it did; "" when there is no Shared. A recreated Traefik's start
// runs it.
func (docker Docker) DropShared() (string, error) {
	if _, err := docker("network", "inspect", "-f", "{{.Name}}", Shared); err != nil {
		if NoNetwork(err, Shared) {
			return "", nil
		}
		return "", fmt.Errorf("docker network inspect %s failed: %v", Shared, err)
	}
	on, err := docker.OnShared()
	if err != nil {
		return "", err
	}
	if len(on) > 0 {
		return fmt.Sprintf("%s kept: %s still on it", Shared, strings.Join(on, ", ")), nil
	}
	if _, err := docker("network", "rm", Shared); err != nil {
		if NoNetwork(err, Shared) {
			return "", nil
		}
		return "", fmt.Errorf("docker network rm %s failed: %v", Shared, err)
	}
	return Shared + " removed: no container is on it", nil
}

func fields(s string) []string {
	f := strings.Fields(strings.ReplaceAll(s, "\r", ""))
	sort.Strings(f)
	return f
}
