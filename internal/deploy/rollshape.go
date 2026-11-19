package deploy

import (
	"slices"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/backup"
)

// RollShape is what compose and the fragment say about whether a routed
// service rolls on deploy, before docker is asked anything. The deploy reads
// it off `docker compose config`; check reads it off compose.prod.yml.
type RollShape struct {
	// NoRoll is what its kasbah.noRoll label asks, as NoRoll reads it.
	NoRoll string
	// ByContainerName: the fragment reaches it by its container_name.
	ByContainerName bool
	ContainerName   bool // it sets container_name
	Published       bool // it publishes a host port
	Health          Healthcheck
	// Gated is its first depends_on entry with a condition other than
	// service_started, as "db (service_healthy)"; "" for none.
	Gated string
}

// Healthcheck is what compose says of a service's healthcheck.
type Healthcheck int

const (
	// HealthUnset: compose declares no test, so the image's HEALTHCHECK decides.
	HealthUnset Healthcheck = iota
	HealthDeclared
	// HealthOff: compose disables it, or names no image to carry one.
	HealthOff
)

// Stay is a static reason a routed service is recreated in place rather
// than rolled.
type Stay int

// NoRollLabel is the compose label that keeps a service from rolling, so its
// old containers all stop before the new ones start. As Traefik reads its own
// labels, the key matches in any case and the value as strconv.ParseBool
// reads it.
const NoRollLabel = "kasbah.noRoll"

// RoleLabel is the label key kasbah's own short-lived containers carry.
const RoleLabel = backup.RoleLabel

// Labels are the kasbah.* label keys kasbah reads or writes; check warns on
// any other a compose service carries (C18).
var Labels = []string{NoRollLabel, RoleLabel, backup.LauncherLabel}

// KnownLabel is whether k is one of Labels as kasbah reads it: NoRollLabel in
// any case, the others exactly.
func KnownLabel(k string) bool {
	return strings.EqualFold(k, NoRollLabel) || slices.Contains(Labels, k)
}

// NoRoll is what a service's labels ask of its roll: "" for a roll (no
// kasbah.noRoll, or one reading false), "true" for none, else the value of a
// kasbah.noRoll that is no boolean, which reads as true too.
func NoRoll(labels map[string]string) string {
	out := ""
	for _, k := range sortedKeys(labels) {
		if !strings.EqualFold(k, NoRollLabel) {
			continue
		}
		v := labels[k]
		b, err := strconv.ParseBool(v)
		switch {
		case err != nil && v == "":
			return `""`
		case err != nil:
			return v
		case b:
			out = "true"
		}
	}
	return out
}

const (
	StayNoRoll Stay = iota + 1
	StayByContainerName
	StayContainerName
	StayNoHealthWait
	StayPublished
	StayNoHealthcheck
	StayGated
)

// Stays is every static reason r is recreated in place, in the order a
// deploy names them; none leaves the verdict to live state. noHealthWait is
// the deploy's --no-health-wait.
func (r RollShape) Stays(noHealthWait bool) []Stay {
	var out []Stay
	for _, c := range []struct {
		on bool
		s  Stay
	}{
		{r.NoRoll != "", StayNoRoll},
		{r.ByContainerName, StayByContainerName},
		{r.ContainerName, StayContainerName},
		{noHealthWait, StayNoHealthWait},
		{r.Published, StayPublished},
		{r.Health != HealthDeclared, StayNoHealthcheck},
		{r.Gated != "", StayGated},
	} {
		if c.on {
			out = append(out, c.s)
		}
	}
	return out
}

// Why is a reason in words, as "it sets container_name".
func (r RollShape) Why(s Stay) string {
	switch s {
	case StayNoRoll:
		if r.NoRoll == "true" {
			return "it is labelled " + NoRollLabel
		}
		return "it is labelled " + NoRollLabel + "=" + r.NoRoll + ", which reads as true"
	case StayByContainerName:
		return "the fragment targets its container_name"
	case StayContainerName:
		return "it sets container_name"
	case StayNoHealthWait:
		return "--no-health-wait leaves nothing to swap on"
	case StayPublished:
		return "it publishes a host port a second replica cannot bind"
	case StayNoHealthcheck:
		return "it declares no healthcheck to swap on"
	case StayGated:
		return "it depends_on " + r.Gated + ", a condition only a plain up waits for"
	}
	return ""
}
