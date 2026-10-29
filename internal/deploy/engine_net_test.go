package deploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// netRig answers network ls with demo_kasbah, traefik on none of it yet;
// connects is one rc per `network connect`.
func netRig(t *testing.T, r *rig, connects string) string {
	t.Helper()
	root := t.TempDir()
	nets, tnets := filepath.Join(root, "nets"), filepath.Join(root, "tnets")
	os.WriteFile(nets, []byte("demo_kasbah\n"), 0o644)
	os.WriteFile(tnets, []byte("kasbah-net\n"), 0o644)
	t.Setenv("NETS", nets)
	t.Setenv("TNETS", tnets)
	if connects != "" {
		f := filepath.Join(root, "connects")
		os.WriteFile(f, []byte(connects), 0o644)
		t.Setenv("CONNECTS", f)
	}
	return tnets
}

func TestEngineConnectsTraefikAfterUp(t *testing.T) {
	r := newRig(t)
	tnets := netRig(t, r, "")
	r.running("demo-web=running", "demo-db=running")
	rc, _, errs := r.run(r.spec())
	if rc != 0 {
		t.Fatalf("rc %d: %s", rc, errs)
	}
	c := r.calls()
	order := []int{index(c, "compose -p demo up -d"), index(c, "network ls --filter label=com.docker.compose.network=kasbah --filter label=com.docker.compose.project=demo"),
		index(c, "network connect demo_kasbah traefik"), index(c, "inspect --format")}
	for i := 1; i < len(order); i++ {
		if order[i-1] < 0 || order[i] <= order[i-1] {
			t.Fatalf("up, connect, health out of order %v:\n%s", order, strings.Join(c, "\n"))
		}
	}
	if !strings.Contains(errs, "connected traefik to demo_kasbah") {
		t.Fatalf("the connect is not said:\n%s", errs)
	}
	// Already connected: a second run connects nothing.
	os.WriteFile(r.log, nil, 0o644)
	if b, _ := os.ReadFile(tnets); !strings.Contains(string(b), "demo_kasbah") {
		t.Fatalf("traefik's networks %q", b)
	}
	if rc, _, errs := r.run(r.spec()); rc != 0 || count(r.calls(), "network connect") != 0 {
		t.Fatalf("rc %d, a re-run connected again:\n%s\n%s", rc, strings.Join(r.calls(), "\n"), errs)
	}
}

func TestEngineRevertsAFailedConnect(t *testing.T) {
	r := revertRig(t, "")
	netRig(t, r, "1\n0\n")
	rc, out, errs := r.run(r.revertSpec())
	if rc != 1 || !strings.Contains(errs, "failed (up) and was reverted — the server is back on 0.9.0") || !strings.Contains(errs, "could not connect traefik to demo's kasbah network") {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	if f := ParseFailure(out); f == nil || f.Outcome != Reverted || f.Reason != "up" {
		t.Fatalf("failure %q", out)
	}
	r.restored(t)
	c := r.calls()
	if count(c, "compose -p demo up -d") != 2 || count(c, "network connect demo_kasbah traefik") != 2 {
		t.Fatalf("the revert did not bring up and reconnect:\n%s", strings.Join(c, "\n"))
	}
	if strings.Contains(r.logText(), "1.0.0") {
		t.Fatalf("versions.log records the failed version:\n%s", r.logText())
	}
}
