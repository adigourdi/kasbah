package deploy

import (
	"bytes"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const v1line = "2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"

// revertRig is a project that ran 0.9.0 — its files, a :current, a log line —
// snapshotted under "tok", then overwritten by 1.0.0's files.
func revertRig(t *testing.T, ups string) *rig {
	t.Helper()
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line), 0o664)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte("v0.9.0\n"), 0o644)
	os.WriteFile(filepath.Join(r.dir, ".env"), []byte("A=old\n"), 0o660)
	os.WriteFile(r.images, []byte("demo-web:1.0.0\ndemo-web:current\n"), 0o644)
	r.running("demo-web=running", "demo-db=running", "cid=running")
	if ups != "" {
		f := filepath.Join(t.TempDir(), "ups")
		os.WriteFile(f, []byte(ups), 0o644)
		t.Setenv("UPS", f)
	}
	var out, errb bytes.Buffer
	if rc := takeSnapshot(r.dir, "tok", []string{".env", "compose.yml", "extra.txt"}, &out, &errb); rc != 0 || out.String() != "snapshot=written\n" {
		t.Fatalf("snapshot rc %d %q %s", rc, out.String(), errb.String())
	}
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte("v1.0.0\n"), 0o644)
	os.WriteFile(filepath.Join(r.dir, ".env"), []byte("A=new\n"), 0o660)
	os.WriteFile(filepath.Join(r.dir, "extra.txt"), []byte("new\n"), 0o644)
	return r
}

func (r *rig) revertSpec() Spec {
	sp := r.spec()
	sp.Backup, sp.Pre, sp.Snapshot = nil, nil, "tok"
	return sp
}

func (r *rig) logText() string {
	b, _ := os.ReadFile(filepath.Join(r.dir, "versions.log"))
	return string(b)
}

func (r *rig) restored(t *testing.T) {
	t.Helper()
	if b, _ := os.ReadFile(filepath.Join(r.dir, "compose.yml")); string(b) != "v0.9.0\n" {
		t.Errorf("compose.yml is %q", b)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, ".env")); string(b) != "A=old\n" {
		t.Errorf(".env is %q", b)
	}
	if _, err := os.Lstat(filepath.Join(r.dir, "extra.txt")); err == nil {
		t.Error("extra.txt, new in 1.0.0, survived the revert")
	}
}

func count(calls []string, prefix string) int {
	n := 0
	for _, c := range calls {
		if strings.HasPrefix(c, prefix) {
			n++
		}
	}
	return n
}

func TestEngineRevertsAFailedUp(t *testing.T) {
	r := revertRig(t, "1\n0\n")
	rc, out, errs := r.run(r.revertSpec())
	if rc != 1 || !strings.Contains(errs, "failed (up) and was reverted — the server is back on 0.9.0") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if f := ParseFailure(out); f == nil || f.Outcome != Reverted || f.Reason != "up" || f.Prev != "0.9.0" {
		t.Fatalf("failure line %q", out)
	}
	if _, _, found := ParseReport(out); found {
		t.Error("a reverted run printed a report")
	}
	r.restored(t)
	c := r.calls()
	tag, back := index(c, "tag demo-web:1.0.0 demo-web:current"), index(c, "tag sha256:id-of-demo-web:current demo-web:current")
	if tag < 0 || back <= tag || count(c, "compose -p demo up -d --remove-orphans") != 2 {
		t.Errorf("calls:\n%s", strings.Join(c, "\n"))
	}
	if r.logText() != v1line {
		t.Errorf("a reverted run wrote versions.log:\n%s", r.logText())
	}
	if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
		t.Error("a revert that worked kept the snapshot: the files on disk are the live stack's")
	}
}

func TestEngineRevertsAnUnhealthyStack(t *testing.T) {
	r := revertRig(t, "0 unhealthy\n0 healthy\n")
	os.WriteFile(r.images, []byte("demo-web:1.0.0\n"), 0o644)
	var errb bytes.Buffer
	now := time.Unix(1000, 0)
	e := &engine{dir: r.dir, sp: r.revertSpec(), stderr: &errb, now: func() time.Time { return now }, sleep: func(d time.Duration) { now = now.Add(d) }}
	_, err := e.run()
	e.lockFile.Close()
	if err == nil || !strings.Contains(err.Error(), "failed (health) and was reverted") || e.failure.Outcome != Reverted {
		t.Fatalf("%v\n%s", err, errb.String())
	}
	r.restored(t)
	c := r.calls()
	// No :current before the run: the revert untags it rather than retag.
	if index(c, "image rm demo-web:current") < 0 || index(c, "compose -p demo ps -q") < 0 {
		t.Errorf("calls:\n%s", strings.Join(c, "\n"))
	}
	if r.logText() != v1line {
		t.Errorf("versions.log:\n%s", r.logText())
	}
}

