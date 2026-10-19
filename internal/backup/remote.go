package backup

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/probe"
	"github.com/adigourdi/kasbah/internal/remote"
)

// RemoteInit is `kasbah remote backup-init <step> …`: init's backup half and
// backup-prune's discovery. Reports on stdout, failures as `remote: …`, exit 1.
func RemoteInit(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	// A dropped session must not skip a step's cleanup, nor stop the docker
	// it runs; a report nobody reads is a write error, not a death.
	stderr, done := remote.Outlive(stderr)
	defer done()
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	usage := func() int {
		return fail("usage: kasbah remote backup-init read APPS DATA | layout APPS SIZE SHA256 | probe APPS IMAGE TIMEOUT | start APPS RESTART | repos APPS")
	}
	if len(args) == 0 {
		return usage()
	}
	var err error
	switch {
	case args[0] == "read" && len(args) == 3:
		err = json.NewEncoder(stdout).Encode(Read(args[1], args[2]))
	case args[0] == "layout" && len(args) == 4:
		err = remoteLayout(args[1], args[2], args[3], stdin, stdout)
	case args[0] == "probe" && len(args) == 4:
		t, perr := strconv.Atoi(args[3])
		if perr != nil || t <= 0 {
			return usage()
		}
		err = Probe(args[1], args[2], time.Duration(t)*time.Second, stdout)
	case args[0] == "start" && len(args) == 3:
		err = remoteStart(args[1], args[2] == "yes", stdout, stderr)
	case args[0] == "repos" && len(args) == 2:
		err = json.NewEncoder(stdout).Encode(Repos(args[1]))
	default:
		return usage()
	}
	if err != nil {
		return fail("%v", err)
	}
	return 0
}

// ReadReport is what the backup half of init needs from a server before it
// decides anything. The env file's content never travels: only whether it
// has any, and the first key in it kasbah sets itself.
type ReadReport struct {
	Dir      string              `json:"dir"`
	Compose  string              `json:"compose_b64"`
	Env      string              `json:"env"`
	EnvOwned string              `json:"env_owned"`
	HasPass  []string            `json:"haspass"`
	Mail     bool                `json:"mail"`
	Projects []backuprec.Project `json:"projects"`
}

// Fresh is a server with nothing of backups on it.
var Fresh = ReadReport{Dir: "absent", Env: "absent", HasPass: []string{}, Projects: []backuprec.Project{}}

// Read is the backup stack as it stands under apps.
func Read(apps, data string) ReadReport {
	dir := apps + "/.kasbah/backup"
	r := ReadReport{
		Dir:      probe.DirState(dir),
		Compose:  probe.B64(dir + "/compose.yml"),
		Env:      "absent",
		HasPass:  backuprec.HasPass(dir + "/repos"),
		Mail:     probe.DirState(apps+"/mail") == "dir",
		Projects: backuprec.Projects(apps, data),
	}
	if env, ok := readEnv(dir + "/env"); ok {
		r.Env = "empty"
		if env != "" {
			r.Env = "present"
			r.EnvOwned = FirstOwned(env)
		}
	}
	return r
}

// readEnv is a regular, readable file's content.
func readEnv(path string) (string, bool) {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return "", false
	}
	return string(b), true
}

// LayoutBody is the layout step's payload: the secrets travel here, on
// stdin and digest-checked, never in argv.
type LayoutBody struct {
	Default   string     `json:"default"`
	RepoBase  string     `json:"repo_base"`
	Env       []string   `json:"env"`
	Passwords []Password `json:"passwords"`
}

// Password is one repository's new restic password.
type Password struct {
	Repo string `json:"repo"`
	Pass string `json:"pass"`
}

