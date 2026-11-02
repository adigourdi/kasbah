package deploy

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

// hostRig is liveRig's apps path with more projects beside demo.
func hostRig(t *testing.T) (*rig, string) {
	r := liveRig(t)
	apps := filepath.Dir(r.dir)
	project := func(name, log string, hooks ...string) string {
		d := filepath.Join(apps, name)
		os.MkdirAll(d, 0o755)
		os.WriteFile(filepath.Join(d, ".env"), []byte("X=1\n"), 0o600)
		if log != "" {
			os.WriteFile(filepath.Join(d, "versions.log"), []byte(log), 0o640)
		}
		if hooks != nil {
			(&rig{dir: d}).hooksFile(hooks, ".env")
		}
		return d
	}
	project("fresh", "", "true")
	project("nohooks", live10)
	project("broken", live10, "echo half; exit 3")
	stale := project("stale", live10, "true")
	os.MkdirAll(filepath.Join(stale, PrevDir), 0o770)
	os.WriteFile(filepath.Join(stale, snapManifest), []byte(`{"token":"t","targets":[],"taken":"2026-09-01T00:00:00+00:00"}`), 0o660)
	project("mail", live10, "true")
	os.MkdirAll(filepath.Join(apps, ".kasbah"), 0o755)
	return r, apps
}

func runHost(apps string, deadline time.Time, env []string) (int, string, string) {
	var out, errb bytes.Buffer
	rc := hostBackup(apps, deadline, func() time.Time { return at10 }, env, &out, &errb)
	return rc, out.String(), errb.String()
}

// One line per project kasbah backs up: what it took, or why not; the
// hooks see the job's environment and nothing of what started it.
func TestHostBackupResults(t *testing.T) {
	r, apps := hostRig(t)
	seen := filepath.Join(t.TempDir(), "env")
	r.hooksFile([]string{`env | sort > ` + seen + `; pwd >> ` + seen + `; umask >> ` + seen}, ".env")
	t.Setenv("KASBAH_BACKUP_REPO_BASE", "leaked")
	rc, out, errs := runHost(apps, time.Now().Add(time.Minute), HostEnv(func(k string) string {
		return map[string]string{"HOME": "/home/stevedore", "USER": "stevedore", "KASBAH_BACKUP_USER": "x"}[k]
	}))
	lines := strings.Split(strings.TrimSuffix(out, "\n"), "\n")
	want := []string{
		"project broken failed the backup hook failed (exit 3): echo half; exit 3 — no backup of 1.0.0 was kept",
		"project demo ok backups/1.0.0-20261102-100000.tar.gz 1.0.0",
		"project fresh skipped no live version",
		"project nohooks skipped no .kasbah-hooks.json: no deploy has recorded its hooks",
		"project stale failed " + apps + "/stale/" + PrevDir + " holds a deploy's snapshot taken no later than the last run that went live (2026-10-01T00:00:00+00:00), so no deploy or rollback is using it: it is left over. Nothing was changed; remove " + apps + "/stale/" + PrevDir + " by hand, then back up",
	}
	if rc != 1 || len(lines) != len(want) {
		t.Fatalf("rc %d\n%s\n%s", rc, out, errs)
	}
	for i, w := range want {
		if !strings.HasPrefix(lines[i], w) {
			t.Errorf("line %d:\n%s\nwant\n%s", i, lines[i], w)
		}
	}
	env, _ := os.ReadFile(seen)
	for _, w := range []string{"PATH=" + HostPath + "\n", "LC_ALL=C\n", "HOME=/home/stevedore\n", "USER=stevedore\n", "KASBAH_PROJECT=demo\n", "\n" + r.dir + "\n"} {
		if !strings.Contains(string(env), w) {
			t.Errorf("hook env lacks %q:\n%s", w, env)
		}
	}
	if strings.Contains(string(env), "leaked") || strings.Contains(string(env), "KASBAH_BACKUP_USER") {
		t.Errorf("the job's environment leaked into the hook:\n%s", env)
	}
	if !strings.Contains(errs, "demo: backing up the live version") || !strings.Contains(errs, "half") {
		t.Errorf("stderr:\n%s", errs)
	}
}

// The deadline kills a hung hook with its whole process group, and the
// projects after it are named, not reached.
func TestHostBackupDeadline(t *testing.T) {
	defer func(g time.Duration) { killGrace = g }(killGrace)
	killGrace = 500 * time.Millisecond
	r, apps := hostRig(t)
	pids := filepath.Join(t.TempDir(), "pids")
	// The child ignores TERM: only the group's SIGKILL ends it.
	r.hooksFile([]string{`sh -c 'trap "" TERM; sleep 300' & echo $! > ` + pids + `; sleep 300`}, ".env")
	start := time.Now()
	rc, out, errs := runHost(apps, time.Now().Add(time.Second), []string{"PATH=" + os.Getenv("PATH")})
	if el := time.Since(start); rc != 1 || el > 10*time.Second {
		t.Fatalf("rc %d after %v\n%s%s", rc, el, out, errs)
	}
	if !strings.Contains(out, "project demo failed the backup hook was still running at the job's deadline (") ||
		!strings.Contains(out, "and was killed with its process group") ||
		!strings.Contains(out, "project fresh skipped") ||
		!strings.Contains(out, "project stale failed not backed up: the job's deadline had passed before its turn") {
		t.Errorf("%s", out)
	}
	b, _ := os.ReadFile(pids)
	pid, err := strconv.Atoi(strings.TrimSpace(string(b)))
	if err != nil {
		t.Fatalf("no pid: %q", b)
	}
	deadline := time.Now().Add(5 * time.Second)
	for alive(pid) && time.Now().Before(deadline) {
		time.Sleep(50 * time.Millisecond)
	}
	if alive(pid) {
		t.Errorf("the hook's child %d outlived the deadline", pid)
	}
	if len(r.backups()) != 0 {
		t.Errorf("backups/ holds %v", r.backups())
	}
}

// alive is a process that exists and is not a zombie.
func alive(pid int) bool {
	b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return false
	}
	_, rest, _ := strings.Cut(string(b), ") ")
	return !strings.HasPrefix(rest, "Z")
}

func TestHostBackupUsage(t *testing.T) {
	var out, errb bytes.Buffer
	for _, a := range [][]string{nil, {"/apps"}, {"apps", "10"}, {"/apps", "0"}, {"/apps", "x"}} {
		errb.Reset()
		if rc := HostBackup(a, &out, &errb); rc != 1 || !strings.Contains(errb.String(), hostUsage) {
			t.Errorf("%v: %d %s", a, rc, errb.String())
		}
	}
}
