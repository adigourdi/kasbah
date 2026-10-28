package drop

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/fsstate"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// Image is one image: its id and every tag it carries.
type Image struct {
	ID   string   `json:"id"`
	Tags []string `json:"tags"`
}

// Container is one of the project's containers as compose labelled it.
type Container struct {
	Name  string `json:"name"`
	State string `json:"state"`
}

// Project is one entry under the apps path that is not kasbah's own.
type Project struct {
	Name         string `json:"name"`
	DirState     string `json:"dir_state"`
	ComposeState string `json:"compose_state"`
	ComposeB64   string `json:"compose_b64"`
}

// Scan is `kasbah remote drop scan APPS DATA NAME`: everything the plan is
// decided from, read in one step and parsed on the workstation. Count is the
// walk's own tally, so a truncated table is told from a short one.
type Scan struct {
	HaveDocker    bool        `json:"have_docker"`
	DockerError   string      `json:"docker_error"`
	AppsState     string      `json:"apps_state"`
	ProjectState  string      `json:"project_state"`
	DataState     string      `json:"data_state"`
	BackupsState  string      `json:"backups_state"`
	BackupsCount  int         `json:"backups_count"`
	FragmentState string      `json:"fragment_state"`
	LockState     string      `json:"lock_state"`
	Containers    []Container `json:"containers"`
	Images        []Image     `json:"images"`
	MailDir       string      `json:"mail_dir"`
	RegistryState string      `json:"registry_state"`
	RegistryB64   string      `json:"registry_b64"`
	Projects      []Project   `json:"projects"`
	Count         int         `json:"project_count"`
}

var scanKeys = []string{"have_docker", "docker_error", "apps_state", "project_state", "data_state",
	"backups_state", "backups_count", "fragment_state", "lock_state", "containers", "images",
	"mail_dir", "registry_state", "registry_b64", "projects", "project_count"}

// Reserved is what under the apps path is never a project.
var Reserved = append([]string{".kasbah"}, manifest.Reserved...)

func isReserved(name string) bool {
	for _, r := range Reserved {
		if r == name {
			return true
		}
	}
	return false
}

var runDocker = func(dir string, args ...string) (string, error) {
	cmd := exec.Command("docker", args...)
	cmd.Dir = dir
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	if err != nil {
		return out.String(), errors.New(flat(errb.String() + "\n" + out.String()))
	}
	return out.String(), nil
}

// flat is one line: CRs off, every run of whitespace one space.
func flat(s string) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(s, "\r", "")), " ")
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

// lockState is whether a deploy holds the project's lock now: probed, never
// created — a read step does not write into the tree it reads.
func lockState(dir string) string {
	f, err := os.Open(filepath.Join(dir, ".deploy.lock"))
	if errors.Is(err, os.ErrNotExist) {
		return "free"
	}
	if err != nil {
		return "unknown"
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return "held"
		}
		return "unknown"
	}
	syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return "free"
}

func scan(apps, data, name string) Scan {
	s := Scan{Containers: []Container{}, Images: []Image{}, Projects: []Project{}}
	_, lerr := exec.LookPath("docker")
	s.HaveDocker = lerr == nil
	_, derr := runDocker("", "version", "--format", "{{.Server.Version}}")
	if derr != nil {
		s.DockerError = derr.Error()
		if s.DockerError == "" {
			s.DockerError = "docker version failed"
		}
	}
	s.AppsState = fsstate.Dir(apps)
	dir := filepath.Join(apps, name)
	s.ProjectState = fsstate.Dir(dir)
	s.DataState = fsstate.Dir(filepath.Join(data, name))
	s.BackupsState = fsstate.Dir(filepath.Join(dir, "backups"))
	if s.BackupsState == "dir" {
		if es, err := os.ReadDir(filepath.Join(dir, "backups")); err == nil {
			for _, e := range es {
				if !strings.HasPrefix(e.Name(), ".") {
					s.BackupsCount++
				}
			}
		}
	}
	s.FragmentState = fsstate.File(filepath.Join(apps, "traefik", "dynamic", name+".yml"))
	s.LockState = lockState(dir)

	if derr == nil {
		out, _ := runDocker("", "ps", "-a", "--filter", "label=com.docker.compose.project="+name,
			"--filter", "label=com.docker.compose.oneoff=False", "--format", "{{.Names}} {{.State}}")
		for _, l := range lines(out) {
			n, st, ok := strings.Cut(l, " ")
			if !ok {
				st = "unknown"
			}
			s.Containers = append(s.Containers, Container{Name: n, State: st})
		}
		ids, _ := runDocker("", "images", "-q")
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
			out, _ := runDocker("", append([]string{"image", "inspect", "--format", "{{.Id}}{{range .RepoTags}} {{.}}{{end}}"}, idl...)...)
			for _, l := range lines(out) {
				f := strings.Fields(l)
				if len(f) == 0 {
					continue
				}
				s.Images = append(s.Images, Image{ID: f[0], Tags: append([]string{}, f[1:]...)})
			}
		}
	}

	s.MailDir = fsstate.Dir(filepath.Join(apps, "mail"))
	s.RegistryState, s.RegistryB64 = fsstate.Read(filepath.Join(apps, "mail", "kasbah.yml"))

	entries, _ := os.ReadDir(apps)
	for _, e := range entries {
		if isReserved(e.Name()) {
			continue
		}
		path := filepath.Join(apps, e.Name())
		p := Project{Name: e.Name(), DirState: fsstate.Dir(path)}
		if p.DirState == "dir" {
			p.ComposeState, p.ComposeB64 = fsstate.Read(filepath.Join(path, "compose.yml"))
		} else {
			p.ComposeState = p.DirState
		}
		s.Projects = append(s.Projects, p)
	}
	s.Count = len(s.Projects)
	return s
}