// remoteLayout makes the tree (700 every run), merges the env file here so
// the operator's credentials never leave the server (600 every run), and
// writes each new password — never over one already there.
func remoteLayout(apps, size, sum string, stdin io.Reader, stdout io.Writer) error {
	dir := apps + "/.kasbah/backup"
	raw, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", dir, err)
	}
	var body LayoutBody
	if err := json.Unmarshal(raw, &body); err != nil {
		return fmt.Errorf("%s: the layout payload is not one kasbah can read", dir)
	}
	if body.RepoBase == "" || strings.ContainsAny(body.RepoBase, "\n\r") {
		return fmt.Errorf("%s: the layout payload carries no usable repository base", dir)
	}
	for _, e := range body.Env {
		if k, v, ok := strings.Cut(e, "="); !ok || !reKey.MatchString(k) || IsOwned(k) || strings.ContainsAny(v, "\n\r") {
			return fmt.Errorf("%s: the layout payload carries an environment entry kasbah would not write", dir)
		}
	}
	if st := probe.DirState(dir); st == "notdir" {
		return fmt.Errorf("%s exists and is not a directory", dir)
	}
	for _, d := range []string{dir, dir + "/repos", dir + "/state"} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return fmt.Errorf("could not create %s/repos and %s/state", dir, dir)
		}
		if err := os.Chmod(d, 0o700); err != nil {
			return fmt.Errorf("could not restrict %s", dir)
		}
	}

	envPath := dir + "/env"
	current, _ := readEnv(envPath)
	if k := FirstOwned(current); k != "" {
		return fmt.Errorf("%s sets %s, which kasbah sets itself — remove the line and re-run", envPath, k)
	}
	merged := MergeEnv(body.Default, current, body.RepoBase, body.Env)
	state := "unchanged"
	if merged != current {
		if err := remote.Install(envPath, []byte(merged), 0o600); err != nil {
			return err
		}
		state = "written"
	} else if err := os.Chmod(envPath, 0o600); err != nil {
		return fmt.Errorf("could not set mode 600 on %s", envPath)
	}

	var written, kept []string
	for _, p := range body.Passwords {
		if !reRepo.MatchString(p.Repo) || p.Pass == "" || strings.ContainsAny(p.Pass, "\n\r") {
			return fmt.Errorf("%s: the layout payload carries a password kasbah would not write", dir)
		}
		path := dir + "/repos/" + p.Repo + ".pass"
		if _, err := os.Lstat(path); err == nil {
			kept = append(kept, p.Repo)
			continue
		}
		if err := remote.Install(path, []byte(p.Pass+"\n"), 0o600); err != nil {
			return err
		}
		written = append(written, p.Repo)
	}
	fmt.Fprintf(stdout, "backup_layout=done\nenv_state=%s\npass_written=%s\npass_kept=%s\n",
		state, strings.Join(written, " "), strings.Join(kept, " "))
	return nil
}

// bounded runs name with a TERM at limit and a KILL ten seconds on, as
// `timeout -k 10 LIMIT` does; it returns the exit status, 124 when the bound
// fired, 127 when name could not be started.
func bounded(limit time.Duration, stdout, stderr io.Writer, env []string, name string, args ...string) int {
	cmd := exec.Command(name, args...)
	cmd.Stdout, cmd.Stderr = stdout, stderr
	// A child that leaves its pipes open must not hold Wait past the bound.
	cmd.WaitDelay = 5 * time.Second
	if env != nil {
		cmd.Env = env
	}
	if err := cmd.Start(); err != nil {
		fmt.Fprintf(stderr, "%s: %v\n", name, err)
		return 127
	}
	// A signal to this process ends the child too; docker relays it.
	pop := atexit.Push(func() { cmd.Process.Signal(syscall.SIGTERM) })
	defer pop()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()
	select {
	case err := <-done:
		return exitCode(err)
	case <-ctx.Done():
	}
	cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		cmd.Process.Kill()
		<-done
	}
	return 124
}

func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		if c := ee.ExitCode(); c >= 0 {
			return c
		}
		return 128 + int(ee.Sys().(syscall.WaitStatus).Signal())
	}
	return 1
}

// envBase is the last KASBAH_BACKUP_REPO_BASE an env file sets.
func envBase(content string) string {
	base := ""
	for _, l := range strings.Split(content, "\n") {
		l = strings.TrimSuffix(l, "\r")
		if v, ok := strings.CutPrefix(l, "KASBAH_BACKUP_REPO_BASE="); ok {
			base = v
		}
	}
	return base
}

