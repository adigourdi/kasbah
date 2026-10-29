package deploy

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/remote"
)

// RemoteUsage names `kasbah remote deploy`'s modes.
const RemoteUsage = "usage: kasbah remote deploy prepare APPS DATA NAME CLIENT [DIR…] | snapshot DIR TOKEN TARGET… | run DIR (spec on stdin) | mail APPS | images VERSION IMAGE…"

// Remote is `kasbah remote deploy …` on a server. stdout is a protocol in
// every mode; narration and docker's output go to stderr.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, RemoteUsage)
		return 1
	}
	// The modes that change state finish whether or not anyone still reads.
	switch {
	case args[0] == "run" && len(args) == 2:
		w, done := remote.Outlive(stderr)
		defer done()
		return Engine(args[1], stdin, stdout, w)
	case args[0] == "snapshot" && len(args) >= 3:
		w, done := remote.Outlive(stderr)
		defer done()
		return takeSnapshot(args[1], args[2], args[3:], stdout, w)
	case args[0] == "prepare" && len(args) >= 5:
		w, done := remote.Outlive(stderr)
		defer done()
		return prepare(args[1], args[2], args[3], args[4], args[5:], stdout, w)
	case args[0] == "mail" && len(args) == 2:
		return mailFacts(args[1], stdout)
	case args[0] == "images" && len(args) >= 2:
		return images(args[1], args[2:], stdout)
	}
	fmt.Fprintln(stderr, RemoteUsage)
	return 1
}

// prepare makes the directories a deploy writes into and records the
// effective client: for the backup runner, by temp + rename, only when it
// changed. Nothing is created unless the server was prepared by init.
func prepare(apps, data, name, client string, parents []string, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	if fi, err := os.Stat(apps); err != nil || !fi.IsDir() {
		return fail("%s is not a directory", apps)
	}
	if fi, err := os.Stat(apps + "/traefik/dynamic"); err != nil || !fi.IsDir() {
		return fail("%s/traefik/dynamic is not a directory", apps)
	}
	for _, d := range append([]string{apps + "/" + name, apps + "/" + name + "/backups", data + "/" + name}, parents...) {
		if os.MkdirAll(d, 0o777) != nil {
			return fail("could not create %s", d)
		}
	}
	record := apps + "/" + name + "/.kasbah-client"
	state := "written"
	if fi, err := os.Lstat(record); err == nil && !fi.Mode().IsRegular() {
		return fail("%s exists and is not a regular file", record)
	}
	if b, err := os.ReadFile(record); err == nil {
		if first, _, ok := strings.Cut(string(b), "\n"); ok && first == client {
			state = "unchanged"
		}
	}
	if state == "written" {
		if err := remote.Install(record, []byte(client+"\n"), 0o644); err != nil {
			return fail("%v", err)
		}
	}
	fmt.Fprintf(stdout, "client=%s\nprepared=yes\n", state)
	return 0
}

// MailFacts is what the mail claim needs from the server, read-only.
type MailFacts struct {
	Stack       bool   `json:"stack"`
	Env         bool   `json:"env"`
	Registry    string `json:"registry_b64"`
	DMS         string `json:"dms"`
	HasRegistry bool   `json:"registry"`
}

func containerState(c string) string {
	out, err := exec.Command("docker", "inspect", "-f", "{{.State.Status}}", c).Output()
	s := strings.TrimSpace(string(out))
	if err != nil || s == "" {
		return "absent"
	}
	return s
}

func mailFacts(apps string, stdout io.Writer) int {
	dir := apps + "/mail"
	var f MailFacts
	if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
		f.Stack = true
	}
	if fi, err := os.Stat(dir + "/.env"); err == nil && fi.Mode().IsRegular() {
		f.Env = true
	}
	if fi, err := os.Stat(dir + "/kasbah.yml"); err == nil && fi.Mode().IsRegular() {
		if b, err := os.ReadFile(dir + "/kasbah.yml"); err == nil {
			f.Registry, f.HasRegistry = base64.StdEncoding.EncodeToString(b), true
		}
	}
	if _, err := exec.LookPath("docker"); err != nil {
		f.DMS = "nodocker"
	} else {
		f.DMS = containerState("mail-dms")
	}
	b, _ := json.Marshal(f)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}

// images reports which <image>:<version> are no longer on the server. The
// count says the check ran over the whole set: a missing= computed over fewer
// images is an empty answer that looks like a pass.
func images(version string, list []string, stdout io.Writer) int {
	var missing []string
	for _, img := range list {
		if exec.Command("docker", "image", "inspect", img+":"+version).Run() != nil {
			missing = append(missing, img)
		}
	}
	fmt.Fprintf(stdout, "checked=%d\nmissing=%s\n", len(list), strings.Join(missing, ","))
	return 0
}
