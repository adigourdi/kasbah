package backup

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
)

// fakeDocker is `docker run … IMAGE --no-cache ARGS` against a repository
// whose behaviour PROBE_MODE picks: append-only, delete, unreachable,
// unwritable, unlisted.
const fakeDocker = `#!/bin/sh
state="$PROBE_STATE"
printf '%s\n' "$*" >> "$state/calls"
[ "$1" != rm ] || exit 0
envfile=""
while [ $# -gt 0 ]; do
  case $1 in
    --env-file) envfile=$2; shift 2 ;;
    --no-cache) shift; break ;;
    *) shift ;;
  esac
done
cp "$envfile" "$state/env"
n=$(cat "$state/n" 2>/dev/null || echo 0)
case "$PROBE_MODE:$1" in
  hang:cat) exec sleep 60 ;;
  unreachable:*) echo "Fatal: unable to open config file" >&2; exit 1 ;;
  *:cat) [ -e "$state/init" ] ;;
  *:init) : > "$state/init" ;;
  unwritable:backup) exit 1 ;;
  secondwrite:backup) [ "$n" -lt 1 ] || exit 4; echo 1 > "$state/n" ;;
  *:backup) echo $((n + 1)) > "$state/n" ;;
  unlisted:list) exit 3 ;;
  listafter:list) [ ! -e "$state/forgot" ] || exit 5; i=0; while [ $i -lt "$n" ]; do echo "abcd000$i"; i=$((i + 1)); done ;;
  listafter:forget) : > "$state/forgot" ;;
  *:list) i=0; while [ $i -lt "$n" ]; do echo "abcd000$i"; i=$((i + 1)); done ;;
  delete:forget) echo $((n - 1)) > "$state/n" ;;
  *:forget) echo "unable to remove"; exit 0 ;;
esac
`

func fakeEnv(t *testing.T, mode string) (apps, state string) {
	apps, _ = appsTree(t)
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=rest:http://real/\nAWS_ACCESS_KEY_ID=theirs\nRESTIC_REPOSITORY=sneaky\nKASBAH_BACKUP_SOMETHING=x\n")
	bin := t.TempDir()
	state = t.TempDir()
	write(t, bin+"/docker", fakeDocker)
	os.Chmod(bin+"/docker", 0o755)
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("PROBE_MODE", mode)
	t.Setenv("PROBE_STATE", state)
	t.Setenv("TMPDIR", t.TempDir())
	return apps, state
}

func probeWith(t *testing.T, mode string) (map[string]string, string) {
	apps, state := fakeEnv(t, mode)
	var out bytes.Buffer
	if err := Probe(apps, ResticImage, 30*time.Second, &out); err != nil {
		t.Fatal(err)
	}
	f := map[string]string{}
	for _, l := range strings.Split(strings.TrimSpace(out.String()), "\n") {
		k, v, _ := strings.Cut(l, "=")
		f[k] = v
	}
	if ents, _ := os.ReadDir(os.Getenv("TMPDIR")); len(ents) != 0 {
		t.Errorf("the probe left %v", ents)
	}
	return f, state
}

func TestProbe(t *testing.T) {
	f, state := probeWith(t, "appendonly")
	if f["probe_stage"] != "deleted" || f["probe_mid"] != "2" || f["probe_after"] != "2" || f["probe_repo"] != "rest:http://real/kasbah.probe" {
		t.Errorf("%v", f)
	}
	env := read(t, state+"/env")
	if env != "AWS_ACCESS_KEY_ID=theirs\nRESTIC_REPOSITORY=rest:http://real/kasbah.probe\nRESTIC_PASSWORD_FILE=/probe/pass\n" {
		t.Errorf("probe env:\n%s", env)
	}
	calls := read(t, state+"/calls")
	if !strings.Contains(calls, "--hostname kasbah-probe") || !strings.Contains(calls, "forget abcd0000 --prune") || strings.Contains(calls, "theirs") {
		t.Errorf("calls:\n%s", calls)
	}
	if log, _ := base64.StdEncoding.DecodeString(f["probe_log_b64"]); !strings.Contains(string(log), "unable to remove") {
		t.Errorf("log %q", log)
	}

	for mode, want := range map[string]map[string]string{
		"delete":      {"probe_stage": "deleted", "probe_mid": "2", "probe_after": "1"},
		"unreachable": {"probe_stage": "reach", "probe_rc": "1"},
		"unwritable":  {"probe_stage": "write"},
		"unlisted":    {"probe_stage": "unlisted", "probe_when": "before", "probe_rc": "3"},
		"listafter":   {"probe_stage": "unlisted", "probe_when": "after", "probe_mid": "2", "probe_rc": "5"},
		"secondwrite": {"probe_stage": "write", "probe_rc": "4"},
	} {
		f, _ := probeWith(t, mode)
		for k, v := range want {
			if f[k] != v {
				t.Errorf("%s: %s=%q, want %q (%v)", mode, k, f[k], v, f)
			}
		}
	}
}