// ActReport is what `kasbah remote drop act` did, step by step. A line
// `started=yes` precedes it: every guard is above that line, so a run that
// never printed it changed nothing.
type ActReport struct {
	Fragment   string    `json:"fragment"`
	Down       string    `json:"down"`
	DownDetail string    `json:"down_detail"`
	DownLeft   string    `json:"down_left"`
	Removed    []string  `json:"removed"`
	Failed     []Failure `json:"failed"`
	Mail       string    `json:"mail,omitempty"`
	Data       string    `json:"data,omitempty"`
	Config     string    `json:"config,omitempty"`
}

// Failure is a tag docker would not remove, and docker's reason.
type Failure struct {
	Ref    string `json:"ref"`
	Reason string `json:"reason"`
}

var reName = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// ActArgs are the act's arguments, in argv order after `act`.
type ActArgs struct {
	Apps, Data, Name string
	Prune            bool
	// RegSize and RegSum describe the re-rendered registry on stdin ("0" and
	// "-" for none); RegPrev is the sha256 of the registry the plan read.
	RegSize, RegSum, RegPrev string
	Tags                     []string
}

// Argv is the act's command line after `kasbah remote drop act`.
func (a ActArgs) Argv() []string {
	p := "no"
	if a.Prune {
		p = "yes"
	}
	return append([]string{a.Apps, a.Data, a.Name, p, a.RegSize, a.RegSum, a.RegPrev, "--"}, a.Tags...)
}

func parseAct(args []string) (ActArgs, error) {
	if len(args) < 8 || args[7] != "--" {
		return ActArgs{}, errors.New("usage: kasbah remote drop act APPS DATA NAME yes|no SIZE SUM PREV -- TAG…")
	}
	a := ActArgs{Apps: args[0], Data: args[1], Name: args[2], RegSize: args[4], RegSum: args[5], RegPrev: args[6], Tags: args[8:]}
	switch args[3] {
	case "yes":
		a.Prune = true
	case "no":
	default:
		return a, fmt.Errorf("refusing to act: prune='%s' is neither yes nor no", args[3])
	}
	return a, nil
}

// guard is the act's own check of everything it was handed: two of its
// steps are a recursive removal of a path built from these.
func (a ActArgs) guard() error {
	for _, p := range []struct{ what, v string }{{"apps", a.Apps}, {"data", a.Data}} {
		if len(p.v) < 2 || p.v[0] != '/' {
			return fmt.Errorf("refusing to act: %s path '%s' is not an absolute path", p.what, p.v)
		}
	}
	if !reName.MatchString(a.Name) {
		return fmt.Errorf("refusing to act: project name '%s' is not a lower-case letter followed by letters, digits and hyphens, and every path this step removes is built from it", a.Name)
	}
	if isReserved(a.Name) {
		return fmt.Errorf("refusing to act: '%s' is a directory kasbah owns under %s, not a project", a.Name, a.Apps)
	}
	// --prune removes both: neither may hold the other's tree.
	ca, cd := filepath.Clean(a.Apps), filepath.Clean(a.Data)
	data, conf := filepath.Join(cd, a.Name), filepath.Join(ca, a.Name)
	if within(ca, data) || within(cd, conf) {
		return fmt.Errorf("refusing to act: %s and %s overlap the apps path %s and the data path %s", conf, data, a.Apps, a.Data)
	}
	for _, t := range a.Tags {
		if t == "" || strings.HasPrefix(t, "-") || strings.ContainsAny(t, " \t\n\r\v\f") {
			return fmt.Errorf("refusing to act: '%s' is not an image tag", t)
		}
	}
	return nil
}

