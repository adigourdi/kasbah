package deploy

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

const noServices = "services: {}\n"

// No service: nothing is started or connected, and the run is recorded as any.
func TestEngineDeploysAServicelessProject(t *testing.T) {
	r := newRig(t)
	netRig(t, r, "")
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte(noServices), 0o644)
	r.running("cid=running") // the stub's compose ps -q answers cid
	sp := r.spec()
	sp.Images, sp.Health = nil, Health{Timeout: 5}
	rc, out, errs := r.run(sp)
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, errs)
	}
	if rep, _, ok := ParseReport(out); !ok || rep.Version != "1.0.0" {
		t.Fatalf("report %q", out)
	}
	c := r.calls()
	for _, p := range []string{"compose -p demo up", "compose -p demo down", "network ls", "network connect", "compose -p demo config"} {
		if index(c, p) >= 0 {
			t.Errorf("ran %q:\n%s", p, strings.Join(c, "\n"))
		}
	}
	if index(c, "hook post 1.0.0") < 0 {
		t.Errorf("the post-deploy hook did not run:\n%s", strings.Join(c, "\n"))
	}
	if !strings.Contains(errs, "compose.yml declares no services — nothing to start") {
		t.Errorf("not said:\n%s", errs)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "versions.log")); !strings.Contains(string(b), " deploy 1.0.0 ") {
		t.Errorf("versions.log %q", b)
	}
}

// Routed hosts do not send a service-less project down the rolling path.
func TestEngineServicelessIgnoresRouted(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte(noServices), 0o644)
	r.running("cid=running") // the stub's compose ps -q answers cid
	sp := r.spec()
	sp.Images, sp.Health, sp.Routed = nil, Health{Timeout: 5}, []string{"web"}
	if rc, _, errs := r.run(sp); rc != 0 || index(r.calls(), "compose -p demo up") >= 0 {
		t.Fatalf("rc %d:\n%s\n%s", rc, strings.Join(r.calls(), "\n"), errs)
	}
}

// A version with no service after one with containers removes them, as
// up --remove-orphans would have.
func TestEngineServicelessRemovesTheOldContainers(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte(noServices), 0o644)
	ps := filepath.Join(t.TempDir(), "ps")
	os.WriteFile(ps, []byte("id1\tdemo-web-1\tweb\t1\trunning\n"), 0o644)
	r.running("cid=running")
	t.Setenv("PS", ps)
	tnets := netRig(t, r, "")
	os.WriteFile(tnets, []byte("kasbah-net\ndemo_kasbah\n"), 0o644)
	sp := r.spec()
	sp.Images, sp.Health = nil, Health{Timeout: 5}
	rc, _, errs := r.run(sp)
	c := r.calls()
	if rc != 0 || count(c, "compose -p demo down --remove-orphans") != 1 || index(c, "compose -p demo up") >= 0 || index(c, "network connect") >= 0 {
		t.Fatalf("rc %d:\n%s\n%s", rc, strings.Join(c, "\n"), errs)
	}
	// Traefik leaves first, or down could not remove the network.
	if d := index(c, "network disconnect demo_kasbah traefik"); d < 0 || d > index(c, "compose -p demo down") || index(c, "network disconnect kasbah-net") >= 0 {
		t.Errorf("calls:\n%s", strings.Join(c, "\n"))
	}
	if !strings.Contains(errs, "disconnected traefik from demo_kasbah") {
		t.Errorf("not said:\n%s", errs)
	}
}

// The revert to a service-less version starts nothing and removes what the
// failed up left.
func TestEngineRevertsToAServicelessVersion(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line), 0o664)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte(noServices), 0o644)
	os.WriteFile(r.images, []byte("demo-web:1.0.0\n"), 0o644)
	ups := filepath.Join(t.TempDir(), "ups")
	os.WriteFile(ups, []byte("1\n"), 0o644)
	t.Setenv("UPS", ups)
	r.running("cid=running")
	ps := filepath.Join(t.TempDir(), "ps")
	os.WriteFile(ps, []byte("id1\tdemo-web-1\tweb\t1\texited\n"), 0o644)
	t.Setenv("PS", ps)
	var out, errb bytes.Buffer
	if rc := takeSnapshot(r.dir, "tok", []string{".env", "compose.yml"}, &out, &errb); rc != 0 {
		t.Fatalf("snapshot rc %d %s", rc, errb.String())
	}
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte("services:\n  web:\n    image: demo-web:current\n"), 0o644)
	rc, o, errs := r.run(r.revertSpec())
	if f := ParseFailure(o); rc != 1 || f == nil || f.Outcome != Reverted {
		t.Fatalf("rc %d %q\n%s", rc, o, errs)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "compose.yml")); string(b) != noServices {
		t.Errorf("compose.yml is %q", b)
	}
	c := r.calls()
	if count(c, "compose -p demo up") != 1 || count(c, "compose -p demo down --remove-orphans") != 1 || index(c, "network connect") >= 0 {
		t.Errorf("calls:\n%s", strings.Join(c, "\n"))
	}
}

// A failed down is named as one, on the deploy and on its revert.
func TestEngineServicelessDownFails(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line), 0o664)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte(noServices), 0o644)
	r.running("cid=running")
	ps := filepath.Join(t.TempDir(), "ps")
	os.WriteFile(ps, []byte("id1\tdemo-web-1\tweb\t1\trunning\n"), 0o644)
	t.Setenv("PS", ps)
	t.Setenv("DOWN_RC", "1")
	var out, errb bytes.Buffer
	if rc := takeSnapshot(r.dir, "tok", []string{".env", "compose.yml"}, &out, &errb); rc != 0 {
		t.Fatalf("snapshot rc %d %s", rc, errb.String())
	}
	rc, o, errs := r.run(r.revertSpec())
	if f := ParseFailure(o); rc != 1 || f == nil || f.Outcome != RevertFailed {
		t.Fatalf("rc %d %q\n%s", rc, o, errs)
	}
	for _, w := range []string{"down --remove-orphans failed", "compose down of what this run started failed"} {
		if !strings.Contains(errs, w) {
			t.Errorf("%q not said:\n%s", w, errs)
		}
	}
	if strings.Contains(errs, "up -d --remove-orphans failed") {
		t.Errorf("an up named:\n%s", errs)
	}
}

// A restore that changes .env has no stack to recreate.
func TestRestoreArmServiceless(t *testing.T) {
	r := restoreLive(t)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte(noServices), 0o644)
	rc, kv, errs := r.restore("1.0.0", "--env=all")
	if rc != 0 || kv["env"] != "restored" || kv["recreated"] != "no-services" || !strings.Contains(errs, "nothing to recreate") {
		t.Fatalf("rc %d %v\n%s", rc, kv, errs)
	}
	if c := r.calls(); index(c, "compose -p demo") >= 0 || index(c, "network ls") >= 0 {
		t.Errorf("calls:\n%s", strings.Join(c, "\n"))
	}
}