func TestEngineRevertThatFailsIsLogged(t *testing.T) {
	r := revertRig(t, "1\n1\n")
	rc, out, errs := r.run(r.revertSpec())
	if rc != 1 || !strings.Contains(errs, "and so did the revert to 0.9.0 — the files and :current are back, and compose up of them failed") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if f := ParseFailure(out); f == nil || f.Outcome != RevertFailed {
		t.Fatalf("failure line %q", out)
	}
	lines := strings.Split(strings.TrimSpace(r.logText()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[1], " deploy-failed 1.0.0 no-backup kasbah=0.1.0 digest=sha256:id-of-demo-web:current by=") || !strings.HasSuffix(lines[1], " reason=revert") {
		t.Errorf("versions.log:\n%s", r.logText())
	}
}

func TestEngineNoSnapshotIsARevertFailure(t *testing.T) {
	r := revertRig(t, "1\n")
	sp := r.revertSpec()
	sp.Snapshot = "another-run"
	rc, _, errs := r.run(sp)
	if rc != 1 || !strings.Contains(errs, "holds no snapshot of this run") || !strings.Contains(errs, "nothing was put back") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "compose.yml")); string(b) != "v1.0.0\n" {
		t.Errorf("a foreign snapshot was restored: %q", b)
	}
	if !strings.HasSuffix(strings.TrimSpace(r.logText()), "reason=revert") {
		t.Errorf("versions.log:\n%s", r.logText())
	}
}

func TestEnginePostHookFailureIsLoggedNotReverted(t *testing.T) {
	for _, mode := range []string{"deploy", "rollback"} {
		r := revertRig(t, "")
		t.Setenv("EXEC_RC", "1")
		sp := r.revertSpec()
		sp.Mode = mode
		rc, out, errs := r.run(sp)
		if rc != 1 || !strings.Contains(errs, "1.0.0 is live and was not reverted") {
			t.Fatalf("%s: rc %d\n%s", mode, rc, errs)
		}
		if f := ParseFailure(out); f == nil || f.Outcome != PostHook || f.Reason != "post-hook" {
			t.Fatalf("%s: failure line %q", mode, out)
		}
		want := " deploy-failed 1.0.0 no-backup kasbah=0.1.0 digest=sha256:id-of-demo-web:current by="
		last := strings.Split(strings.TrimSpace(r.logText()), "\n")[1]
		suffix := " reason=post-hook"
		if mode == "rollback" {
			suffix += " mode=rollback"
		}
		if !strings.Contains(last, want) || !strings.HasSuffix(last, suffix) {
			t.Errorf("%s: versions.log:\n%s", mode, r.logText())
		}
		if b, _ := os.ReadFile(filepath.Join(r.dir, "compose.yml")); string(b) != "v1.0.0\n" {
			t.Errorf("%s: the files were reverted: %q", mode, b)
		}
		if n := count(r.calls(), "compose -p demo up"); n != 1 {
			t.Errorf("%s: %d ups", mode, n)
		}
	}
}

func TestEngineFirstDeployFailureLeavesTheStack(t *testing.T) {
	r := newRig(t)
	t.Setenv("UP_RC", "1")
	sp := r.spec()
	sp.Backup, sp.Snapshot = nil, "tok"
	rc, out, errs := r.run(sp)
	if rc != 1 || !strings.Contains(errs, "first deploy of demo here, so there is nothing to revert to") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if f := ParseFailure(out); f == nil || f.Outcome != FirstFailed {
		t.Fatalf("failure line %q", out)
	}
	if _, err := os.Stat(filepath.Join(r.dir, "versions.log")); err == nil {
		t.Error("a failed first deploy wrote versions.log")
	}
	if n := count(r.calls(), "compose -p demo up"); n != 1 {
		t.Errorf("%d ups", n)
	}
}

// A failed run's line is never the previous version; success drops the snapshot.
func TestEnginePrevSkipsFailedLines(t *testing.T) {
	r := revertRig(t, "")
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line+"2026-10-02T00:00:00+00:00 deploy-failed 0.9.5 no-backup kasbah=0.1.0 digest=- by=al reason=post-hook\n"), 0o664)
	rc, out, errs := r.run(r.revertSpec())
	if rc != 0 {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if rep, _, _ := ParseReport(out); rep == nil || rep.PrevVersion != "0.9.0" || !rep.DeployedBefore {
		t.Errorf("report %q", out)
	}
	if index(r.calls(), "exec -e VERSION=1.0.0 -e PREV_VERSION=0.9.0 ") < 0 {
		t.Errorf("calls:\n%s", strings.Join(r.calls(), "\n"))
	}
	if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
		t.Error("a successful run left its snapshot")
	}
}

