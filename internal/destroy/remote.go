package destroy

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/deploy"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/fsstate"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// The backup stack's compose project and the objects it leaves behind
// (templates/backup/compose.yml names the volume so this can).
const (
	BackupProject   = "kasbah-backup"
	BackupContainer = "kasbah-backup"
	BackupVolume    = "kasbah-backup-cache"
	// BackupLauncher is the nightly job's container, outside the compose
	// project, and BackupLauncherLabel the label every launcher carries.
	BackupLauncher      = "kasbah-backup-launcher"
	BackupLauncherLabel = "kasbah.backup.launcher"
	BackupNetwork       = "kasbah-backup_default"
)

// Helpers are the two scripts a deploy installed in <project>/scripts/
// before 10.8, removed by name: anything else there is somebody else's.
var Helpers = []string{"remote-deploy.sh", "setup-env.sh"}

// MailKeys are the lines of <apps>/mail/.env that are kasbah's; every other
// line — the operator's relay block above all — goes.
var MailKeys = []string{"MAIL_HOSTNAME", "DOMAIN", "DATA_PATH"}

// Reserved is what under the apps path is never a project.
var Reserved = append([]string{".kasbah"}, manifest.Reserved...)

var reName = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

func isReserved(name string) bool {
	for _, r := range Reserved {
		if r == name {
			return true
		}
	}
	return false
}

// Row is one project as the scan found it.
type Row struct {
	Name      string `json:"name"`
	Dir       string `json:"dir"`
	Vlog      string `json:"vlog"`
	VlogGz    string `json:"vlog_gz"`
	Scripts   string `json:"scripts"`
	Helpers   int    `json:"helpers"`
	Other     int    `json:"other"`
	Lock      string `json:"lock"`
	Client    string `json:"client"`
	Env       string `json:"env"`
	Sentinels int    `json:"sentinels"`
	// Prev is .kasbah-prev/, a failed deploy's snapshot (fsstate.Dir).
	Prev string `json:"prev"`
	// Seeds counts the staged --env-seed files, .kasbah-env-seed*.
	Seeds int `json:"seeds"`
	// Kept counts the snapshots a backup could not take in, .kasbah-prev.kept-*;
	// Unpacked the backups an interrupted rollback extracted, .kasbah-unpacked.*.
	Kept     int `json:"kept"`
	Unpacked int `json:"unpacked"`
	// Hooks is .kasbah-hooks.json (fsstate.File).
	Hooks string `json:"hooks"`
}

// Scan is `kasbah remote destroy scan APPS POINTER`.
type Scan struct {
	HaveDocker      bool     `json:"have_docker"`
	DockerError     string   `json:"docker_error"`
	AppsState       string   `json:"apps_state"`
	MarkerState     string   `json:"marker_state"`
	KasbahDir       string   `json:"kasbah_dir"`
	KasbahExtra     []string `json:"kasbah_extra"`
	BinLock         bool     `json:"bin_lock"`
	BinState        string   `json:"bin_state"`
	BackupDir       string   `json:"backup_dir"`
	BackupContainer string   `json:"backup_container"`
	BackupVolume    string   `json:"backup_volume"`
	BackupNetwork   string   `json:"backup_network"`
	PointerState    string   `json:"pointer_state"`
	PointerDir      string   `json:"pointer_dir"`
	PointerDirOther int      `json:"pointer_dir_other"`
	Sudo            string   `json:"sudo"`
	MailDir         string   `json:"mail_dir"`
	MailEnvState    string   `json:"mail_env_state"`
	MailEnvExtra    int      `json:"mail_env_extra"`
	RegistryState   string   `json:"registry_state"`
	// LayersMap is <apps>/.kasbah/layers.map, build-push's layer-name cache.
	LayersMap string `json:"layers_map"`
	// AcmeDNS is the DNS providers whose credentials are under traefik/acme-dns.
	AcmeDNS  []string `json:"acme_dns"`
	Projects []Row    `json:"projects"`
	Count    int      `json:"project_count"`
	Skipped  []string `json:"skipped"`
}

var scanKeys = []string{"have_docker", "docker_error", "apps_state", "marker_state", "kasbah_dir",
	"kasbah_extra", "bin_state", "backup_dir", "backup_container", "backup_volume", "backup_network",
	"pointer_state", "pointer_dir", "pointer_dir_other", "sudo", "mail_dir", "mail_env_state",
	"mail_env_extra", "registry_state", "layers_map", "projects", "project_count", "skipped"}

