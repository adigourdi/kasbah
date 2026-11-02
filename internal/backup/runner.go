package backup

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/dockerapi"
)

// Grace is added to a state's own bound before the healthcheck calls it
// stale; it covers a container stopped and started across the slot.
const Grace = 300

// Runner is the kasbah-backup container's process: `kasbah remote backup`
// with the image's restic beside it, configured by the compose file's
// KASBAH_BACKUP_* environment.
type Runner struct {
	Apps, Data, At  string
	Jitter, Timeout int
	Stdout, Stderr  io.Writer
	// Environ is the environment restic inherits; Restic is its binary.
	Environ []string
	Restic  string
	Now     func() time.Time
	Sleep   func(time.Duration)
	Pid     int
	// The nightly job: the user it runs as on the host, its deadline, the
	// launcher's image, and the daemon it is started through.
	User        string
	HookTimeout int
	Image       string
	Socket      string
	Docker      Engine

	started, finished int64
	status, repos     string
	// failed is each project the last run's job did not back up; launcher
	// why the job did not run, "" when it did.
	failed   []Failure
	launcher string
}

// NewRunner is the runner the container's environment describes.
func NewRunner(stdout, stderr io.Writer) *Runner {
	env := func(k, def string) string {
		if v := os.Getenv(k); v != "" {
			return v
		}
		return def
	}
	jitter, _ := strconv.Atoi(env("KASBAH_BACKUP_JITTER", "0"))
	timeout, err := strconv.Atoi(env("KASBAH_BACKUP_TIMEOUT", strconv.Itoa(DefaultTimeout)))
	if err != nil || timeout <= 0 {
		timeout = DefaultTimeout
	}
	hooks, err := strconv.Atoi(env("KASBAH_BACKUP_HOOK_TIMEOUT", strconv.Itoa(DefaultHookTimeout)))
	if err != nil || hooks <= 0 {
		hooks = DefaultHookTimeout
	}
	return &Runner{
		Apps: os.Getenv("KASBAH_BACKUP_APPS"), Data: os.Getenv("KASBAH_BACKUP_DATA"),
		At: env("KASBAH_BACKUP_AT", DefaultAt), Jitter: jitter, Timeout: timeout,
		Stdout: stdout, Stderr: stderr, Environ: os.Environ(), Restic: "restic",
		Now: time.Now, Sleep: time.Sleep, Pid: os.Getpid(),
		User: os.Getenv("KASBAH_BACKUP_USER"), HookTimeout: hooks, Image: env("KASBAH_BACKUP_IMAGE", ResticImage),
		Socket: dockerapi.Socket, Docker: dockerapi.New(dockerapi.Socket),
	}
}

func (r *Runner) say(format string, a ...any) {
	fmt.Fprintf(r.Stdout, "kasbah-backup: "+format+"\n", a...)
}

func (r *Runner) warn(format string, a ...any) {
	fmt.Fprintf(r.Stderr, "kasbah-backup: "+format+"\n", a...)
}

func (r *Runner) dir() string       { return r.Apps + "/.kasbah/backup" }
func (r *Runner) envfile() string   { return r.dir() + "/env" }
func (r *Runner) passdir() string   { return r.dir() + "/repos" }
func (r *Runner) statedir() string  { return r.dir() + "/state" }
func (r *Runner) statefile() string { return r.statedir() + "/status" }

// Run is the entry point: schedule (the default), once, plan, next, health;
// launch is the launcher container's.
func (r *Runner) Run(args []string) int {
	mode := "schedule"
	if len(args) > 0 {
		mode = args[0]
	}
	switch mode {
	case "plan":
		if r.Apps == "" {
			r.warn("KASBAH_BACKUP_APPS is not set")
			return 1
		}
		r.printPlan(r.plan())
		return 0
	case "next":
		at := r.Now()
		if len(args) > 1 && args[1] != "" {
			e, ok := backuprec.Epoch(args[1])
			if !ok {
				r.warn("next: '%s' is not a unix time", args[1])
				return 1
			}
			at = time.Unix(e, 0)
		}
		d := r.delay(at)
		fmt.Fprintf(r.Stdout, "next run in %ds (%02d:%02d:%02d from now), slot %s plus %ds jitter\n",
			d, d/3600, d%3600/60, d%60, r.At, r.Jitter)
		return 0
	case "once":
		switch {
		case len(args) == 1:
			return r.once("")
		case len(args) == 3 && args[1] == "--project" && args[2] != "":
			return r.once(args[2])
		}
		r.warn("usage: once [--project NAME]")
		return 1
	case "push":
		if len(args) != 3 {
			r.warn("usage: push APPS NAME")
			return 1
		}
		return Push(args[1], args[2], r.Stdout, r.Stderr)
	case "health":
		return r.health()
	case "launch":
		return Launch(args[1:], r.Stdout, r.Stderr)
	case "schedule":
		r.schedule()
		return 0
	}
	r.warn("unknown mode '%s' (expected: schedule, once, plan, next, health, push, launch, host)", mode)
	return 1
}

