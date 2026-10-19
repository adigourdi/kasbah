package serverinit

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/remote"
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
		return fail("usage: kasbah remote init read APPS | layout APPS DATA | write PATH SIZE SHA256 | acme-reset ACME STAMP | start APPS RESTART TIMEOUT | marker APPS SIZE SHA256")
	}
	if len(args) == 0 {
		return usage()
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
		err = remoteAcmeReset(args[1], args[2], stdout)
	case args[0] == "start" && len(args) == 4:
		t, perr := strconv.Atoi(args[3])
		if perr != nil {
			return usage()
		}
		err = remoteStart(args[1], args[2] == "yes", time.Duration(t)*time.Second, stdout, stderr)
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
	return json.NewEncoder(stdout).Encode(r)
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
	if err := os.Chmod(acme, 0o600); err != nil {
		return fmt.Errorf("could not set mode 600 on %s", acme)
	}
	fmt.Fprintf(stdout, "acme=%s\n", state)
	return nil
}

// install writes body beside path and renames it over, mode set first: a
// reader — Traefik's file watcher above all — sees the old file or the new.
func install(path string, body []byte, mode fs.FileMode) error {
	tmp := fmt.Sprintf("%s.tmp.%d", path, os.Getpid())
	if err := os.WriteFile(tmp, body, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not write %s", tmp)
	}
	if err := os.Chmod(tmp, mode); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not set mode %o on %s", mode, tmp)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("could not install %s", path)
	}
	return nil
}

func remoteWrite(path, size, sum string, stdin io.Reader, stdout io.Writer) error {
	body, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	if err := install(path, body, 0o644); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "written=yes")
	return nil
}

// remoteAcmeReset archives the store beside itself — never deletes it, the
// certificates may be real — and leaves an empty one at mode 600.
func remoteAcmeReset(acme, stamp string, stdout io.Writer) error {
	exists, regular := isFile(acme)
	if exists && !regular {
		return fmt.Errorf("%s exists and is not a regular file — Traefik needs a file there. Remove it (rm -rf '%s') and re-run.", acme, acme)
	}
	archive := ""
	if regular {
		archive = acme + "." + stamp
		if _, err := os.Lstat(archive); err == nil {
			return fmt.Errorf("%s is already there — kasbah will not write over an archived certificate store", archive)
		}
		if err := os.Rename(acme, archive); err != nil {
			return fmt.Errorf("could not archive %s as %s", acme, archive)
		}
		if err := os.Chmod(archive, 0o600); err != nil {
			return fmt.Errorf("could not set mode 600 on %s", archive)
		}
	}
	fmt.Fprintf(stdout, "acme_archive=%s\n", archive)
	f, err := os.OpenFile(acme, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return fmt.Errorf("could not create %s", acme)
	}
	f.Close()
	if err := os.Chmod(acme, 0o600); err != nil {
		return fmt.Errorf("could not set mode 600 on %s", acme)
	}
	fmt.Fprintln(stdout, "acme_reset=done")
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
	if err := install(marker, body, 0o644); err != nil {
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

// remoteStart is `compose up -d`, a restart only when the static config
// changed and up did not just (re)create the container, then the health wait.
// Always -p: COMPOSE_PROJECT_NAME in a login shell outranks `name:`.
func remoteStart(apps string, restart bool, timeout time.Duration, stdout, stderr io.Writer) error {
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
	if err := dc("up", "-d"); err != nil {
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

// errSaid is a failure already explained on stderr.
var errSaid = errors.New("")
