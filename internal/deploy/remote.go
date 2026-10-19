package deploy

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// RemoteUsage names `kasbah remote deploy`'s modes.
const RemoteUsage = "usage: kasbah remote deploy prepare APPS DATA NAME CLIENT [DIR…] | run DIR (spec on stdin) | mail APPS | seed CONTAINER PATH (file on stdin)"

// Remote is `kasbah remote deploy …` on a server. stdout is a protocol in
// every mode; narration and docker's output go to stderr.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, RemoteUsage)
		return 1
	}
	switch {
	case args[0] == "run" && len(args) == 2:
		return Engine(args[1], stdin, stdout, stderr)
	case args[0] == "prepare" && len(args) >= 5:
		return prepare(args[1], args[2], args[3], args[4], args[5:], stdout, stderr)
	case args[0] == "mail" && len(args) == 2:
		return mailFacts(args[1], stdout)
	case args[0] == "seed" && len(args) == 3:
		return seed(args[1], args[2], stdin, stdout)
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
		tmp := record + ".tmp." + strconv.Itoa(os.Getpid())
		if os.WriteFile(tmp, []byte(client+"\n"), 0o666) != nil {
			os.Remove(tmp)
			return fail("could not write %s", tmp)
		}
		if os.Chmod(tmp, 0o644) != nil {
			return fail("could not set mode 644 on %s", tmp)
		}
		if os.Rename(tmp, record) != nil {
			return fail("could not install %s", record)
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
	Snappymail  string `json:"snappymail"`
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
		f.DMS, f.Snappymail = "nodocker", "nodocker"
	} else {
		f.DMS, f.Snappymail = containerState("mail-dms"), containerState("mail-snappymail")
	}
	b, _ := json.Marshal(f)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}

// seed copies a SnappyMail domain config into the container when it is not
// already there. Through docker cp, because SnappyMail owns its data tree at
// 750 under its own uid, and docker cp works on a stopped container too.
func seed(container, target string, stdin io.Reader, stdout io.Writer) int {
	state := "nocontainer"
	if exec.Command("docker", "inspect", container).Run() == nil {
		state = "failed"
		if tmp, err := os.MkdirTemp("", "tmp."); err == nil {
			switch {
			case exec.Command("docker", "cp", container+":"+target, filepath.Join(tmp, "probe")).Run() == nil:
				state = "present"
			default:
				f, err := os.Create(filepath.Join(tmp, "domain.json"))
				if err == nil {
					_, cerr := io.Copy(f, bufio.NewReader(stdin))
					if f.Close() == nil && cerr == nil &&
						exec.Command("docker", "cp", filepath.Join(tmp, "domain.json"), container+":"+target).Run() == nil {
						state = "copied"
					}
				}
			}
			os.RemoveAll(tmp)
		}
	}
	fmt.Fprintf(stdout, "mail_seed=%s\n", state)
	return 0
}
