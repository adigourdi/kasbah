package drop

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/adigourdi/kasbah/internal/remote"
)

// stubDocker records every docker call and answers from fn.
func stubDocker(t *testing.T, fn func(args []string) (string, error)) *[][]string {
	t.Helper()
	var calls [][]string
	old := runDocker
	runDocker = func(dir string, args ...string) (string, error) {
		calls = append(calls, args)
		return fn(args)
	}
	t.Cleanup(func() { runDocker = old })
	return &calls
}

func appsTree(t *testing.T) (apps, data string) {
	t.Helper()
	root := t.TempDir()
	apps, data = filepath.Join(root, "apps"), filepath.Join(root, "apps", "data")
	for _, d := range []string{"traefik/dynamic", "mail", "built-app/backups", "demo", "data/built-app", "backups/keep"} {
		os.MkdirAll(filepath.Join(apps, d), 0o755)
	}
	w := func(p, s string) { os.WriteFile(filepath.Join(apps, p), []byte(s), 0o644) }
	w("traefik/dynamic/built-app.yml", "http: {}\n")
	w("built-app/compose.yml", builtCompose)
	w("built-app/backups/pre-deploy-1.sql", "x")
	w("demo/compose.yml", "services: {}\n")
	w("data/built-app/keep", "x")
	w("mail/kasbah.yml", "primary_domain: a.test\n")
	return apps, data
}

func TestScan(t *testing.T) {
	apps, data := appsTree(t)
	stubDocker(t, func(a []string) (string, error) {
		switch a[0] {
		case "ps":
			return "built-app-web running\nbuilt-app-cache exited\n", nil
		case "images":
			return "sha256:b\nsha256:a\nsha256:a\n", nil
		case "image":
			return "sha256:a x:1 x:current\nsha256:b\n", nil
		}
		return "", nil
	})
	s := scan(apps, data, "built-app")
	if s.FragmentState != "ok" || s.ProjectState != "dir" || s.BackupsCount != 1 || s.LockState != "free" ||
		s.RegistryState != "ok" || len(s.Containers) != 2 || len(s.Images) != 2 || s.Images[1].Tags == nil {
		t.Fatalf("%+v", s)
	}
	var names []string
	for _, p := range s.Projects {
		names = append(names, p.Name+":"+p.ComposeState)
	}
	if strings.Join(names, " ") != "built-app:ok demo:ok" || s.Count != 2 {
		t.Errorf("projects: %v (reserved names are never projects)", names)
	}
	if _, err := os.Stat(filepath.Join(apps, "built-app", ".deploy.lock")); err == nil {
		t.Errorf("the scan created the lock file")
	}

	// A deploy holding the lock is seen.
	f, _ := os.Create(filepath.Join(apps, "built-app", ".deploy.lock"))
	defer f.Close()
	syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
	if s := scan(apps, data, "built-app"); s.LockState != "held" {
		t.Errorf("lock: %s", s.LockState)
	}
}

func runAct(t *testing.T, a ActArgs, stdin string) (string, string, int) {
	var so, se bytes.Buffer
	code := Remote(append([]string{"act"}, a.Argv()...), strings.NewReader(stdin), &so, &se)
	return so.String(), se.String(), code
}

func report(t *testing.T, out string) ActReport {
	t.Helper()
	head, body, _ := strings.Cut(out, "\n")
	if head != "started=yes" {
		t.Fatalf("no started line: %q", out)
	}
	var r ActReport
	if err := json.Unmarshal([]byte(body), &r); err != nil {
		t.Fatalf("%v: %q", err, body)
	}
	return r
}