// --- The record ------------------------------------------------------------

// writeStatus replaces the record through a temp file: the healthcheck reads
// it from another process.
func (r *Runner) writeStatus(state string, deadline, next int64) {
	if fi, err := os.Stat(r.statedir()); err != nil || !fi.IsDir() {
		return
	}
	body := fmt.Sprintf("state=%s\nsince=%d\ndeadline=%d\nnext_run=%d\nlast_run_started=%d\nlast_run_finished=%d\nlast_run_status=%s\nlast_run_repos=%s\ntimeout=%d\nat=%s\njitter=%d\nhook_timeout=%d\n",
		state, r.Now().Unix(), deadline, next, r.started, r.finished, r.status, r.repos, r.Timeout, r.At, r.Jitter, r.HookTimeout)
	for _, f := range r.failed {
		body += "last_run_failed=" + f.Project + " " + oneLine(f.Reason) + "\n"
	}
	if r.launcher != "" {
		body += "last_run_launcher=" + oneLine(r.launcher) + "\n"
	}
	tmp := fmt.Sprintf("%s.tmp.%d", r.statefile(), r.Pid)
	if err := os.WriteFile(tmp, []byte(body), 0o644); err != nil {
		os.Remove(tmp)
		r.warn("could not write %s", r.statefile())
		return
	}
	if err := os.Rename(tmp, r.statefile()); err != nil {
		r.warn("could not install %s", r.statefile())
	}
}

// oneLine is s fit for a record line.
func oneLine(s string) string { return strings.Join(strings.Fields(s), " ") }

// field is one field of the record, the last line naming it; "" without.
func (r *Runner) field(key string) string {
	v := ""
	if all := r.fields(key); len(all) > 0 {
		v = all[len(all)-1]
	}
	return v
}

// fields is every line of the record naming key, in order.
func (r *Runner) fields(key string) []string {
	b, err := os.ReadFile(r.statefile())
	if err != nil {
		return nil
	}
	var vs []string
	for _, l := range strings.Split(strings.TrimSuffix(string(b), "\n"), "\n") {
		if rest, ok := strings.CutPrefix(l, key+"="); ok {
			vs = append(vs, rest)
		}
	}
	return vs
}

// loadLastRun carries the last run's facts out of the record — all four or
// none, so a truncated record is never carried in halves. No CR is
// stripped: a CRLF record fails Epoch and carries nothing.
func (r *Runner) loadLastRun() {
	started, finished := r.field("last_run_started"), r.field("last_run_finished")
	status, repos := r.field("last_run_status"), r.field("last_run_repos")
	r.started, r.finished, r.status, r.repos = 0, 0, "-", "-"
	r.failed, r.launcher = nil, ""
	s, ok1 := backuprec.Epoch(started)
	f, ok2 := backuprec.Epoch(finished)
	if ok1 && ok2 && (status == "ok" || status == "failed") && repos != "" {
		r.started, r.finished, r.status, r.repos = s, f, status, repos
		for _, l := range r.fields("last_run_failed") {
			name, why, _ := strings.Cut(l, " ")
			r.failed = append(r.failed, Failure{name, why})
		}
		r.launcher = r.field("last_run_launcher")
	}
}

// --- The schedule ----------------------------------------------------------

// secsOfDay is seconds since local midnight (/etc/localtime is mounted).
func secsOfDay(t time.Time) int {
	t = t.Local()
	return t.Hour()*3600 + t.Minute()*60 + t.Second()
}

func (r *Runner) slot() int {
	h, m, _ := strings.Cut(r.At, ":")
	hh, _ := strconv.Atoi(h)
	mm, _ := strconv.Atoi(m)
	return (hh*3600 + mm*60 + r.Jitter) % 86400
}

