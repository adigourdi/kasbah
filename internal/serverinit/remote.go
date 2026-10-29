package serverinit

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"

	markerpkg "github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// Remote is `kasbah remote init <step> …`, run by the server binary. Each step
// reports on stdout as key=value lines (read: one JSON object) and says what
// went wrong on stderr as `remote: …`, exit 1.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	usage := func() int {
		return fail("usage: kasbah remote init read APPS | layout APPS DATA | write PATH SIZE SHA256 | acme-reset ACME STAMP | start APPS RESTART TIMEOUT [ACME STAMP] | marker APPS SIZE SHA256")
	}
	if len(args) == 0 {
		return usage()
	}
	if args[0] != "read" {
		w, done := remote.Outlive(stderr)
		defer done()
		stderr = w
	}
	var err error
	switch {
	case args[0] == "read" && len(args) == 2:
		err = remoteRead(args[1], stdout)
	case args[0] == "layout" && len(args) == 3:
		err = remoteLayout(args[1], args[2], stdout)
	case args[0] == "write" && len(args) == 4:
		err = remoteWrite(args[1], args[2], args[3], stdin, stdout)
	case args[0] == "acme-reset" && len(args) == 3:
		// Kept for 1.0.0 workstations, which reset before `start`.
		err = remoteAcmeReset(args[1], args[2], stdout)
	case args[0] == "start" && (len(args) == 4 || len(args) == 6):
		t, perr := strconv.Atoi(args[3])
		if perr != nil {
			return usage()
		}
		var acme, stamp string
		if len(args) == 6 {
			acme, stamp = args[4], args[5]
		}
		err = remoteStart(args[1], args[2] == "yes", time.Duration(t)*time.Second, acme, stamp, stdout, stderr)
	case args[0] == "marker" && len(args) == 4:
		err = remoteMarker(args[1], args[2], args[3], stdin, stdout)
	default:
		return usage()
	}
	if err == errSaid {
		return 1
	}
	if err != nil {
		return fail("%v", err)
	}
	return 0
}

// ReadReport is what `remote init read` finds under an existing apps path.
type ReadReport struct {
	Marker  string            `json:"marker"`
	Body    string            `json:"marker_b64"`
	Traefik map[string]string `json:"traefik_b64"`
	// Hosts are each project fragment's Host(`…`) names, by file name.
	Hosts map[string][]string `json:"fragment_hosts"`
}

// b64 is a file's bytes, "" for one that is absent, not regular or
// unreadable — nothing to compare against, so it is shipped.
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

func remoteRead(apps string, stdout io.Writer) error {
	r := ReadReport{Marker: "absent", Traefik: map[string]string{}}
	marker := apps + "/.kasbah/server.json"
	if fi, err := os.Stat(marker); err == nil {
		if !fi.Mode().IsRegular() {
			return fmt.Errorf("%s exists and is not a regular file", marker)
		}
		b, err := os.ReadFile(marker)
		if err != nil {
			return fmt.Errorf("could not read %s: %v", marker, err)
		}
		r.Marker, r.Body = "present", base64.StdEncoding.EncodeToString(b)
	}
	for _, rel := range Files {
		r.Traefik[rel] = b64(apps + "/traefik/" + rel)
	}
	r.Hosts = fragmentHosts(apps + "/traefik/dynamic")
	return json.NewEncoder(stdout).Encode(r)
}

var reHost = regexp.MustCompile("Host\\(`([^`]+)`\\)")

// fragmentHosts reads every .yml/.yaml in dir not prefixed `_` (kasbah's own).
func fragmentHosts(dir string) map[string][]string {
	hosts := map[string][]string{}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		n := e.Name()
		if strings.HasPrefix(n, "_") || !e.Type().IsRegular() || !(strings.HasSuffix(n, ".yml") || strings.HasSuffix(n, ".yaml")) {
			continue
		}
		b, err := os.ReadFile(dir + "/" + n)
		if err != nil {
			continue
		}
		for _, m := range reHost.FindAllStringSubmatch(strings.ReplaceAll(string(b), "\r", ""), -1) {
			hosts[n] = append(hosts[n], m[1])
		}
	}
	return hosts
}

// isFile is `[ -f ]`, symlinks followed.
func isFile(p string) (exists, regular bool) {
	fi, err := os.Stat(p)
	if err != nil {
		_, lerr := os.Lstat(p)
		return lerr == nil, false
	}
	return true, fi.Mode().IsRegular()
}