// operatorLines is the env file's lines handed to restic: KEY=VALUE only,
// neither kasbah's own namespace nor a key it sets per repository.
func operatorLines(content string) []string {
	var out []string
	for _, l := range strings.Split(content, "\n") {
		l = strings.TrimSuffix(l, "\r")
		k, _, ok := strings.Cut(l, "=")
		if l == "" || l[0] == '#' || !ok || IsOwned(k) {
			continue
		}
		out = append(out, l)
	}
	return out
}

// scan counts the snapshot ids `restic list snapshots` printed, and names
// the first.
func scan(out string) (n int, first string) {
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSuffix(l, "\r")
		if len(l) >= 2 && isHex(l[0]) && isHex(l[1]) {
			n++
			if first == "" {
				first = l
			}
		}
	}
	return n, first
}

func isHex(c byte) bool { return c >= '0' && c <= '9' || c >= 'a' && c <= 'f' }

// Probe proves the credential in effect: two snapshots written, a named one
// forgotten, the rest counted — fewer after is a credential that can delete.
// The report is written only once the scratch holding the credential is gone.
func Probe(apps, image string, limit time.Duration, stdout io.Writer) error {
	rep, err := runProbe(apps, image, limit)
	if err != nil {
		return err
	}
	_, err = io.WriteString(stdout, rep)
	return err
}

func runProbe(apps, image string, limit time.Duration) (string, error) {
	envfile := apps + "/.kasbah/backup/env"
	content, ok := readEnv(envfile)
	if !ok {
		return "", fmt.Errorf("%s is not there — the probe has no credentials to test", envfile)
	}
	base := envBase(content)
	if base == "" {
		return "", fmt.Errorf("%s sets no KASBAH_BACKUP_REPO_BASE", envfile)
	}
	d, err := os.MkdirTemp("", "kasbah-backup-probe.*")
	if err != nil {
		return "", errors.New("could not create a temp directory for the probe")
	}
	// The env file holds the operator's credentials, and so does the saved
	// config of a container a signal left `Created`: both go, signal or not.
	var names []string
	cleanup := func() {
		if len(names) > 0 {
			exec.Command("docker", append([]string{"rm", "-f"}, names...)...).Run()
		}
		os.RemoveAll(d)
	}
	pop := atexit.Push(cleanup)
	defer func() { pop(); cleanup() }()
	if err := os.Chmod(d, 0o700); err != nil {
		return "", fmt.Errorf("could not restrict %s", d)
	}
	if err := os.Mkdir(d+"/src", 0o755); err != nil {
		return "", fmt.Errorf("could not create %s/src", d)
	}
	if err := os.WriteFile(d+"/src/probe.txt", []byte("kasbah backup credential probe\n"), 0o644); err != nil {
		return "", errors.New("could not write the probe object")
	}
	if err := os.WriteFile(d+"/pass", []byte(ProbePassword+"\n"), 0o600); err != nil {
		return "", errors.New("could not write the probe password")
	}
	// The operator's lines first: `docker --env-file` is last-wins.
	env := strings.Join(operatorLines(content), "\n")
	if env != "" {
		env += "\n"
	}
	env += "RESTIC_REPOSITORY=" + base + ProbeRepo + "\nRESTIC_PASSWORD_FILE=/probe/pass\n"
	if err := os.WriteFile(d+"/env", []byte(env), 0o600); err != nil {
		return "", errors.New("could not write the probe environment")
	}

	var log bytes.Buffer
	// --hostname: restic groups snapshots by host, and docker's are random.
	r := func(args ...string) (string, int) {
		var out bytes.Buffer
		name := fmt.Sprintf("kasbah-probe-%d-%d", os.Getpid(), len(names)+1)
		names = append(names, name)
		rc := bounded(limit, &out, &out, nil, "docker", append([]string{"run", "--rm", "--name", name, "--hostname", "kasbah-probe",
			"--env-file", d + "/env", "-v", d + ":/probe:ro", "-v", d + "/src:/probe-src:ro", image, "--no-cache"}, args...)...)
		log.WriteString(out.String() + "\n")
		return out.String(), rc
	}
	report := func(stage string, mid, after, rc int, when string) (string, error) {
		return fmt.Sprintf("probe_repo=%s%s\nprobe_stage=%s\nprobe_mid=%d\nprobe_after=%d\nprobe_rc=%d\nprobe_when=%s\nprobe_log_b64=%s\n",
			base, ProbeRepo, stage, mid, after, rc, when, base64.StdEncoding.EncodeToString(log.Bytes())), nil
	}

	if _, rc := r("cat", "config"); rc != 0 {
		if _, rc := r("init"); rc != 0 {
			return report("reach", 0, 0, rc, "-")
		}
	}
	for i := 0; i < 2; i++ {
		if _, rc := r("backup", "--tag", "kasbah-probe", "/probe-src"); rc != 0 {
			return report("write", 0, 0, rc, "-")
		}
	}
	// "Listed zero" and "could not list" are opposite facts.
	out, rc := r("list", "snapshots")
	if rc != 0 {
		return report("unlisted", 0, 0, rc, "before")
	}
	mid, victim := scan(out)
	_, frc := r("forget", victim, "--prune")
	out, rc = r("list", "snapshots")
	if rc != 0 {
		return report("unlisted", mid, 0, rc, "after")
	}
	after, _ := scan(out)
	return report("deleted", mid, after, frc, "-")
}

