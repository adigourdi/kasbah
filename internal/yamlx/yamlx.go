// Package yamlx reads YAML documents into trees: yaml.v3 parses and resolves
// scalars, then a walk applies kasbah's rules (duplicate keys, merges, local
// tags, numbers JSON can hold) — TestLoad's table lists them.
package yamlx

import (
	"bytes"
	"fmt"
	"io"
	"math"
	"math/big"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/tree"
	"go.yaml.in/yaml/v3"
)

// Error is a stream that does not read as YAML, or holds a value a tree
// cannot: the loader yields no documents for it.
type Error struct {
	Msg string
}

func (e *Error) Error() string { return e.Msg }

func refuse(n *yaml.Node, format string, args ...any) error {
	return &Error{Msg: fmt.Sprintf("yaml: line %d: ", n.Line) + fmt.Sprintf(format, args...)}
}

// A document's aliases may expand it to at most this many times the nodes
// it is written with.
const expansionFactor = 1000

// Load converts a YAML stream into its documents. An empty or comment-only
// stream is no documents; anything unreadable fails the lot.
func Load(data []byte) ([]tree.Value, error) {
	dec := yaml.NewDecoder(bytes.NewReader(bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))))
	var docs []tree.Value
	for {
		var n yaml.Node
		err := dec.Decode(&n)
		if err == io.EOF {
			return docs, nil
		}
		if err != nil {
			return nil, &Error{Msg: err.Error()}
		}
		w := &walker{open: map[*yaml.Node]bool{}, budget: expansionFactor * written(&n)}
		v, err := w.value(&n)
		if err != nil {
			return nil, err
		}
		docs = append(docs, v)
	}
}

// LoadFile is Load over a file's content.
// Strict is whether data decodes as one mapping under yaml.v3's own map
// decoder, which refuses a duplicate key where Load keeps the last value.
func Strict(data []byte) bool {
	var m map[string]any
	return yaml.Unmarshal(data, &m) == nil
}

func LoadFile(path string) ([]tree.Value, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Load(data)
}

// written counts the nodes as the source spells them, an alias as one.
func written(n *yaml.Node) int {
	c := 1
	for _, k := range n.Content {
		c += written(k)
	}
	return c
}

// walker converts one document: open holds the alias targets being expanded,
// budget the nodes it may still produce.
type walker struct {
	open   map[*yaml.Node]bool
	budget int
}

func (w *walker) value(n *yaml.Node) (tree.Value, error) {
	if w.budget--; w.budget < 0 {
		return nil, refuse(n, "aliases expand the document past %d times its size", expansionFactor)
	}
	switch n.Kind {
	case yaml.DocumentNode:
		if len(n.Content) == 0 {
			return nil, nil
		}
		return w.value(n.Content[0])
	case yaml.AliasNode:
		if w.open[n.Alias] {
			return nil, refuse(n, "alias *%s is inside its own anchor", n.Value)
		}
		w.open[n.Alias] = true
		defer delete(w.open, n.Alias)
		return w.value(n.Alias)
	case yaml.SequenceNode:
		out := make([]tree.Value, 0, len(n.Content))
		for _, c := range n.Content {
			v, err := w.value(c)
			if err != nil {
				return nil, err
			}
			out = append(out, v)
		}
		return out, nil
	case yaml.MappingNode:
		return w.mapping(n)
	}
	return scalar(n)
}

// mapping keeps each key at its first place with its last value; `<<` is such
// a key, and its last value merges in at its first place beneath the
// mapping's own keys. Every value must convert, kept or not.
func (w *walker) mapping(n *yaml.Node) (*tree.Map, error) {
	var keys []string
	names := make([]string, len(n.Content)/2)
	own := map[string]bool{}
	mergeAt := -1
	for i := range names {
		k := n.Content[2*i]
		if isMerge(k) {
			if mergeAt < 0 {
				mergeAt = len(keys)
			}
			continue
		}
		ks, err := key(k)
		if err != nil {
			return nil, err
		}
		if !own[ks] {
			own[ks] = true
			keys = append(keys, ks)
		}
		names[i] = ks
	}
	vals := map[string]tree.Value{}
	var merged *tree.Map
	for i, ks := range names {
		v := n.Content[2*i+1]
		var err error
		if isMerge(n.Content[2*i]) {
			merged, err = w.merge(v, own)
		} else {
			vals[ks], err = w.value(v)
		}
		if err != nil {
			return nil, err
		}
	}
	m := tree.NewMap()
	for i := 0; i <= len(keys); i++ {
		if i == mergeAt {
			for _, k := range merged.Keys() {
				v, _ := merged.Get(k)
				m.Set(k, v)
			}
		}
		if i < len(keys) {
			m.Set(keys[i], vals[keys[i]])
		}
	}
	return m, nil
}

