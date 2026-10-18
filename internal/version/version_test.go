package version

import (
	"testing"
	"time"
)

func TestStamp(t *testing.T) {
	at := time.Unix(1760790000, 0)
	tests := []struct {
		name    string
		base    string
		commits int
		dirty   bool
		want    string
	}{
		{"clean pre-release", "0.1.0-dev", 142, false, "0.1.0-dev.142"},
		{"dirty pre-release", "0.1.0-dev", 142, true, "0.1.0-dev.142.1760790000"},
		{"trailing newline from the file", "0.1.0-dev\n", 7, false, "0.1.0-dev.7"},
		{"CRLF from the file", "0.1.0-dev\r\n", 7, false, "0.1.0-dev.7"},
		{"clean release", "1.0.0", 142, false, "1.0.0"},
		{"dirty release", "1.0.0\n", 142, true, "1.0.0"},
		{"dotted pre-release", "1.1.0-rc.1", 300, false, "1.1.0-rc.1.300"},
		{"release with build metadata", "1.0.0+exp-sha.5114f85", 142, true, "1.0.0+exp-sha.5114f85"},
		{"pre-release with build metadata", "0.1.0-dev+meta", 142, true, "0.1.0-dev.142.1760790000+meta"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := Stamp(tt.base, tt.commits, tt.dirty, at); got != tt.want {
				t.Errorf("Stamp(%q, %d, %v) = %q, want %q", tt.base, tt.commits, tt.dirty, got, tt.want)
			}
		})
	}
}
