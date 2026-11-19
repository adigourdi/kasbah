package deploy

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/fsstate"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/trace"
)

// RemoteUsage names `kasbah remote deploy`'s modes.
const RemoteUsage = "usage: kasbah remote deploy prepare APPS DATA NAME CLIENT [DIR…] | snapshot DIR TOKEN TARGET… | run DIR (spec on stdin) | unroute APPS NAME | fragment APPS NAME SIZE SHA256 TARGET [--tagged] (fragment on stdin) | mail APPS | images VERSION IMAGE… | backup DIR | backup-probe DIR VERSION | restore-env DIR BACKUP --all|KEY… | restore-env DIR --undo TOKEN | backup-probe DIR --backup NAME | restore-list APPS NAME [SNAPSHOT] [--from-path=PATH] | fetch DIR SNAPSHOT BACKUP [--from-path=PATH] | restore DIR BACKUP LIVE [--env=all|--env=KEY,…] [--data]"

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
		return Engine(args[1], stdin, stdout, w, stderr)
	case args[0] == "snapshot" && len(args) >= 3:
		w, done := remote.Outlive(stderr)
		defer done()
		return takeSnapshot(args[1], args[2], args[3:], stdout, w)
	case args[0] == "prepare" && len(args) >= 5:
		w, done := remote.Outlive(stderr)
		defer done()
		return prepare(args[1], args[2], args[3], args[4], args[5:], stdout, w)
	case args[0] == "unroute" && len(args) == 3:
		w, done := remote.Outlive(stderr)
		defer done()
		return unroute(args[1], args[2], stdout, w)
	case args[0] == "fragment" && (len(args) == 6 || len(args) == 7 && args[6] == "--tagged"):
		w, done := remote.Outlive(stderr)
		defer done()
		return installFragment(args[1], args[2], args[3], args[4], args[5], len(args) == 7, stdin, stdout, w)
	case args[0] == "backup" && len(args) == 2:
		w, done := remote.Outlive(stderr)
		defer done()
		return takeBackup(args[1], time.Now, stdout, w)
	case args[0] == "restore-env" && len(args) == 4 && args[2] == "--undo":
		w, done := remote.Outlive(stderr)
		defer done()
		return undoEnv(args[1], args[3], stdout, w)
	case args[0] == "restore-env" && len(args) >= 4:
		w, done := remote.Outlive(stderr)
		defer done()
		return restoreEnv(args[1], args[2], args[3:], stdout, w)
	case args[0] == "backup-probe" && len(args) == 4 && args[2] == "--backup":
		return probeBackup(args[1], "", args[3], stdout, stderr)
	case args[0] == "backup-probe" && len(args) == 3:
		return backupProbe(args[1], args[2], stdout, stderr)
	case args[0] == "restore-list" && len(args) >= 3:
		if rest, from, ok := fromPathArg(args[3:]); ok && len(rest) <= 1 {
			return restoreList(args[1], args[2], strings.Join(rest, ""), from, stdout, stderr)
		}
	case args[0] == "fetch" && len(args) >= 4:
		if rest, from, ok := fromPathArg(args[4:]); ok && len(rest) == 0 {
			w, done := remote.Outlive(stderr)
			defer done()
			return fetchBackup(args[1], args[2], args[3], from, stdout, w)
		}
	case args[0] == "restore" && len(args) >= 4:
		w, done := remote.Outlive(stderr)
		defer done()
		return restoreArm(args[1], args[2], args[3], args[4:], stdout, w, stderr)
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
	if err := checkBackups(apps + "/" + name); err != nil {
		return fail("%s", cli.Full(err))
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
			return fail("%s", cli.Full(err))
		}
	}
	fmt.Fprintf(stdout, "client=%s\nprepared=yes\n", state)
	return 0
}

// unroute removes an unrouted project's leftover route file, never anything
// but a file: route=removed, or route=absent when there was none.
func unroute(apps, name string, stdout, stderr io.Writer) int {
	if !manifest.ValidName(name) {
		fmt.Fprintf(stderr, "remote: invalid project name '%s'\n", name)
		return 1
	}
	p := filepath.Join(apps, "traefik", "dynamic", name+".yml")
	if fi, err := os.Lstat(p); err == nil && fi.IsDir() {
		fmt.Fprintf(stderr, "remote: %s is a directory, not a route file — move it aside (Traefik reads no route from it), then re-run the deploy\n", p)
		return 1
	}
	st := fsstate.Remove(p)
	if st == "failed" {
		fmt.Fprintf(stderr, "remote: could not remove %s\n", p)
		return 1
	}
	fmt.Fprintf(stdout, "route=%s\n", st)
	return 0
}

// FragmentMode is an installed fragment's: it may carry the project's
// secrets, so it is no more readable than .env is.
const FragmentMode = 0o640

// installFragment renders the fragment on stdin (RenderFragment), refuses a
// dotted name on Traefik's networks (dotted), scopes its backends to the
// project's kasbah network (scopeFragment) and renames it over
// <apps>/traefik/dynamic/<name>.yml: fragment=written, or unchanged for the
// bytes already there. A failure leaves the live file as it was.
func installFragment(apps, name, size, sum, target string, tagged bool, stdin io.Reader, stdout, stderr io.Writer) int {
	if !manifest.ValidName(name) {
		fmt.Fprintf(stderr, "remote: invalid project name '%s'\n", name)
		return 1
	}
	dest := filepath.Join(apps, "traefik", "dynamic", name+".yml")
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+" — %s was left as it was\n", append(a, dest)...)
		return 1
	}
	var body []byte
	if _, empty := remote.Digest(nil); size != "0" || sum != empty {
		var err error
		if body, err = remote.Payload(stdin, size, sum); err != nil {
			return fail("%v", err)
		}
	}
	// The engine's pre-flight rendered it first and named what it kept.
	dir := filepath.Join(apps, name)
	out, _, err := RenderFragment(dir, body, target, tagged)
	if err != nil {
		return fail("%v", err)
	}
	model := sync.OnceValues(func() (*composeModel, error) { return readModel(name, composeQuery(dir)) })
	if m, err := model(); err == nil {
		if err := m.foreign(name); err != nil {
			return fail("%v", err)
		}
		if err := m.clashes(name); err != nil {
			return fail("%v", err)
		}
	}
	run := map[bool]string{false: "deploy", true: "deploy X.Y.Z or rollback"}[tagged]
	out, err = scopeFragment(body, out, scoping{name, target, run, model})
	if err != nil {
		return fail("%v", err)
	}
	if fi, err := os.Lstat(dest); err == nil && fi.IsDir() {
		return fail("%s is a directory, not a route file: move it aside (Traefik reads no route from it), then re-run the deploy", dest)
	} else if err == nil && fi.Mode().IsRegular() && fi.Mode().Perm() == FragmentMode {
		if cur, err := os.ReadFile(dest); err == nil && bytes.Equal(cur, out) {
			fmt.Fprintln(stdout, "fragment=unchanged")
			return 0
		}
	}
	if err := remote.Install(dest, out, FragmentMode); err != nil {
		return fail("%v", err)
	}
	fmt.Fprintln(stdout, "fragment=written")
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
	out, err := trace.Output(exec.Command("docker", "inspect", "-f", "{{.State.Status}}", c))
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
		if trace.Run(exec.Command("docker", "image", "inspect", img+":"+version)) != nil {
			missing = append(missing, img)
		}
	}
	fmt.Fprintf(stdout, "checked=%d\nmissing=%s\n", len(list), strings.Join(missing, ","))
	return 0
}
