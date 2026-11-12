package prune

import (
	"encoding/json"
	"io/fs"
	"regexp"
	"slices"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/templates"
)

// TestRetiredIsRetired: nothing kasbah names now is on the list, and every
// entry is a tag as docker lists it (no docker.io/ or library/, a tag).
func TestRetiredIsRetired(t *testing.T) {
	current := []string{serverinit.TraefikImage, backup.ResticImage}
	reImage := regexp.MustCompile(`(?m)^\s*image:\s*"?([^\s"#]+)`)
	fs.WalkDir(templates.FS, ".", func(path string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		b, _ := templates.FS.ReadFile(path)
		for _, m := range reImage.FindAllStringSubmatch(string(b), -1) {
			if !strings.Contains(m[1], "__") {
				current = append(current, m[1])
			}
		}
		return nil
	})
	if !slices.Contains(current, "cypht/cypht:2.13.0") {
		t.Fatalf("the template walk found %v", current)
	}
	for _, r := range Retired {
		if slices.Contains(current, r) {
			t.Errorf("%s is on the retired list and kasbah still names it", r)
		}
		if strings.HasPrefix(r, "docker.io/") || strings.HasPrefix(r, "library/") || !regexp.MustCompile(`:[\w][\w.-]*$`).MatchString(r) {
			t.Errorf("%s is not a tag as docker lists it", r)
		}
	}
}

func TestStock(t *testing.T) {
	s := fixture("2026-08")
	retired := Retired[0]
	s.Images = append(s.Images,
		Image{ID: "sha256:sm1", Created: "2026-01-01T00:00:00Z", Tags: []string{retired, "djmaze/snappymail:latest"}},
		Image{ID: "sha256:t10", Created: "2026-01-01T00:00:00Z", Tags: []string{serverinit.TraefikImage}},
		Image{ID: "sha256:t20", Created: "2026-01-01T00:00:00Z", Tags: []string{"traefik:v3.8.0"}},
		Image{ID: "sha256:sm0", Created: "2026-01-01T00:00:00Z", Tags: []string{"djmaze/snappymail:v2.37.0"}})
	s.Containers = append(s.Containers, Container{"sha256:t20", "running", "traefik"})
	pl, err := Decide(s, "deploy@vps", "/apps", "store")
	if err != nil {
		t.Fatal(err)
	}
	out := report(pl)
	if want := "alpha-api:0.4.0 alpha-web:0.8.0 alpha-web:1.1.0 alpha-web:1.2.0 gamma-web:1.0.0 " + retired + " " + serverinit.TraefikImage; strings.Join(pl.Remove, " ") != want {
		t.Errorf("removal set\n want %s\n got  %s\n%s", want, strings.Join(pl.Remove, " "), out)
	}
	for _, want := range []string{
		"\nkasbah's retired images\n  remove " + retired + "  a stock image an earlier kasbah ran, which no container uses — untags only, the image also carries djmaze/snappymail:latest\n",
		"  remove " + serverinit.TraefikImage + " ",
		"container traefik runs another image (upgrade-traefik)",
		"7 tag(s) to remove on deploy@vps.",
	} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	for _, never := range []string{"traefik:v3.8.0", "snappymail:latest", "v2.37.0", "redis:7-alpine"} {
		if regexp.MustCompile(`(remove|keep) +\S*` + regexp.QuoteMeta(never)).MatchString(out) {
			t.Errorf("%s is no retired image of kasbah's and was a candidate:\n%s", never, out)
		}
	}

	// A container of any state holds it; Traefik's default while it runs it is not retired.
	s.Containers = append(s.Containers, Container{"sha256:sm1", "exited", "old-webmail"})
	s.Containers[len(s.Containers)-2] = Container{"sha256:t10", "running", "traefik"}
	pl, _ = Decide(s, "deploy@vps", "/apps", "store")
	out = report(pl)
	if slices.Contains(pl.Remove, retired) || slices.Contains(pl.Remove, serverinit.TraefikImage) ||
		!strings.Contains(out, "  keep   "+retired+"  held by container old-webmail(exited)") || strings.Contains(out, " "+serverinit.TraefikImage+" ") {
		t.Errorf("a used image was offered: %v\n%s", pl.Remove, out)
	}

	// Asked in prune's one question; --yes answers it, no terminal without it fails.
	s.Containers = s.Containers[:len(s.Containers)-1]
	raw, _ := json.Marshal(s)
	f := &fake{scan: raw}
	_, se, code := runFake(t, f, Options{Target: "deploy@vps"}, false, "")
	if code != 1 || len(f.removed) != 0 || !strings.Contains(se, "--yes") {
		t.Errorf("no tty, no --yes: code=%d\n%s", code, se)
	}
	f = &fake{scan: raw}
	_, se, code = runFake(t, f, Options{Target: "deploy@vps", Yes: true}, false, "")
	if code != 0 || len(f.removed) != 1 || !strings.HasSuffix(strings.Join(f.removed[0], " "), "gamma-web:1.0.0 "+retired) {
		t.Errorf("--yes: code=%d removed=%v\n%s", code, f.removed, se)
	}

	// A tag any project's compose.yml names, as written or by docker's defaults, is kept.
	for _, ref := range []string{"docker.io/" + retired, retired + "@sha256:0123", "djmaze/snappymail:${WEBMAIL_TAG:-x}", "${WEBMAIL}"} {
		s := fixture("2026-08")
		s.Images = append(s.Images, Image{ID: "sha256:sm1", Created: "2026-01-01T00:00:00Z", Tags: []string{retired}})
		s.Projects = append(s.Projects, proj("omega", "ok", "services:\n  mail:\n    image: \""+ref+"\"\n", "ok", "", "missing", ""))
		s.Count = len(s.Projects)
		pl, _ = Decide(s, "deploy@vps", "/apps", "store")
		if slices.Contains(pl.Remove, retired) || !strings.Contains(report(pl), "  keep   "+retired+"  a project's compose.yml names it (image: "+ref+")") {
			t.Errorf("image: %s names it and it was offered: %v\n%s", ref, pl.Remove, report(pl))
		}
	}
	s2 := fixture("2026-08")
	s2.Images = append(s2.Images, Image{ID: "sha256:sm1", Created: "2026-01-01T00:00:00Z", Tags: []string{retired}})
	s2.Projects = append(s2.Projects, proj("omega", "ok", "services:\n  mail:\n    image: djmaze/snappymail\n  db:\n    image: x/djmaze/snappymail:v2.38.2\n", "ok", "", "missing", ""))
	s2.Count = len(s2.Projects)
	if pl, _ = Decide(s2, "deploy@vps", "/apps", "store"); !slices.Contains(pl.Remove, retired) {
		t.Errorf("another tag or repository is no name for it: %v\n%s", pl.Remove, report(pl))
	}

	// An unreadable declaration holds back the version tags and every stock image.
	s.Projects = append(s.Projects, proj("omega", "ok", "services: [\n", "ok", "", "missing", ""))
	s.Count = len(s.Projects)
	pl, _ = Decide(s, "deploy@vps", "/apps", "store")
	out = report(pl)
	if len(pl.Remove) != 0 || !strings.Contains(out, "No version tag and no retired stock\nimage is removed anywhere") ||
		!strings.Contains(out, "  keep   "+retired+"  unknown whether it is in use: omega declare(s) images kasbah could not read") {
		t.Errorf("unknown ownership: %v\n%s", pl.Remove, out)
	}
}
