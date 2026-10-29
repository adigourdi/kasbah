package upgrade

import (
	"bufio"
	"bytes"
	"crypto/sha256"
	"encoding/base64"
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
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/traefiknet"
)

// Project is the live stack's frozen compose project name: anything else
// would bring a second proxy up beside it.
const Project = "traefik"

// Stack is `kasbah remote traefik read APPS DATA`: the three kasbah-owned
// files, the fragments the file provider reads, the certificate store's
// digest and the live container — read-only.
type Stack struct {
	Compose      string   `json:"compose_b64"`
	Static       string   `json:"static_b64"`
	Shared       string   `json:"shared_b64"`
	Fragments    []string `json:"fragments"`
	AcmeState    string   `json:"acme_state"`
	AcmeDigest   string   `json:"acme_digest"`
	Docker       bool     `json:"docker"`
	State        string   `json:"traefik_state"`
	Health       string   `json:"traefik_health"`
	RunningImage string   `json:"traefik_running_image"`
}

// DryPayload is what the dry run mounts: the rendered _shared.yml over the
// server's copy, and the isolated static configuration.
type DryPayload struct {
	Shared string `json:"shared"`
	Static string `json:"static"`
}

// Dry is the dry run's report.
type Dry struct {
	Swept    int    `json:"dry_swept"`
	Verdict  string `json:"dry_verdict"`
	ExitCode string `json:"dry_exitcode"`
	Errors   string `json:"dry_errors"`
	Warns    string `json:"dry_warns"`
	Routers  string `json:"dry_routers"`
	Log      string `json:"dry_log"`
}

// Up is the start's report; RolledBack is no, yes or failed.
type Up struct {
	RolledBack string `json:"up_rolled_back"`
	Health     string `json:"up_health"`
	State      string `json:"up_state"`
	Image      string `json:"up_image"`
	StartedAt  string `json:"up_started_at"`
	AcmeDigest string `json:"up_acme_digest"`
	// Networks is every project network Traefik is on after the start;
	// JoinErr why it could not rejoin one.
	Networks string `json:"up_networks"`
	JoinErr  string `json:"up_join_err,omitempty"`
}

func b64(path string) string {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
}

func digest(path string) string {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() == 0 {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// dockerCmd's error carries docker's stderr, as traefiknet.Docker's contract asks.
var dockerCmd = func(dir string, args ...string) (string, error) {
	cmd := exec.Command("docker", args...)
	cmd.Dir = dir
	var errb bytes.Buffer
	cmd.Stderr = &errb
	out, err := cmd.Output()
	if msg := strings.TrimSpace(errb.String()); err != nil && msg != "" {
		err = errors.New(msg)
	}
	return strings.TrimSpace(string(out)), err
}

var haveDocker = func() bool { _, err := exec.LookPath("docker"); return err == nil }

var dockerLogs = func(name string) string {
	out, _ := exec.Command("docker", "logs", name).CombinedOutput()
	return string(out)
}

func inspect(id, format string) (string, error) { return dockerCmd("", "inspect", "-f", format, id) }

const healthFmt = "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"

func readStack(apps, data string) Stack {
	dir := apps + "/traefik"
	s := Stack{
		Compose:   b64(dir + "/compose.yml"),
		Static:    b64(dir + "/traefik.yml"),
		Shared:    b64(dir + "/dynamic/_shared.yml"),
		Fragments: []string{},
		State:     "absent",
		Health:    "none",
	}
	// Traefik's own rule: it reads .yml, .yaml and .toml and skips the rest.
	if ents, err := os.ReadDir(dir + "/dynamic"); err == nil {
		for _, e := range ents {
			fi, err := os.Stat(filepath.Join(dir, "dynamic", e.Name()))
			if err != nil || !fi.Mode().IsRegular() {
				continue
			}
			switch filepath.Ext(e.Name()) {
			case ".yml", ".yaml", ".toml":
				s.Fragments = append(s.Fragments, e.Name())
			}
		}
	}
	acme := data + "/traefik/letsencrypt/acme.json"
	if _, err := os.Lstat(acme); err != nil {
		s.AcmeState = "absent"
	} else if fi, err := os.Stat(acme); err != nil || !fi.Mode().IsRegular() {
		s.AcmeState = "notfile"
	} else if fi.Size() == 0 {
		s.AcmeState = "empty"
	} else {
		s.AcmeState, s.AcmeDigest = "nonempty", digest(acme)
	}
	if !haveDocker() {
		return s
	}
	s.Docker = true
	cid := ""
	if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
		cid, _ = dockerCmd(dir, "compose", "-p", Project, "ps", "-a", "-q", "traefik")
	}
	if cid != "" {
		var err error
		if s.State, err = inspect(cid, "{{.State.Status}}"); err != nil {
			s.State = "unknown"
		}
		if s.Health, err = inspect(cid, healthFmt); err != nil {
			s.Health = "none"
		}
		s.RunningImage, _ = inspect(cid, "{{.Config.Image}}")
	}
	return s
}

var reColour = regexp.MustCompile("\x1b\\[[0-9;]*m")

// Classify reads a throwaway's log: every ERR line is a config error, less
// the certificate this run's own unreachable CA refuses — that exemption is
// the message AND the URL on one line, and its routerName is the evidence a
// router was built. Routers come back in first-seen order.
func Classify(text, acmeMsg, dryCA string) (errs, warns []string, routers []string) {
	seen := map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSuffix(line, "\r")
		switch {
		case strings.Contains(line, " ERR "):
			if strings.Contains(line, acmeMsg) && strings.Contains(line, dryCA) {
				if _, r, ok := strings.Cut(line, "routerName="); ok {
					r, _, _ = strings.Cut(r, " ")
					if !seen[r] {
						seen[r] = true
						routers = append(routers, r)
					}
				}
				continue
			}
			errs = append(errs, line)
		case strings.Contains(line, " WRN "):
			warns = append(warns, line)
		}
	}
	return errs, warns, routers
}

