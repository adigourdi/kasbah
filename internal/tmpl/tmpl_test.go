package tmpl

import (
	"strings"
	"testing"
)

func TestSection(t *testing.T) {
	tpl := "a\n  # [s]\nb\n  # [/s]\nc\n"
	for keep, want := range map[bool]string{true: "a\nb\nc\n", false: "a\nc\n"} {
		if got, err := Section(tpl, "x", "s", keep); err != nil || got != want {
			t.Errorf("keep=%v: %q %v", keep, got, err)
		}
	}
	for _, bad := range []string{"# [s]\n", "# [/s]\n", "# [s]\n# [s]\n# [/s]\n"} {
		if _, err := Section(bad, "x", "s", true); err == nil || !strings.Contains(err.Error(), "internal:") {
			t.Errorf("%q: %v", bad, err)
		}
	}
}
