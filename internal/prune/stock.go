package prune

import (
	"fmt"
	"regexp"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/serverinit"
	"github.com/adigourdi/kasbah/internal/traefiknet"
)

// Retired is every stock image kasbah's templates or constants named in an
// earlier release and name no longer, as `docker images` lists its tag. A tag
// here is offered whoever pulled it: the question names each one.
var Retired = []string{
	"djmaze/snappymail:v2.38.2", // the mail stack's webmail before Cypht
}

// stock is the retired images' lines, then init's Traefik once the traefik
// container runs another: each removed by tag when no container uses it, no
// image: in named names it, and every project's compose.yml was read.
func stock(s *Scan, pl *Plan, named []string, tagID map[string]string, idTags, held map[string][]string) []Line {
	var out []Line
	line := func(tag, why string) {
		if slices.ContainsFunc(pl.Lines, func(l Line) bool { return l.Tag == tag }) {
			return
		}
		id := tagID[tag]
		l := Line{Tag: tag, Verdict: "keep"}
		if by := namedBy(named, tag); len(held[id]) > 0 {
			l.Why = "held by container " + strings.Join(held[id], " ")
		} else if by != "" {
			l.Why = "a project's compose.yml names it (image: " + by + ")"
		} else if len(pl.Unknown) > 0 {
			l.Why = "unknown whether it is in use: " + strings.Join(pl.Unknown, " ") + " declare(s) images kasbah could not read"
		} else {
			l.Verdict, l.Why = "remove", why
			var other []string
			for _, t := range idTags[id] {
				if t != tag {
					other = append(other, t)
				}
			}
			if len(other) > 0 {
				l.Why += " — untags only, the image also carries " + strings.Join(other, " ")
			}
		}
		out = append(out, l)
	}
	retired := slices.Sorted(slices.Values(Retired))
	for _, tag := range retired {
		if tagID[tag] != "" {
			line(tag, "a stock image an earlier kasbah ran, which no container uses")
		}
	}
	ti := serverinit.TraefikImage
	if id := tagID[ti]; id != "" && len(held[id]) == 0 && !slices.Contains(retired, ti) {
		for _, c := range s.Containers {
			if c.Name == traefiknet.Container && c.Image != id {
				line(ti, fmt.Sprintf("the Traefik server init installs, which no container uses — container %s runs another image (upgrade-traefik)", c.Name))
				break
			}
		}
	}
	return out
}

// namedBy is the first image: in named that is tag once docker's defaults
// are applied (docker.io/, library/, :latest, a digest off); a ${VAR} in it
// matches anything, since kasbah cannot know what compose interpolates.
func namedBy(named []string, tag string) string {
	for _, raw := range named {
		ref := raw
		if i := strings.Index(ref, "@"); i >= 0 {
			ref = ref[:i]
		}
		ref = strings.TrimPrefix(ref, "docker.io/")
		ref = strings.TrimPrefix(ref, "library/")
		if !strings.ContainsAny(ref[strings.LastIndex(ref, "/")+1:], ":$") {
			ref += ":latest"
		}
		re := "^" + reVar.ReplaceAllString(regexp.QuoteMeta(ref), ".*") + "$"
		if regexp.MustCompile(re).MatchString(tag) {
			return raw
		}
	}
	return ""
}

var reVar = regexp.MustCompile(`\\\$(\\\{[^}]*\\\}|\w+)`)