var sleep = time.Sleep

func dryRun(apps, image, label, stamp, acmeMsg, dryCA string, timeout time.Duration, p DryPayload) (Dry, error) {
	var d Dry
	name := "kasbah-traefik-dry-run-" + stamp
	work := ""
	cleanup := func() {
		dockerCmd("", "rm", "-f", name)
		if work != "" {
			os.RemoveAll(work)
		}
	}
	// On the atexit stack: a signal (a dropped session's SIGHUP) removes it too.
	pop := atexit.Push(cleanup)
	defer func() { pop(); cleanup() }()

	stale, _ := dockerCmd("", "ps", "-aq", "--filter", "label="+label)
	for _, c := range strings.Fields(stale) {
		if _, err := dockerCmd("", "rm", "-f", c); err == nil {
			d.Swept++
		}
	}
	var err error
	if work, err = os.MkdirTemp("", "kasbah-dry-run."); err != nil {
		return d, errors.New("could not create a temp directory")
	}
	for _, f := range []struct{ name, body string }{{"traefik.yml", p.Static}, {"_shared.yml", p.Shared}} {
		path := filepath.Join(work, f.name)
		if err := os.WriteFile(path, []byte(f.body), 0o644); err != nil || os.Chmod(path, 0o644) != nil {
			return d, fmt.Errorf("could not write %s", path)
		}
	}
	// Pulled before anything on the server is overwritten.
	if _, err := dockerCmd("", "pull", image); err != nil {
		return d, fmt.Errorf("could not pull %s — check the tag exists (docker pull %s)", image, image)
	}
	if _, err := dockerCmd("", "run", "-d", "--name", name, "--label", label, "--network", "none", "--restart", "no",
		"-v", work+"/traefik.yml:/etc/traefik/traefik.yml:ro",
		"-v", apps+"/traefik/dynamic:/etc/traefik/dynamic:ro",
		"-v", work+"/_shared.yml:/etc/traefik/dynamic/_shared.yml:ro",
		image); err != nil {
		return d, fmt.Errorf("the throwaway %s container would not start at all (docker run refused it)", image)
	}
	logs := func() string { return reColour.ReplaceAllString(dockerLogs(name), "") }
	deadline := time.Now().Add(timeout)
	d.Verdict = "waiting"
	for {
		text := logs()
		if strings.Contains(text, " ERR ") || strings.Contains(text, acmeMsg) {
			d.Verdict = "spoke"
			break
		}
		if r, err := inspect(name, "{{.State.Running}}"); err != nil || r != "true" {
			d.Verdict = "exited"
			break
		}
		if !time.Now().Before(deadline) {
			d.Verdict = "timeout"
			break
		}
		sleep(time.Second)
	}
	// Router errors and ACME attempts come from different goroutines.
	if d.Verdict == "spoke" {
		sleep(2 * time.Second)
	}
	text := logs()
	d.ExitCode, _ = inspect(name, "{{.State.ExitCode}}")
	errs, warns, routers := Classify(text, acmeMsg, dryCA)
	d.Errors, d.Warns = strings.Join(errs, "\n"), strings.Join(warns, "\n")
	if len(routers) > 0 {
		d.Routers = strings.Join(routers, " ") + " "
	}
	d.Log = clipTail(text, 8000)
	return d, nil
}