// Before the retag nothing was started: the shipped files go back, the
// snapshot with them.
func TestEnginePreRetagFailureRestoresTheFiles(t *testing.T) {
	for name, set := range map[string]func(t *testing.T, sp *Spec){
		"pre-hook":     func(t *testing.T, sp *Spec) { t.Setenv("EXEC_RC", "1"); sp.Pre = []string{"demo-web echo pre"} },
		"image lookup": func(t *testing.T, sp *Spec) { t.Setenv("IMAGE_ERR", "Cannot connect to the Docker daemon") },
	} {
		t.Run(name, func(t *testing.T) {
			r := revertRig(t, "")
			sp := r.revertSpec()
			set(t, &sp)
			rc, out, errs := r.run(sp)
			if rc != 1 || !strings.Contains(errs, "stopped before anything was started, and the files it had shipped were put back") {
				t.Fatalf("rc %d\n%s", rc, errs)
			}
			if f := ParseFailure(out); f == nil || f.Outcome != Restored {
				t.Fatalf("failure line %q", out)
			}
			r.restored(t)
			// The .env the run found was not the live stack's: kept, and named.
			if b, _ := os.ReadFile(filepath.Join(r.dir, Replaced)); string(b) != "A=new\n" || !strings.Contains(errs, "kept as "+r.dir+"/"+Replaced) {
				t.Errorf("replaced .env %q\n%s", b, errs)
			}
			if fi, err := os.Stat(filepath.Join(r.dir, Replaced)); err != nil || fi.Mode().Perm() != 0o660 {
				t.Errorf("replaced .env mode %v", fi)
			}
			if f := ParseFailure(out); f.Saved != r.dir+"/"+Replaced {
				t.Errorf("failure line %q", out)
			}
			if index(r.calls(), "tag ") >= 0 || index(r.calls(), "compose -p demo up") >= 0 {
				t.Errorf("calls:\n%s", strings.Join(r.calls(), "\n"))
			}
			if _, err := os.Lstat(filepath.Join(r.dir, PrevDir)); err == nil {
				t.Error("the snapshot outlived files that match the live stack again")
			}
		})
	}
}

// A run that went live and could not be logged says so.
func TestEngineUnrecordedRun(t *testing.T) {
	r := revertRig(t, "")
	sp := r.revertSpec()
	sp.Kasbah = "0.1 0"
	rc, out, errs := r.run(sp)
	if rc != 1 || !strings.Contains(errs, "demo 1.0.0 is live") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if f := ParseFailure(out); f == nil || f.Outcome != Unrecorded {
		t.Fatalf("failure line %q", out)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "compose.yml")); string(b) != "v1.0.0\n" {
		t.Errorf("compose.yml %q", b)
	}
}

// A kept snapshot's ids are the live stack's: the revert retags to them, not
// to what :current names when this run starts.
func TestEngineRevertUsesTheSnapshotsIDs(t *testing.T) {
	r := revertRig(t, "1\n0\n")
	pinIDs(r.dir, "tok", []string{"demo-web"}, map[string]string{"demo-web": "sha256:the-live-one"}, io.Discard)
	rc, _, errs := r.run(r.revertSpec())
	if rc != 1 || index(r.calls(), "tag sha256:the-live-one demo-web:current") < 0 {
		t.Fatalf("rc %d\n%s\n%s", rc, errs, strings.Join(r.calls(), "\n"))
	}
	if !strings.Contains(errs, "put back the files this run replaced (.env, compose.yml, extra.txt)") {
		t.Errorf("%s", errs)
	}
}

func TestPinIDsWarnsWhenItCannotRecord(t *testing.T) {
	r := revertRig(t, "")
	os.Chmod(filepath.Join(r.dir, PrevDir), 0o555)
	defer os.Chmod(filepath.Join(r.dir, PrevDir), 0o770)
	var warn bytes.Buffer
	got := pinIDs(r.dir, "tok", []string{"demo-web"}, map[string]string{"demo-web": "v1"}, &warn)
	if got["demo-web"] != "v1" || (os.Getuid() != 0 && !strings.Contains(warn.String(), "a later run's would not")) {
		t.Errorf("%v %q", got, warn.String())
	}
}