// within is whether p is dir or below it.
func within(p, dir string) bool { return p == dir || strings.HasPrefix(p, dir+"/") }

// Sum is a registry's sha256 as the act compares it.
func Sum(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// takeLock is flock(2) on the deploy engine's own lock file, held until
// the process exits.
func takeLock(dir string) (*os.File, error) {
	path := filepath.Join(dir, ".deploy.lock")
	f, err := serverlock.Open(path)
	if err != nil {
		return nil, fmt.Errorf("could not open the lock file %s. Nothing was changed.", path)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("another deploy or rollback is already running in %s — it holds the lock on %s. Nothing was changed.", dir, path)
	}
	return f, nil
}

func act(a ActArgs, stdin io.Reader, stdout io.Writer) error {
	if err := a.guard(); err != nil {
		return err
	}
	var registry []byte
	if a.RegSize != "0" {
		b, err := remote.Payload(stdin, a.RegSize, a.RegSum)
		if err != nil {
			return fmt.Errorf("the mail registry: %v", err)
		}
		registry = b
	}
	sl, err := serverlock.Take(a.Apps, serverlock.Shared, "")
	if err != nil {
		return err
	}
	if sl != nil {
		defer sl.Close()
	}
	dir := filepath.Join(a.Apps, a.Name)
	if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
		lock, err := takeLock(dir)
		if err != nil {
			return err
		}
		// Unlinked with the directory under --prune, the lock still holds
		// until this process exits.
		defer lock.Close()
	}
	// A dropped session does not strand the act half way.
	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
	fmt.Fprintln(stdout, "started=yes")

	r := ActReport{Removed: []string{}, Failed: []Failure{}}
	fragment := filepath.Join(a.Apps, "traefik", "dynamic", a.Name+".yml")
	r.Fragment = "absent"
	if _, err := os.Stat(fragment); err == nil {
		r.Fragment = fsstate.Remove(fragment)
	}

	// By label from /: no compose file or .env needed, and none picked up.
	// Without -v: named volumes are data, and drop keeps data.
	out, err := runDocker("/", "compose", "-p", a.Name, "down", "--remove-orphans")
	r.Down = "ok"
	if err != nil {
		r.Down = "failed"
		r.DownDetail = err.Error()
	} else {
		r.DownDetail = flat(out)
	}
	left, _ := runDocker("", "ps", "-a", "--filter", "label=com.docker.compose.project="+a.Name, "--format", "{{.Names}}")
	r.DownLeft = strings.Join(lines(left), " ")

	for _, ref := range a.Tags {
		if _, err := runDocker("", "image", "rm", ref); err != nil {
			r.Failed = append(r.Failed, Failure{Ref: ref, Reason: err.Error()})
		} else {
			r.Removed = append(r.Removed, ref)
		}
	}

	if a.Prune {
		r.Mail = "skipped"
		if registry != nil {
			reg := filepath.Join(a.Apps, "mail", "kasbah.yml")
			cur, err := os.ReadFile(reg)
			switch {
			case err != nil || Sum(cur) != a.RegPrev:
				r.Mail = "stale"
			case remote.Install(reg, registry, 0o644) != nil:
				r.Mail = "failed"
			default:
				r.Mail = "written"
			}
		}
		r.Data = removeTree(filepath.Join(a.Data, a.Name))
		// --data-path equal to --apps-path: one directory, one verdict.
		if filepath.Clean(filepath.Join(a.Data, a.Name)) == filepath.Clean(dir) {
			r.Config = r.Data
		} else {
			r.Config = removeTree(dir)
		}
	}
	b, _ := json.Marshal(r)
	fmt.Fprintf(stdout, "%s\n", b)
	return nil
}

func removeTree(p string) string {
	if _, err := os.Stat(p); err != nil {
		return "absent"
	}
	if os.RemoveAll(p) != nil {
		return "failed"
	}
	return "removed"
}

// Remote is the server's half: `scan APPS DATA NAME` reads, `act …` removes.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	switch {
	case len(args) == 4 && args[0] == "scan":
		b, _ := json.Marshal(scan(args[1], args[2], args[3]))
		fmt.Fprintf(stdout, "%s\n", b)
		return 0
	case len(args) >= 1 && args[0] == "act":
		a, err := parseAct(args[1:])
		if err == nil {
			err = act(a, stdin, stdout)
		}
		if err != nil {
			fmt.Fprintf(stderr, "remote: %v\n", err)
			return 1
		}
		return 0
	}
	fmt.Fprintln(stderr, "remote: usage: kasbah remote drop scan APPS DATA NAME | act APPS DATA NAME yes|no SIZE SUM PREV -- TAG…")
	return 1
}
