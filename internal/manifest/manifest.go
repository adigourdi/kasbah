// Package manifest reads and writes a project's kasbah.yml
// (docs/project-manifest.md), and validates it.
package manifest

import (
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// File is the manifest's name, relative to the project root every project
// command runs from.
const File = "kasbah.yml"

// Schema is the manifest schema this kasbah writes, the highest it reads, and
// what --version reports.
const Schema = 1

// Reserved are the directory names kasbah owns under <apps>, which a project
// (or a backup `client:`) may not take: a project called `traefik` or `mail`
// would be deployed over the shared stack of that name.
var Reserved = []string{"traefik", "mail", "data", "backups"}

// Stacks are the compose project names of kasbah's own stacks that are not a
// directory under <apps> (traefik's and mail's are): a project may not take
// one, or its up would take that stack's containers for its own.
var Stacks = []string{"kasbah-backup"}

var reName = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)

// ValidName is whether name matches the name: field's charset.
func ValidName(name string) bool { return reName.MatchString(name) }

// NameReserved reports whether a project name is one kasbah owns.
func NameReserved(name string) bool {
	return slices.Contains(Reserved, name) || slices.Contains(Stacks, name)
}

// ReservedWhy is why a reserved project name is refused, in the words every
// reader prints: "'<name>' is reserved — <why> (reserved: <all>)".
func ReservedWhy(name string) string {
	why := fmt.Sprintf("kasbah owns <apps>/%s on every server", name)
	if slices.Contains(Stacks, name) {
		why = "it is the compose project of kasbah's own backup stack, on any server that runs backups"
	}
	return fmt.Sprintf("'%s' is reserved — %s (reserved: %s)", name, why, strings.Join(append(slices.Clone(Reserved), Stacks...), " "))
}

// ClientCheck judges a `client:` value. ok is false with the reason in the
// words every reader prints; what a reader does with it (refuse, or warn and
// fall back) stays the reader's.
func ClientCheck(raw string) (reason string, ok bool) {
	if !reName.MatchString(raw) {
		return fmt.Sprintf("client '%s' must match ^[a-z][a-z0-9-]*$ — it names a backup repository, the same charset as name (docs/project-manifest.md)", raw), false
	}
	if slices.Contains(Reserved, raw) {
		return fmt.Sprintf("client '%s' is reserved — kasbah owns the backup repository of that name (reserved: %s)", raw, strings.Join(Reserved, " ")), false
	}
	return "", true
}

// NewerSchema is the refusal of a manifest whose schema is above Schema: a
// kasbah of that major reads it.
type NewerSchema struct {
	Schema uint64
	err    *cli.Error
}

func (n *NewerSchema) Error() string { return n.err.Error() }
func (n *NewerSchema) Unwrap() error { return n.err }

// Manifest is a validated kasbah.yml.
type Manifest struct {
	Path          string
	Schema        string
	KasbahVersion string
	Name          string
	// Domain may be empty: init-project without --domain writes `domain: ""`,
	// and the commands that need one enforce it themselves.
	Domain string
	// Unrouted is `routed: false`: the project has no Traefik fragment on
	// purpose. Absent or null is routed.
	Unrouted bool
	// Doc is the whole document, for every other question about it.
	Doc tree.Value
}

// Get is the value at path in the document (tree.Lookup).
func (m *Manifest) Get(path ...any) (tree.Value, bool) { return tree.Lookup(m.Doc, path...) }

// Require reads and validates the manifest at path. A
// missing manifest is exit 2; anything else wrong is exit 1. version is this
// kasbah's, for the newer-schema refusal.
func Require(path, version string) (*Manifest, error) {
	if fi, err := os.Stat(path); err != nil || !fi.Mode().IsRegular() {
		return nil, cli.Failf(cli.ExitNoProject, "No %s in current directory.", path).
			Cont("Run from the project root, or `kasbah init-project` to scaffold.")
	}
	docs, err := yamlx.LoadFile(path)
	if err != nil {
		return nil, cli.Fail("%s: could not parse YAML", path).Cont(err.Error())
	}

	if len(docs) != 1 {
		return nil, cli.Fail("%s: expected a single YAML document", path)
	}
	if _, ok := docs[0].(*tree.Map); !ok && docs[0] != nil {
		return nil, cli.Fail("%s: the document is not a mapping — kasbah.yml is a set of fields like schema: and name:", path)
	}
	// The four fields are single-line values: null or absent is "".
	var fields [4]string
	for i, k := range []string{"schema", "kasbah_version", "name", "domain"} {
		v, _ := tree.Lookup(docs[0], k)
		switch v.(type) {
		case []tree.Value, *tree.Map:
			return nil, cli.Fail("%s: %s: is a list or a mapping — it has to be a single value", path, k)
		case bool:
			if k != "schema" {
				return nil, cli.Fail("%s: %s: must be a string, not %s", path, k, tree.Compact(v))
			}
		}
		f := tree.TextAt(docs[0], k)
		if strings.Contains(f, "\n") {
			return nil, cli.Fail("%s: %s: spans more than one line — it has to be a single value", path, k)
		}
		fields[i] = strings.TrimSuffix(f, "\r")
	}
	schema, kv, name, domain := fields[0], fields[1], fields[2], fields[3]

	if schema == "" {
		return nil, cli.Fail("%s: missing required field 'schema'", path)
	}
	if !regexp.MustCompile(`^[0-9]+$`).MatchString(schema) {
		return nil, cli.Fail("%s: schema must be an integer (got '%s')", path, schema)
	}
	// `[ "$schema" -gt 1 ]`: a value too large for test(1) is an error there,
	// and the check is then skipped rather than failed.
	if n, err := strconv.ParseUint(schema, 10, 64); err == nil && n > Schema {
		return nil, &NewerSchema{Schema: n, err: cli.Fail("%s: schema %s is newer than this kasbah (%s supports schema %d). Upgrade kasbah.", path, schema, version, Schema)}
	}
	// After the schema: a newer one may give `routed` a meaning this kasbah lacks.
	routed, _ := tree.Lookup(docs[0], "routed")
	if _, ok := routed.(bool); !ok && routed != nil {
		return nil, cli.Fail("%s: routed: must be true or false, not %s", path, tree.Compact(routed))
	}
	if name == "" || name == "null" {
		return nil, cli.Fail("%s: missing required field 'name'", path)
	}
	if !reName.MatchString(name) {
		return nil, cli.Fail("%s: invalid name '%s' (must match ^[a-z][a-z0-9-]*$)", path, name)
	}
	if NameReserved(name) {
		return nil, cli.Fail("%s: %s. Rename the project.", path, ReservedWhy(name))
	}
	return &Manifest{Path: path, Schema: schema, KasbahVersion: kv, Name: name, Domain: domain, Unrouted: routed == false, Doc: docs[0]}, nil
}

// Render is the manifest init-project scaffolds. The domain is written inside
// double quotes as given: callers pass a validated hostname or nothing.
func Render(name, domain, version string) []byte {
	return []byte("schema: " + strconv.Itoa(Schema) + "\n" +
		"kasbah_version: " + version + "\n" +
		"\n" +
		"name: " + name + "\n" +
		"domain: \"" + domain + "\"\n" +
		"\n" +
		"sync:\n" +
		"  - compose.prod.yml -> compose.yml\n" +
		"  - .env.prod.example\n")
}

// Write creates or truncates path with Render's bytes, mode from the umask
// (docs/files.md).
func Write(path, name, domain, version string) error {
	return os.WriteFile(path, Render(name, domain, version), 0o666)
}
