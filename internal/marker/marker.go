// Package marker builds and reads the server marker, <apps>/.kasbah/server.json
// (docs/server-setup.md → Server marker): the merge `server init` writes and
// the validation every server-targeting command applies to what it reads.
package marker

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
)

// Mode is the marker's file mode (docs/files.md).
const Mode = 0o644

// Path is the marker's path under an apps path.
func Path(apps string) string { return apps + "/.kasbah/server.json" }

// Retention is the backup object's retention counts.
type Retention struct{ Daily, Weekly, Monthly int }

// Backup is what `--with-backup` decided (lib/backup.sh's _bk_marker_json).
type Backup struct {
	RepoBase  string
	At        string
	Jitter    int
	Timeout   int
	Retention Retention
}

func num(i int) jv.Number { return jv.Number(fmt.Sprint(i)) }

func (b *Backup) object() *jv.Map {
	m := jv.NewMap()
	m.Set("enabled", true)
	m.Set("repo_base", b.RepoBase)
	m.Set("at", b.At)
	m.Set("jitter", num(b.Jitter))
	m.Set("timeout", num(b.Timeout))
	return m
}

func (r Retention) object() *jv.Map {
	m := jv.NewMap()
	m.Set("daily", num(r.Daily))
	m.Set("weekly", num(r.Weekly))
	m.Set("monthly", num(r.Monthly))
	return m
}

// Fields are the five keys `server init` owns.
type Fields struct {
	KasbahVersion, AppsPath, DataPath, CPULimit, MemLimit string
}

// objectOr is jq's `x // {}` feeding an object `+`: null and false are
// empty, any other non-object is jq's error.
func objectOr(v jv.Value, what string) (*jv.Map, error) {
	switch v := v.(type) {
	case *jv.Map:
		return v, nil
	case nil:
		return jv.NewMap(), nil
	case bool:
		if !v {
			return jv.NewMap(), nil
		}
	}
	return nil, fmt.Errorf("%s (%s) and object cannot be added", what, jv.Type(v))
}

// Build is _server_marker_json: merged into existing (nil for none), owned
// keys keeping their place. A nil backup keeps the existing one or records
// `{enabled: false}`; a given one merges into it, retention into retention.
func Build(f Fields, existing *jv.Map, backup *Backup) (*jv.Map, error) {
	e := existing
	if e == nil {
		e = jv.NewMap()
	}
	own := jv.NewMap()
	own.Set("kasbah_version", f.KasbahVersion)
	own.Set("apps_path", f.AppsPath)
	own.Set("data_path", f.DataPath)
	own.Set("cpu_limit", f.CPULimit)
	own.Set("mem_limit", f.MemLimit)
	out := jv.Add(e, own)

	if backup == nil {
		if !out.Has("backup") {
			off := jv.NewMap()
			off.Set("enabled", false)
			out.Set("backup", off)
		}
		return out, nil
	}
	eb, _ := e.Get("backup")
	if b, ok := eb.(bool); ok && !b {
		// `$e.backup.retention` indexes the false itself.
		return nil, fmt.Errorf(`Cannot index boolean with string "retention"`)
	}
	old, err := objectOr(eb, "backup")
	if err != nil {
		return nil, err
	}
	er, _ := old.Get("retention")
	oldRet, err := objectOr(er, "backup.retention")
	if err != nil {
		return nil, err
	}
	merged := jv.Add(old, backup.object())
	ret := jv.NewMap()
	ret.Set("retention", jv.Add(oldRet, backup.Retention.object()))
	out.Set("backup", jv.Add(merged, ret))
	return out, nil
}

// Render is the marker's bytes: jq's pretty print and one newline.
func Render(m *jv.Map) []byte { return []byte(jv.Pretty(m) + "\n") }

// Marker is a server marker that passed Validate.
type Marker struct {
	JSON     *jv.Map
	AppsPath string
	DataPath string
	// CPULimit and MemLimit are written through as spelled (`14.4`, `54g`).
	CPULimit string
	MemLimit string
}

// field is `$(jq -r '.k // "" | tostring')`: trailing newlines go with $(…).
func field(m *jv.Map, k string) string {
	v, _ := m.Get(k)
	return strings.TrimRight(jv.ToString(jv.Alt(v, "")), "\n")
}

// Validate is lib/marker.sh's judgement of a marker's content, read from path
// on target. initCmd is the init command spelled for this server, which every
// refusal names as the remedy.
func Validate(body []byte, path, target, initCmd string) (*Marker, error) {
	v, err := jv.ParseOne(body)
	m, ok := v.(*jv.Map)
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

// Compat is `server init`'s check of an existing marker: a newer major is
// refused, versions that cannot be compared are warned about. An older major
// passes until `kasbah migrate` exists (docs/server-setup.md).
func Compat(existing []byte, ours, path, target string) (warnings []string, err error) {
	v, perr := jv.ParseOne(existing)
	m, ok := v.(*jv.Map)
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
	// test(1)'s -gt: a major too large for it is an error there, and the
	// refusal is skipped.
	m64, err1 := strconv.ParseInt(major, 10, 64)
	o64, err2 := strconv.ParseInt(ourMajor, 10, 64)
	if err1 == nil && err2 == nil && m64 > o64 {
		return nil, cli.Fail("%s was written by kasbah %s, and this is kasbah %s", path, version, ours).Cont(
			"a newer major on the server means fields this binary does not know about",
			"upgrade kasbah locally, or point at a server this version manages")
	}
	return nil, nil
}
