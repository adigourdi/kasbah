package prune

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// Image is one row of the server's image table: its id, its own creation
// time (a `docker load` keeps it) and every tag it carries.
type Image struct {
	ID      string   `json:"id"`
	Created string   `json:"created"`
	Tags    []string `json:"tags"`
}

// Container is a container, running or not, and the image id it was created from.
type Container struct {
	Image string `json:"image"`
	State string `json:"state"`
	Name  string `json:"name"`
}

// Project is one entry under the apps path that is not kasbah's own: three
// files in the states `server status` reports them in, and their bytes.
type Project struct {
	Name         string `json:"name"`
	ComposeState string `json:"compose_state"`
	ComposeB64   string `json:"compose_b64"`
	vlog.Probe
}

// Scan is `kasbah remote prune scan APPS`: everything prune decides on, read
// in one step and parsed on the workstation. Count is the walk's own tally,
// so a truncated table is told from a short one.
type Scan struct {
	NowMonth    string      `json:"now_month"`
	DockerError string      `json:"docker_error"`
	Images      []Image     `json:"images"`
	Containers  []Container `json:"containers"`
	Projects    []Project   `json:"projects"`
	Count       int         `json:"project_count"`
}

// Reserved is what under the apps path is never a project.
var Reserved = append([]string{".kasbah"}, manifest.Reserved...)

var runDocker = func(args ...string) (string, error) {
	cmd := exec.Command("docker", args...)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if err != nil {
		msg := strings.TrimSpace(errb.String() + "\n" + out.String())
		return out.String(), fmt.Errorf("%s", strings.Join(strings.Fields(strings.ReplaceAll(msg, "\r", "")), " "))
	}
	return out.String(), nil
}

func lines(s string) []string {
	var out []string
	for _, l := range strings.Split(s, "\n") {
		if l = strings.TrimSuffix(l, "\r"); l != "" {
			out = append(out, l)
		}
	}
	return out
}

func scan(apps string, now time.Time) Scan {
	s := Scan{NowMonth: now.UTC().Format("2006-01"), Images: []Image{}, Containers: []Container{}, Projects: []Project{}}
	if _, err := runDocker("version", "--format", "{{.Server.Version}}"); err != nil {
		s.DockerError = err.Error()
		if s.DockerError == "" {
			s.DockerError = "docker version failed"
		}
	} else {
		ids, _ := runDocker("images", "-q")
		uniq := map[string]bool{}
		var idl []string
		for _, id := range lines(ids) {
			if !uniq[id] {
				uniq[id] = true
				idl = append(idl, id)
			}
		}
		sort.Strings(idl)
		if len(idl) > 0 {
			out, _ := runDocker(append([]string{"image", "inspect", "--format", "{{.Id}} {{.Created}}{{range .RepoTags}} {{.}}{{end}}"}, idl...)...)
			for _, l := range lines(out) {
				f := strings.Fields(l)
				if len(f) < 2 {
					continue
				}
				s.Images = append(s.Images, Image{ID: f[0], Created: f[1], Tags: append([]string{}, f[2:]...)})
			}
		}
		cids, _ := runDocker("ps", "-a", "-q")
		if c := lines(cids); len(c) > 0 {
			out, _ := runDocker(append([]string{"inspect", "--format", "{{.Image}} {{.State.Status}} {{.Name}}"}, c...)...)
			for _, l := range lines(out) {
				f := strings.Fields(l)
				if len(f) == 0 {
					continue
				}
				ct := Container{Image: f[0], State: "unknown"}
				if len(f) > 1 {
					ct.State = f[1]
				}
				if len(f) > 2 {
					ct.Name = strings.TrimPrefix(f[2], "/")
				}
				s.Containers = append(s.Containers, ct)
			}
		}
	}
	entries, _ := os.ReadDir(apps)
	reserved := map[string]bool{}
	for _, r := range Reserved {
		reserved[r] = true
	}
	for _, e := range entries {
		if reserved[e.Name()] {
			continue
		}
		dir := filepath.Join(apps, e.Name())
		p := Project{Name: e.Name()}
		p.ComposeState, p.ComposeB64 = vlog.ReadFile(apps, dir, filepath.Join(dir, "compose.yml"))
		p.ActiveState, p.ActiveB64 = vlog.ReadFile(apps, dir, filepath.Join(dir, vlog.Log))
		p.ArchiveState, p.ArchiveB64 = vlog.ReadFile(apps, dir, filepath.Join(dir, vlog.Archive))
		s.Projects = append(s.Projects, p)
	}
	s.Count = len(s.Projects)
	return s
}

// Removal is one line of `kasbah remote prune rm`: a tag removed, or not and why.
type Removal struct {
	Removed string `json:"removed,omitempty"`
	Failed  string `json:"failed,omitempty"`
	Reason  string `json:"reason,omitempty"`
}

// Remote is the server's half: `scan APPS` reads, `rm APPS TAG…` removes, under the server lock.
func Remote(args []string, stdout, stderr io.Writer) int {
	switch {
	case len(args) == 2 && args[0] == "scan":
		b, _ := json.Marshal(scan(args[1], time.Now()))
		fmt.Fprintf(stdout, "%s\n", b)
		return 0
	case len(args) >= 3 && args[0] == "rm":
		sl, err := serverlock.Take(args[1], serverlock.Exclusive, "server prune")
		if err != nil {
			fmt.Fprintf(stderr, "remote: %v\n", err)
			return 1
		}
		if sl != nil {
			defer sl.Close()
		}
		// A dropped session does not stop the removals half way.
		signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
		enc := json.NewEncoder(stdout)
		for _, ref := range args[2:] {
			if _, err := runDocker("image", "rm", ref); err != nil {
				enc.Encode(Removal{Failed: ref, Reason: err.Error()})
			} else {
				enc.Encode(Removal{Removed: ref})
			}
		}
		return 0
	}
	fmt.Fprintln(stderr, "remote: usage: kasbah remote prune scan APPS | rm APPS TAG…")
	return 1
}
