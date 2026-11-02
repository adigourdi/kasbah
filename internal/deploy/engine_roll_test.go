package deploy

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// rollStub is a docker whose project containers are rows of $PS (id, name,
// service, number, state); a --scale up adds new1 as demo-web's second replica.
const rollStub = `#!/bin/sh
printf '%s\n' "$*" >> "$LOG"
for last; do :; done
row() { awk -F'\t' -v k="$1" '$1==k || $2==k' "$PS"; }
col() { printf '%s' "$1" | cut -f"$2"; }
case "$1" in
ps) cat "$PS"; exit 0 ;;
image) case "$*" in *Healthcheck*) printf '%s\n' "$IMGHC" ;; esac; exit 0 ;;
inspect)
    [ "$last" != traefik ] || exit 0
    r=$(row "$last"); [ -n "$r" ] || exit 1
    case "$*" in
    *Networks*) printf '{"demo_kasbah":{"Aliases":null,"DNSNames":["%s","%s"]}}\n' "$(col "$r" 2)" "$(col "$r" 3)" ;;
    *Running*) [ "$(col "$r" 5)" = running ] && echo true || echo false ;;
    *Health*) h=$(sed -n "s/^$(col "$r" 1)=//p" "$HEALTHS"); echo "${h:-healthy}" ;;
    *Status*) col "$r" 5; echo ;;
    *Name*) echo "/$(col "$r" 2)" ;;
    esac
    exit 0 ;;
compose)
    case "$*" in
    *" config "*) cat "$MODEL" ;;
    *"--scale "*) printf 'new1\tdemo-demo-web-2\tdemo-web\t2\trunning\n' >> "$PS"; exit "${SCALE_RC:-0}" ;;
    *" ps "*) cut -f1 "$PS" ;;
    esac
    exit 0 ;;
stop) awk -F'\t' -v OFS='\t' -v k="$last" '$1==k { $5="exited" } 1' "$PS" > "$PS.n" && mv "$PS.n" "$PS" ;;
rm) awk -F'\t' -v k="$last" '$1!=k' "$PS" > "$PS.n" && mv "$PS.n" "$PS" ;;
esac
exit 0
`

const rollModel = `{"name":"demo","networks":{"kasbah":{"name":"demo_kasbah"},"internal":{"name":"demo_internal"}},
"services":{
 "demo-web":{"image":"demo-web:current","healthcheck":{"test":["CMD","true"]},"networks":{"kasbah":null,"internal":null}},
 "demo-db":{"image":"postgres","networks":{"internal":null}}}}`

type rollRig struct {
	t                           *testing.T
	dir, log, ps, model, health string
}

func newRollRig(t *testing.T, model string) *rollRig {
	t.Helper()
	root := t.TempDir()
	r := &rollRig{t: t, dir: filepath.Join(root, "apps", "demo"), log: filepath.Join(root, "log"),
		ps: filepath.Join(root, "ps"), model: filepath.Join(root, "model"), health: filepath.Join(root, "healths")}
	bin := filepath.Join(root, "bin")
	os.MkdirAll(bin, 0o755)
	os.MkdirAll(r.dir, 0o755)
	os.WriteFile(filepath.Join(bin, "docker"), []byte(rollStub), 0o755)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), nil, 0o644)
	os.WriteFile(filepath.Join(r.dir, ".env"), nil, 0o600)
	os.WriteFile(r.model, []byte(model), 0o644)
	os.WriteFile(r.health, nil, 0o644)
	r.containers("old1\tdemo-demo-web-1\tdemo-web\t1\trunning", "db1\tdemo-demo-db-1\tdemo-db\t1\trunning")
	r.live("demo-web")
	t.Setenv("PATH", bin+":"+os.Getenv("PATH"))
	t.Setenv("LOG", r.log)
	t.Setenv("PS", r.ps)
	t.Setenv("MODEL", r.model)
	t.Setenv("HEALTHS", r.health)
	t.Setenv("IMGHC", "")
	return r
}

// live is the fragment Traefik routes by during the run, one server per host.
func (r *rollRig) live(hosts ...string) {
	dyn := filepath.Join(filepath.Dir(r.dir), "traefik", "dynamic")
	os.MkdirAll(dyn, 0o755)
	if len(hosts) == 0 {
		os.Remove(filepath.Join(dyn, "demo.yml"))
		return
	}
	b := "http:\n  services:\n    demo:\n      loadBalancer:\n        servers:\n"
	for _, h := range hosts {
		b += "          - url: http://" + h + ":80\n"
	}
	os.WriteFile(filepath.Join(dyn, "demo.yml"), []byte(b), 0o644)
}

func (r *rollRig) containers(rows ...string) {
	os.WriteFile(r.ps, []byte(strings.Join(rows, "\n")+"\n"), 0o644)
}