// delay is never zero: a run finishing inside its own slot second would
// otherwise start again at once.
func (r *Runner) delay(at time.Time) int {
	d := r.slot() - secsOfDay(at)
	if d <= 0 {
		d += 86400
	}
	return d
}

func (r *Runner) writeSleeping() {
	d := int64(r.delay(r.Now()))
	now := r.Now().Unix()
	r.writeStatus("sleeping", now+d+int64(r.Timeout)+Grace, now+d)
}

// schedule sleeps until the slot, backs up, and sleeps again. A failed run
// is slept off: exiting would make one bad endpoint a restart loop.
func (r *Runner) schedule() {
	r.say("scheduled daily at %s plus %ds jitter; apps %s, data %s", r.At, r.Jitter, r.Apps, r.Data)
	r.say("one restic call may take %ds (kasbah server init --backup-timeout=)", r.Timeout)
	r.say("the backup hooks run on the host as %s, within %ds (kasbah server init --backup-user= --backup-hook-timeout=)", r.User, r.HookTimeout)
	r.loadLastRun()
	r.writeStatus("starting", r.Now().Unix()+Grace, 0)
	if fi, err := os.Stat(r.Socket); err == nil && fi.Mode()&os.ModeSocket != 0 {
		if _, err := r.sweepLaunchers(true); err != nil {
			r.warn("%v", err)
		}
	}
	for {
		d := r.delay(r.Now())
		r.say("sleeping %ds until the next run", d)
		r.writeSleeping()
		r.Sleep(time.Duration(d) * time.Second)
		if r.once("") != 0 {
			r.warn("the run did not finish cleanly — the next one is still scheduled")
		}
	}
}

// --- What to back up -------------------------------------------------------

type planProject struct{ name, client, origin string }

type planRepo struct {
	name  string
	have  bool
	paths []string
	// unshipped is each backups/ or .env resolving outside the container's
	// mounts, with the project it is of ("" for mail).
	unshipped []unshippedPath
}

// unshippedPath is "<path> -> <where it resolves>", and its project.
type unshippedPath struct{ project, desc string }