func TestActGuards(t *testing.T) {
	apps, data := appsTree(t)
	calls := stubDocker(t, func([]string) (string, error) { return "", nil })
	base := ActArgs{Apps: apps, Data: data, Name: "built-app", RegSize: "0", RegSum: "-", RegPrev: "-"}
	for _, c := range []struct {
		mut  func(*ActArgs)
		want string
	}{
		{func(a *ActArgs) { a.Name = "" }, "project name ''"},
		{func(a *ActArgs) { a.Name = ".." }, "project name '..'"},
		{func(a *ActArgs) { a.Name = "a/b" }, "project name 'a/b'"},
		{func(a *ActArgs) { a.Name = "mail" }, "'mail' is a directory kasbah owns"},
		{func(a *ActArgs) { a.Apps = "apps" }, "apps path 'apps' is not an absolute path"},
		{func(a *ActArgs) { a.Data = "/" }, "data path '/' is not an absolute path"},
		{func(a *ActArgs) { a.Tags = []string{"-f"} }, "'-f' is not an image tag"},
		{func(a *ActArgs) { a.Prune, a.RegSize, a.RegSum = true, "5", strings.Repeat("0", 64) }, "the mail registry: the payload is 0 bytes"},
	} {
		a := base
		c.mut(&a)
		so, se, code := runAct(t, a, "")
		if code != 1 || !strings.Contains(se, c.want) || strings.Contains(so, "started") {
			t.Errorf("%s: %d %q %q", c.want, code, so, se)
		}
	}
	if len(*calls) != 0 {
		t.Errorf("a refusal ran docker: %v", *calls)
	}
	if _, err := os.Stat(filepath.Join(apps, "traefik/dynamic/built-app.yml")); err != nil {
		t.Errorf("a refusal removed the route")
	}

	// A deploy holding the lock.
	f, _ := os.Create(filepath.Join(apps, "built-app", ".deploy.lock"))
	syscall.Flock(int(f.Fd()), syscall.LOCK_EX)
	so, se, code := runAct(t, base, "")
	f.Close()
	if code != 1 || !strings.Contains(se, "is running in") || so != "" || len(*calls) != 0 {
		t.Errorf("held: %d %q %q", code, so, se)
	}
}

func TestActPlain(t *testing.T) {
	apps, data := appsTree(t)
	calls := stubDocker(t, func(a []string) (string, error) {
		if a[0] == "image" && a[2] == "bad:1" {
			return "", &os.PathError{Op: "rm", Path: "bad:1", Err: os.ErrPermission}
		}
		if a[0] == "ps" {
			return "built-app-run-1\n", nil
		}
		return "", nil
	})
	so, se, code := runAct(t, ActArgs{Apps: apps, Data: data, Name: "built-app", RegSize: "0", RegSum: "-", RegPrev: "-",
		Tags: []string{"x:1", "bad:1"}}, "")
	if code != 0 {
		t.Fatalf("%d %s", code, se)
	}
	r := report(t, so)
	if r.Fragment != "removed" || r.Down != "ok" || r.DownLeft != "built-app-run-1" ||
		strings.Join(r.Removed, " ") != "x:1" || len(r.Failed) != 1 || r.Failed[0].Ref != "bad:1" || r.Config != "" {
		t.Errorf("%+v", r)
	}
	if want := "compose -p built-app down --remove-orphans"; strings.Join((*calls)[1], " ") != want {
		t.Errorf("down: %v", *calls)
	}
	for _, p := range []string{"built-app/compose.yml", "data/built-app/keep", "built-app/backups/pre-deploy-1.sql"} {
		if _, err := os.Stat(filepath.Join(apps, p)); err != nil {
			t.Errorf("plain drop removed %s", p)
		}
	}
	if _, err := os.Stat(filepath.Join(apps, "traefik/dynamic/built-app.yml")); err == nil {
		t.Errorf("the route survived")
	}
}