// remoteLayout is everything below an apps path that already exists and
// belongs to this user, unelevated; acme.json is touched as a file, since
// Docker materialises a missing bind-mount source as a directory.
func remoteLayout(apps, data string, stdout io.Writer) error {
	for _, d := range []string{apps + "/.kasbah", apps + "/backups", apps + "/traefik/dynamic", data, data + "/traefik/letsencrypt"} {
		if err := os.MkdirAll(d, 0o777); err != nil {
			return fmt.Errorf("could not create %s", d)
		}
	}
	acme := data + "/traefik/letsencrypt/acme.json"
	exists, regular := isFile(acme)
	if exists && !regular {
		return fmt.Errorf("%s exists and is not a regular file — Traefik needs a file there. Remove it (rm -rf '%s') and re-run.", acme, acme)
	}
	state := "existed"
	if !exists {
		f, err := os.OpenFile(acme, os.O_WRONLY|os.O_CREATE, 0o666)
		if err != nil {
			return fmt.Errorf("could not create %s", acme)
		}
		f.Close()
		state = "created"
	}
	if err := serverlock.EnsureMode(acme, 0o600); err != nil {
		return err
	}
	// What every operator writes beside init, put back to its group mode where
	// it is this user's; the root step's file find covers the others'.
	for p, m := range map[string]os.FileMode{
		markerpkg.Path(apps):           markerpkg.Mode,
		serverlock.Path(apps):          serverlock.Mode,
		apps + "/.kasbah/migrate.lock": serverlock.Mode,
		apps + "/.kasbah/bin/.lock":    serverlock.Mode,
		apps + "/.kasbah/bin/kasbah":   0o775,
	} {
		if fi, err := os.Lstat(p); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm() != m && serverlock.Owned(fi) {
			os.Chmod(p, m)
		}
	}
	fmt.Fprintf(stdout, "acme=%s\n", state)
	return nil
}

func remoteWrite(path, size, sum string, stdin io.Reader, stdout io.Writer) error {
	body, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	if err := remote.Install(path, body, 0o644); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "written=yes")
	return nil
}

// remoteAcmeReset copies the store beside itself — never deletes it, the
// certificates may be real — then empties it in place at mode 600: the same
// inode, so DMS's file bind mount sees the reset and every later renewal.
func remoteAcmeReset(acme, stamp string, stdout io.Writer) error {
	exists, regular := isFile(acme)
	if exists && !regular {
		return fmt.Errorf("%s exists and is not a regular file — Traefik needs a file there. Remove it (rm -rf '%s') and re-run.", acme, acme)
	}
	archive := ""
	if regular {
		archive = acme + "." + stamp
		if err := archiveCopy(acme, archive); err != nil {
			return err
		}
	}
	fmt.Fprintf(stdout, "acme_archive=%s\n", archive)
	f, err := os.OpenFile(acme, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("could not empty %s in place: %v", acme, err)
	}
	f.Close()
	if err := serverlock.EnsureMode(acme, 0o600); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "acme_reset=done")
	return nil
}

// archiveCopy writes src's bytes to a new dst at mode 600, synced, and proves
// the copy is all of src; one that is not is removed and src left as it was.
func archiveCopy(src, dst string) error {
	if _, err := os.Lstat(dst); err == nil {
		return fmt.Errorf("%s is already there — kasbah will not write over an archived certificate store", dst)
	}
	fail := fmt.Errorf("could not archive %s as %s", src, dst)
	in, err := os.Open(src)
	if err != nil {
		return fail
	}
	defer in.Close()
	out, err := os.OpenFile(dst, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fail
	}
	n, cerr := io.Copy(out, in)
	if fi, err := in.Stat(); cerr == nil && (err != nil || fi.Size() != n) {
		cerr = fmt.Errorf("the source changed size during the copy")
	}
	if serr := out.Sync(); cerr == nil {
		cerr = serr
	}
	if xerr := out.Close(); cerr == nil {
		cerr = xerr
	}
	if cerr == nil {
		cerr = os.Chmod(dst, 0o600)
	}
	// Read back whole and compared: the store need not be JSON to be reset.
	if cerr == nil {
		got, err1 := os.ReadFile(dst)
		want, err2 := os.ReadFile(src)
		if err1 != nil || err2 != nil || !bytes.Equal(got, want) {
			cerr = fmt.Errorf("the archived copy does not read back as the store")
		}
	}
	if cerr != nil {
		os.Remove(dst)
		return fmt.Errorf("%v (%v) — acme.json was not emptied", fail, cerr)
	}
	return nil
}

// remoteMarker writes the marker only when it differs, so a re-run does not
// even move its mtime. Trailing newlines do not count, as in `$(cat)`.
func remoteMarker(apps, size, sum string, stdin io.Reader, stdout io.Writer) error {
	marker := apps + "/.kasbah/server.json"
	body, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", marker, err)
	}
	exists, regular := isFile(marker)
	if exists && !regular {
		return fmt.Errorf("%s exists and is not a regular file", marker)
	}
	if regular {
		cur, err := os.ReadFile(marker)
		if err != nil {
			return fmt.Errorf("could not read %s", marker)
		}
		if bytes.Equal(bytes.TrimRight(cur, "\n"), bytes.TrimRight(body, "\n")) {
			fmt.Fprintln(stdout, "marker=unchanged")
			return nil
		}
	}
	if err := remote.Install(marker, body, markerpkg.Mode); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "marker=written")
	return nil
}

