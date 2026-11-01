// Package resources is kasbah.yml's resources: block and the integer arithmetic
// it and server init's 90% ceilings are spelled by (docs/project-manifest.md →
// resources, docs/server-setup.md → Resource limits).
package resources

import (
	"bufio"
	"fmt"
	"math/big"
	"os"
	"regexp"
	"runtime"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/tree"
)

// Spec is the block as written, "" for an unset half.
type Spec struct{ CPUs, Memory string }

// Set reports whether either half is set.
func (s Spec) Set() bool { return s.CPUs != "" || s.Memory != "" }

var (
	reCores = regexp.MustCompile(`^(0|[1-9][0-9]{0,5})(\.[0-9])?$`)
	reSize  = regexp.MustCompile(`^[1-9][0-9]{0,8}[mg]$`)
	rePct   = regexp.MustCompile(`^([1-9][0-9]?|100)%$`)
	// reTwoDecimals and reBare name the two near-misses worth their own message.
	reTwoDecimals = regexp.MustCompile(`^[0-9]+\.[0-9]{2,}$`)
	reBare        = regexp.MustCompile(`^[0-9]+(\.[0-9]+)?$`)
)

// minMiB is docker's smallest memory limit, 6 MiB.
const minMiB = 6

const cpusHelp = "cpus takes a number of cores with at most one decimal (0.5, 2) or a share of the host (50%)"
const memHelp = "memory takes MiB (512m), GiB (2g) or a share of the host (50%) — m, g or %"

// CheckCPUs judges one cpus value: nil when it is one.
func CheckCPUs(v string) error {
	if rePct.MatchString(v) {
		return nil
	}
	if strings.HasSuffix(v, "%") {
		return fmt.Errorf("resources.cpus '%s' is not a whole percentage from 1%% to 100%%", v)
	}
	if reTwoDecimals.MatchString(v) {
		return fmt.Errorf("resources.cpus '%s' has more than one decimal — kasbah spells cpus in tenths of a core, at most one decimal (0.5, 2)", v)
	}
	if !reCores.MatchString(v) || strings.Trim(v, "0.") == "" {
		return fmt.Errorf("resources.cpus '%s' is not a limit — %s", v, cpusHelp)
	}
	return nil
}

// CheckMemory judges one memory value: nil when it is one.
func CheckMemory(v string) error {
	switch {
	case rePct.MatchString(v):
		return nil
	case strings.HasSuffix(v, "%"):
		return fmt.Errorf("resources.memory '%s' is not a whole percentage from 1%% to 100%%", v)
	case reBare.MatchString(v):
		return fmt.Errorf("resources.memory '%s' has no unit — %s", v, memHelp)
	case !reSize.MatchString(v):
		return fmt.Errorf("resources.memory '%s' is not a size — %s", v, memHelp)
	}
	if n, _ := strconv.Atoi(strings.TrimSuffix(v, "m")); strings.HasSuffix(v, "m") && n < minMiB {
		return fmt.Errorf("resources.memory '%s' is below docker's %dm minimum", v, minMiB)
	}
	return nil
}

// Read is the manifest's resources: block, each half judged. An absent or
// null block, or half, is unset.
func Read(m *manifest.Manifest) (Spec, error) {
	var s Spec
	v, _ := m.Get("resources")
	if v == nil {
		return s, nil
	}
	rm, ok := v.(*tree.Map)
	if !ok {
		return s, fmt.Errorf("resources: is not a block — it holds cpus: and memory: (docs/project-manifest.md)")
	}
	for _, k := range rm.Keys() {
		if k != "cpus" && k != "memory" {
			return s, fmt.Errorf("resources.%s is not a limit kasbah sets — resources: holds cpus: and memory: (docs/project-manifest.md)", k)
		}
	}
	for _, k := range []string{"cpus", "memory"} {
		x, _ := rm.Get(k)
		switch x.(type) {
		case nil, string, tree.Number:
		default:
			return s, fmt.Errorf("resources.%s must be a number or a string, not %s", k, tree.Compact(x))
		}
		t := strings.TrimSpace(strings.TrimSuffix(tree.TextAt(x), "\r"))
		if t == "" || t == "null" {
			continue
		}
		var err error
		if k == "cpus" {
			s.CPUs, err = t, CheckCPUs(t)
		} else {
			s.Memory, err = t, CheckMemory(t)
		}
		if err != nil {
			return Spec{}, err
		}
	}
	return s, nil
}

// CPUShare is pct% of cores in tenths of a core, floored, spelled with one
// decimal; never 0.0 on a host that has a core.
func CPUShare(cores, pct int64) string {
	tenths := cores * pct / 10
	if tenths < 1 && cores > 0 {
		tenths = 1
	}
	return fmt.Sprintf("%d.%d", tenths/10, tenths%10)
}