func isMerge(k *yaml.Node) bool { return k.Kind == yaml.ScalarNode && k.ShortTag() == "!!merge" }

// merge is a mapping, an alias to one, or a sequence of those, an earlier
// source winning over a later; keys the mapping has itself are left out.
func (w *walker) merge(v *yaml.Node, own map[string]bool) (*tree.Map, error) {
	srcs := []*yaml.Node{v}
	if v.Kind == yaml.SequenceNode {
		srcs = v.Content
	}
	out := tree.NewMap()
	for _, s := range srcs {
		if deref(s).Kind != yaml.MappingNode {
			return nil, refuse(s, "a merge (<<) takes a mapping or a sequence of mappings")
		}
		src, err := w.value(s)
		if err != nil {
			return nil, err
		}
		for _, k := range src.(*tree.Map).Keys() {
			if !own[k] && !out.Has(k) {
				x, _ := src.(*tree.Map).Get(k)
				out.Set(k, x)
			}
		}
	}
	return out, nil
}

func deref(n *yaml.Node) *yaml.Node {
	for n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

// key is a scalar key's resolved value as text: `1` "1", `~` "null".
func key(n *yaml.Node) (string, error) {
	n = deref(n)
	if n.Kind != yaml.ScalarNode {
		return "", refuse(n, "a mapping key must be a scalar")
	}
	v, err := scalar(n)
	if err != nil {
		return "", err
	}
	switch v := v.(type) {
	case string:
		return v, nil
	case tree.Number:
		return string(v), nil
	}
	return tree.Compact(v), nil
}

var reDecimal = regexp.MustCompile(`^[-+]?[0-9][0-9_]*$`)

func scalar(n *yaml.Node) (tree.Value, error) {
	if !strings.HasPrefix(n.ShortTag(), "!!") {
		c := *n
		c.Tag, c.Style = "", c.Style&^yaml.TaggedStyle
		n = &c
	}
	var v any
	if err := n.Decode(&v); err != nil {
		return nil, &Error{Msg: err.Error()}
	}
	switch v := v.(type) {
	case nil, bool, string:
		return v, nil
	case int:
		return tree.Number(strconv.Itoa(v)), nil
	case int64:
		return tree.Number(strconv.FormatInt(v, 10)), nil
	case uint64:
		return tree.Number(strconv.FormatUint(v, 10)), nil
	case float64:
		if math.IsInf(v, 0) || math.IsNaN(v) {
			return nil, refuse(n, "%s has no JSON number", n.Value)
		}
		// A plain integer past uint64 keeps its digits.
		if n.Style == 0 && reDecimal.MatchString(n.Value) {
			if b, ok := new(big.Int).SetString(strings.ReplaceAll(n.Value, "_", ""), 10); ok {
				return tree.Number(b.String()), nil
			}
		}
		s := strconv.FormatFloat(v, 'g', -1, 64)
		if !strings.ContainsAny(s, ".eE") {
			s += ".0"
		}
		return tree.Number(s), nil
	case time.Time:
		return n.Value, nil
	case []byte:
		return string(v), nil
	}
	return nil, refuse(n, "unsupported scalar %q", n.Value)
}

// File is one YAML file read once: every question about it is answered from
// Docs, never by reading it again (CLAUDE.md, "Read a YAML file once").
type File struct {
	Path string
	Docs []tree.Value
	// Err is the read or conversion failure; Docs is empty when it is set.
	Err error
}

// Cache holds files by the path they were asked for, and is not safe for
// concurrent use. Nothing checks a file against its mtime: whatever rewrites
// a file it has read calls Forget.
type Cache struct {
	files map[string]*File
}

// Get returns the file, reading it on first use.
func (c *Cache) Get(path string) *File {
	if f, ok := c.files[path]; ok {
		return f
	}
	if c.files == nil {
		c.files = map[string]*File{}
	}
	docs, err := LoadFile(path)
	c.files[path] = &File{Path: path, Docs: docs, Err: err}
	return c.files[path]
}

// Forget drops a path, so the next Get reads it again.
func (c *Cache) Forget(path string) { delete(c.files, path) }
