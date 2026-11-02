// Package marker builds and reads the server marker, <apps>/.kasbah/server.json
// (docs/server-setup.md → Server marker): the merge `server init` writes and
// the validation every server-targeting command applies to what it reads.
package marker

import (
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/tree"
)

// Mode is the marker's file mode (docs/files.md).
const Mode = 0o664

// Path is the marker's path under an apps path.
func Path(apps string) string { return apps + "/.kasbah/server.json" }

// Retention is the backup object's retention counts.
type Retention struct{ Daily, Weekly, Monthly int }

// Backup is what `--with-backup` decided.
type Backup struct {
	RepoBase  string
	At        string
	Jitter    int
	Timeout   int
	Retention Retention
	// User and HookTimeout are the nightly job's; "" and 0 record nothing.
	User        string
	HookTimeout int
}

func num(i int) tree.Number { return tree.Number(fmt.Sprint(i)) }

func (b *Backup) object() *tree.Map {
	m := tree.NewMap()
	m.Set("enabled", true)
	m.Set("repo_base", b.RepoBase)
	m.Set("at", b.At)
	m.Set("jitter", num(b.Jitter))
	m.Set("timeout", num(b.Timeout))
	if b.User != "" {
		m.Set("user", b.User)
	}
	if b.HookTimeout != 0 {
		m.Set("hook_timeout", num(b.HookTimeout))
	}
	return m
}

func (r Retention) object() *tree.Map {
	m := tree.NewMap()
	m.Set("daily", num(r.Daily))
	m.Set("weekly", num(r.Weekly))
	m.Set("monthly", num(r.Monthly))
	return m
}

// Fields are the five keys `server init` owns.
type Fields struct {
	KasbahVersion, AppsPath, DataPath, CPULimit, MemLimit string
}

// objectOr is v as an object to merge into: null is an empty one, anything
// else that is not an object is refused.
func objectOr(v tree.Value, what string) (*tree.Map, error) {
	switch v := v.(type) {
	case *tree.Map:
		return v, nil
	case nil:
		return tree.NewMap(), nil
	}
	return nil, fmt.Errorf("the existing marker's %s is %s, not an object, so the new backup settings cannot be merged into it", what, tree.Text(v))
}

// Build is the marker `server init` writes: merged into existing (nil for none), owned
// keys keeping their place. A nil backup keeps the existing one or records
// `{enabled: false}`; a given one merges into it, retention into retention.
func Build(f Fields, existing *tree.Map, backup *Backup) (*tree.Map, error) {
	e := existing
	if e == nil {
		e = tree.NewMap()
	}
	own := tree.NewMap()
	own.Set("kasbah_version", f.KasbahVersion)
	own.Set("apps_path", f.AppsPath)
	own.Set("data_path", f.DataPath)
	own.Set("cpu_limit", f.CPULimit)
	own.Set("mem_limit", f.MemLimit)
	out := tree.Merge(e, own)

	if backup == nil {
		if !out.Has("backup") {
			off := tree.NewMap()
			off.Set("enabled", false)
			out.Set("backup", off)
		}
		return out, nil
	}
	eb, _ := e.Get("backup")
	old, err := objectOr(eb, "backup")
	if err != nil {
		return nil, err
	}
	er, _ := old.Get("retention")
	oldRet, err := objectOr(er, "backup.retention")
	if err != nil {
		return nil, err
	}
	merged := tree.Merge(old, backup.object())
	ret := tree.NewMap()
	ret.Set("retention", tree.Merge(oldRet, backup.Retention.object()))
	out.Set("backup", tree.Merge(merged, ret))
	return out, nil
}

// ReadLocal is the marker under apps on this machine, as `kasbah remote
// marker` prints it — kept for 1.0.0 workstations; later ones read the probe's copy.
func ReadLocal(apps string) ([]byte, error) {
	p := Path(apps)
	fi, err := os.Stat(p)
	if err != nil {
		return nil, err
	}
	if !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s exists and is not a regular file", p)
	}
	return os.ReadFile(p)
}

// Render is the marker's bytes: indented JSON and one newline.
func Render(m *tree.Map) []byte { return []byte(tree.Indent(m) + "\n") }

// Marker is a server marker that passed Validate.
type Marker struct {
	JSON     *tree.Map
	AppsPath string
	DataPath string
	// CPULimit and MemLimit are written through as spelled (`14.4`, `54g`).
	CPULimit string
	MemLimit string
}

// field is a key's value as text, "" for none or null, trailing newlines off.
func field(m *tree.Map, k string) string {
	return strings.TrimRight(tree.TextAt(m, k), "\n")
}

