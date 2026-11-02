package deploy

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/serverlock"
)

func TestEngineRollbackMode(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(
		"2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"+
			"2026-10-02T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n"), 0o644)
	os.WriteFile(r.images, []byte("demo-web:0.9.0\n"), 0o644)
	r.running("demo-web=running", "demo-db=exited")
	sp := r.spec()
	sp.Mode, sp.Version = "rollback", "0.9.0"
	sp.Pre = []string{`echo "pre-rb $KASBAH_VERSION prev=$KASBAH_PREV_VERSION project=$KASBAH_PROJECT" >> "$LOG"`}
	sp.Post = []string{`echo "post-rb $KASBAH_VERSION prev=$KASBAH_PREV_VERSION project=$KASBAH_PROJECT" >> "$LOG"`}
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, errs)
	}
	if !strings.Contains(errs, "pre-rollback hook: echo \"pre-rb") || !strings.Contains(errs, "post-rollback hook: echo \"post-rb") {
		t.Errorf("narration: %s", errs)
	}
	if c := r.calls(); index(c, "pre-rb 0.9.0 prev=1.0.0 project=demo") < 0 || c[len(c)-1] != "post-rb 0.9.0 prev=1.0.0 project=demo" {
		t.Errorf("the rollback hooks' variables: %v", c)
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
	if len(lines) != 3 || !strings.HasSuffix(lines[2], " rollback 0.9.0 no-backup kasbah=0.1.0 digest=sha256:id-of-demo-web:current by="+serverlock.Who()) {
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

// A truncated last line is history: the outgoing steps run, and the run
// reports no previous version.
func TestEngineTruncatedLastLine(t *testing.T) {
	r := newRig(t)
	log := filepath.Join(r.dir, "versions.log")
	os.WriteFile(log, []byte("2026-10-01T00:00:00+00:00 dep"), 0o644)
	r.running("demo-web=running", "demo-db=running")
	rc, out, errs := r.run(r.spec())
	rep, _, _ := ParseReport(out)
	if rc != 0 || rep == nil || rep.PrevVersion != "" || !rep.DeployedBefore || !strings.Contains(errs, "had no newline") {
		t.Fatalf("proceeding: rc %d %q %s", rc, out, errs)
	}
	if index(r.calls(), "exec demo-db") < 0 || index(r.calls(), "hook pre 1.0.0 prev= ") < 0 {
		t.Errorf("the outgoing steps did not run: %v", r.calls())
	}
	if b, _ := os.ReadFile(log); !strings.HasPrefix(string(b), "2026-10-01T00:00:00+00:00 dep\n2026-") {
		t.Errorf("versions.log %q", b)
	}
}

// The active log gone and the archive holding entries is not a first deploy.
func TestEngineArchiveOnly(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log.gz"), []byte("gzip bytes"), 0o644)
	r.running("demo-web=running", "demo-db=running")
	rc, out, errs := r.run(r.spec())
	if rep, _, _ := ParseReport(out); rc != 0 || rep == nil || !rep.DeployedBefore || !rep.ArchiveOnly || rep.FailedOnly || strings.Contains(errs, "first deploy") {
		t.Fatalf("rc %d %q %s", rc, out, errs)
	}
	if index(r.calls(), "exec demo-db") < 0 || index(r.calls(), "hook pre") < 0 {
		t.Errorf("the outgoing steps did not run: %v", r.calls())
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

// converse runs the engine with its stdin held open after the bytes SSH.Run
// writes, its stdout answered as the workstation answers it (Converse).
func (r *rig) converse(sp Spec, ask func(Question) string) (int, string, string) {
	r.t.Helper()
	b, _ := json.Marshal(sp)
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	var errb bytes.Buffer
	done := make(chan int)
	go func() {
		rc := Engine(r.dir, inR, outW, &errb)
		outW.Close()
		done <- rc
	}()
	go inW.Write(append(b, '\n'))
	out := Converse(outR, inW, ask)
	return <-done, out, errb.String()
}

// No answer within the wait is stop, both locks released with the run.
func TestEngineQuestionTimesOut(t *testing.T) {
	r := revertRig(t, "")
	sp := r.spec()
	sp.Snapshot, sp.Pre = "tok", []string{"exit 7"}
	b, _ := json.Marshal(sp)
	inR, inW := io.Pipe()
	defer inW.Close()
	go inW.Write(append(b, '\n'))
	var out, errb bytes.Buffer
	rc := engineMain(r.dir, inR, &out, &errb, 50*time.Millisecond)
	if rc != 1 || !strings.Contains(out.String(), `{"kasbah_deploy_question":1,`) || !strings.Contains(errb.String(), "no answer came back within 50ms to whether to deploy past the failed pre-deploy hook — stopping") {
		t.Fatalf("rc %d %q\n%s", rc, out.String(), errb.String())
	}
	if index(r.calls(), "tag ") >= 0 {
		t.Fatalf("retagged after the wait ran out: %v", r.calls())
	}
	r.restored(t)
}

// A failed pre-step asks once; continue carries on to the retag, stop and
// no-tty put the files back and change nothing else.
func TestEnginePreFailureAsks(t *testing.T) {
	for _, tc := range []struct {
		name, flag, answer, step string
		backupFails              bool
		rc                       int
		want                     string
	}{
		{"hook, continue", "", AnswerContinue, "pre-deploy hook", false, 0, "continuing past the failed pre-deploy hook (answered continue)"},
		{"hook, stop", "", AnswerStop, "pre-deploy hook", false, 1, "the files it had shipped were put back"},
		{"hook, no terminal", "", AnswerNoTTY, "pre-deploy hook", false, 1, "there was no terminal to ask whether to deploy anyway; pass --on-hook-failure=continue or --on-hook-failure=stop"},
		{"backup, continue", "", AnswerContinue, "backup", true, 0, "continuing past the failed backup (answered continue)"},
		{"flag continue", AnswerContinue, "", "pre-deploy hook", false, 0, "continuing past the failed pre-deploy hook (--on-hook-failure=continue)"},
		{"flag stop", AnswerStop, "", "pre-deploy hook", false, 1, "the pre-deploy hook failed (exit 7)"},
		{"unrecognised answer", "", "maybe", "pre-deploy hook", false, 1, `the answer to whether to deploy past the failed pre-deploy hook was "maybe", not continue or stop — stopping`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := revertRig(t, "")
			sp := r.spec()
			sp.Snapshot, sp.OnHookFailure = "tok", tc.flag
			sp.Pre = []string{"exit 7", `echo second-pre >> "$LOG"`}
			if tc.backupFails {
				sp.Pre = []string{preHook}
				sp.Backup.Pipe = "cat >/dev/null; exit 3"
			}
			var asked []Question
			rc, out, errs := r.converse(sp, func(q Question) string { asked = append(asked, q); return tc.answer })
			if rc != tc.rc || !strings.Contains(errs, tc.want) {
				t.Fatalf("rc %d, want %d and %q:\n%s", rc, tc.rc, tc.want, errs)
			}
			switch {
			case tc.flag != "" && len(asked) != 0:
				t.Fatalf("a given flag still asked: %v", asked)
			case tc.flag == "" && (len(asked) != 1 || asked[0].Step != tc.step || !strings.Contains(asked[0].Error, "failed")):
				t.Fatalf("asked %+v", asked)
			}
			if ran := index(r.calls(), "second-pre") >= 0; !tc.backupFails && ran != (tc.rc == 0) {
				t.Fatalf("the pre-deploy hook after the failed one ran=%v with rc %d", ran, tc.rc)
			}
			retagged := index(r.calls(), "tag demo-web:1.0.0 demo-web:current") >= 0
			if retagged != (tc.rc == 0) {
				t.Fatalf("retagged=%v with rc %d: %v", retagged, tc.rc, r.calls())
			}
			if tc.rc != 0 {
				r.restored(t)
			}
			if tc.rc == 0 {
				rep, _, _ := ParseReport(out)
				if rep == nil || len(rep.Continued) != 1 || rep.Continued[0] != tc.step {
					t.Fatalf("report %+v", rep)
				}
				if tc.backupFails && rep.Backup != "no-backup" {
					t.Fatalf("a failed backup reported %s", rep.Backup)
				}
			}
		})
	}
}

// EOF on stdin is a dropped session: the run stops.
func TestEnginePreFailureEOFStops(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"), 0o640)
	r.running("demo-web=running", "demo-db=running")
	sp := r.spec()
	sp.Pre = []string{"exit 1"}
	rc, out, errs := r.run(sp)
	if rc != 1 || !strings.Contains(out, `{"kasbah_deploy_question":1,"step":"pre-deploy hook"`) || !strings.Contains(errs, "no answer came back") || index(r.calls(), "tag ") >= 0 {
		t.Fatalf("rc %d %q %s", rc, out, errs)
	}
}
