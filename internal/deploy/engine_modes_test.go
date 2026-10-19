package deploy

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEngineRollbackMode(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(
		"2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"+
			"2026-10-02T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n"), 0o644)
	os.WriteFile(r.images, []byte("demo-web:0.9.0\n"), 0o644)
	// The backup container is down: a rollback takes no backup, so it is no
	// reason to refuse.
	r.running("demo-web=running", "demo-db=exited")
	sp := r.spec()
	sp.Mode, sp.Version = "rollback", "0.9.0"
	sp.Pre, sp.Post = []string{"demo-web echo pre-rb"}, []string{"demo-web echo post-rb"}
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, errs)
	}
	if !strings.Contains(errs, "pre-rollback hook: demo-web: echo pre-rb") || !strings.Contains(errs, "post-rollback hook: demo-web: echo post-rb") {
		t.Errorf("narration: %s", errs)
	}
	if index(r.calls(), "check") >= 0 || index(r.calls(), "exec demo-db") >= 0 {
		t.Errorf("a rollback ran the backup: %v", r.calls())
	}
	rep, _, _ := ParseReport(out)
	if rep == nil || rep.Backup != "no-backup" || rep.PrevVersion != "1.0.0" || !rep.DeployedBefore {
		t.Fatalf("report %q", out)
	}
	b, _ := os.ReadFile(filepath.Join(r.dir, "versions.log"))
	lines := strings.Split(strings.TrimSpace(string(b)), "\n")
	if len(lines) != 3 || !strings.HasSuffix(lines[2], " rollback 0.9.0 no-backup kasbah=0.1.0 digest=sha256:id-of-demo-web:current") {
		t.Errorf("versions.log %q", b)
	}
}

func TestEnginePreconditions(t *testing.T) {
	for _, f := range []string{"compose.yml", ".env"} {
		r := newRig(t)
		os.Remove(filepath.Join(r.dir, f))
		rc, _, errs := r.run(r.spec())
		if rc != 1 || !strings.Contains(errs, "/"+f+" is missing") || len(r.calls()) > 1 {
			t.Errorf("no %s: rc %d %s %v", f, rc, errs, r.calls())
		}
		if _, err := os.Stat(filepath.Join(r.dir, "versions.log")); err == nil {
			t.Errorf("no %s: versions.log was written", f)
		}
	}
}

// A truncated last line is history: a stopped stack is refused as "deployed
// here before", and a run that proceeds reports no previous version.
func TestEngineTruncatedLastLine(t *testing.T) {
	r := newRig(t)
	log := filepath.Join(r.dir, "versions.log")
	os.WriteFile(log, []byte("2026-10-01T00:00:00+00:00 dep"), 0o644)
	r.running("demo-web=exited", "demo-db=running")
	rc, _, errs := r.run(r.spec())
	if rc != 1 || !strings.Contains(errs, "deployed here before (versions.log has entries for it, though its last line is not one a version can be read out of)") {
		t.Fatalf("stopped: rc %d %s", rc, errs)
	}
	r.running("demo-web=running", "demo-db=running")
	rc, out, errs := r.run(r.spec())
	rep, _, _ := ParseReport(out)
	if rc != 0 || rep == nil || rep.PrevVersion != "" || !rep.DeployedBefore || !strings.Contains(errs, "had no newline") {
		t.Fatalf("proceeding: rc %d %q %s", rc, out, errs)
	}
	if b, _ := os.ReadFile(log); !strings.HasPrefix(string(b), "2026-10-01T00:00:00+00:00 dep\n2026-") {
		t.Errorf("versions.log %q", b)
	}
}

// The active log gone and the archive holding entries is not a first deploy.
func TestEngineArchiveOnly(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log.gz"), []byte("gzip bytes"), 0o644)
	r.running("demo-web=exited", "demo-db=running")
	rc, _, errs := r.run(r.spec())
	if rc != 1 || strings.Contains(errs, "first deploy") || !strings.Contains(errs, "versions.log.gz holds archived ones") {
		t.Fatalf("rc %d %s", rc, errs)
	}
	r.running("demo-web=running", "demo-db=running")
	rc, out, _ := r.run(r.spec())
	if rep, _, _ := ParseReport(out); rc != 0 || rep == nil || !rep.DeployedBefore || !rep.ArchiveOnly {
		t.Fatalf("rc %d %q", rc, out)
	}
}

// A rotation that fails is a note, never the run's status.
func TestEngineRotationFailureIsANote(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2020-01-01T00:00:00+00:00 deploy 0.9.0 no-backup\n"), 0o644)
	os.Mkdir(filepath.Join(r.dir, "versions.log.gz"), 0o755)
	r.running("demo-web=running", "demo-db=running")
	rc, out, errs := r.run(r.spec())
	if rep, _, _ := ParseReport(out); rc != 0 || rep == nil {
		t.Fatalf("rc %d %q %s", rc, out, errs)
	}
	if !strings.Contains(errs, "the append to versions.log.gz stopped partway") {
		t.Errorf("no note: %s", errs)
	}
}

func TestPrepare(t *testing.T) {
	apps, data := t.TempDir(), t.TempDir()
	var out, errb bytes.Buffer
	if rc := prepare(apps, data, "demo", "acme", nil, &out, &errb); rc != 1 || !strings.Contains(errb.String(), "traefik/dynamic is not a directory") {
		t.Fatalf("unprepared server: rc %d %s", rc, errb.String())
	}
	os.MkdirAll(filepath.Join(apps, "traefik", "dynamic"), 0o755)
	call := func(client string) string {
		out.Reset()
		if rc := prepare(apps, data, "demo", client, []string{apps + "/demo/conf/sub"}, &out, &errb); rc != 0 {
			t.Fatalf("rc %d: %s", rc, errb.String())
		}
		return out.String()
	}
	if got := call("acme"); got != "client=written\nprepared=yes\n" {
		t.Errorf("first: %q", got)
	}
	for _, d := range []string{apps + "/demo/backups", data + "/demo", apps + "/demo/conf/sub"} {
		if fi, err := os.Stat(d); err != nil || !fi.IsDir() {
			t.Errorf("%s not created", d)
		}
	}
	rec := filepath.Join(apps, "demo", ".kasbah-client")
	if fi, _ := os.Stat(rec); fi == nil || fi.Mode().Perm() != 0o644 {
		t.Errorf(".kasbah-client mode %v", fi)
	}
	if b, _ := os.ReadFile(rec); string(b) != "acme\n" {
		t.Errorf(".kasbah-client %q", b)
	}
	if got := call("acme"); got != "client=unchanged\nprepared=yes\n" {
		t.Errorf("again: %q", got)
	}
	if got := call("beta"); got != "client=written\nprepared=yes\n" {
		t.Errorf("changed: %q", got)
	}
}