// clipTail is at most n bytes off the end of s, starting on a rune.
func clipTail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	i := len(s) - n
	for i < len(s) && !utf8.RuneStart(s[i]) {
		i++
	}
	return s[i:]
}

func backup(apps, stamp, from, to string) (string, error) {
	dir := apps + "/traefik"
	dest := dir + "/backups/" + stamp
	if _, err := os.Lstat(dest); err == nil {
		return "", fmt.Errorf("%s is already there — kasbah will not write over a backup", dest)
	}
	if err := os.MkdirAll(dest, 0o777); err != nil {
		return "", fmt.Errorf("could not create %s", dest)
	}
	for _, rel := range []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml"} {
		if err := copyFile(dir+"/"+rel, dest+"/"+filepath.Base(rel)); err != nil {
			return "", fmt.Errorf("could not copy %s/%s to %s", dir, rel, dest)
		}
	}
	if err := os.WriteFile(dest+"/kasbah-upgrade", []byte(from+" -> "+to+"\n"), 0o666); err != nil {
		return "", fmt.Errorf("could not write %s/kasbah-upgrade", dest)
	}
	return dest, nil
}

// copyFile is `cp -p`: bytes, mode and mtime.
func copyFile(src, dst string) error {
	fi, err := os.Stat(src)
	if err != nil {
		return err
	}
	b, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	if err := os.WriteFile(dst, b, fi.Mode().Perm()); err != nil {
		return err
	}
	if err := os.Chmod(dst, fi.Mode().Perm()); err != nil {
		return err
	}
	return os.Chtimes(dst, fi.ModTime(), fi.ModTime())
}

