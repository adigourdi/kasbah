// Package state reads and merges a project's .kasbah/state.json
// (docs/project-manifest.md → State file): rendered the
// way jq renders it, merged rather than rewritten, renamed into place.
package state

import (
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
)

// File is the state file, relative to the project root.
const File = ".kasbah/state.json"

// Defaults is the shape every state file has: init-project writes it, and a
// merge puts it under whatever a file already holds.
func Defaults(version string) *jv.Map {
	m := jv.NewMap()
	m.Set("kasbah_version", version)
	m.Set("last_server", nil)
	m.Set("last_deploy", nil)
	m.Set("last_version", nil)
	m.Set("schema_migrations_applied", []jv.Value{})
	return m
}

func render(vs ...jv.Value) []byte {
	var b strings.Builder
	for _, v := range vs {
		b.WriteString(jv.Pretty(v))
		b.WriteByte('\n')
	}
	return []byte(b.String())
}

// Init writes a fresh state file, creating its directory. The
// mode is the umask's (docs/files.md).
func Init(path, version string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o777); err != nil {
		return err
	}
	return os.WriteFile(path, render(Defaults(version)), 0o666)
}

func isFile(path string) bool {
	fi, err := os.Stat(path)
	return err == nil && fi.Mode().IsRegular()
}

// Get is `$(jq -r '.[$k] // "" | tostring')`: empty for an absent file, key,
// null or false; a non-string compact. A file of anything but JSON objects is
// an error, never a silent empty.
func Get(path, key string) (string, error) {
	if !isFile(path) {
		return "", nil
	}
	unreadable := cli.Fail("%s: not readable as JSON — delete it, or fix it by hand", path)
	data, err := os.ReadFile(path)
	if err != nil {
		return "", unreadable
	}
	vs, err := jv.Parse(data)
	if err != nil {
		return "", unreadable
	}
	var outs []string
	for _, v := range vs {
		switch v.(type) {
		case nil, *jv.Map:
		default:
			return "", unreadable
		}
		f, _ := jv.Get(v, key)
		outs = append(outs, jv.ToString(jv.Alt(f, "")))
	}
	out := strings.TrimRight(strings.Join(outs, "\n"), "\n")
	return strings.TrimSuffix(out, "\r"), nil
}

var reKey = regexp.MustCompile(`^[a-z][a-z0-9_]*$`)

// Record merges: defaults, then the file's own fields, then these,
// rendered to <path>.tmp.<pid> and renamed. A file of anything but JSON
// objects is refused untouched. Call it only after kasbah's work succeeded.
func Record(path, version string, kv ...string) error {
	if len(kv)%2 != 0 {
		return cli.Fail("internal: state.Record got an odd number of arguments (key '%s' has no value)", kv[len(kv)-1])
	}
	for i := 0; i < len(kv); i += 2 {
		if !reKey.MatchString(kv[i]) {
			return cli.Fail("internal: '%s' is not a state field name", kv[i])
		}
	}
	return update(path, version, func(m *jv.Map) {
		for i := 0; i < len(kv); i += 2 {
			m.Set(kv[i], kv[i+1])
		}
	})
}

// Append is Record for a list field: value joins the end of key's array
// unless it is already in it (one that is not an array is replaced by a
// one-element one).
func Append(path, version, key, value string) error {
	if !reKey.MatchString(key) {
		return cli.Fail("internal: '%s' is not a state field name", key)
	}
	return update(path, version, func(m *jv.Map) {
		var list []jv.Value
		if v, _ := m.Get(key); v != nil {
			if l, ok := v.([]jv.Value); ok {
				list = l
			}
		}
		for _, x := range list {
			if x == value {
				return
			}
		}
		m.Set(key, append(list, value))
	})
}

func update(path, version string, apply func(m *jv.Map)) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return cli.Fail("could not create %s", dir)
	}

	current := []jv.Value{Defaults(version)}
	if isFile(path) {
		notObject := cli.Fail("%s: not a JSON object — kasbah will not overwrite it. Look at it, then delete it.", path)
		data, err := os.ReadFile(path)
		if err != nil {
			return notObject
		}
		vs, err := jv.Parse(data)
		if err != nil || len(vs) == 0 {
			return notObject
		}
		current = current[:0]
		for _, v := range vs {
			m, ok := v.(*jv.Map)
			if !ok {
				return notObject
			}
			current = append(current, jv.Add(Defaults(version), m))
		}
	}
	for _, v := range current {
		apply(v.(*jv.Map))
	}

	tmp := path + ".tmp." + strconv.Itoa(os.Getpid())
	if err := os.WriteFile(tmp, render(current...), 0o666); err != nil {
		os.Remove(tmp)
		return cli.Fail("could not write %s", tmp)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return cli.Fail("could not install %s", path)
	}
	return nil
}

// Server is the server a command talks to: given when set, else the project's
// last_server (stored says so). example spells the command with a server, for
// the refusal when there is neither; more lines follow it.
func Server(given, cmd, example string, more ...string) (target string, stored bool, err error) {
	if given != "" {
		return given, false, nil
	}
	last, err := Get(File, "last_server")
	if err != nil {
		return "", false, err
	}
	if last == "" || last == "null" {
		return "", false, cli.Fail("%s: no server given, and this project has never talked to one", cmd).Cont(
			"pass it once — `"+example+"` — and it is remembered in",
			File+" as last_server").Cont(more...)
	}
	return last, true, nil
}
