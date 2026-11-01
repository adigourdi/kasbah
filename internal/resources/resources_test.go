package resources

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/manifest"
)

func manifestWith(t *testing.T, block string) *manifest.Manifest {
	t.Helper()
	p := filepath.Join(t.TempDir(), "kasbah.yml")
	if err := os.WriteFile(p, []byte("schema: 1\nname: demo\n"+block), 0o644); err != nil {
		t.Fatal(err)
	}
	m, err := manifest.Require(p, "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestRead(t *testing.T) {
	for block, want := range map[string]Spec{
		"":                                      {},
		"resources:\n":                          {},
		"resources:\n  cpus: 2\n":               {CPUs: "2"},
		"resources:\n  cpus: 1.5\r\n":           {CPUs: "1.5"},
		"resources:\n  cpus: 0.5\n":             {CPUs: "0.5"},
		"resources:\n  cpus: \"50%\"\n":         {CPUs: "50%"},
		"resources:\n  memory: 512m\n":          {Memory: "512m"},
		"resources:\n  memory: 2g\n  cpus: ~\n": {Memory: "2g"},
		"resources: {cpus: 100%, memory: 1%}\n": {CPUs: "100%", Memory: "1%"},
	} {
		got, err := Read(manifestWith(t, block))
		if err != nil || got != want {
			t.Errorf("%q: %+v %v, want %+v", block, got, err, want)
		}
	}
	for block, want := range map[string]string{
		"resources: 2\n":                      "is not a block",
		"resources:\n  cpu: 2\n":              "resources.cpu is not a limit",
		"resources:\n  cpus: [1]\n":           "must be a number or a string",
		"resources:\n  cpus: true\n":          "must be a number or a string",
		"resources:\n  cpus: 0\n":             "is not a limit",
		"resources:\n  cpus: 0.0\n":           "is not a limit",
		"resources:\n  cpus: 1.25\n":          "more than one decimal",
		"resources:\n  cpus: -1\n":            "is not a limit",
		"resources:\n  cpus: 2c\n":            "is not a limit",
		"resources:\n  cpus: 0%\n":            "whole percentage",
		"resources:\n  cpus: 101%\n":          "whole percentage",
		"resources:\n  cpus: 12.5%\n":         "whole percentage",
		"resources:\n  memory: 512\n":         "has no unit — memory takes MiB (512m), GiB (2g) or a share of the host (50%) — m, g or %",
		"resources:\n  memory: 1.5\n":         "has no unit",
		"resources:\n  memory: 1.5g\n":        "is not a size",
		"resources:\n  memory: 512M\n":        "is not a size",
		"resources:\n  memory: 512mb\n":       "is not a size",
		"resources:\n  memory: 5m\n":          "below docker's 6m minimum",
		"resources:\n  memory: 0g\n":          "is not a size",
		"resources:\n  memory: 1000000000g\n": "is not a size",
	} {
		_, err := Read(manifestWith(t, block))
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%q: %v, want %q", block, err, want)
		}
	}
	if err := CheckMemory("6m"); err != nil {
		t.Errorf("6m refused: %v", err)
	}
}

func TestShares(t *testing.T) {
	// 90% is server init's ceiling: the same spelling either way.
	for _, c := range []struct {
		cores, kb, pct int64
		cpu, mem       string
	}{
		{16, 65011712, 90, "14.4", "55g"},
		{1, 8388608, 90, "0.9", "7g"},
		{2, 524288, 90, "1.8", "460m"},
		{3, 1165085, 90, "2.7", "1g"},
		{3, 1165084, 90, "2.7", "1023m"},
		{4, 8388608, 100, "4.0", "8g"},
		{4, 8388608, 50, "2.0", "4g"},
		{4, 8388608, 1, "0.1", "81m"},
		{3, 8388608, 33, "0.9", "2g"},
		{1, 8388608, 5, "0.1", "409m"},
		{1, 1000, 1, "0.1", "1m"},
	} {
		if cpu, mem := CPUShare(c.cores, c.pct), MemShare(c.kb, c.pct); cpu != c.cpu || mem != c.mem {
			t.Errorf("%d%% of %d cores / %d kB: %s %s, want %s %s", c.pct, c.cores, c.kb, cpu, mem, c.cpu, c.mem)
		}
	}
}

func TestResolve(t *testing.T) {
	for _, c := range []struct {
		spec     Spec
		cpu, mem string
	}{
		{Spec{}, "", ""},
		{Spec{CPUs: "2"}, "2.0", ""},
		{Spec{CPUs: "1.5"}, "1.5", ""},
		{Spec{CPUs: "0.5", Memory: "512m"}, "0.5", "512m"},
		{Spec{CPUs: "25%", Memory: "25%"}, "1.0", "2g"},
		{Spec{Memory: "2g"}, "", "2g"},
	} {
		// Twice: the spelling is the same on every run.
		for range 2 {
			cpu, mem, err := Resolve(c.spec, 4, 8388608)
			if err != nil || cpu != c.cpu || mem != c.mem {
				t.Errorf("%+v: %q %q %v, want %q %q", c.spec, cpu, mem, err, c.cpu, c.mem)
			}
		}
	}
	if _, _, err := Resolve(Spec{Memory: "1%"}, 1, 524288); err == nil || !strings.Contains(err.Error(), "5m, below docker's 6m minimum") {
		t.Errorf("1%% of 512 MiB: %v", err)
	}
	if _, _, err := Resolve(Spec{Memory: "512"}, 1, 524288); err == nil {
		t.Error("a bare memory resolved")
	}
}

func TestHost(t *testing.T) {
	cores, kb, err := Host()
	if err != nil || cores < 1 || kb < 1 {
		t.Errorf("Host: %d %d %v", cores, kb, err)
	}
}

func TestCompare(t *testing.T) {
	for _, c := range []struct{ a, b, cpu, mem string }{
		{"2.0", "3.6", "below", ""},
		{"3.6", "3.6", "same", ""},
		{"4.0", "3.6", "above", ""},
		{"x", "3.6", "unknown", ""},
		{"", "", "", ""},
	} {
		if c.cpu != "" && CmpCPU(c.a, c.b) != c.cpu {
			t.Errorf("CmpCPU(%s, %s) = %s", c.a, c.b, CmpCPU(c.a, c.b))
		}
	}
	if CmpMem("55296m", "54g") != "same" || CmpMem("8g", "7g") != "above" || CmpMem("512m", "7g") != "below" || CmpMem("50%", "7g") != "unknown" {
		t.Error("CmpMem")
	}
}

func TestMemBytes(t *testing.T) {
	for in, want := range map[string]int64{
		"512m": 512 << 20, "1.5g": 1610612736, "2GiB": 2 << 30, "1t": 1 << 40, "512 MB": 512 << 20,
		".5k": 512, "536870912": 536870912, "1b": 1, "54G": 54 << 30, "8191p": 8191 << 50,
	} {
		if got, ok := MemBytes(in); !ok || got != want {
			t.Errorf("MemBytes(%q) = %d, %v; want %d", in, got, ok, want)
		}
	}
	for _, in := range []string{"512mi", "1ib", "8192p", "99999999999t", "5.5.5m", "1e3", "-1m", "512  m", "1,5g", ""} {
		if got, ok := MemBytes(in); ok {
			t.Errorf("MemBytes(%q) = %d, want not a size", in, got)
		}
	}
}
