package deploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A stack outside the project, holding its port or its compose project name,
// stops the run before anything is started; the project's own containers never do.
func TestEngineOutsiders(t *testing.T) {
	r := newRig(t)
	r.running("demo-web")
	cfg := filepath.Join(filepath.Dir(r.log), "config.json")
	os.WriteFile(cfg, []byte(`{"services":{"web":{"ports":[{"mode":"ingress","host_ip":"127.0.0.1","target":80,"published":"8080","protocol":"tcp"}]}}}`), 0o644)
	t.Setenv("CONFIG", cfg)
	ps := filepath.Join(filepath.Dir(r.log), "ps")
	t.Setenv("PS", ps)
	for _, tc := range []struct{ row, want string }{
		{"other-web-1\trunning\tother\t/home/u/other\t/home/u/other/compose.yml\t0.0.0.0:8080->80/tcp, [::]:8080->80/tcp",
			"container other-web-1 (compose project other) publishes 8080/tcp, which service web of this project publishes too — stop or move that container, or change the port web publishes. Nothing was started."},
		{"proxy\trunning\t\t\t\t127.0.0.1:8080->8080/tcp", "container proxy (not a compose container) publishes 127.0.0.1:8080/tcp"},
		{"demo-web-1\texited\tdemo\t/home/u/demo\t/home/u/demo/compose.yml\t",
			"a compose project named demo already exists outside " + r.dir + ": demo-web-1, started from /home/u/demo (/home/u/demo/compose.yml) — Docker keys compose projects by name, so this project's up would take its containers for its own; run `docker compose -p demo down` in /home/u/demo, or rename this project. Nothing was started."},
	} {
		os.WriteFile(ps, []byte(tc.row+"\n"), 0o644)
		os.Remove(r.log)
		rc, _, errs := r.run(r.spec())
		if rc != 1 || !strings.Contains(errs, tc.want) {
			t.Errorf("rc %d, want 1 and %q:\n%s", rc, tc.want, errs)
		}
		if log, _ := os.ReadFile(r.log); strings.Contains(string(log), " up ") || strings.Contains(string(log), "hook ") || strings.Contains(string(log), "tag ") {
			t.Errorf("started something:\n%s", log)
		}
	}
	for _, row := range []string{
		"demo-web-1\trunning\tdemo\t" + r.dir + "\tc\t127.0.0.1:8080->80/tcp",
		"other\trunning\tother\t/o\tc\t127.0.0.2:8080->80/tcp, 0.0.0.0:8080->80/udp",
	} {
		os.WriteFile(ps, []byte(row+"\n"), 0o644)
		sp := r.spec()
		sp.NoHealthWait = true
		if rc, _, errs := r.run(sp); rc != 0 {
			t.Errorf("%q: rc %d\n%s", row, rc, errs)
		}
	}
	// A rollback onto a host where another stack has since taken the port.
	os.WriteFile(ps, []byte("late\trunning\tlate\t/srv/late\tc\t0.0.0.0:8080->80/tcp\n"), 0o644)
	sp := r.spec()
	sp.Mode = "rollback"
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "container late (compose project late) publishes 0.0.0.0:8080/tcp") {
		t.Errorf("rollback: rc %d\n%s", rc, errs)
	}
}

