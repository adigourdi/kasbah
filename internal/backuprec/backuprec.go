// Package backuprec is the one workstation reader of the backup scheduler's
// last-run record, <apps>/.kasbah/backup/state/status (docs/backup.md), used by
// `server status` and B01 alike, and the server-side facts both ask for. The
// runner's healthcheck is the other reader; tests/backup_test.sh pins its
// is_epoch against Epoch.
package backuprec

import (
	"encoding/base64"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/probe"
)

// Verdicts. The first four are "no record to judge"; the last four are
// verdicts on a record that was read.
const (
	NoStack    = "nostack"
	NoRecord   = "norecord"
	Unreadable = "unreadable"
	Unparsed   = "unparsed"
	Never      = "never"
	Failed     = "failed"
	Overdue    = "overdue"
	OK         = "ok"
)

// Record is a judged record. Epoch fields are -1 when absent or not an epoch
// Epoch admits; Age is -1 when no run has finished.
type Record struct {
	Verdict string
	// Reason is the clause after the path, for the states that have one.
	Reason string

	State, Status, Repos                        string
	Since, Deadline, NextRun, Started, Finished int64

	Overdue, Age, Now int64
	// Clock is "server" when judged against the server's clock, "local" when
	// the probe's was unusable and this machine's was used.
	Clock string
}

// Judged is whether the verdict is one of the four read off a record.
func (r *Record) Judged() bool {
	switch r.Verdict {
	case Never, Failed, Overdue, OK:
		return true
	}
	return false
}

