package release

import (
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

func TestPick(t *testing.T) {
	for _, tt := range []struct {
		tags, want, err string
	}{
		{"v1.4.2\n", "1.4.2", ""},
		{"nightly\nv3.1.0\n", "3.1.0", ""},
		{"v1.4.2\r\n", "1.4.2", ""},
		{"v1.0.0-rc.1\n", "1.0.0-rc.1", ""},
		{"v1.0.0+build.7\n", "1.0.0+build.7", ""},
		{"", "", "no version tag"},
		{"release-7\nlatest\n", "", "HEAD is tagged release-7 latest"},
		{"v\n", "", "no version tag"},
		{"v1.4.2\nv1.5.0\n", "", "2 version tags — v1.4.2 v1.5.0"},
		{"v1.4\n", "", "'v1.4' is not a version"},
		{"vnext\n", "", "'vnext' is not a version"},
		{"v1.2.3-\n", "", "is not a version"},
		{"v١.2.3\n", "", "is not a version"},
	} {
		got, err := Pick(tt.tags)
		if tt.err == "" {
			if err != nil || got != tt.want {
				t.Errorf("Pick(%q) = %q, %v; want %q", tt.tags, got, err, tt.want)
			}
			continue
		}
		e, ok := err.(*cli.Error)
		if !ok || e.Code != 1 || !strings.Contains(e.Error(), tt.err) {
			t.Errorf("Pick(%q) = %q, %v; want exit 1 saying %q", tt.tags, got, err, tt.err)
		}
	}
}