// Traefik leaves the project's network after the route goes and before the
// down, which cannot remove a network a foreign container is on.
func TestActDisconnectsTraefik(t *testing.T) {
	for _, tc := range []struct {
		name, inspect, detached, err string
		inspectErr                   error
	}{
		{"attached", "kasbah-net\nbuilt-app_kasbah\n", "built-app_kasbah", "", nil},
		{"not attached", "kasbah-net\n", "", "", nil},
		{"no traefik", "", "", "", errors.New("Error: No such object: traefik")},
		{"inspect fails", "", "", "docker inspect traefik failed: boom", errors.New("boom")},
	} {
		t.Run(tc.name, func(t *testing.T) {
			apps, data := appsTree(t)
			disconnected := false
			calls := stubDocker(t, func(a []string) (string, error) {
				switch a[0] {
				case "network":
					switch a[1] {
					case "ls":
						return "built-app_kasbah built-app\n", nil
					case "disconnect":
						disconnected = true
					case "inspect":
						// Gone after the down, unless Traefik kept it in use.
						if tc.err != "" || (!disconnected && strings.Contains(tc.inspect, "built-app_kasbah")) {
							return "[{}]", nil
						}
						return "", errors.New("Error: No such network: built-app_kasbah")
					}
				case "inspect":
					return tc.inspect, tc.inspectErr
				}
				return "", nil
			})
			so, se, code := runAct(t, ActArgs{Apps: apps, Data: data, Name: "built-app", RegSize: "0", RegSum: "-", RegPrev: "-"}, "")
			if code != 0 {
				t.Fatalf("%d %s", code, se)
			}
			r := report(t, so)
			// A failed disconnect leaves the network in use: down exits 0 and is
			// still reported failed.
			wantDown := "ok"
			if tc.err != "" {
				wantDown = "failed"
			}
			if r.Detached != tc.detached || r.DetachErr != tc.err || r.Down != wantDown ||
				(wantDown == "failed") != strings.Contains(r.DownDetail, "network built-app_kasbah is still there") {
				t.Fatalf("%+v", r)
			}
			var seq []string
			for _, c := range *calls {
				seq = append(seq, strings.Join(c, " "))
			}
			disc, down := -1, -1
			for i, c := range seq {
				if c == "network disconnect built-app_kasbah traefik" {
					disc = i
				}
				if strings.HasPrefix(c, "compose -p built-app down") {
					down = i
				}
			}
			if (tc.detached != "") != (disc >= 0) || down < 0 || disc > down {
				t.Fatalf("disconnect %d, down %d:\n%s", disc, down, strings.Join(seq, "\n"))
			}
		})
	}
}

func TestActPrune(t *testing.T) {
	apps, data := appsTree(t)
	stubDocker(t, func([]string) (string, error) { return "", nil })
	reg := filepath.Join(apps, "mail", "kasbah.yml")
	prev, _ := os.ReadFile(reg)
	body := []byte("primary_domain: a.test\ndomains:\n  - a.test\n")
	size, sum := remote.Digest(body)
	a := ActArgs{Apps: apps, Data: data, Name: "built-app", Prune: true, RegSize: size, RegSum: sum, RegPrev: Sum(prev)}
	so, se, code := runAct(t, a, string(body))
	if code != 0 {
		t.Fatalf("%s", se)
	}
	r := report(t, so)
	if r.Mail != "written" || r.Data != "removed" || r.Config != "removed" {
		t.Errorf("%+v", r)
	}
	got, _ := os.ReadFile(reg)
	if string(got) != string(body) {
		t.Errorf("registry: %q", got)
	}
	if fi, _ := os.Stat(reg); fi.Mode().Perm() != 0o644 {
		t.Errorf("mode %o", fi.Mode().Perm())
	}
	for _, p := range []string{"built-app", "data/built-app"} {
		if _, err := os.Stat(filepath.Join(apps, p)); err == nil {
			t.Errorf("%s survived --prune", p)
		}
	}
	for _, p := range []string{"demo/compose.yml", "backups/keep", "data"} {
		if _, err := os.Stat(filepath.Join(apps, p)); err != nil {
			t.Errorf("--prune took %s", p)
		}
	}
	entries, _ := os.ReadDir(filepath.Join(apps, "mail"))
	if len(entries) != 1 {
		t.Errorf("a staging file was left: %v", entries)
	}

	// The registry changed between the plan's read and the act: left alone.
	apps, data = appsTree(t)
	os.WriteFile(filepath.Join(apps, "mail", "kasbah.yml"), []byte("primary_domain: a.test\ndomains: [b.test]\n"), 0o644)
	a.Apps, a.Data = apps, data
	so, _, _ = runAct(t, a, string(body))
	if r := report(t, so); r.Mail != "stale" {
		t.Errorf("stale: %+v", r)
	}
	if got, _ := os.ReadFile(filepath.Join(apps, "mail", "kasbah.yml")); strings.Contains(string(got), "  - a.test") {
		t.Errorf("a changed registry was overwritten")
	}
}