// Validate judges a marker's content, read from path
// on target. initCmd is the init command spelled for this server, which every
// refusal names as the remedy.
func Validate(body []byte, path, target, initCmd string) (*Marker, error) {
	v, err := tree.ParseOne(body)
	m, ok := v.(*tree.Map)
	if err != nil || !ok {
		return nil, cli.Fail("%s on %s is not a JSON object — re-run `%s`", path, target, initCmd)
	}
	mk := &Marker{
		JSON:     m,
		AppsPath: field(m, "apps_path"),
		DataPath: field(m, "data_path"),
		CPULimit: field(m, "cpu_limit"),
		MemLimit: field(m, "mem_limit"),
	}
	for _, p := range []string{mk.AppsPath, mk.DataPath} {
		if len(p) < 2 || p[0] != '/' {
			return nil, cli.Fail("%s on %s records apps_path='%s' data_path='%s'; both must be absolute paths — re-run `%s`",
				path, target, mk.AppsPath, mk.DataPath, initCmd)
		}
	}
	// No whitespace: the limits go into `KEY=value` lines compose re-reads.
	for _, l := range []string{mk.CPULimit, mk.MemLimit} {
		if l == "" || strings.ContainsAny(l, " \t\n\v\f\r") {
			return nil, cli.Fail("%s on %s records cpu_limit='%s' mem_limit='%s'", path, target, mk.CPULimit, mk.MemLimit).Cont(
				"both are required and neither may carry whitespace: kasbah writes them",
				"into every project's .env as KASBAH_CPU_LIMIT / KASBAH_MEM_LIMIT, and",
				"the compose files read cpus: and mem_limit: from there",
				"(docs/env-template.md). Re-run `"+initCmd+"` to rewrite it.")
		}
	}
	return mk, nil
}

// Major is a version's major, as `server init` compares them: a leading `v`
// dropped, everything from the first dot off.
func Major(version string) string {
	v := strings.TrimPrefix(version, "v")
	major, _, _ := strings.Cut(v, ".")
	return major
}

var reDigits = regexp.MustCompile(`^[0-9]+$`)

// MigrateCmd is `kasbah migrate server` spelled for this server: the remedy
// an older-major refusal names.
func MigrateCmd(target string) string { return "kasbah migrate server " + target }

// Check judges a marker's major against ours, before anything ships: an older
// major is refused until MigrateCmd has run, a newer one until kasbah is
// upgraded; migrating admits the older one. A marker that is not an object,
// or a version that cannot be compared, passes — the caller's own reading
// judges those.
func Check(body []byte, ours, path, target string, migrating bool) error {
	v, perr := tree.ParseOne(body)
	m, ok := v.(*tree.Map)
	if perr != nil || !ok {
		return nil
	}
	version := field(m, "kasbah_version")
	major, ourMajor := Major(version), Major(ours)
	// test(1)'s -gt: a major too large for it is an error there, and the
	// refusal is skipped.
	m64, err1 := strconv.ParseInt(major, 10, 64)
	o64, err2 := strconv.ParseInt(ourMajor, 10, 64)
	if !reDigits.MatchString(major) || !reDigits.MatchString(ourMajor) || err1 != nil || err2 != nil {
		return nil
	}
	switch {
	case m64 > o64:
		return cli.Fail("%s on %s was written by kasbah %s, and this is kasbah %s", path, target, version, ours).Cont(
			"a newer major on the server means fields this binary does not know about",
			"upgrade kasbah locally, or point at a server this version manages")
	case m64 < o64 && !migrating:
		return cli.Fail("%s on %s was written by kasbah %s, and this is kasbah %s", path, target, version, ours).Cont(
			"a server stays on its major until it is migrated, and nothing was shipped to it:",
			"run `"+MigrateCmd(target)+"` to move it — every kasbah workstation older",
			fmt.Sprintf("than %s.x will be refused by this server afterwards", ourMajor))
	}
	return nil
}

// Compat is `server init`'s check of an existing marker: Check, after the
// marker is known to be an object; versions that cannot be compared are
// warned about.
func Compat(existing []byte, ours, path, target string) (warnings []string, err error) {
	v, perr := tree.ParseOne(existing)
	m, ok := v.(*tree.Map)
	if perr != nil || !ok {
		return nil, cli.Fail("%s on %s is not a JSON object", path, target).Cont(
			"kasbah will not overwrite a marker it cannot read — look at it, then remove",
			"it and re-run to start the server's record over")
	}
	version := field(m, "kasbah_version")
	major, ourMajor := Major(version), Major(ours)
	if !reDigits.MatchString(major) || !reDigits.MatchString(ourMajor) {
		return []string{
			fmt.Sprintf("%s records kasbah_version '%s'; this kasbah is %s", path, version, ours),
			"the two cannot be compared, so no compatibility check was made",
		}, nil
	}
	return nil, Check(existing, ours, path, target, false)
}