// MemShare is pct% of memKB, floored to whole GiB with a g once that is at
// least 1, else to whole MiB with an m, at least 1m.
func MemShare(memKB, pct int64) string {
	if gib := memKB * pct / 104857600; gib >= 1 {
		return fmt.Sprintf("%dg", gib)
	}
	mib := memKB * pct / 102400
	if mib < 1 {
		mib = 1
	}
	return fmt.Sprintf("%dm", mib)
}

func percent(v string) (int64, bool) {
	if !strings.HasSuffix(v, "%") {
		return 0, false
	}
	n, err := strconv.ParseInt(strings.TrimSuffix(v, "%"), 10, 64)
	return n, err == nil
}

// Resolve spells each set half as the marker spells its ceilings: a share
// against this host's cores and MemTotal, cores with one decimal, a size as
// written. An unset half is "".
func Resolve(s Spec, cores, memKB int64) (cpu, mem string, err error) {
	if s.CPUs != "" {
		if err := CheckCPUs(s.CPUs); err != nil {
			return "", "", err
		}
		if p, ok := percent(s.CPUs); ok {
			cpu = CPUShare(cores, p)
		} else if cpu = s.CPUs; !strings.Contains(cpu, ".") {
			cpu += ".0"
		}
	}
	if s.Memory != "" {
		if err := CheckMemory(s.Memory); err != nil {
			return "", "", err
		}
		mem = s.Memory
		if p, ok := percent(s.Memory); ok {
			if mem = MemShare(memKB, p); memKB*p/102400 < minMiB {
				return "", "", fmt.Errorf("resources.memory '%s' of this host is %s, below docker's %dm minimum", s.Memory, mem, minMiB)
			}
		}
	}
	return cpu, mem, nil
}

// Host is the CPUs this process may run on (its affinity, as server init's
// nproc counts them) and /proc/meminfo's MemTotal in kB.
func Host() (cores, memKB int64, err error) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, 0, fmt.Errorf("cannot read /proc/meminfo")
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		if fs := strings.Fields(sc.Text()); len(fs) >= 2 && fs[0] == "MemTotal:" {
			if memKB, err = strconv.ParseInt(fs[1], 10, 64); err != nil {
				break
			}
			return int64(runtime.NumCPU()), memKB, nil
		}
	}
	return 0, 0, fmt.Errorf("/proc/meminfo reports no MemTotal")
}

var reCPU = regexp.MustCompile(`^([0-9]+(\.[0-9]+)?|\.[0-9]+)$`)

// CPUText reports whether v is a plain decimal, as compose's cpus takes one.
func CPUText(v string) bool { return reCPU.MatchString(strings.TrimSuffix(v, "\r")) }

// Cores is a cpus value as an exact number; ok false when it is not one.
func Cores(v string) (*big.Rat, bool) {
	v = strings.TrimSuffix(v, "\r")
	if !reCPU.MatchString(v) {
		return nil, false
	}
	return new(big.Rat).SetString(v)
}

// CmpCPU is above, below, same or unknown.
func CmpCPU(a, b string) string {
	x, ok1 := Cores(a)
	y, ok2 := Cores(b)
	if !ok1 || !ok2 {
		return "unknown"
	}
	return verdict(x.Cmp(y))
}

var reMem = regexp.MustCompile(`^([0-9]+(?:\.[0-9]+)?|\.[0-9]+) ?(b|[kmgtp](?:i?b)?)?$`)

// MemBytes is a memory size in bytes as docker reads one — a decimal, an
// optional space, a binary unit with an optional b or ib, any case, the
// fraction truncated; ok false when it is not one or overflows int64.
func MemBytes(v string) (int64, bool) {
	m := reMem.FindStringSubmatch(strings.ToLower(strings.TrimSuffix(v, "\r")))
	if m == nil {
		return 0, false
	}
	n, ok := new(big.Rat).SetString(m[1])
	if !ok {
		return 0, false
	}
	if m[2] != "" && m[2] != "b" {
		unit := new(big.Int).Lsh(big.NewInt(1), uint(10*(strings.IndexByte("kmgtp", m[2][0])+1)))
		n.Mul(n, new(big.Rat).SetInt(unit))
	}
	q := new(big.Int).Quo(n.Num(), n.Denom())
	if !q.IsInt64() {
		return 0, false
	}
	return q.Int64(), true
}

// CmpMem is above, below, same or unknown, compared in bytes.
func CmpMem(a, b string) string {
	x, ok1 := MemBytes(a)
	y, ok2 := MemBytes(b)
	if !ok1 || !ok2 {
		return "unknown"
	}
	return verdict(big.NewInt(x).Cmp(big.NewInt(y)))
}

func verdict(c int) string {
	switch {
	case c > 0:
		return "above"
	case c < 0:
		return "below"
	}
	return "same"
}
