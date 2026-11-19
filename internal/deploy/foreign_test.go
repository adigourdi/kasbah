package deploy

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/mail"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/traefiknet"
)

func TestParseShortPort(t *testing.T) {
	for in, want := range map[string]string{
		"8080:80":               "8080/tcp",
		"127.0.0.1:8080:80/udp": "127.0.0.1:8080/udp",
		"31984:1194/udp":        "31984/udp",
		"9000-9001:9000-9001":   "9000-9001/tcp",
		"18000-18002:80":        "18000-18002/tcp any",
		"0.0.0.0:443:443":       "0.0.0.0:443/tcp",
		"[::1]:8080:80":         "[::1]:8080/tcp",
		"[::]:8080:80":          "[::]:8080/tcp",
		"[0:0::0]:8080:80":      "[::]:8080/tcp",
		"80":                    "",
		"3000-3005":             "",
		"127.0.0.1::80":         "",
		"x:80":                  "error",
		"[::1:80":               "error",
	} {
		got := ""
		b, ok, err := ParseShortPort(in)
		switch {
		case err != nil:
			got = "error"
		case ok:
			got = b.String()
			if b.Any {
				got += " any"
			}
		}
		if got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

func TestDockerPorts(t *testing.T) {
	got := dockerPorts("0.0.0.0:8080->80/tcp, [::]:8080->80/tcp, 127.0.0.1:9000-9001->9000-9001/udp, 0.0.0.0:53->53/udp, [::]:443->443/tcp, 5432/tcp")
	var s []string
	for _, b := range got {
		s = append(s, b.String())
	}
	if strings.Join(s, " ") != "8080/tcp 127.0.0.1:9000-9001/udp 0.0.0.0:53/udp [::]:443/tcp" {
		t.Errorf("ports: %v", s)
	}
}

func TestCollisions(t *testing.T) {
	bind := func(s, svc string) Bind { b, _, _ := ParseShortPort(s); b.Svc = svc; return b }
	for _, tc := range []struct {
		ours, theirs string
		hit          bool
	}{
		{"8080:80", "0.0.0.0:8080->80/tcp", true},
		{"127.0.0.1:8080:80", "0.0.0.0:8080->80/tcp", true},
		{"8080:80", "127.0.0.1:8080->80/tcp", true},
		{"127.0.0.1:8080:80", "127.0.0.2:8080->80/tcp", false},
		{"8080:80/udp", "0.0.0.0:8080->80/tcp", false},
		{"9000-9005:9000-9005", "0.0.0.0:9003->9003/tcp", true},
		{"8081:80", "0.0.0.0:8080->80/tcp", false},
		// Families: none given is both wildcards; each wildcard its own family.
		{"8080:80", "[::]:8080->80/tcp", true},
		{"8080:80", "[::1]:8080->80/tcp", true},
		{"0.0.0.0:8080:80", "[::]:8080->80/tcp", false},
		{"[::]:8080:80", "0.0.0.0:8080->80/tcp", false},
		{"0.0.0.0:8080:80", "0.0.0.0:8080->80/tcp", true},
		{"[::]:8080:80", "[::]:8080->80/tcp", true},
		{"0.0.0.0:8080:80", "127.0.0.1:8080->80/tcp", true},
		{"127.0.0.1:8080:80", "[::]:8080->80/tcp", false},
		{"[::]:8080:80", "[::1]:8080->80/tcp", true},
		{"[::1]:8080:80", "[::]:8080->80/tcp", true},
		{"[::1]:8080:80", "0.0.0.0:8080->80/tcp", false},
		{"0.0.0.0:8080:80", "[::1]:8080->80/tcp", false},
		{"[::1]:8080:80", "[::1]:8080->80/tcp", true},
		{"[::1]:8080:80", "[::2]:8080->80/tcp", false},
		{"0.0.0.0:8080:80", "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp", true},
		{"[::]:8080:80", "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp", true},
		// A range for one container port is refused only when every port is taken.
		{"18000-18002:80", "0.0.0.0:18000->80/tcp", false},
		{"18000-18002:80", "0.0.0.0:18000-18002->80-82/tcp", true},
		{"0.0.0.0:18000-18002:80", "0.0.0.0:18000-18001->80-81/tcp, [::1]:18002->80/tcp", false},
		{"18000-18002:80", "0.0.0.0:18000-18001->80-81/tcp, 127.0.0.1:18002->80/tcp", true},
		{"127.0.0.1:18000-18001:80", "0.0.0.0:18000-18001->80-81/tcp", true},
		{"18000-18001:80/udp", "0.0.0.0:18000-18001->80-81/tcp", false},
	} {
		c := Collisions("demo", "/apps/demo", []Bind{bind(tc.ours, "web")}, nil, []Holder{{Name: "x", Ports: dockerPorts(tc.theirs)}})
		if (len(c) > 0) != tc.hit || tc.hit && c[0].Kind != PortCollision {
			t.Errorf("%s vs %s: %+v", tc.ours, tc.theirs, c)
		}
	}
	c := Collisions("demo", "/apps/demo", []Bind{bind("18000-18002:80", "web")}, nil, []Holder{
		{Name: "a", Project: "other", Ports: dockerPorts("0.0.0.0:18000->80/tcp, [::]:18000->80/tcp")},
		{Name: "b", Ports: dockerPorts("0.0.0.0:18001-18002->80-81/tcp")},
	})
	if len(c) != 1 || c[0].Kind != PortCollision || c[0].Msg != "every port of 18000-18002/tcp, the range service web of this project publishes one port from, is taken: container a (compose project other) publishes 18000/tcp, container b (not a compose container) publishes 0.0.0.0:18001-18002/tcp — stop or move one of those containers, or change the range web publishes" {
		t.Errorf("range: %+v", c)
	}
	for _, tc := range []struct {
		name string
		hs   []Holder
		want string
	}{
		{"demo", []Holder{
			{Name: "demo-db-1", Project: "demo", Dir: "/home/u/demo", Config: "/home/u/demo/compose.yml"},
			{Name: "demo-web-1", Project: "demo", Dir: "/home/u/demo", Config: "/home/u/demo/compose.yml"},
		}, "a compose project named demo already exists outside /apps/demo: demo-db-1, demo-web-1, started from /home/u/demo (/home/u/demo/compose.yml) — Docker keys compose projects by name, so this project's up would take its containers for its own; run `docker compose -p demo down` in /home/u/demo, or rename this project"},
		{"demo", []Holder{{Name: "demo-web-1", Project: "demo"}},
			"a compose project named demo already exists outside /apps/demo: demo-web-1, started with no working directory recorded — Docker keys compose projects by name, so this project's up would take its containers for its own; run `docker compose -p demo down` where it was started, or rename this project"},
	} {
		c := Collisions(tc.name, "/apps/"+tc.name, nil, nil, tc.hs)
		if len(c) != 1 || c[0].Kind != NameCollision || c[0].Msg != tc.want {
			t.Errorf("name: %+v", c)
		}
	}
}

// A container_name is held by a container of that exact name, running or not,
// listed alone or among a legacy link's names.
func TestContainerNameCollisions(t *testing.T) {
	names := []ContainerName{{"web", "app"}, {"db", "store"}}
	c := Collisions("demo", "/apps/demo", nil, names, []Holder{
		{Name: "web", Project: "other", Dir: "/o"},
		{Name: "Web"},
		{Name: "db-1"},
		{Name: "proxy"},
	})
	if len(c) != 1 || c[0].Kind != ContainerNameCollision || c[0].Msg != "container web (compose project other) already holds web, the container_name service app of this project sets — Docker gives a name to one container per host, running or stopped; remove or rename that container, or change the container_name app sets" {
		t.Errorf("name: %+v", c)
	}
	c = Collisions("demo", "/apps/demo", nil, names, []Holder{{Name: "db,other/db"}})
	if len(c) != 1 || c[0].Kind != ContainerNameCollision || !strings.HasPrefix(c[0].Msg, "container db (not a compose container) already holds db, the container_name service store of this project sets") {
		t.Errorf("linked: %+v", c)
	}
	// The project's own one-off holding one refuses that alone.
	c = Collisions("demo", "/apps/demo", []Bind{{Lo: 80, Hi: 80, Proto: "tcp", Svc: "app"}}, names, []Holder{{Name: "web", Project: "demo", Run: true, Ports: []Bind{{Lo: 80, Hi: 80, Proto: "tcp"}}}})
	if len(c) != 1 || c[0].Kind != ContainerNameCollision || !strings.HasPrefix(c[0].Msg, "container web (a one-off `docker compose run` of this project) already holds web") {
		t.Errorf("own one-off: %+v", c)
	}
	// Another stack of the project's name holding one is both refusals.
	c = Collisions("demo", "/apps/demo", nil, names, []Holder{{Name: "web", Project: "demo", Dir: "/home/u/demo"}})
	if len(c) != 2 || c[0].Kind != NameCollision || c[1].Kind != ContainerNameCollision {
		t.Errorf("same project name: %+v", c)
	}
}

func TestOutsiders(t *testing.T) {
	root := t.TempDir()
	real := filepath.Join(root, "real")
	os.MkdirAll(filepath.Join(real, "demo"), 0o755)
	os.Symlink(real, filepath.Join(root, "apps"))
	dir := filepath.Join(root, "apps", "demo")
	rows := strings.Join([]string{
		"demo-web-1\trunning\tdemo\t" + dir + "\tc\t0.0.0.0:8080->80/tcp",
		"demo-db-1\trunning\tdemo\t" + filepath.Join(real, "demo") + "\tc\t0.0.0.0:5432->5432/tcp",
		"zed\trunning\t\t\t\t0.0.0.0:8080->80/tcp\r",
		"idle\texited\tother\t/o\tc\t",
		"old\texited\tdemo\t/home/u/demo\tc\t",
		"web\texited\tdemo\t" + dir + "\tc\t",
		"demo-web-run-1\texited\tdemo\t" + dir + "\tc\t\tTrue",
		"pinned\trunning\tdemo\t" + dir + "\tc\t\tTrue",
		"quiet\trunning\tother\t/o\tc\t5432/tcp",
		"bad row",
	}, "\n")
	hs, err := Outsiders("demo", dir, func(...string) (string, error) { return rows, nil })
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, h := range hs {
		names = append(names, h.Name)
	}
	if strings.Join(names, " ") != "demo-web-run-1 idle old pinned quiet zed" || !hs[0].Run || !hs[3].Run || hs[1].Run || hs[1].Ports != nil || hs[4].Ports != nil {
		t.Errorf("outsiders: %v", names)
	}
}

// The compose project names of kasbah's own stacks are refused as project
// names when a manifest loads, so Collisions never meets one.
func TestOwnStacksReserved(t *testing.T) {
	for _, p := range []string{traefiknet.Project, mail.Project, backup.Project} {
		if !manifest.NameReserved(p) {
			t.Errorf("%s, a stack of kasbah's own, is not a reserved project name", p)
		}
	}
}