func inspect(id, format string) string {
	out, _ := exec.Command("docker", "inspect", "-f", format, id).Output()
	return strings.TrimRight(string(out), "\n")
}

// remoteStart brings the stack up, restarting it when the binary changed and
// up did not just recreate it. Always -p: COMPOSE_PROJECT_NAME in a login
// shell outranks `name:`.
func remoteStart(apps string, restart bool, stdout, stderr io.Writer) error {
	dir := apps + "/.kasbah/backup"
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return fmt.Errorf("could not enter %s", dir)
	}
	dc := func(args ...string) error {
		cmd := exec.Command("docker", append([]string{"compose", "-p", Project}, args...)...)
		cmd.Dir, cmd.Stdout, cmd.Stderr = dir, stderr, stderr
		return cmd.Run()
	}
	cid := func() string {
		cmd := exec.Command("docker", "compose", "-p", Project, "ps", "-a", "-q", "backup")
		cmd.Dir = dir
		out, _ := cmd.Output()
		return strings.TrimSpace(string(out))
	}
	before := ""
	if id := cid(); id != "" {
		before = inspect(id, "{{.State.StartedAt}}")
	}
	if err := dc("up", "-d"); err != nil {
		return fmt.Errorf("docker compose -p %s up -d failed in %s", Project, dir)
	}
	id := cid()
	if id == "" {
		return errors.New("compose reported no backup container after up -d")
	}
	// The Bash-era runner, once a container that does not need it is up.
	legacy := "absent"
	if fi, err := os.Lstat(dir + "/backup.sh"); err == nil && fi.Mode().IsRegular() {
		if err := os.Remove(dir + "/backup.sh"); err != nil {
			return fmt.Errorf("could not remove %s/backup.sh", dir)
		}
		legacy = "removed"
	}
	if restart && before != "" && before == inspect(id, "{{.State.StartedAt}}") {
		if err := dc("restart", "backup"); err != nil {
			return fmt.Errorf("docker compose -p %s restart backup failed", Project)
		}
	}
	fmt.Fprintf(stdout, "backup_state=%s\nbackup_restarts=%s\nbackup_image=%s\nbackup_container=%s\nbackup_legacy=%s\n",
		inspect(id, "{{.State.Status}}"), inspect(id, "{{.RestartCount}}"), inspect(id, "{{.Config.Image}}"),
		strings.TrimPrefix(inspect(id, "{{.Name}}"), "/"), legacy)
	return nil
}

// ReposReport is `server backup-prune`'s discovery: the repositories with a
// password, and each password's bytes.
type ReposReport struct {
	Repos []string          `json:"repos"`
	Pass  map[string]string `json:"pass_b64"`
}

func Repos(apps string) ReposReport {
	dir := apps + "/.kasbah/backup/repos"
	r := ReposReport{Repos: backuprec.HasPass(dir), Pass: map[string]string{}}
	for _, n := range r.Repos {
		r.Pass[n] = probe.B64(dir + "/" + n + ".pass")
	}
	return r
}
