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
last=${@: -1}
printf '%s\n' "$last" >> "$SSH_LOG"
exec bash -c "$last"`,
		"docker": `case "$1 $2" in
"version --format") echo 27.1.0 ;;
"compose version") echo 2.29.7 ;;
*) exit 1 ;;
esac`,
		"rsync": "exit 0", "openssl": "exit 0", "gzip": "exit 0",
	}
	for name, body := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/bash\n"+body+"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("SSH_LOG", sshLog)
	return dir, sshLog
}

func runScript(t *testing.T, script string, env []string, args ...string) (string, string, int) {
	t.Helper()
	cmd := exec.Command("bash", append([]string{"-s", "--"}, args...)...)
	cmd.Stdin = strings.NewReader(script)
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
	for name, s := range map[string]string{"probe": probeScript, "elevate": elevateScript, "pointer": pointerScript} {
		cmd := exec.Command("bash", "-n")
		cmd.Stdin = strings.NewReader(s)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Errorf("%s: %v %s", name, err, out)
		}
	}
}

func TestProbeScript(t *testing.T) {
	stubs(t)
	root := t.TempDir()
	apps, data, ptr := root+"/apps", root+"/apps/data", root+"/etc/kasbah/apps-path"
	out, e, rc := runScript(t, probeScript, nil, apps, data, ptr)
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
	out, _, _ = runScript(t, probeScript, []string{"STUB_SUDO=no"}, apps, data, ptr)
	f, _ = ParseProbe("d@h", out)
	if f["apps_state"] != "dir" || f["apps_owned"] != "yes" || f["acme_store"] != "nonempty" ||
		f["pointer_state"] != "present" || f["pointer_value"] != "/srv/apps" || f["sudo_nopasswd"] != "no" {
		t.Errorf("prepared host: %v", f)
	}
	if err := Preflight(f, "d@h", apps, data); err != nil {
		t.Errorf("a stubbed host fails preflight: %v", err)
	}
}

func TestElevateScript(t *testing.T) {
	stubs(t)
	apps := t.TempDir() + "/a/apps"
	out, e, rc := runScript(t, elevateScript, nil, apps, "u:g")
	if fi, err := os.Stat(apps); rc != 0 || out != "elevated=yes\n" || err != nil || !fi.IsDir() {
		t.Fatalf("elevate: %q %q %d", out, e, rc)
	}
	if _, e, rc := runScript(t, elevateScript, nil, apps, "u:g"); rc != 1 || !strings.Contains(e, "exists after all") {
		t.Errorf("an existing path is not adopted: %q %d", e, rc)
	}
}

func TestPointerScript(t *testing.T) {
	stubs(t)
	ptr := t.TempDir() + "/etc/kasbah/apps-path"
	dir := filepath.Dir(ptr)
	uid := strconv.Itoa(os.Getuid())
	run := func(env ...string) (Facts, string, int) {
		out, e, rc := runScript(t, pointerScript, env, "/srv/apps", ptr, uid)
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
	os.WriteFile(ptr, []byte("/apps\n"), 0o644)
	if f, _, _ := run("STUB_SUDO=no"); f["pointer"] != "nosudo" {
		t.Errorf("wrong content without sudo: %v", f)
	}
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
	if !strings.Contains(errText(err), "--domain=<value>") {
		t.Fatalf("unanswered: %v", err)
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
