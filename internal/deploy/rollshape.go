package deploy

// RollShape is what compose and the fragment say about whether a routed
// service rolls on deploy, before docker is asked anything. The deploy reads
// it off `docker compose config`; check reads it off compose.prod.yml.
type RollShape struct {
	// ByContainerName: the fragment reaches it by its container_name; OffNet:
	// by a name it answers only off the project's kasbah network (check only —
	// the deploy counts such a service unrouted).
	ByContainerName, OffNet bool
	ContainerName           bool // it sets container_name
	Published               bool // it publishes a host port
	Health                  Healthcheck
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

const (
	StayByContainerName Stay = iota + 1
	StayOffNet
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
		{r.ByContainerName, StayByContainerName},
		{r.OffNet, StayOffNet},
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
	case StayByContainerName:
		return "the fragment targets its container_name"
	case StayOffNet:
		return "the fragment reaches it by a name it answers only off the project's kasbah network"
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