func TestProbeNoEnv(t *testing.T) {
	apps, _ := appsTree(t)
	if err := Probe(apps, ResticImage, time.Second, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "no credentials to test") {
		t.Error(err)
	}
	write(t, apps+"/.kasbah/backup/env", "A=1\n")
	if err := Probe(apps, ResticImage, time.Second, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "sets no KASBAH_BACKUP_REPO_BASE") {
		t.Error(err)
	}
}

// A report nobody reads is a write error, and the credential scratch is gone
// before the write is even tried.
func TestProbeClosedPipe(t *testing.T) {
	apps, _ := fakeEnv(t, "appendonly")
	pr, pw, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	pr.Close()
	defer pw.Close()
	var errb bytes.Buffer
	if rc := RemoteInit([]string{"probe", apps, ResticImage, "30"}, nil, pw, &errb); rc != 1 || !strings.Contains(errb.String(), "broken pipe") {
		t.Errorf("rc %d: %s", rc, errb.String())
	}
	if ents, _ := os.ReadDir(os.Getenv("TMPDIR")); len(ents) != 0 {
		t.Errorf("the probe left %v", ents)
	}
}

// TestProbeHelper is the server binary's `remote backup-init` for
// TestProbeSIGTERM: signals handled as cmd/kasbah handles them.
func TestProbeHelper(t *testing.T) {
	if os.Getenv("KASBAH_PROBE_HELPER") != "1" {
		t.Skip("run by TestProbeSIGTERM")
	}
	atexit.HandleSignals()
	atexit.Exit(RemoteInit(os.Args[len(os.Args)-4:], os.Stdin, os.Stdout, os.Stderr))
}

func TestProbeSIGTERM(t *testing.T) {
	apps, state := fakeEnv(t, "hang")
	tmp := os.Getenv("TMPDIR")
	cmd := exec.Command(os.Args[0], "-test.run=^TestProbeHelper$", "--", "probe", apps, ResticImage, "30")
	cmd.Env = append(os.Environ(), "KASBAH_PROBE_HELPER=1")
	var said bytes.Buffer
	cmd.Stdout, cmd.Stderr = &said, &said
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		if m, _ := filepath.Glob(tmp + "/kasbah-backup-probe.*/env"); len(m) == 1 {
			break
		}
		if time.Now().After(deadline) {
			cmd.Process.Kill()
			cmd.Wait()
			t.Fatalf("the probe never wrote its scratch: %s", said.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
	cmd.Process.Signal(syscall.SIGTERM)
	err := cmd.Wait()
	if ee, ok := err.(*exec.ExitError); !ok || ee.ExitCode() != 143 {
		t.Errorf("exit: %v %s", err, said.String())
	}
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("SIGTERM left %v", ents)
	}
	if calls, _ := os.ReadFile(state + "/calls"); !strings.Contains(string(calls), "cat config") {
		t.Errorf("the hanging call never ran: %s", calls)
	} else {
		rmCoversRuns(t, string(calls))
	}
}

// rmCoversRuns is whether the last call removes every container a run named.
func rmCoversRuns(t *testing.T, calls string) {
	t.Helper()
	var names []string
	lines := strings.Split(strings.TrimSpace(calls), "\n")
	for _, l := range lines {
		f := strings.Fields(l)
		for i := 0; i+1 < len(f); i++ {
			if f[0] == "run" && f[i] == "--name" {
				names = append(names, f[i+1])
			}
		}
	}
	last := lines[len(lines)-1]
	if len(names) == 0 || last != "rm -f "+strings.Join(names, " ") {
		t.Errorf("named %v, last call %q", names, last)
	}
	for i, n := range names {
		if !strings.HasPrefix(n, "kasbah-probe-") || !strings.HasSuffix(n, fmt.Sprintf("-%d", i+1)) {
			t.Errorf("container name %q", n)
		}
	}
}

func TestProbeRemovesContainers(t *testing.T) {
	for _, mode := range []string{"appendonly", "unreachable"} {
		_, state := probeWith(t, mode)
		rmCoversRuns(t, read(t, state+"/calls"))
	}
}
