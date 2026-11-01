package deploy

import (
	"encoding/json"
	"slices"
	"testing"
)

func TestRollShapeStays(t *testing.T) {
	ok := RollShape{Health: HealthDeclared}
	for _, tc := range []struct {
		name         string
		r            RollShape
		noHealthWait bool
		want         []Stay
		why          string
	}{
		{"rollable", ok, false, nil, ""},
		{"targeted by container_name", RollShape{ByContainerName: true, ContainerName: true, Health: HealthDeclared}, false,
			[]Stay{StayByContainerName, StayContainerName}, "the fragment targets its container_name"},
		{"off the project network", RollShape{OffNet: true, Health: HealthDeclared}, false,
			[]Stay{StayOffNet}, "the fragment reaches it by a name it answers only off the project's kasbah network"},
		{"sets container_name", RollShape{ContainerName: true, Health: HealthDeclared}, false,
			[]Stay{StayContainerName}, "it sets container_name"},
		{"--no-health-wait", ok, true, []Stay{StayNoHealthWait}, "--no-health-wait leaves nothing to swap on"},
		{"published", RollShape{Published: true, Health: HealthDeclared}, false,
			[]Stay{StayPublished}, "it publishes a host port a second replica cannot bind"},
		{"no compose healthcheck", RollShape{}, false, []Stay{StayNoHealthcheck}, "it declares no healthcheck to swap on"},
		{"healthcheck off", RollShape{Health: HealthOff}, false, []Stay{StayNoHealthcheck}, "it declares no healthcheck to swap on"},
		{"gated", RollShape{Health: HealthDeclared, Gated: "db (service_healthy)"}, false,
			[]Stay{StayGated}, "it depends_on db (service_healthy), a condition only a plain up waits for"},
		{"in the deploy's order", RollShape{ContainerName: true, Published: true, Gated: "db (service_healthy)"}, true,
			[]Stay{StayContainerName, StayNoHealthWait, StayPublished, StayNoHealthcheck, StayGated}, "it sets container_name"},
	} {
		got := tc.r.Stays(tc.noHealthWait)
		if !slices.Equal(got, tc.want) {
			t.Errorf("%s: stays %v, want %v", tc.name, got, tc.want)
			continue
		}
		if len(got) > 0 && tc.r.Why(got[0]) != tc.why {
			t.Errorf("%s: why %q, want %q", tc.name, tc.r.Why(got[0]), tc.why)
		}
	}
}

func TestShapeOf(t *testing.T) {
	for _, tc := range []struct {
		name, js string
		byCN     bool
		want     RollShape
	}{
		{"healthchecked", `{"image":"x","healthcheck":{"test":["CMD","true"]}}`, false, RollShape{Health: HealthDeclared}},
		{"no healthcheck leaves the image to decide", `{"image":"x"}`, false, RollShape{}},
		{"timing alone leaves the image to decide", `{"image":"x","healthcheck":{}}`, false, RollShape{}},
		{"disabled", `{"image":"x","healthcheck":{"disable":true}}`, false, RollShape{Health: HealthOff}},
		{"NONE", `{"image":"x","healthcheck":{"test":["NONE"]}}`, false, RollShape{Health: HealthOff}},
		{"no image to carry one", `{}`, false, RollShape{Health: HealthOff}},
		{"container_name, targeted", `{"image":"x","container_name":"w"}`, true, RollShape{ByContainerName: true, ContainerName: true}},
		{"published", `{"image":"x","ports":[{"published":"8080"},{"published":""}]}`, false, RollShape{Published: true}},
		{"an ephemeral port is not published", `{"image":"x","ports":[{"published":""}]}`, false, RollShape{}},
		{"gated", `{"image":"x","depends_on":{"b":{"condition":"service_healthy"},"a":{"condition":"service_started"}}}`, false,
			RollShape{Gated: "b (service_healthy)"}},
	} {
		var s composeService
		if err := json.Unmarshal([]byte(tc.js), &s); err != nil {
			t.Fatal(err)
		}
		if got := shapeOf(s, tc.byCN); got != tc.want {
			t.Errorf("%s: %+v, want %+v", tc.name, got, tc.want)
		}
	}
}