func snapshot(root string) string {
	var b strings.Builder
	filepath.Walk(root, func(p string, fi os.FileInfo, err error) error {
		data, _ := os.ReadFile(p)
		b.WriteString(p + " " + fi.Mode().String() + " " + string(data) + "\n")
		return nil
	})
	return b.String()
}

func TestActRefusalsChangeNothing(t *testing.T) {
	apps, data := appsTree(t)
	calls := stubDocker(t, func([]string) (string, error) { return "", nil })
	before := snapshot(filepath.Dir(apps))
	for _, n := range []string{"data", "backups", ".kasbah", "traefik", "mail"} {
		a := ActArgs{Apps: apps, Data: data, Name: n, Prune: true, RegSize: "0", RegSum: "-", RegPrev: "-"}
		if so, se, code := runAct(t, a, ""); code != 1 || so != "" || !strings.Contains(se, "refusing to act") {
			t.Errorf("%s: %d %q", n, code, se)
		}
	}
	// --apps-path=/srv/k/apps --data-path=/srv/k: a project named apps would
	// put the apps tree under <data>/<name>; and the other way round.
	root := filepath.Dir(apps)
	for _, a := range []ActArgs{
		{Apps: apps, Data: root, Name: "apps"},
		{Apps: root, Data: apps + "/x", Name: "apps"},
	} {
		a.Prune, a.RegSize, a.RegSum, a.RegPrev = true, "0", "-", "-"
		if so, se, code := runAct(t, a, ""); code != 1 || so != "" || !strings.Contains(se, "overlap") {
			t.Errorf("%+v: %d %q", a, code, se)
		}
	}
	if snapshot(filepath.Dir(apps)) != before || len(*calls) != 0 {
		t.Errorf("a refusal changed the tree or ran docker")
	}
}

// --data-path equal to --apps-path is a layout init accepts: <data>/<name> is
// then the project directory itself, and --prune goes ahead.
func TestActDataEqualsApps(t *testing.T) {
	apps, _ := appsTree(t)
	stubDocker(t, func([]string) (string, error) { return "", nil })
	so, se, code := runAct(t, ActArgs{Apps: apps, Data: apps, Name: "built-app", Prune: true, RegSize: "0", RegSum: "-", RegPrev: "-"}, "")
	if code != 0 {
		t.Fatalf("%s", se)
	}
	if r := report(t, so); r.Config != "removed" || r.Data != "removed" {
		t.Errorf("%+v", r)
	}
	if _, err := os.Stat(filepath.Join(apps, "demo")); err != nil {
		t.Errorf("a neighbour went")
	}
}

func TestLockStateUnknown(t *testing.T) {
	dir := t.TempDir()
	if lockState(dir) != "free" {
		t.Errorf("no lock file is free")
	}
	os.Mkdir(filepath.Join(dir, ".deploy.lock"), 0o700)
	os.Chmod(filepath.Join(dir, ".deploy.lock"), 0)
	defer os.Chmod(filepath.Join(dir, ".deploy.lock"), 0o700)
	if os.Geteuid() != 0 {
		if s := lockState(dir); s != "unknown" {
			t.Errorf("an unopenable lock: %s", s)
		}
	}
}

func TestActOverlapUncleanPaths(t *testing.T) {
	apps, _ := appsTree(t)
	calls := stubDocker(t, func([]string) (string, error) { return "", nil })
	root := filepath.Dir(apps)
	unclean := strings.Replace(apps, "/apps", "//apps", 1)
	a := ActArgs{Apps: unclean, Data: root + "/", Name: "apps", Prune: true, RegSize: "0", RegSum: "-", RegPrev: "-"}
	if so, se, code := runAct(t, a, ""); code != 1 || so != "" || !strings.Contains(se, "overlap") || len(*calls) != 0 {
		t.Errorf("%d %q", code, se)
	}
	if _, err := os.Stat(filepath.Join(apps, "demo")); err != nil {
		t.Errorf("the apps tree went")
	}
}