func (r *rollRig) spec() Spec {
	return Spec{Mode: "deploy", Version: "1.0.0", Kasbah: "0.1.0", Routed: []string{"demo-web"},
		Pre: []string{preHook}, Post: []string{postHook},
		Health: Health{Container: "demo-web", Timeout: 1}}
}

func (r *rollRig) run(sp Spec) (int, string, string) {
	r.t.Helper()
	return (&rig{t: r.t, dir: r.dir}).run(sp)
}

func (r *rollRig) calls() []string {
	b, _ := os.ReadFile(r.log)
	return strings.Split(strings.TrimSpace(string(b)), "\n")
}

func (r *rollRig) left() string {
	b, _ := os.ReadFile(r.ps)
	return string(b)
}

func TestEngineRollsARoutedService(t *testing.T) {
	r := newRollRig(t, rollModel)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line), 0o664)
	rc, _, errs := r.run(r.spec())
	if rc != 0 {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	c := r.calls()
	order := []int{
		index(c, "hook pre 1.0.0 prev=0.9.0 project=demo"),
		index(c, "compose -p demo up -d --no-deps --remove-orphans demo-db"),
		index(c, "compose -p demo up -d --no-deps --no-recreate --remove-orphans --scale demo-web=2 demo-web"),
		index(c, "inspect --format {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} new1"),
		index(c, "stop old1"), index(c, "rm old1"),
		index(c, "hook post 1.0.0 prev=0.9.0 project=demo"),
	}
	for i := 1; i < len(order); i++ {
		if order[i-1] < 0 || order[i] <= order[i-1] {
			t.Fatalf("out of order %v:\n%s", order, strings.Join(c, "\n"))
		}
	}
	if index(c, "compose -p demo up -d --remove-orphans") >= 0 {
		t.Errorf("the whole stack went through a plain up:\n%s", strings.Join(c, "\n"))
	}
	if left := r.left(); strings.Contains(left, "old1") || !strings.Contains(left, "new1") {
		t.Errorf("containers left: %q", left)
	}
	if !strings.Contains(errs, "demo-web: stopped and removed the old container old1") {
		t.Errorf("no word of the swap:\n%s", errs)
	}
}

// A stopped old replica is removed before the scale-up, which would restart it
// on its old config, and is not counted in the scale.
func TestEngineRollRemovesStoppedReplicas(t *testing.T) {
	r := newRollRig(t, rollModel)
	r.containers("old0\tdemo-demo-web-3\tdemo-web\t3\texited", "old1\tdemo-demo-web-1\tdemo-web\t1\trunning", "db1\tdemo-demo-db-1\tdemo-db\t1\trunning")
	rc, _, errs := r.run(r.spec())
	if rc != 0 {
		t.Fatalf("rc %d\n%s", rc, errs)
	}
	c := r.calls()
	if i, j := index(c, "rm old0"), index(c, "compose -p demo up -d --no-deps --no-recreate --remove-orphans --scale demo-web=2 demo-web"); i < 0 || j < i {
		t.Fatalf("stopped replica not removed before a scale of 2 (%d %d):\n%s", i, j, strings.Join(c, "\n"))
	}
	if left := r.left(); strings.Contains(left, "old") || !strings.Contains(left, "new1") {
		t.Errorf("containers left: %q", left)
	}
}

// A restarting or paused old replica sends the service in place.
func TestEngineRollRefusesABusyReplica(t *testing.T) {
	for _, st := range []string{"restarting", "paused"} {
		r := newRollRig(t, rollModel)
		r.containers("old0\tdemo-demo-web-2\tdemo-web\t2\t"+st, "old1\tdemo-demo-web-1\tdemo-web\t1\trunning")
		rc, _, errs := r.run(r.spec())
		if rc != 0 || !strings.Contains(errs, "demo-web is recreated in place, as its old replica demo-demo-web-2 is "+st) || index(r.calls(), "rm old0") >= 0 {
			t.Errorf("%s: rc %d\n%s", st, rc, errs)
		}
	}
}

