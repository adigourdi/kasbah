package check

import (
	"fmt"
	"sort"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/tree"
)

// yamlDoc is a project YAML file as the rules read it: a single document.
type yamlDoc struct {
	file string
	// root is the document, nil for an empty file.
	root tree.Value
	// bad is why the file cannot be read as one document, "" when it can.
	bad string
}

func (c *checker) load(file string) yamlDoc {
	f := c.cache.Get(file)
	switch {
	case f.Err != nil:
		return yamlDoc{file: file, bad: "does not parse as YAML"}
	case len(f.Docs) > 1:
		return yamlDoc{file: file, bad: fmt.Sprintf("holds %d YAML documents, where kasbah reads one", len(f.Docs))}
	case len(f.Docs) == 1:
		return yamlDoc{file: file, root: f.Docs[0]}
	}
	return yamlDoc{file: file}
}

// lookup is the value at path through mappings, nil where a key is absent or
// null; bad names the first step that is neither a mapping nor null.
func lookup(v tree.Value, path ...string) (x tree.Value, bad string) {
	for i, k := range path {
		switch m := v.(type) {
		case nil:
			return nil, ""
		case *tree.Map:
			if m == nil {
				return nil, ""
			}
			v, _ = m.Get(k)
		default:
			return nil, notMapping(path[:i], v)
		}
	}
	return v, ""
}

// mapAt is the mapping at path, nil for none; bad also names a value there
// that is not one. The helpers below take its nil as no mapping.
func mapAt(v tree.Value, path ...string) (*tree.Map, string) {
	x, bad := lookup(v, path...)
	if bad != "" || x == nil {
		return nil, bad
	}
	m, ok := x.(*tree.Map)
	if !ok {
		return nil, notMapping(path, x)
	}
	return m, ""
}

func notMapping(path []string, v tree.Value) string {
	where := "the document"
	if len(path) > 0 {
		where = strings.Join(path, ".")
	}
	return fmt.Sprintf("%s is %s, not a mapping", where, kind(v))
}

func kind(v tree.Value) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "a boolean"
	case tree.Number:
		return "a number"
	case string:
		return "a string"
	case []tree.Value:
		return "a list"
	}
	return "a mapping"
}

// opt is the value at path, nil where the file's shape has none.
func opt(v tree.Value, path ...string) tree.Value {
	x, _ := lookup(v, path...)
	return x
}

// need is the value at path; a step that is not a mapping is a question the
// run cannot answer, so it ends with exit 1, naming the file and the key.
func (c *checker) need(d yamlDoc, path ...string) tree.Value {
	x, bad := lookup(d.root, path...)
	if bad != "" {
		fmt.Fprintf(c.out.Stderr, "error: cannot check %s: %s\n", d.file, bad)
		panic(abort{cli.ExitFailure})
	}
	return x
}

// scalar is a value as the rules compare it: "" for null, a string as itself,
// anything else as compact JSON.
func scalar(v tree.Value) string {
	if v == nil {
		return ""
	}
	return tree.Text(v)
}

// keysOf is a mapping's keys in byte order, none for anything else.
func keysOf(v tree.Value) []string {
	m, ok := v.(*tree.Map)
	if !ok || m == nil {
		return nil
	}
	ks := m.Keys()
	sort.Strings(ks)
	return ks
}

func hasKey(v tree.Value, k string) bool {
	m, ok := v.(*tree.Map)
	return ok && m != nil && m.Has(k)
}

// rotationSet is whether a logging max-size or max-file is given: a
// non-empty string, or a number.
func rotationSet(v tree.Value) bool {
	switch x := v.(type) {
	case string:
		return x != ""
	case tree.Number:
		return true
	}
	return false
}

// listHas is whether v is a list holding the string s.
// asList is a list's items, none for anything else.
func asList(v tree.Value) []tree.Value {
	l, _ := v.([]tree.Value)
	return l
}

func listHas(v tree.Value, s string) bool {
	l, _ := v.([]tree.Value)
	for _, x := range l {
		if x == s {
			return true
		}
	}
	return false
}

// joinsNet is whether a service's networks: names net, as a list member or
// a mapping key.
func joinsNet(networks tree.Value, net string) bool {
	return listHas(networks, net) || hasKey(networks, net)
}