type plan struct {
	projects []planProject
	repos    []planRepo
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

// plan is what a run backs up: mail's repository first when the stack is
// there, then one per effective client, each with the paths that exist.
func (r *Runner) plan() plan {
	var p plan
	var order []string
	byClient := map[string][]string{}
	if fi, err := os.Stat(r.Apps + "/mail"); err == nil && fi.IsDir() {
		order = append(order, "mail")
	}
	for _, pr := range backuprec.Projects(r.Apps, r.Data) {
		c, origin := pr.Client, "record"
		switch c {
		case "":
			c, origin = pr.Name, "fallback"
		case "?":
			c, origin = pr.Name, "invalid"
			r.warn("%s/%s/.kasbah-client is not a repository name — %s is filed under '%s'", r.Apps, pr.Name, pr.Name, c)
		}
		p.projects = append(p.projects, planProject{pr.Name, c, origin})
		if _, seen := byClient[c]; !seen {
			order = append(order, c)
		}
		byClient[c] = append(byClient[c], pr.Name)
	}
	for _, name := range order {
		fi, err := os.Stat(r.passdir() + "/" + name + ".pass")
		repo := planRepo{name: name, have: err == nil && fi.Mode().IsRegular()}
		type cand struct{ project, path string }
		cands := []cand{{"", r.Data + "/mail"}, {"", r.Apps + "/mail/.env"}}
		if name != "mail" {
			cands = nil
			for _, n := range byClient[name] {
				cands = append(cands, cand{n, r.Apps + "/" + n + "/backups"}, cand{n, r.Apps + "/" + n + "/.env"})
			}
		}
		for _, c := range cands {
			if !strings.HasSuffix(c.path, "/backups") && !strings.HasSuffix(c.path, "/.env") {
				if exists(c.path) {
					repo.paths = append(repo.paths, c.path)
				}
				continue
			}
			if _, err := os.Lstat(c.path); err != nil {
				continue
			}
			// restic stores a symlink as the link: it gets what it resolves to.
			if real, ok := r.resolve(c.path); ok {
				repo.paths = append(repo.paths, real)
			} else {
				repo.unshipped = append(repo.unshipped, unshippedPath{c.project, c.path + " -> " + real})
			}
		}
		p.repos = append(p.repos, repo)
	}
	return p
}

// resolve is p with every symlink resolved, and whether that is inside the
// container's mounts, the apps and data paths; what it links to when it
// resolves to nothing here.
func (r *Runner) resolve(p string) (string, bool) {
	real, err := filepath.EvalSymlinks(p)
	if err != nil {
		l, lerr := os.Readlink(p)
		if lerr != nil {
			return p, false
		}
		if !filepath.IsAbs(l) {
			l = filepath.Join(filepath.Dir(p), l)
		}
		return l, false
	}
	for _, m := range []string{r.Apps, r.Data} {
		if m = strings.TrimSuffix(m, "/"); m != "" && (real == m || strings.HasPrefix(real, m+"/")) {
			return real, true
		}
	}
	return real, false
}

func (r *Runner) printPlan(p plan) {
	for _, pr := range p.projects {
		fmt.Fprintf(r.Stdout, "project %s %s %s\n", pr.name, pr.client, pr.origin)
	}
	for _, repo := range p.repos {
		have := "no"
		if repo.have {
			have = "yes"
		}
		fmt.Fprintf(r.Stdout, "repo %s %s\n", repo.name, have)
		for _, path := range repo.paths {
			fmt.Fprintf(r.Stdout, "path %s\n", path)
		}
		for _, u := range repo.unshipped {
			fmt.Fprintf(r.Stdout, "unshipped %s\n", u.desc)
		}
	}
}

// --- The run ---------------------------------------------------------------

// loadEnv is the env file as restic's environment, read rather than sourced:
// its values are credentials, taken literally to the end of the line.
func (r *Runner) loadEnv() (env []string, base string, ok bool) {
	content, ok := readEnv(r.envfile())
	if !ok {
		r.warn("no %s — nothing says where the repository is", r.envfile())
		return nil, "", false
	}
	env = append([]string{}, r.Environ...)
	for _, e := range r.Environ {
		if v, found := strings.CutPrefix(e, "KASBAH_BACKUP_REPO_BASE="); found {
			base = v
		}
	}
	for _, l := range strings.Split(strings.TrimSuffix(content, "\n"), "\n") {
		l = strings.TrimSuffix(l, "\r")
		k, v, found := strings.Cut(l, "=")
		if l == "" || l[0] == '#' || !found {
			continue
		}
		if k == "" || !reKey.MatchString(k) {
			r.warn("%s: ignoring '%s=' — not a variable name", r.envfile(), k)
			continue
		}
		if IsOwned(k) && !strings.HasPrefix(k, "KASBAH_BACKUP_") {
			r.warn("%s: ignoring %s= — kasbah sets it per repository", r.envfile(), k)
			continue
		}
		if k == "KASBAH_BACKUP_REPO_BASE" {
			base = v
		}
		env = append(env, k+"="+v)
	}
	return env, base, true
}

// restic runs against one repository, named through the environment and
// never argv, bounded every time.
func (r *Runner) restic(env []string, base, repo string, out, errw io.Writer, args ...string) int {
	env = append(append([]string{}, env...),
		"RESTIC_REPOSITORY="+base+repo, "RESTIC_PASSWORD_FILE="+r.passdir()+"/"+repo+".pass")
	return bounded(time.Duration(r.Timeout)*time.Second, out, errw, env, r.Restic, args...)
}

// once backs up every repository, or with only set the one that project
// files into, leaving the record alone: it is not the scheduled run.
func (r *Runner) once(only string) int {
	// The record, not this process's memory: a scheduler and a hand-run
	// `once` are two writers of one file.
	r.loadLastRun()
	r.started = r.Now().Unix()
	r.say("run started %s", r.Now().Local().Format("2006-01-02T15:04:05-0700"))
	// The backups first, so the push ships what they took; a failed one
	// still pushes everything else (and what backups/ already holds).
	if only == "" {
		r.writeStatus("running", r.Now().Unix()+int64(r.HookTimeout+LaunchGrace+r.Timeout*(len(backuprec.RepoSet(backuprec.Projects(r.Apps, r.Data), true))*2+1)+Grace), 0)
		r.failed, r.launcher = r.hostRun()
		if r.launcher != "" {
			r.warn("no project was backed up on the host: %s", r.launcher)
		}
	}
	sleeping := func() {
		if only == "" {
			r.writeSleeping()
		}
	}
	failed := func() int {
		r.finished, r.status, r.repos = r.Now().Unix(), "failed", "-"
		sleeping()
		return 1
	}
	env, base, ok := r.loadEnv()
	if !ok {
		return failed()
	}
	if base == "" {
		r.warn("%s sets no KASBAH_BACKUP_REPO_BASE — re-run kasbah server init --with-backup", r.envfile())
		return failed()
	}

	p := r.plan()
	if only != "" {
		var ok bool
		if p, ok = p.only(only); !ok {
			r.warn("no project '%s' under %s — nothing backed up", only, r.Apps)
			return 1
		}
	} else {
		r.writeStatus("running", r.Now().Unix()+int64(r.Timeout*(len(p.repos)*2+1)+Grace), 0)
	}

	var fallbacks, nopass, done string
	for _, pr := range p.projects {
		if pr.origin != "record" {
			fallbacks += " " + pr.name
		}
	}
	status := 0
	for _, repo := range p.repos {
		for _, u := range repo.unshipped {
			why := ""
			// A sibling's fails the nightly run, not this project's push.
			if only == "" || u.project == only {
				status = 1
			} else {
				why = " (" + u.project + "'s, not " + only + "'s: this run does not fail on it)"
			}
			r.warn("%s: %s resolves outside this container's mounts (%s, %s) — NOT shipped off-box%s", repo.name, u.desc, r.Apps, r.Data, why)
		}
		switch {
		case !repo.have:
			nopass += " " + repo.name
			status = 1
		case len(repo.paths) == 0:
			r.say("%s: nothing to back up yet", repo.name)
		default:
			if r.restic(env, base, repo.name, io.Discard, io.Discard, "cat", "config") != 0 {
				r.say("%s: initialising the repository", repo.name)
				if r.restic(env, base, repo.name, r.Stdout, r.Stderr, "init") != 0 {
					r.warn("%s: could not initialise the repository", repo.name)
					status = 1
					continue
				}
			}
			r.say("%s: backing up %s", repo.name, strings.Join(repo.paths, " "))
			if r.restic(env, base, repo.name, r.Stdout, r.Stderr, append([]string{"backup", "--tag", "kasbah"}, repo.paths...)...) != 0 {
				r.warn("%s: restic backup failed", repo.name)
				status = 1
				continue
			}
			done += " " + repo.name
		}
	}

	if fallbacks != "" {
		r.say("no .kasbah-client record, filed under their own name:%s", fallbacks)
	}
	if nopass != "" {
		r.warn("no password in %s, NOT backed up:%s", r.passdir(), nopass)
		r.warn("  supply one: kasbah server init USER@HOST --with-backup")
	}
	if done == "" {
		done = " none"
	}
	r.say("run finished, repositories backed up:%s", done)
	r.finished, r.repos, r.status = r.Now().Unix(), done, "ok"
	if only == "" && (len(r.failed) > 0 || r.launcher != "") {
		var names []string
		for _, f := range r.failed {
			names = append(names, f.Project)
		}
		if len(names) > 0 {
			r.warn("backups that failed on the host, whose older backups were shipped instead: %s", strings.Join(names, " "))
		}
		status = 1
	}
	if status != 0 {
		r.status = "failed"
	}
	sleeping()
	return status
}

// only is p cut to the repository project files into, and that repository's
// projects; false when project is not in p.
func (p plan) only(project string) (plan, bool) {
	var out plan
	client := ""
	for _, pr := range p.projects {
		if pr.name == project {
			client = pr.client
		}
	}
	if client == "" {
		return out, false
	}
	for _, pr := range p.projects {
		if pr.client == client {
			out.projects = append(out.projects, pr)
		}
	}
	for _, repo := range p.repos {
		if repo.name == client {
			out.repos = append(out.repos, repo)
		}
	}
	return out, true
}

// health is the healthcheck's one question: has the recorded state outlived
// its own deadline?
func (r *Runner) health() int {
	state, deadline := r.field("state"), r.field("deadline")
	if state == "" {
		r.warn("no %s — the scheduler has not reported in", r.statefile())
		return 1
	}
	if deadline == "" {
		r.warn("%s carries no deadline, which is the one field this check rests on", r.statefile())
		return 1
	}
	d, ok := backuprec.Epoch(deadline)
	if !ok {
		r.warn("%s records deadline='%s', which is not a unix time this check can compare", r.statefile(), deadline)
		return 1
	}
	now := r.Now().Unix()
	if now > d {
		r.warn("state '%s' has outlived its deadline by %ds", state, now-d)
		r.warn("  a run that never returned, or a sleep that never woke — see docker logs")
		return 1
	}
	r.say("%s, %ds of its budget left", state, d-now)
	return 0
}