// start recreates the container and waits for health; a start that does not
// come up has the backup copied back and the old version brought up here, on
// the server, before a word of it is written — the session may be gone.
func start(apps, backupDir, acme string, timeout time.Duration, stderr io.Writer) Up {
	dir := apps + "/traefik"
	dc := func(args ...string) error {
		_, err := dockerCmd(dir, append([]string{"compose", "-p", Project}, args...)...)
		return err
	}
	cid := func() string {
		id, _ := dockerCmd(dir, "compose", "-p", Project, "ps", "-a", "-q", "traefik")
		return id
	}
	waitHealthy := func() bool {
		id := cid()
		if id == "" {
			return false
		}
		deadline := time.Now().Add(timeout)
		for {
			h, err := inspect(id, healthFmt)
			if err != nil {
				h = "gone"
			}
			if h == "healthy" {
				return true
			}
			if h == "none" {
				return false
			}
			if r, err := inspect(id, "{{.State.Running}}"); err != nil || r != "true" {
				return false
			}
			if !time.Now().Before(deadline) {
				return false
			}
			sleep(2 * time.Second)
		}
	}
	u := Up{RolledBack: "no", Health: "none"}
	// A recreated Traefik is on kasbah-net alone: it rejoins every project
	// network and the mail stack's as soon as it is up.
	up := func() bool {
		if dc("up", "-d") != nil {
			return false
		}
		nets, _, err := traefiknet.Docker(func(a ...string) (string, error) { return dockerCmd("", a...) }).JoinAll(apps)
		u.Networks, u.JoinErr = strings.Join(nets, " "), ""
		if err != nil {
			u.JoinErr = err.Error()
		}
		return true
	}
	if !up() || !waitHealthy() {
		failing, _ := dockerCmd(dir, "compose", "-p", Project, "logs", "--no-color", "--tail", "40")
		u.RolledBack = "failed"
		if fi, err := os.Stat(backupDir); err == nil && fi.IsDir() &&
			copyFile(backupDir+"/compose.yml", dir+"/compose.yml") == nil &&
			copyFile(backupDir+"/traefik.yml", dir+"/traefik.yml") == nil &&
			copyFile(backupDir+"/_shared.yml", dir+"/dynamic/_shared.yml") == nil &&
			up() && waitHealthy() {
			u.RolledBack = "yes"
		}
		fmt.Fprintf(stderr, "remote: the new Traefik did not come up healthy — restored %s (rollback: %s); its log:\n%s\n", backupDir, u.RolledBack, failing)
	}
	if id := cid(); id != "" {
		var err error
		if u.Health, err = inspect(id, healthFmt); err != nil {
			u.Health = "gone"
		}
		u.Image, _ = inspect(id, "{{.Config.Image}}")
		u.StartedAt, _ = inspect(id, "{{.State.StartedAt}}")
		u.State, _ = inspect(id, "{{.State.Status}}")
	}
	u.AcmeDigest = digest(acme)
	return u
}

const remoteUsage = "usage: kasbah remote traefik read APPS DATA | dry-run APPS IMAGE LABEL STAMP ACME_MSG DRY_CA TIMEOUT SIZE SHA256 | backup APPS STAMP FROM TO | start APPS BACKUP ACME TIMEOUT"

// Remote is the server's half of upgrade-traefik. Reports are one JSON line
// on stdout; a failure is `remote: …` on stderr, exit 1. start exits 3 when
// it had to roll back.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	emit := func(v any) {
		b, _ := json.Marshal(v)
		fmt.Fprintf(stdout, "%s\n", b)
	}
	switch {
	case len(args) == 3 && args[0] == "read":
		emit(readStack(args[1], args[2]))
		return 0
	case len(args) == 10 && args[0] == "dry-run":
		t, err := strconv.Atoi(args[7])
		if err != nil {
			return fail("%s", remoteUsage)
		}
		body, err := remote.Payload(bufio.NewReader(stdin), args[8], args[9])
		if err != nil {
			return fail("the dry-run configuration: %v", err)
		}
		var p DryPayload
		if err := json.Unmarshal(body, &p); err != nil || p.Shared == "" || p.Static == "" {
			return fail("the dry-run configuration is not the payload this binary reads")
		}
		d, err := dryRun(args[1], args[2], args[3], args[4], args[5], args[6], time.Duration(t)*time.Second, p)
		if err != nil {
			return fail("%v", err)
		}
		emit(d)
		return 0
	case len(args) == 5 && args[0] == "backup":
		signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
		dest, err := backup(args[1], args[2], args[3], args[4])
		if err != nil {
			return fail("%v", err)
		}
		emit(map[string]string{"backup_dir": dest})
		return 0
	case len(args) == 5 && args[0] == "start":
		t, err := strconv.Atoi(args[4])
		if err != nil {
			return fail("%s", remoteUsage)
		}
		if fi, err := os.Stat(args[1] + "/traefik"); err != nil || !fi.IsDir() {
			return fail("could not enter %s/traefik", args[1])
		}
		// The rollback must outlive the session.
		w, done := remote.Outlive(stderr)
		defer done()
		u := start(args[1], args[2], args[3], time.Duration(t)*time.Second, w)
		emit(u)
		if u.RolledBack != "no" {
			return 3
		}
		return 0
	}
	return fail("%s", remoteUsage)
}

// decodeB64 is a base64 field back to bytes; "" for anything undecodable.
func decodeB64(s string) string {
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil {
		return ""
	}
	return string(b)
}