// Epoch admits a unix time arithmetic can be done on: digits, no leading zero
// (`0` itself excepted), at most eighteen of them.
func Epoch(v string) (int64, bool) {
	if v == "" || len(v) > 18 || (v[0] == '0' && v != "0") {
		return -1, false
	}
	for i := 0; i < len(v); i++ {
		if v[i] < '0' || v[i] > '9' {
			return -1, false
		}
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil {
		return -1, false
	}
	return n, true
}

// Read judges a record. dir is the stack directory's state (dir, notdir,
// absent), file the record's FState, content its bytes, now the server's
// `date +%s` as it reported it.
func Read(dir, file, content, now string) *Record {
	r := &Record{Since: -1, Deadline: -1, NextRun: -1, Started: -1, Finished: -1, Age: -1, Clock: "server"}
	var ok bool
	if r.Now, ok = Epoch(now); !ok {
		r.Now, r.Clock = time.Now().Unix(), "local"
	}
	switch dir {
	case "dir":
	case "notdir":
		r.Verdict, r.Reason = NoStack, "exists and is not a directory"
		return r
	default:
		r.Verdict, r.Reason = NoStack, "is not there"
		return r
	}
	switch file {
	case "file":
	case "absent":
		r.Verdict = NoRecord
		return r
	case "empty":
		r.Verdict, r.Reason = Unreadable, "is empty"
		return r
	case "unreadable":
		r.Verdict, r.Reason = Unreadable, "cannot be read by the ssh user"
		return r
	case "notfile":
		r.Verdict, r.Reason = Unreadable, "exists and is not a regular file"
		return r
	case "dir":
		r.Verdict, r.Reason = Unreadable, "is a directory"
		return r
	default:
		r.Verdict, r.Reason = Unreadable, fmt.Sprintf("is in a state this kasbah does not know ('%s')", file)
		return r
	}
	if strings.TrimRight(content, "\n") == "" {
		r.Verdict, r.Reason = Unreadable, "did not come back as readable bytes"
		return r
	}

	var since, deadline, next, started, finished string
	for _, line := range strings.Split(strings.TrimSuffix(content, "\n"), "\n") {
		line = strings.TrimSuffix(line, "\r")
		k, v, found := strings.Cut(line, "=")
		if !found {
			continue
		}
		switch k {
		case "state":
			r.State = v
		case "since":
			since = v
		case "deadline":
			deadline = v
		case "next_run":
			next = v
		case "last_run_started":
			started = v
		case "last_run_finished":
			finished = v
		case "last_run_status":
			r.Status = v
		case "last_run_repos":
			r.Repos = v
		}
	}
	r.Deadline, _ = Epoch(deadline)
	r.Since, _ = Epoch(since)
	r.NextRun, _ = Epoch(next)
	r.Started, _ = Epoch(started)
	r.Finished, _ = Epoch(finished)

	// The deadline is the one field the healthcheck asks about.
	if r.State == "" || r.Deadline < 0 {
		r.Verdict = Unparsed
		switch {
		case r.State == "":
			r.Reason = "carries no scheduler state"
		case deadline == "":
			r.Reason = "carries no deadline, which is the one field a verdict rests on"
		default:
			r.Reason = fmt.Sprintf("records deadline='%s', which is not a unix time this kasbah can compare", deadline)
		}
		return r
	}

	if r.Now > r.Deadline {
		r.Overdue = r.Now - r.Deadline
	}
	if r.Finished > 0 {
		// Both off the server's clock: negative means it moved backwards.
		r.Age = max(r.Now-r.Finished, 0)
	}

	// A failed run is named first; an overdue state outranks the two below.
	switch {
	case r.Status == "failed":
		r.Verdict = Failed
	case r.Overdue > 0:
		r.Verdict = Overdue
	case r.Status == "ok":
		r.Verdict = OK
	case r.Status == "" || r.Status == "-":
		r.Verdict = Never
	default:
		r.Verdict = Unparsed
		r.Reason = fmt.Sprintf("records last_run_status='%s', which this kasbah does not know", r.Status)
	}
	return r
}

// Ago is a duration in seconds in one unit; "unknown" for a negative one.
func Ago(s int64) string {
	switch {
	case s < 0:
		return "unknown"
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm", s/60)
	case s < 172800:
		return fmt.Sprintf("%dh", s/3600)
	}
	return fmt.Sprintf("%d day(s)", s/86400)
}

// Project is a directory under <apps> and the client its snapshots file
// under: "" when it records none, "?" when what it records is not a name.
type Project struct {
	Name   string `json:"name"`
	Client string `json:"client"`
}

// RepoSet is the repositories a server has, `server init --with-backup`'s
// own answer: one per effective client in project order, then mail.
func RepoSet(projects []Project, mail bool) []string {
	var repos []string
	seen := map[string]bool{}
	for _, p := range projects {
		c := p.Client
		if c == "" || c == "?" {
			c = p.Name
		}
		if seen[c] {
			continue
		}
		seen[c] = true
		repos = append(repos, c)
	}
	if mail && !seen["mail"] {
		repos = append(repos, "mail")
	}
	return repos
}

// Diff is the repositories with no password, and the passwords no repository
// files into any more.
func Diff(repos, have []string) (missing, orphan []string) {
	in := func(ss []string, x string) bool {
		for _, s := range ss {
			if s == x {
				return true
			}
		}
		return false
	}
	for _, r := range repos {
		if !in(have, r) {
			missing = append(missing, r)
		}
	}
	for _, h := range have {
		if !in(repos, h) {
			orphan = append(orphan, h)
		}
	}
	return missing, orphan
}

// Container is the kasbah-backup scheduler container: State is absent,
// nodocker, nodaemon, notours or docker's own status.
type Container struct {
	State    string `json:"state"`
	Health   string `json:"health"`
	Restarts string `json:"restarts"`
}

// Facts is what the server reports about its backup stack.
type Facts struct {
	Dir       string    `json:"dir"`
	Record    string    `json:"record"`
	RecordB64 string    `json:"record_b64"`
	Now       string    `json:"now"`
	Container Container `json:"container"`
	HasPass   []string  `json:"haspass"`
	Projects  []Project `json:"projects"`
	Mail      bool      `json:"mail"`
}

// Content is the record's bytes, "" when they did not decode.
func (f *Facts) Content() string {
	b, err := base64.StdEncoding.DecodeString(f.RecordB64)
	if err != nil {
		return ""
	}
	return string(b)
}

// Repos is RepoSet over these facts.
func (f *Facts) Repos() []string { return RepoSet(f.Projects, f.Mail) }

// Collect reads the backup facts of the server it runs on. data is skipped
// when a project directory is looked for.
func Collect(apps, data string) Facts {
	bdir := apps + "/.kasbah/backup"
	rec := bdir + "/state/status"
	f := Facts{
		Dir:       probe.DirState(bdir),
		Record:    probe.FState(rec),
		RecordB64: probe.B64(rec),
		Container: container(),
		Mail:      probe.DirState(apps+"/mail") == "dir",
		HasPass:   []string{},
		Projects:  []Project{},
	}
	if ents, err := os.ReadDir(bdir + "/repos"); err == nil {
		for _, e := range ents {
			n := e.Name()
			if strings.HasPrefix(n, ".") || !strings.HasSuffix(n, ".pass") {
				continue
			}
			if fi, err := os.Stat(bdir + "/repos/" + n); err == nil && fi.Mode().IsRegular() {
				f.HasPass = append(f.HasPass, strings.TrimSuffix(n, ".pass"))
			}
		}
	}
	if ents, err := os.ReadDir(apps); err == nil {
		for _, e := range ents {
			n := e.Name()
			d := apps + "/" + n
			if strings.HasPrefix(n, ".") || probe.DirState(d) != "dir" || d == data || probe.IsReserved(n) {
				continue
			}
			f.Projects = append(f.Projects, Project{Name: n, Client: client(d + "/.kasbah-client")})
		}
	}
	f.Now = strconv.FormatInt(time.Now().Unix(), 10)
	return f
}

// client is the runner's reading of .kasbah-client: the first line, and only
// a line the file terminates (`IFS= read -r c || c=""`).
func client(path string) string {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	line, _, terminated := strings.Cut(string(b), "\n")
	if !terminated {
		return ""
	}
	c := strings.TrimSuffix(line, "\r")
	if c == "" {
		return ""
	}
	if c[0] < 'a' || c[0] > 'z' || probe.IsReserved(c) {
		return "?"
	}
	for i := 0; i < len(c); i++ {
		if !(c[i] >= 'a' && c[i] <= 'z' || c[i] >= '0' && c[i] <= '9' || c[i] == '-') {
			return "?"
		}
	}
	return c
}

// container is the scheduler by name and by compose project: a container
// merely named kasbah-backup is notours. A failed inspect is followed by
// `docker version` to tell a missing container from a daemon not answering.
func container() Container {
	c := Container{State: "absent", Health: "none"}
	if !probe.HaveDocker() {
		return Container{State: "nodocker", Health: "nodocker"}
	}
	info, rc := probe.Docker("inspect", "-f",
		`{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.RestartCount}} {{index .Config.Labels "com.docker.compose.project"}}`,
		"kasbah-backup")
	if rc != 0 {
		info = ""
	}
	if strings.TrimSpace(info) == "" {
		if _, rc := probe.Docker("version", "--format", "{{.Server.Version}}"); rc != 0 {
			return Container{State: "nodaemon", Health: "nodaemon"}
		}
		return c
	}
	f := strings.Fields(strings.ReplaceAll(info, "\r", ""))
	at := func(n int, def string) string {
		if n < len(f) {
			return f[n]
		}
		return def
	}
	if at(3, "") != "kasbah-backup" {
		c.State = "notours"
		return c
	}
	return Container{State: at(0, "unknown"), Health: at(1, "none"), Restarts: at(2, "")}
}
