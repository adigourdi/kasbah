package env

import (
	"fmt"
	"io"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/probe"
	"github.com/adigourdi/kasbah/internal/resources"
)

// Limits is what the managed block gets, and where each value came from.
type Limits struct {
	CPU, Mem string
	Source   string
}

// Resolve is the project's limits on target: the marker's ceilings, or
// resources: resolved by the server binary and held to them. lenient (a
// rollback) warns and takes the ceiling where a plain deploy refuses.
func Resolve(out *cli.Output, s Session, target string, spec resources.Spec, mk *marker.Marker, lenient bool) (Limits, error) {
	l := Limits{CPU: mk.CPULimit, Mem: mk.MemLimit, Source: "from the server marker"}
	if !spec.Set() {
		return l, nil
	}
	raw, rc := s.Limits(dash(spec.CPUs), dash(spec.Memory))
	if rc != 0 {
		if lenient {
			out.Warn("could not resolve the resources: of the manifest in this version on %s (`kasbah remote setup-env limits` failed: %s, see above) — taking the server's ceilings", target, exitText(rc))
			return l, nil
		}
		return l, cli.Fail("could not resolve kasbah.yml's resources: on %s", target).Cont(
			"`kasbah remote setup-env limits` failed: " + exitText(rc) + " (see above). Nothing of the project's changed on the server.")
	}
	got := map[string]string{}
	for _, line := range strings.Split(raw, "\n") {
		if k, v, ok := strings.Cut(line, "="); ok {
			got[k] = v
		}
	}
	host := fmt.Sprintf("%s cores, %s kB", got["host_cores"], got["host_mem_kb"])
	var from []string
	for _, h := range []struct {
		field, spec, key, ceiling string
		value                     *string
		cmp                       func(a, b string) string
	}{
		{"cpus", spec.CPUs, "cpu", mk.CPULimit, &l.CPU, resources.CmpCPU},
		{"memory", spec.Memory, "mem", mk.MemLimit, &l.Mem, resources.CmpMem},
	} {
		if h.spec == "" {
			continue
		}
		v := got[h.key]
		var err *cli.Error
		switch {
		case v == "" || strings.ContainsAny(v, " \t\r"):
			err = cli.Fail("the server reported no %s for resources.%s '%s' (raw output: %s)", h.key, h.field, h.spec, strings.TrimSpace(raw))
		case h.cmp(v, h.ceiling) == "above":
			err = cli.Fail("kasbah.yml: resources.%s '%s' comes to %s on %s (%s), above the server's 90%% ceiling of %s", h.field, h.spec, v, target, host, h.ceiling).Cont(
				"the ceiling is what keeps one project from taking the host down: a project",
				fmt.Sprintf("may set less, never more. Set resources.%s to %s or less, or leave it unset", h.field, h.ceiling),
				"to get the ceiling. The ceiling is what `kasbah server init` measured: if the",
				"host has changed since (more cores or memory, a new kernel), re-run it to",
				"re-measure. Nothing of the project's changed on the server.")
		case h.cmp(v, h.ceiling) == "unknown":
			err = cli.Fail("kasbah.yml: resources.%s '%s' comes to %s on %s, which cannot be compared with the marker's ceiling '%s'", h.field, h.spec, v, target, h.ceiling).Cont(
				"re-run `kasbah server init " + target + "` to rewrite the marker. Nothing of the project's changed on the server.")
		}
		if err != nil {
			if !lenient {
				return l, err
			}
			out.Warn("the manifest in this version: %s — taking the ceiling", strings.TrimPrefix(err.Lines[0], "kasbah.yml: "))
			continue
		}
		*h.value = v
		from = append(from, h.field)
	}
	switch len(from) {
	case 2:
		l.Source = "from kasbah.yml resources"
	case 1:
		other := map[string]string{"cpus": "memory", "memory": "cpus"}[from[0]]
		l.Source = from[0] + " from kasbah.yml resources, " + other + " from the server marker"
	}
	return l, nil
}

func dash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}

// remoteLimits is `setup-env limits CPUS MEMORY` ("-" for an unset half):
// each set half resolved against this host, with the totals it read.
func remoteLimits(cpus, memory string, stdout, stderr io.Writer) int {
	spec := resources.Spec{}
	if cpus != "-" {
		spec.CPUs = cpus
	}
	if memory != "-" {
		spec.Memory = memory
	}
	cores, kb, err := resources.Host()
	if err == nil {
		var cpu, mem string
		if cpu, mem, err = resources.Resolve(spec, cores, kb); err == nil {
			fmt.Fprintf(stdout, "host_cores=%d\nhost_mem_kb=%d\n", cores, kb)
			if cpu != "" {
				fmt.Fprintln(stdout, "cpu="+cpu)
			}
			if mem != "" {
				fmt.Fprintln(stdout, "mem="+mem)
			}
			return 0
		}
	}
	fmt.Fprintf(stderr, "ERROR: %v\n", err)
	return 1
}

// ManagedLimits is the two KASBAH_* limits as envfile's managed block sets
// them (last assignment wins, as compose reads it), and no other line; ok is
// false when envfile is not a regular file or cannot be read.
func ManagedLimits(envfile string) (cpu, mem string, ok bool) {
	data, err := probe.ReadRegular(envfile)
	if err != nil {
		return "", "", false
	}
	lines := rawLines(data)
	in := managedBlock(lines)
	for i, line := range lines {
		if !in[i] {
			continue
		}
		switch k, v, ok := envtpl.Assign(strings.TrimSuffix(line, "\r")); {
		case ok && k == "KASBAH_CPU_LIMIT":
			cpu = v
		case ok && k == "KASBAH_MEM_LIMIT":
			mem = v
		}
	}
	return cpu, mem, true
}