// docker runs docker with its output on stderr, so stdout stays the report.
func docker(stderr io.Writer, dir string, args ...string) error {
	cmd := exec.Command("docker", args...)
	cmd.Dir = dir
	cmd.Stdout, cmd.Stderr = stderr, stderr
	return cmd.Run()
}

func inspect(id, format string) (string, error) {
	out, err := exec.Command("docker", "inspect", "-f", format, id).Output()
	return strings.TrimRight(string(out), "\n"), err
}

// remoteStart is `compose -p traefik up -d` (a restart only when the static config
// changed and up did not), then the health wait. A reset runs between a stop and
// the up: a running Traefik would save its in-memory store back into the file.
func remoteStart(apps string, restart bool, timeout time.Duration, acme, stamp string, stdout, stderr io.Writer) error {
	dir := apps + "/traefik"
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return fmt.Errorf("could not enter %s", dir)
	}
	const project = "traefik"
	dc := func(args ...string) error {
		return docker(stderr, dir, append([]string{"compose", "-p", project}, args...)...)
	}
	cid := func() string {
		cmd := exec.Command("docker", "compose", "-p", project, "ps", "-a", "-q", "traefik")
		cmd.Dir = dir
		out, _ := cmd.Output()
		return strings.TrimSpace(string(out))
	}
	startedAt := func(id string) string { s, _ := inspect(id, "{{.State.StartedAt}}"); return s }

	before := ""
	if id := cid(); id != "" {
		before = startedAt(id)
	}
	var resetErr error
	if acme != "" {
		if err := dc("stop", "traefik"); err != nil {
			resetErr = fmt.Errorf("docker compose -p %s stop traefik failed, so acme.json was not reset", project)
		} else {
			resetErr = remoteAcmeReset(acme, stamp, stdout)
		}
	}
	// Up whatever the reset did: Traefik is never left down.
	upErr := dc("up", "-d")
	if resetErr != nil {
		state := "Traefik is up on the store as it was"
		if upErr != nil {
			state = "and starting Traefik again failed too — see docker's error above"
		}
		return resetByHand(resetErr, state, dir, acme, stamp)
	}
	if upErr != nil {
		return fmt.Errorf("docker compose -p %s up -d failed in %s", project, dir)
	}
	id := cid()
	if id == "" {
		return errors.New("compose reported no traefik container after up -d")
	}
	if restart && before != "" && before == startedAt(id) {
		if err := dc("restart", "traefik"); err != nil {
			return fmt.Errorf("docker compose -p %s restart traefik failed", project)
		}
	}

	diagnose := func(msg string) error {
		fmt.Fprintf(stderr, "remote: %s\n", msg)
		dc("ps", "-a")
		dc("logs", "--no-color", "--tail", "60")
		return errSaid
	}
	deadline := time.Now().Add(timeout)
	health := ""
	for {
		h, err := inspect(id, "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}")
		if err != nil {
			h = "gone"
		}
		health = h
		if health == "healthy" {
			break
		}
		if health == "none" {
			return diagnose("the traefik container declares no healthcheck — compose.yml lost it")
		}
		if running, err := inspect(id, "{{.State.Running}}"); err != nil || running != "true" {
			return diagnose(fmt.Sprintf("traefik is not running (health %s) — it exited instead of coming up", health))
		}
		if !time.Now().Before(deadline) {
			return diagnose(fmt.Sprintf("traefik did not report healthy within %ds (last health: %s)", int(timeout/time.Second), health))
		}
		time.Sleep(2 * time.Second)
	}

	after := startedAt(id)
	action := "running"
	switch {
	case before == "":
		action = "started"
	case before != after:
		action = "restarted"
	}
	name, _ := inspect(id, "{{.Name}}")
	image, _ := inspect(id, "{{.Config.Image}}")
	fmt.Fprintf(stdout, "traefik_action=%s\ntraefik_health=%s\ntraefik_started_at=%s\ntraefik_image=%s\ntraefik_container=%s\n",
		action, health, after, image, strings.TrimPrefix(name, "/"))
	return nil
}

// resetByHand is a failed reset's refusal: traefik.yml already names the new CA,
// so a re-run of init sees nothing to switch, and the reset is done by hand.
func resetByHand(err error, state, dir, acme, stamp string) error {
	return fmt.Errorf("%v; %s.\n"+
		"A re-run of init will not redo the reset: traefik.yml already names the new CA.\n"+
		"Reset the store by hand (: > keeps the inode DMS's mount follows):\n"+
		"  cd %s && docker compose -p traefik stop traefik\n"+
		"  cp -p %s %s.%s\n"+
		"  : > %s\n"+
		"  docker compose -p traefik up -d", err, state, dir, acme, acme, stamp, acme)
}

// errSaid is a failure already explained on stderr.
var errSaid = errors.New("")
