package version

import (
	"testing"
	"time"
)

func TestDirtyLabel(t *testing.T) {
	now := time.Date(2026, 10, 28, 9, 5, 7, 0, time.FixedZone("x", 3600))
	got := DirtyLabel("1.2.0", now)
	if got != "1.2.0-dirty.20261028080507" {
		t.Fatalf("DirtyLabel = %q", got)
	}
	if _, err := Parse(got); err != nil {
		t.Errorf("label does not parse as semver: %v", err)
	}
	if Dev(got) {
		t.Errorf("a dirty label must not read as a dev build stamp")
	}
}

func TestIsDirty(t *testing.T) {
	for v, want := range map[string]bool{
		"1.2.0-dirty.20261028080507":      true,
		"1.2.0-dirty.20261028080507\r":    true,
		"1.3.0-rc.1-dirty.20261028080507": true,
		"0.0.0-dirty.20261028080507":      true,
		"1.2.0":                           false,
		"1.2.0-rc.1":                      false,
		"1.2.0-dirty":                     false,
		"1.2.0-dirty.2026":                false,
		"1.2.0-dirty.20261028080507.1":    false,
	} {
		if got := IsDirty(v); got != want {
			t.Errorf("IsDirty(%q) = %v, want %v", v, got, want)
		}
	}
}

func TestDirtyBase(t *testing.T) {
	for v, want := range map[string]string{
		"1.2.0-dirty.20261028080507":      "1.2.0",
		"1.3.0-rc.1-dirty.20261028080507": "1.3.0-rc.1",
		"1.2.0":                           "1.2.0",
		"1.2.0-dirty":                     "1.2.0-dirty",
	} {
		if got := DirtyBase(v); got != want {
			t.Errorf("DirtyBase(%q) = %q, want %q", v, got, want)
		}
	}
}