// A container_name a container outside the project holds, stopped or not,
// stops the run before anything is started; the project's own older one never does.
func TestEngineOutsidersContainerName(t *testing.T) {
	r := newRig(t)
	r.running("demo-web")
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"services":{"web":{"container_name":"web"}}}`), 0o644)
	t.Setenv("CONFIG", cfg)
	ps := filepath.Join(t.TempDir(), "ps")
	t.Setenv("PS", ps)
	for _, row := range []string{"web\texited\tother\t/home/u/other\tc\t", "web\trunning\t\t\t\t"} {
		os.WriteFile(ps, []byte(row+"\n"), 0o644)
		os.Remove(r.log)
		rc, _, errs := r.run(r.spec())
		if rc != 1 || !strings.Contains(errs, "already holds web, the container_name service web of this project sets — Docker gives a name to one container per host, running or stopped; remove or rename that container, or change the container_name web sets. Nothing was started.") {
			t.Errorf("%q: rc %d\n%s", row, rc, errs)
		}
		if log, _ := os.ReadFile(r.log); strings.Contains(string(log), " up ") || strings.Contains(string(log), "hook ") || strings.Contains(string(log), "tag ") {
			t.Errorf("started something:\n%s", log)
		}
	}
	os.WriteFile(ps, []byte("web\texited\tdemo\t"+r.dir+"\tc\t\nother\texited\tother\t/o\tc\t\n"), 0o644)
	sp := r.spec()
	sp.NoHealthWait = true
	if rc, _, errs := r.run(sp); rc != 0 {
		t.Errorf("own container: rc %d\n%s", rc, errs)
	}
}

// A redeploy refused here is a failure before the retag: the shipped files
// go back and versions.log gains nothing.
func TestEngineOutsidersRedeploy(t *testing.T) {
	r := revertRig(t, "")
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"services":{"web":{"ports":[{"target":80,"published":"8080","protocol":"tcp"}]}}}`), 0o644)
	t.Setenv("CONFIG", cfg)
	ps := filepath.Join(t.TempDir(), "ps")
	os.WriteFile(ps, []byte("proxy\trunning\t\t\t\t0.0.0.0:8080->80/tcp\n"), 0o644)
	t.Setenv("PS", ps)
	before := r.logText()
	rc, _, errs := r.run(r.revertSpec())
	if rc != 1 || !strings.Contains(errs, "container proxy (not a compose container) publishes 0.0.0.0:8080/tcp") || !strings.Contains(errs, "the files it had shipped were put back") {
		t.Fatalf("rc %d:\n%s", rc, errs)
	}
	if index(r.calls(), "tag ") >= 0 || index(r.calls(), " up ") >= 0 {
		t.Errorf("started something: %v", r.calls())
	}
	r.restored(t)
	if r.logText() != before {
		t.Errorf("versions.log %q", r.logText())
	}
}

// A range for one container port is refused only when no port of it is free;
// a compose config that cannot be read is said, and the name still checked.
func TestEngineOutsidersRangeAndConfig(t *testing.T) {
	r := newRig(t)
	r.running("demo-web")
	cfg := filepath.Join(t.TempDir(), "config.json")
	os.WriteFile(cfg, []byte(`{"services":{"web":{"ports":[{"target":80,"published":"18000-18001","protocol":"tcp"}]}}}`), 0o644)
	t.Setenv("CONFIG", cfg)
	ps := filepath.Join(t.TempDir(), "ps")
	t.Setenv("PS", ps)
	os.WriteFile(ps, []byte("a\trunning\t\t\t\t0.0.0.0:18000->80/tcp\n"), 0o644)
	sp := r.spec()
	sp.NoHealthWait = true
	if rc, _, errs := r.run(sp); rc != 0 {
		t.Errorf("one port free: rc %d\n%s", rc, errs)
	}
	os.WriteFile(ps, []byte("a\trunning\t\t\t\t0.0.0.0:18000->80/tcp, [::]:18000->80/tcp\nb\trunning\t\t\t\t0.0.0.0:18001->80/tcp, [::]:18001->80/tcp\n"), 0o644)
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "every port of 18000-18001/tcp, the range service web of this project publishes one port from, is taken: container a (not a compose container) publishes 18000/tcp, container b (not a compose container) publishes 18001/tcp") {
		t.Errorf("all taken: rc %d\n%s", rc, errs)
	}
	os.WriteFile(cfg, []byte("not json"), 0o644)
	if rc, _, errs := r.run(sp); rc != 0 || !strings.Contains(errs, "could not read the ports compose.yml publishes and the container_names it sets (") || !strings.Contains(errs, "whether a container outside the project holds one was not checked") {
		t.Errorf("config: rc %d\n%s", rc, errs)
	}
	os.WriteFile(ps, []byte("demo-web-1\texited\tdemo\t/home/u/demo\tc\t\n"), 0o644)
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "a compose project named demo already exists outside") {
		t.Errorf("name with no config: rc %d\n%s", rc, errs)
	}
}
