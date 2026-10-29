package serverinit

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/shtest"
)

// stubs puts a fake sudo, ssh and docker, and the tools the probe looks for,
// first on PATH. sudo insists on -n and fakes chown (no test is root); ssh
// runs its remote command here, logging it; STUB_SUDO=no is a host without.
func stubs(t *testing.T) (dir, sshLog string) {
	t.Helper()
	dir = t.TempDir()
	sshLog = filepath.Join(dir, "ssh.log")
	files := map[string]string{
		"sudo": `[ "$1" = -n ] || exit 97
[ "${STUB_SUDO:-yes}" = yes ] || exit 1
shift
[ "$1" = chown ] && exit 0
exec "$@"`,
		"ssh": `for a in "$@"; do [ "$a" = -O ] && exit 0; done
for last in "$@"; do :; done
printf '%s\n' "$last" >> "$SSH_LOG"
exec sh -c "$last"`,
		"docker": `case "$1 $2" in
"version --format") echo 27.1.0 ;;
"compose version") echo 2.29.7 ;;
*) exit 1 ;;
esac`,
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("SSH_LOG", sshLog)
	return dir, sshLog
}

func runScript(t *testing.T, sh shtest.Shell, script string, env []string, args ...string) (string, string, int) {
	t.Helper()
	cmd := sh.Stdin(script, args...)
	cmd.Env = append(os.Environ(), env...)
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	err := cmd.Run()
	rc := 0
	if ee, ok := err.(*exec.ExitError); ok {
		rc = ee.ExitCode()
	} else if err != nil {
		t.Fatal(err)
	}
	return o.String(), e.String(), rc
}

func TestScriptsParse(t *testing.T) {
	shtest.Check(t, "serverinit", map[string]string{"probe": probeScript, "elevate": elevateScript, "pointer": pointerScript, "group": groupScript})
}

func TestGroupScript(t *testing.T) { eachShell(t, testGroupScript) }

// testGroupScript: no group is everything to do; a group the tree is not
// reads as tree and directories to do, on the resolved path of a symlinked
// apps path; entries owned by no one considered are left out.
func testGroupScript(t *testing.T, sh shtest.Shell) {
	stubs(t)
	root := t.TempDir()
	real, apps := root+"/real", root+"/my apps"
	os.MkdirAll(real+"/demo", 0o755)
	os.Symlink(real, apps)
	os.WriteFile(real+"/demo/.env", nil, 0o660)
	os.Chmod(real+"/demo/.env", 0o660)
	me := strconv.Itoa(os.Getuid())
	// root's primary group is root's: uid 0 is an owner the step considers.
	out, e, rc := runScript(t, sh, groupScript, nil, apps, apps+"/data", me, "no-such-group-kasbah")
	f, err := checked("group", "d@h", out, groupKeys...)
	if rc != 0 || err != nil || f["group_exists"] != "no" || f["group_tree"] != "yes" || f["group_sudo"] != "yes" || f["group_apps"] != real {
		t.Fatalf("no group: %d %v %v %s", rc, err, f, e)
	}
	out, e, rc = runScript(t, sh, groupScript, []string{"STUB_SUDO=no"}, apps, apps+"/data", me, "root")
	f, err = checked("group", "d@h", out, groupKeys...)
	if rc != 0 || err != nil || f["group_exists"] != "yes" || f["group_sudo"] != "no" || f["group_uids"] != strings.TrimSuffix(me+",0", map[bool]string{true: ",0"}[me == "0"]) ||
		f["group_tree"] != "yes" || f["group_dirs"] != "yes" || f["group_files"] != "no" {
		t.Fatalf("root's group: %d %v %v %s", rc, err, f, e)
	}
	os.Chmod(real+"/demo/.env", 0o600)
	out, _, _ = runScript(t, sh, groupScript, []string{"STUB_SUDO=no"}, apps, apps+"/data", me, "root")
	if f, _ := checked("group", "d@h", out, groupKeys...); f["group_files"] != "yes" {
		t.Errorf("a 600 .env through the symlinked apps path: %v", f)
	}
}

func TestGroupBlock(t *testing.T) {
	all := Facts{"group_exists": "no", "group_member": "no", "group_tree": "yes", "group_dirs": "yes", "group_data": "yes", "group_files": "yes",
		"group_apps": "/srv/my apps", "group_datadir": "/srv/my apps/data", "group_uids": "1000,1001"}
	b := GroupBlock(all, "d@h", "/apps", "/apps/data", "ops")
	tree := `sudo find '/srv/my apps' \( -path '/srv/my apps/data' -o -path '/srv/my apps/data' \) -prune -o \( -user 1000 -o -user 1001 \)`
	want := []string{
		"sudo groupadd kasbah",
		"sudo usermod -aG kasbah ops",
		tree + " ! -group kasbah -exec chgrp -h kasbah {} +",
		`sudo find '/srv/my apps' \( -path '/srv/my apps/data' -o -path '/srv/my apps/data' \) -prune -o -type d \( -user 1000 -o -user 1001 \) -perm /070 ! -perm -2070 -exec chmod g+rwxs {} +`,
		`sudo find '/srv/my apps/data' -maxdepth 0 -type d \( -user 1000 -o -user 1001 \) -exec chgrp -h kasbah {} + -exec chmod g+rwxs {} +`,
	}
	if len(b.Commands) != 6 || strings.Join(b.Commands[:5], "\n") != strings.Join(want, "\n") ||
		!strings.Contains(b.Commands[5], "! -path '/srv/my apps/mail/.env'") || !strings.Contains(b.Commands[5], "-path '/srv/my apps/.kasbah/migrate.lock'") {
		t.Fatalf("block:\n%s", strings.Join(b.Commands, "\n"))
	}
	none := Facts{"group_exists": "yes", "group_member": "yes", "group_tree": "no", "group_dirs": "no", "group_data": "no", "group_files": "no"}
	if b := GroupBlock(none, "d@h", "/apps", "/apps/data", "ops"); !b.Empty() {
		t.Errorf("a converged server needs %v", b.Commands)
	}
}

// eachShell runs f once per POSIX sh the scripts are held to.
func eachShell(t *testing.T, f func(*testing.T, shtest.Shell)) {
	for _, sh := range shtest.Shells(t) {
		t.Run(sh.Name, func(t *testing.T) { f(t, sh) })
	}
}

func TestProbeScript(t *testing.T) { eachShell(t, testProbeScript) }

func testProbeScript(t *testing.T, sh shtest.Shell) {
	stubs(t)
	root := t.TempDir()
	apps, data, ptr := root+"/my apps", root+"/my apps/data", root+"/etc/kasbah/apps-path"
	out, e, rc := runScript(t, sh, probeScript, nil, apps, data, ptr)
	f, err := ParseProbe("d@h", out)
	if rc != 0 || err != nil {
		t.Fatalf("probe: %d %v %s", rc, err, e)
	}
	if f["apps_state"] != "absent" || f["apps_root_state"] != "absent" || f["pointer_state"] != "absent" ||
		f["sudo_nopasswd"] != "yes" || f["acme_store"] != "absent" || f["compose_version"] != "2.29.7" {
		t.Errorf("bare host: %v", f)
	}
	os.MkdirAll(data+"/traefik/letsencrypt", 0o755)
	os.WriteFile(data+"/traefik/letsencrypt/acme.json", []byte("{}"), 0o600)
	os.MkdirAll(filepath.Dir(ptr), 0o755)
	os.WriteFile(ptr, []byte("/srv//apps/ \n"), 0o644)
	out, _, _ = runScript(t, sh, probeScript, []string{"STUB_SUDO=no"}, apps, data, ptr)
	f, _ = ParseProbe("d@h", out)
	if f["apps_state"] != "dir" || f["apps_owned"] != "yes" || f["acme_store"] != "nonempty" ||
		f["pointer_state"] != "present" || f["pointer_value"] != "/srv/apps" || f["sudo_nopasswd"] != "no" {
		t.Errorf("prepared host: %v", f)
	}
	if err := Preflight(f, "d@h", apps, data, false); err != nil {
		t.Errorf("a stubbed host fails preflight: %v", err)
	}
	// Owned but stripped of its write bit: the errno is what tells it from a
	// read-only mount.
	os.WriteFile(ptr, []byte("/sp ace//x/\t\r\n"), 0o644)
	os.Chmod(apps, 0o555)
	defer os.Chmod(apps, 0o755)
	out, _, _ = runScript(t, sh, probeScript, []string{"STUB_SUDO=no"}, apps, data, ptr)
	f, _ = ParseProbe("d@h", out)
	if f["pointer_value"] != "/sp ace/x" || f["apps_owned"] != "yes" || f["apps_writable"] != "no" ||
		!strings.Contains(f["apps_write_error"], "Permission denied") {
		t.Errorf("stripped apps path: %v", f)
	}
}

func TestElevateScript(t *testing.T) { eachShell(t, testElevateScript) }

func testElevateScript(t *testing.T, sh shtest.Shell) {
	stubs(t)
	apps := t.TempDir() + "/a b/apps"
	out, e, rc := runScript(t, sh, elevateScript, nil, apps, "u:g")
	if fi, err := os.Stat(apps); rc != 0 || out != "elevated=yes\n" || err != nil || !fi.IsDir() {
		t.Fatalf("elevate: %q %q %d", out, e, rc)
	}
	if _, e, rc := runScript(t, sh, elevateScript, nil, apps, "u:g"); rc != 1 || !strings.Contains(e, "exists after all") {
		t.Errorf("an existing path is not adopted: %q %d", e, rc)
	}
}

func TestPointerScript(t *testing.T) { eachShell(t, testPointerScript) }

func testPointerScript(t *testing.T, sh shtest.Shell) {
	stubs(t)
	ptr := t.TempDir() + "/etc/kasbah/apps-path"
	dir := filepath.Dir(ptr)
	uid := strconv.Itoa(os.Getuid())
	run := func(env ...string) (Facts, string, int) {
		out, e, rc := runScript(t, sh, pointerScript, env, "/srv/apps", ptr, uid)
		f := Facts{}
		absorb(f, out)
		return f, e, rc
	}
	if f, e, rc := run(); rc != 0 || f["pointer"] != "written" {
		t.Fatalf("first write: %v %q", f, e)
	}
	if b, _ := os.ReadFile(ptr); string(b) != "/srv/apps\n" || mode(t, ptr) != 0o644 || mode(t, dir) != 0o755 {
		t.Errorf("pointer %q %o, dir %o", b, mode(t, ptr), mode(t, dir))
	}
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "unchanged" || f["pointer_dir_mode"] != "" {
		t.Errorf("re-run without sudo: %v", f)
	}
	// A drifted directory: repaired with sudo, reported without.
	os.Chmod(dir, 0o711)
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "unchanged" || f["pointer_dir_mode"] != "711" {
		t.Errorf("drift without sudo: %v", f)
	}
	if f, _, _ := run(); f["pointer"] != "written" || mode(t, dir) != 0o755 {
		t.Errorf("drift with sudo: %v %o", f, mode(t, dir))
	}
	os.WriteFile(ptr, []byte("/srv/apps\r\n"), 0o644)
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "unchanged" {
		t.Errorf("a CRLF pointer: %v", f)
	}
	os.WriteFile(ptr, []byte("/apps\n"), 0o644)
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "nosudo" || f["pointer_dir"] != "755" {
		t.Errorf("wrong content without sudo: %v", f)
	}
	os.Chmod(dir, 0o700)
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "nosudo" || f["pointer_dir"] != "700" {
		t.Errorf("wrong content, drifted directory, without sudo: %v", f)
	}
	os.Chmod(dir, 0o755)
	os.Rename(ptr, dir+".pointer")
	os.Remove(dir)
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "nosudo" || f["pointer_dir"] != "absent" {
		t.Errorf("no directory without sudo: %v", f)
	}
	os.Mkdir(dir, 0o755)
	os.Rename(dir+".pointer", ptr)
	os.Remove(ptr)
	os.Mkdir(ptr, 0o755)
	if _, e, rc := run(); rc != 1 || !strings.Contains(e, "not a regular file") {
		t.Errorf("a directory pointer: %q %d", e, rc)
	}
}

func TestRemotePayloads(t *testing.T) {
	root := t.TempDir()
	os.MkdirAll(root+"/.kasbah", 0o755)
	body := "{\n  \"a\": 1\n}\n"
	size, sum := remote.Digest([]byte(body))
	for _, c := range []struct{ in, size, sum string }{
		{"", size, sum}, {body[:4], size, sum}, {body + "x", size, sum},
		{body, size, strings.Repeat("0", 64)}, {"", "0", sum},
	} {
		for _, args := range [][]string{{"marker", root}, {"write", root + "/f.yml"}} {
			_, e, rc := remoteRun(t, c.in, append(args, c.size, c.sum)...)
			if rc != 1 || !strings.Contains(e, "remote: ") {
				t.Errorf("%s %q accepted: %q", args[0], c.in, e)
			}
		}
	}
	if _, err := os.Stat(root + "/.kasbah/server.json"); err == nil {
		t.Error("a refused marker was installed")
	}
	if _, err := os.Stat(root + "/f.yml"); err == nil {
		t.Error("a refused file was installed")
	}
	if left, _ := filepath.Glob(root + "/*.tmp.*"); len(left) != 0 {
		t.Errorf("temp left: %v", left)
	}
}

// TestRunOrder drives Run through a local ssh: refusals and unanswerable
// questions come before anything is created or shipped.
func TestRunOrder(t *testing.T) {
	_, sshLog := stubs(t)
	tmp, err := os.MkdirTemp("", "k")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(tmp) })
	t.Setenv("TMPDIR", tmp)
	root := t.TempDir()
	saved := pointerPath
	pointerPath = root + "/etc/kasbah/apps-path"
	t.Cleanup(func() { pointerPath = saved })
	ctx := func() (Ctx, *bytes.Buffer) {
		out, b := newOut()
		return Ctx{Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: out}, Version: "1.0.0",
			Templates: repoTemplates(t),
			Local:     func(string) (string, error) { t.Fatal("the binary was shipped"); return "", nil },
			Hash:      func(string, string) (string, error) { t.Fatal("hashed"); return "", nil },
		}, b
	}
	apps := root + "/apps"
	o := Options{Target: "u@h", Apps: apps, Data: apps + "/data", Mail: prompt.No, Backup: prompt.No}

	// A bare host and a question nobody can answer: nothing created.
	c, _ := ctx()
	err = Run(c, o)
	if !strings.Contains(errText(err), "--with-dashboard or --no-dashboard") {
		t.Fatalf("unanswered: %v", err)
	}
	o.Dashboard = prompt.Yes
	c, _ = ctx()
	if err = Run(c, o); !strings.Contains(errText(err), "--domain=<value>") {
		t.Fatalf("unanswered domain: %v", err)
	}
	if _, err := os.Stat(apps); err == nil {
		t.Error("the apps path was created before every question was answered")
	}
	log, _ := os.ReadFile(sshLog)
	if strings.Contains(string(log), "remote") || strings.Contains(string(log), "uname") {
		t.Errorf("ssh ran more than the probe: %s", log)
	}

	// A pointer naming another tree is refused before the binary ships.
	os.MkdirAll(apps, 0o755)
	os.MkdirAll(filepath.Dir(pointerPath), 0o755)
	os.WriteFile(pointerPath, []byte("/elsewhere\n"), 0o644)
	os.Truncate(sshLog, 0)
	c, _ = ctx()
	if err := Run(c, o); !strings.Contains(errText(err), "already prepared at /elsewhere") {
		t.Fatalf("pointer conflict: %v", err)
	}
	if _, err := os.Stat(apps + "/.kasbah"); err == nil {
		t.Error("something was created under the apps path before the pointer check")
	}
	if log, _ := os.ReadFile(sshLog); strings.Count(string(log), "\n") != 2 {
		t.Errorf("more than the connect and the probe ran: %s", log)
	}
}
