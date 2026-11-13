package help

import (
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/check"
)

func TestTopics(t *testing.T) {
	const dev = "1.0.1-dev.3.1760790000+g5114f85"
	for _, tt := range []struct{ build, topic, doc string }{
		{"1.0.0", "", "/blob/v1.0.0/docs/README.md"},
		{"1.0.0", "files", "/blob/v1.0.0/docs/authoring.md"},
		{"1.0.0", "setups", "/blob/v1.0.0/docs/authoring.md#setups"},
		{"1.0.0", "rules", "/blob/v1.0.0/docs/compliance.md"},
		{"1.0.0", "hk01", "/blob/v1.0.0/docs/compliance.md"},
		{dev, "rules", "/blob/main/docs/compliance.md"},
		{"", "C01", "/blob/main/docs/compliance.md"},
	} {
		got, err := Topic(tt.build, tt.topic)
		if err != nil || !strings.HasSuffix(got, "\n\nhttps://github.com/adigourdi/kasbah"+tt.doc+"\n") {
			t.Errorf("Topic(%q, %q) does not end with its doc link: %v\n%s", tt.build, tt.topic, err, got)
		}
	}
}

func TestRulesTopic(t *testing.T) {
	got, _ := Topic("1.0.0", "rules")
	for _, r := range check.Rules {
		if !strings.Contains(got, "\n  "+r.ID+" ") || !strings.Contains(got, r.Title+"\n") {
			t.Errorf("help rules has no line for %s", r.ID)
		}
	}
	for _, a := range check.Areas {
		if !strings.Contains(got, "\n"+a+":\n") {
			t.Errorf("help rules has no %s group", a)
		}
	}
	if !strings.Contains(got, "  C12   fail       [--server] No outside container holds a published port\n") {
		t.Errorf("a --server rule is not marked:\n%s", got)
	}
}

func TestRuleTopic(t *testing.T) {
	for _, r := range check.Rules {
		got, err := Topic("1.0.0", strings.ToLower(r.ID))
		if err != nil || !strings.HasPrefix(got, r.ID+"  "+r.Level+"  (") || !strings.Contains(got, ")\n"+r.Title+"\n\nWhy: ") || !strings.Contains(got, "\nChange: ") {
			t.Errorf("help %s:\n%s", r.ID, got)
		}
		for _, l := range strings.Split(got, "\n") {
			if n := len([]rune(l)); n > 80 && !strings.HasPrefix(l, "https://") {
				t.Errorf("help %s: a %d-character line: %q", r.ID, n, l)
			}
		}
	}
}

// The topic text is a screen wide.
func TestTopicWidth(t *testing.T) {
	for _, name := range []string{"", "files", "setups", "rules"} {
		got, _ := Topic("1.0.0", name)
		for _, l := range strings.Split(got, "\n") {
			if n := len([]rune(l)); n > 80 && !strings.HasPrefix(l, "https://") {
				t.Errorf("help %s: a %d-character line: %q", name, n, l)
			}
		}
	}
}

func TestUnknownTopic(t *testing.T) {
	for _, topic := range []string{"nope", "debug", "troubleshooting", "C6", "M05"} {
		if _, err := Topic("1.0.0", topic); err == nil || !strings.Contains(err.Error(), "unknown topic '"+topic+"' — the topics are files, setups, rules") {
			t.Errorf("Topic(%q): %v", topic, err)
		}
	}
}