// A new replica that never turns healthy is removed; the old one keeps
// running, and the run fails into the revert.
func TestEngineRollFailsHealth(t *testing.T) {
	r := newRollRig(t, rollModel)
	os.WriteFile(r.health, []byte("new1=unhealthy\n"), 0o644)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte(v1line), 0o664)
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte("v0.9.0\n"), 0o644)
	var out, errb bytes.Buffer
	if rc := takeSnapshot(r.dir, "tok", []string{".env", "compose.yml"}, &out, &errb); rc != 0 {
		t.Fatalf("snapshot rc %d %s", rc, errb.String())
	}
	os.WriteFile(filepath.Join(r.dir, "compose.yml"), []byte("v1.0.0\n"), 0o644)
	sp := r.spec()
	sp.Snapshot = "tok"
	rc, stdout, errs := r.run(sp)
	if f := ParseFailure(stdout); rc != 1 || f == nil || f.Outcome != Reverted || f.Reason != "health" {
		t.Fatalf("rc %d %q\n%s", rc, stdout, errs)
	}
	c := r.calls()
	if index(c, "rm -f new1") < 0 || index(c, "stop old1") >= 0 || index(c, "rm old1") >= 0 {
		t.Errorf("the new replica stays or the old one went:\n%s", strings.Join(c, "\n"))
	}
	if left := r.left(); !strings.Contains(left, "old1\tdemo-demo-web-1\tdemo-web\t1\trunning") || strings.Contains(left, "new1") {
		t.Errorf("containers left: %q", left)
	}
	if b, _ := os.ReadFile(filepath.Join(r.dir, "compose.yml")); string(b) != "v0.9.0\n" {
		t.Errorf("compose.yml is %q", b)
	}
}

func TestEngineRecreatesInPlace(t *testing.T) {
	for _, tc := range []struct{ name, model, why string }{
		{"container_name", strings.Replace(rollModel, `"image":"demo-web:current",`, `"image":"demo-web:current","container_name":"demo-web",`, 1), "as the fragment targets its container_name"},
		{"no healthcheck", strings.Replace(rollModel, `"healthcheck":{"test":["CMD","true"]},`, ``, 1), "as it declares no healthcheck to swap on"},
		{"disabled healthcheck", strings.Replace(rollModel, `"test":["CMD","true"]`, `"test":["NONE"]`, 1), "as it declares no healthcheck to swap on"},
		{"published port", strings.Replace(rollModel, `"image":"demo-web:current",`, `"image":"demo-web:current","ports":[{"target":80,"published":"8080"}],`, 1), "as it publishes a host port"},
		{"gated depends_on", strings.Replace(rollModel, `"image":"demo-web:current",`, `"image":"demo-web:current","depends_on":{"demo-db":{"condition":"service_started"},"migrate":{"condition":"service_completed_successfully","required":true}},`, 1),
			"as it depends_on migrate (service_completed_successfully), a condition only a plain up waits for"},
		{"live route by container name", rollModel, "as the live route targets demo-demo-web-1, which its new replicas will not answer"},
		{"no live route", rollModel, "as the live route does not reach its running container on demo_kasbah"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRollRig(t, tc.model)
			switch tc.name {
			case "live route by container name":
				r.live("demo-web", "demo-demo-web-1")
			case "no live route":
				r.live()
			}
			rc, _, errs := r.run(r.spec())
			if rc != 0 || !strings.Contains(errs, "demo-web is recreated in place, "+tc.why) {
				t.Fatalf("rc %d\n%s", rc, errs)
			}
			c := r.calls()
			if index(c, "compose -p demo up -d --remove-orphans") < 0 || index(c, "compose -p demo up -d --no-deps") >= 0 {
				t.Errorf("not one plain up:\n%s", strings.Join(c, "\n"))
			}
		})
	}
	// The image's own healthcheck counts.
	r := newRollRig(t, strings.Replace(rollModel, `"healthcheck":{"test":["CMD","true"]},`, ``, 1))
	t.Setenv("IMGHC", `["CMD-SHELL","wget -q -O /dev/null http://127.0.0.1/"]`)
	if rc, _, errs := r.run(r.spec()); rc != 0 || index(r.calls(), "compose -p demo up -d --no-deps --no-recreate --remove-orphans --scale demo-web=2 demo-web") < 0 {
		t.Fatalf("an image healthcheck did not roll: rc %d\n%s", rc, errs)
	}
}

func TestEngineTargets(t *testing.T) {
	r := newRollRig(t, rollModel)
	e := &engine{dir: r.dir, project: "demo"}
	r.containers("a\tdemo-demo-web-2\tdemo-web\t2\trunning", "b\tdemo-demo-web-10\tdemo-web\t10\trunning",
		"c\tdemo-web\tother\t1\texited", "d\tdemo-demo-db-1\tdemo-db\t1\texited")
	for name, want := range map[string]string{
		"demo-web": "demo-web", // a container_name wins over the service
		"other":    "demo-web",
		"demo-db":  "demo-demo-db-1",
		"ghost":    "ghost",
	} {
		if got, _ := e.target(name); got != want {
			t.Errorf("target(%s) = %s, want %s", name, got, want)
		}
	}
	r.containers("b\tdemo-demo-web-10\tdemo-web\t10\trunning", "a\tdemo-demo-web-2\tdemo-web\t2\trunning")
	if got, isSvc := e.target("demo-web"); got != "demo-demo-web-2" || !isSvc {
		t.Errorf("target(demo-web) = %s %v, want the lowest-numbered running replica", got, isSvc)
	}
}