var docker = func(dir string, args ...string) (string, error) {
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

// sudoState is root, yes (passwordless sudo) or no.
var sudoState = func() string {
	if os.Geteuid() == 0 {
		return "root"
	}
	if exec.Command("sudo", "-n", "true").Run() == nil {
		return "yes"
	}
	return "no"
}

func flat(s string) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(s, "\r", "")), " ")
}

// entries is a directory's names, dotfiles included; nil when it cannot be
// read and entered.
func entries(dir string) []string {
	if fsstate.Dir(dir) != "dir" {
		return nil
	}
	es, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range es {
		out = append(out, e.Name())
	}
	return out
}

// binOwn is whether a name under <apps>/.kasbah/bin is kasbah's own: the
// binary, its install lock, an upload a killed run left.
func binOwn(name string) bool {
	return name == "kasbah" || name == serverbin.LockName || strings.HasPrefix(name, serverbin.TempPrefix)
}

func splitLines(b []byte) []string { return strings.Split(string(b), "\n") }

// sentinel is whether a line is one of the managed block's two comments.
func sentinel(line string) bool {
	l := strings.TrimSuffix(line, "\r")
	return l == env.ManagedBegin || l == env.ManagedEnd
}

func countSentinels(path string) int {
	if fsstate.File(path) == "missing" || fsstate.File(path) == "notfile" || !fsstate.Access(path, fsstate.R) {
		return 0
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n := 0
	for _, l := range splitLines(b) {
		if sentinel(l) {
			n++
		}
	}
	return n
}

// mailKeep is whether a mail .env line is one of kasbah's three keys, read
// as compose reads it: leading blanks and an `export ` off.
func mailKeep(line string) bool {
	s := strings.TrimLeft(strings.TrimSuffix(line, "\r"), " \t")
	if r, ok := strings.CutPrefix(s, "export"); ok && r != "" && (r[0] == ' ' || r[0] == '\t') {
		s = strings.TrimLeft(r, " \t")
	}
	for _, k := range MailKeys {
		if strings.HasPrefix(s, k+"=") {
			return true
		}
	}
	return false
}

// splitKeep is a file's lines with the final fragment marked: a last line
// without a newline is data, and must not gain one.
func splitKeep(b []byte) (lines []string, lastBare bool) {
	s := string(b)
	if s == "" {
		return nil, false
	}
	lines = strings.Split(s, "\n")
	if lines[len(lines)-1] == "" {
		return lines[:len(lines)-1], false
	}
	return lines, true
}

// filter is b with the lines keep refuses dropped, every other byte kept.
func filter(b []byte, keep func(string) bool) (out []byte, dropped int) {
	lines, bare := splitKeep(b)
	var buf bytes.Buffer
	for i, l := range lines {
		if !keep(l) {
			dropped++
			continue
		}
		buf.WriteString(l)
		if i < len(lines)-1 || !bare {
			buf.WriteByte('\n')
		}
	}
	return buf.Bytes(), dropped
}

func countMailExtra(path string) int {
	if fsstate.File(path) != "ok" {
		return 0
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	_, n := filter(b, mailKeep)
	return n
}

func scan(apps, pointer string) Scan {
	s := Scan{KasbahExtra: []string{}, Projects: []Row{}, Skipped: []string{}}
	_, lerr := exec.LookPath("docker")
	s.HaveDocker = lerr == nil
	_, derr := docker("", "version", "--format", "{{.Server.Version}}")
	if derr != nil {
		s.DockerError = derr.Error()
		if s.DockerError == "" {
			s.DockerError = "docker version failed"
		}
	}
	k := filepath.Join(apps, ".kasbah")
	s.AppsState = fsstate.Dir(apps)
	s.MarkerState = fsstate.File(filepath.Join(k, "server.json"))
	s.KasbahDir = fsstate.Dir(k)
	for _, n := range entries(k) {
		switch n {
		case "server.json", "backup", serverlock.Name, buildpush.MapName:
		case "bin":
			for _, b := range entries(filepath.Join(k, "bin")) {
				if b == serverbin.LockName {
					s.BinLock = true
				}
				if !binOwn(b) {
					s.KasbahExtra = append(s.KasbahExtra, "bin/"+b)
				}
			}
		default:
			s.KasbahExtra = append(s.KasbahExtra, n)
		}
	}
	s.BinState = fsstate.File(serverbin.Path(apps))
	s.LayersMap = fsstate.File(filepath.Join(k, buildpush.MapName))
	s.AcmeDNS = serverinit.PresentDNS(filepath.Join(apps, "traefik", serverinit.DNSDir))
	s.BackupDir = fsstate.Dir(filepath.Join(k, "backup"))
	if derr == nil {
		s.BackupContainer = "absent"
		if out, err := docker("", "container", "inspect", "-f", "{{.State.Status}}", BackupContainer); err == nil {
			s.BackupContainer = flat(out)
		}
		s.BackupVolume, s.BackupNetwork = "absent", "absent"
		if _, err := docker("", "volume", "inspect", BackupVolume); err == nil {
			s.BackupVolume = "present"
		}
		if _, err := docker("", "network", "inspect", BackupNetwork); err == nil {
			s.BackupNetwork = "present"
		}
	} else {
		s.BackupContainer, s.BackupVolume, s.BackupNetwork = "unknown", "unknown", "unknown"
	}

	s.PointerState = fsstate.File(pointer)
	s.PointerDir = fsstate.Dir(filepath.Dir(pointer))
	for _, n := range entries(filepath.Dir(pointer)) {
		if n != filepath.Base(pointer) {
			s.PointerDirOther++
		}
	}
	s.Sudo = sudoState()

	mail := filepath.Join(apps, "mail")
	s.MailDir = fsstate.Dir(mail)
	s.MailEnvState = fsstate.File(filepath.Join(mail, ".env"))
	s.MailEnvExtra = countMailExtra(filepath.Join(mail, ".env"))
	s.RegistryState = fsstate.File(filepath.Join(mail, "kasbah.yml"))

	es, _ := os.ReadDir(apps)
	for _, e := range es {
		n := e.Name()
		if isReserved(n) {
			continue
		}
		// Only a project name is a project: README.md and .DS_Store belong to
		// whoever put them there.
		if !reName.MatchString(n) {
			s.Skipped = append(s.Skipped, n)
			continue
		}
		d := filepath.Join(apps, n)
		left := leftovers(d)
		r := Row{Name: n, Dir: fsstate.Dir(d),
			Vlog: fsstate.File(filepath.Join(d, "versions.log")), VlogGz: fsstate.File(filepath.Join(d, "versions.log.gz")),
			Scripts: fsstate.Dir(filepath.Join(d, "scripts")),
			Lock:    fsstate.File(filepath.Join(d, ".deploy.lock")), Client: fsstate.File(filepath.Join(d, ".kasbah-client")),
			Env: fsstate.File(filepath.Join(d, ".env")), Sentinels: countSentinels(filepath.Join(d, ".env")),
			Prev: prevState(filepath.Join(d, ".kasbah-prev")), Seeds: len(seeds(d)), Kept: len(left.Kept), Unpacked: len(left.Unpacked), Hooks: fsstate.File(filepath.Join(d, ".kasbah-hooks.json"))}
		for _, f := range entries(filepath.Join(d, "scripts")) {
			if helper(f) {
				r.Helpers++
			} else {
				r.Other++
			}
		}
		s.Projects = append(s.Projects, r)
	}
	s.Count = len(s.Projects)
	return s
}

func helper(name string) bool {
	for _, h := range Helpers {
		if h == name {
			return true
		}
	}
	return false
}

// ProjectResult is one project's verdicts, in the order the act did them.
type ProjectResult struct {
	Name    string `json:"name"`
	Vlog    string `json:"vlog"`
	VlogGz  string `json:"vlog_gz"`
	Scripts string `json:"scripts"`
	Lock    string `json:"lock"`
	Client  string `json:"client"`
	Env     string `json:"env"`
	Prev    string `json:"prev"`
	Seeds   string `json:"seeds"`
	Kept    string `json:"kept"`
	Hooks   string `json:"hooks"`
}

// ActReport is what `kasbah remote destroy act` did. A `started=yes` line
// precedes it: every guard is above that line.
type ActReport struct {
	BkDown       string `json:"bk_down"`
	BkDownDetail string `json:"bk_down_detail"`
	BkContainer  string `json:"bk_container"`
	// BkLaunchers is the labelled launchers: removed, absent or failed.
	BkLaunchers  string          `json:"bk_launchers"`
	BkVolume     string          `json:"bk_volume"`
	BkNetwork    string          `json:"bk_network"`
	BkFiles      string          `json:"bk_files"`
	Projects     []ProjectResult `json:"projects"`
	MailEnv      string          `json:"mail_env"`
	MailEnvN     int             `json:"mail_env_n"`
	MailRegistry string          `json:"mail_registry"`
	LayersMap    string          `json:"layers_map"`
	// AcmeDNS is the DNS providers' credentials: removed, absent or failed.
	AcmeDNS string `json:"acme_dns"`
	// Marker is removed, absent, failed — or held, when anything above
	// failed: the marker is how a second run finds this server.
	Marker string `json:"marker"`
}

var actKeys = []string{"bk_down", "bk_down_detail", "bk_container", "bk_launchers", "bk_volume", "bk_network", "bk_files",
	"projects", "mail_env", "mail_env_n", "mail_registry", "layers_map", "acme_dns", "marker"}

// rewrite replaces a file's lines through keep, beside the file it resolves
// to: written whole and checked before it is renamed over, mode kept.
// stripped, noblock (nothing dropped), absent, unreadable or failed.
func rewrite(path string, keep func(string) bool, mode os.FileMode) string {
	target := path
	if fi, err := os.Lstat(path); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		t, err := filepath.EvalSymlinks(path)
		if err != nil {
			// readlink -f: a link whose last component is missing names no file.
			if dangling(path) {
				return "absent"
			}
			return "unreadable"
		}
		target = t
	}
	fi, err := os.Stat(target)
	switch {
	case err != nil && !fsstate.Exists(target):
		return "absent"
	case err != nil || !fi.Mode().IsRegular():
		return "unreadable"
	case !fsstate.Access(target, fsstate.R|fsstate.W):
		return "unreadable"
	}
	b, err := os.ReadFile(target)
	if err != nil {
		return "unreadable"
	}
	out, n := filter(b, keep)
	if n == 0 {
		return "noblock"
	}
	if mode == 0 {
		mode = fi.Mode().Perm()
	}
	if remote.Install(target, out, mode) != nil {
		return "failed"
	}
	return "stripped"
}

// dangling is whether a symlink resolves up to its final component, which
// does not exist.
func dangling(link string) bool {
	t, err := os.Readlink(link)
	if err != nil {
		return false
	}
	if !filepath.IsAbs(t) {
		t = filepath.Join(filepath.Dir(link), t)
	}
	dir, err := filepath.EvalSymlinks(filepath.Dir(t))
	if err != nil {
		return false
	}
	_, err = os.Lstat(filepath.Join(dir, filepath.Base(t)))
	return errors.Is(err, os.ErrNotExist)
}

func act(apps string, names []string, stdout io.Writer) error {
	if len(apps) < 2 || apps[0] != '/' {
		return fmt.Errorf("refusing to act: apps path '%s' is not an absolute path", apps)
	}
	if strings.HasSuffix(apps, "/") {
		return fmt.Errorf("refusing to act: apps path '%s' ends in a slash", apps)
	}
	for _, n := range names {
		if !reName.MatchString(n) {
			return fmt.Errorf("refusing to act: project name '%s' is not a lower-case letter followed by letters, digits and hyphens, and every path this step touches is built from it", n)
		}
		if isReserved(n) {
			return fmt.Errorf("refusing to act: '%s' is a directory kasbah owns under %s, not a project", n, apps)
		}
	}
	sl, err := serverlock.Take(apps, serverlock.Exclusive, "server destroy")
	if err != nil {
		return err
	}
	if sl != nil {
		defer sl.Close()
	}
	// A dropped session does not strand the act half way.
	signal.Ignore(syscall.SIGHUP, syscall.SIGPIPE)
	fmt.Fprintln(stdout, "started=yes")

	bad := false
	r := ActReport{Projects: []ProjectResult{}}
	k := filepath.Join(apps, ".kasbah")
	bdir := filepath.Join(k, "backup")

	// Stopped, not merely unlinked: a schedule left running would push the
	// new owner's data into the departing operator's storage.
	_, cerr := docker("", "container", "inspect", BackupContainer)
	if fi, err := os.Stat(bdir); cerr == nil || (err == nil && fi.IsDir()) {
		out, err := docker("/", "compose", "-p", BackupProject, "down", "--remove-orphans")
		r.BkDown = "ok"
		r.BkDownDetail = flat(out)
		if err != nil {
			r.BkDown, r.BkDownDetail, bad = "failed", err.Error(), true
		}
	} else {
		r.BkDown = "skipped"
	}
	obj := func(inspect, rm []string) string {
		if _, err := docker("", inspect...); err != nil {
			return "absent"
		}
		if _, err := docker("", rm...); err != nil {
			bad = true
			return "failed"
		}
		return "removed"
	}
	r.BkContainer = obj([]string{"container", "inspect", BackupContainer}, []string{"rm", "-f", BackupContainer})
	// A launcher a stopped scheduler left holds the host's / mounted.
	r.BkLaunchers = "absent"
	if ids, err := docker("", "ps", "-aq", "--filter", "label="+BackupLauncherLabel); err != nil {
		r.BkLaunchers, bad = "failed", true
	} else if l := strings.Fields(ids); len(l) > 0 {
		r.BkLaunchers = "removed"
		if _, err := docker("", append([]string{"rm", "-f"}, l...)...); err != nil {
			r.BkLaunchers, bad = "failed", true
		}
	}
	r.BkVolume = obj([]string{"volume", "inspect", BackupVolume}, []string{"volume", "rm", BackupVolume})
	r.BkNetwork = obj([]string{"network", "inspect", BackupNetwork}, []string{"network", "rm", BackupNetwork})
	r.BkFiles = "absent"
	if _, err := os.Stat(bdir); err == nil {
		r.BkFiles = "removed"
		if os.RemoveAll(bdir) != nil {
			r.BkFiles, bad = "failed", true
		}
	}

	for _, n := range names {
		d := filepath.Join(apps, n)
		p := ProjectResult{Name: n,
			Vlog: fsstate.Remove(filepath.Join(d, "versions.log")), VlogGz: fsstate.Remove(filepath.Join(d, "versions.log.gz"))}
		sd := filepath.Join(d, "scripts")
		if fi, err := os.Stat(sd); err == nil && fi.IsDir() {
			p.Scripts = "removed"
			for _, h := range Helpers {
				if fsstate.Remove(filepath.Join(sd, h)) == "failed" {
					p.Scripts = "failed"
				}
			}
			if p.Scripts == "removed" && syscall.Rmdir(sd) != nil {
				p.Scripts = "kept"
			}
		} else if fsstate.Exists(sd) {
			p.Scripts = "notdir"
		} else {
			p.Scripts = "absent"
		}
		p.Lock = fsstate.Remove(filepath.Join(d, ".deploy.lock"))
		p.Client = fsstate.Remove(filepath.Join(d, ".kasbah-client"))
		p.Hooks = fsstate.Remove(filepath.Join(d, ".kasbah-hooks.json"))
		p.Prev = removePrev(filepath.Join(d, ".kasbah-prev"))
		p.Seeds = removeSeeds(d)
		p.Kept = removeKept(d)
		// The sentinel comments go; KASBAH_CPU_LIMIT and KASBAH_MEM_LIMIT
		// stay, because compose interpolates them into every service.
		p.Env = rewrite(filepath.Join(d, ".env"), func(l string) bool { return !sentinel(l) }, 0)
		for _, v := range []string{p.Vlog, p.VlogGz, p.Scripts, p.Lock, p.Client, p.Hooks, p.Prev, p.Seeds, p.Kept} {
			if v == "failed" {
				bad = true
			}
		}
		// A .env still claiming kasbah rewrites it has not been de-branded.
		if p.Env == "failed" || p.Env == "unreadable" {
			bad = true
		}
		r.Projects = append(r.Projects, p)
	}

	// The operator's relay block, and every line kasbah cannot prove is not a
	// credential. postfix-accounts.cf stays: the postmaster must still log in.
	menv := filepath.Join(apps, "mail", ".env")
	if b, err := os.ReadFile(menv); err == nil {
		_, r.MailEnvN = filter(b, mailKeep)
	}
	switch v := rewrite(menv, mailKeep, 0o600); v {
	case "stripped":
		r.MailEnv = "stripped"
	case "noblock":
		r.MailEnv, r.MailEnvN = "unchanged", 0
	case "absent":
		r.MailEnv, r.MailEnvN = "absent", 0
	default:
		r.MailEnv, r.MailEnvN, bad = v, 0, true
	}
	r.MailRegistry = fsstate.Remove(filepath.Join(apps, "mail", "kasbah.yml"))
	if r.MailRegistry == "failed" {
		bad = true
	}

	r.LayersMap = fsstate.Remove(filepath.Join(k, buildpush.MapName))
	if r.LayersMap == "failed" {
		bad = true
	}

	r.AcmeDNS = removeAcmeDNS(apps)
	if r.AcmeDNS == "failed" {
		bad = true
	}

	r.Marker = "held"
	if !bad {
		r.Marker = fsstate.Remove(filepath.Join(k, "server.json"))
		// Unlinked while held so .kasbah can go; a command that reaches the
		// server after this refuses it for want of a marker before locking.
		os.Remove(serverlock.Path(apps))
	}
	b, _ := json.Marshal(r)
	fmt.Fprintf(stdout, "%s\n", b)
	return nil
}

// dnsEnvLine is a line of the env_file block server init renders into
// Traefik's compose.yml.
var dnsEnvLine = regexp.MustCompile(`^(    env_file:|      - ` + serverinit.DNSDir + `/[a-z0-9]+\.env|    # Each DNS provider's credentials, .*)$`)

// removeAcmeDNS takes the DNS providers' credentials, agency-owned, off the
// server: compose.yml's env_file block first, so the stack still comes up
// from its own files, then the directory. The running Traefik keeps them.
func removeAcmeDNS(apps string) string {
	dir := filepath.Join(apps, "traefik", serverinit.DNSDir)
	if !fsstate.Exists(dir) {
		return "absent"
	}
	switch rewrite(filepath.Join(apps, "traefik", "compose.yml"), func(l string) bool { return !dnsEnvLine.MatchString(l) }, 0) {
	case "stripped", "noblock", "absent":
	default:
		return "failed"
	}
	if os.RemoveAll(dir) != nil {
		return "failed"
	}
	return "removed"
}

// Remote is the server's half: `scan APPS POINTER` reads, `act APPS NAME…`
// de-brands everything but the pointer and the binary itself.
func Remote(args []string, stdout, stderr io.Writer) int {
	switch {
	case len(args) == 3 && args[0] == "scan":
		b, _ := json.Marshal(scan(args[1], args[2]))
		fmt.Fprintf(stdout, "%s\n", b)
		return 0
	case len(args) >= 2 && args[0] == "act":
		if err := act(args[1], args[2:], stdout); err != nil {
			fmt.Fprintf(stderr, "remote: %v\n", err)
			return 1
		}
		return 0
	}
	fmt.Fprintln(stderr, "remote: usage: kasbah remote destroy scan APPS POINTER | act APPS NAME…")
	return 1
}

// prevState is the snapshot directory's fsstate.Dir; a symlink there is
// notdir, never followed.
func prevState(p string) string {
	if fi, err := os.Lstat(p); err == nil && !fi.IsDir() {
		return "notdir"
	}
	return fsstate.Dir(p)
}

// seedPrefix names a staged --env-seed and its staging files (env.SeedName).
const seedPrefix = ".kasbah-env-seed"

// seeds is d's staged --env-seed files: they hold .env values.
func seeds(d string) []string {
	var out []string
	for _, n := range entries(d) {
		if strings.HasPrefix(n, seedPrefix+".") {
			out = append(out, filepath.Join(d, n))
		}
	}
	return out
}

// removeSeeds removes every staged --env-seed in d.
func removeSeeds(d string) string {
	v := "absent"
	for _, p := range seeds(d) {
		v = "removed"
		if os.Remove(p) != nil && fsstate.Exists(p) {
			return "failed"
		}
	}
	return v
}

// kept is d's kept-aside snapshots and leftover extractions: they hold a copy
// of .env.
func kept(d string) []string {
	l := leftovers(d)
	l.Backups = nil
	return l.Paths(d)
}

// leftovers is deploy's scan of d, nothing when d is not a directory.
func leftovers(d string) deploy.Leftovers {
	if fsstate.Dir(d) != "dir" {
		return deploy.Leftovers{}
	}
	return deploy.ScanLeftovers(d)
}

// removeKept removes every kept-aside snapshot in d.
func removeKept(d string) string {
	v := "absent"
	for _, p := range kept(d) {
		v = "removed"
		if os.RemoveAll(p) != nil {
			return "failed"
		}
	}
	return v
}

// removePrev removes a failed deploy's snapshot: it holds a copy of .env.
func removePrev(p string) string {
	if !fsstate.Exists(p) {
		return "absent"
	}
	if os.RemoveAll(p) != nil {
		return "failed"
	}
	return "removed"
}
