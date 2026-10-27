package check

import (
	"github.com/adigourdi/kasbah/internal/tree"
)

// The guard: a candidate is written only when its parsed tree is the
// original's with exactly the planned edits applied. A text edit that lands
// where the scanner misread the file — inside a block scalar, under an alias —
// changes some other value, and that is refused rather than shipped.

// edit is one planned change to the tree: set a value, delete a key, append to
// a sequence (null is an empty one), or mask — a rewritten scalar, whose new
// value the re-plan proves, compared on neither side.
type edit struct {
	kind byte // 's', 'd', 'a', 'm'
	path []string
	val  tree.Value
}

func (x *fixer) set(v tree.Value, p ...string) { x.edits = append(x.edits, edit{'s', p, v}) }
func (x *fixer) del(p ...string)               { x.edits = append(x.edits, edit{'d', p, nil}) }
func (x *fixer) app(v tree.Value, p ...string) { x.edits = append(x.edits, edit{'a', p, v}) }
func (x *fixer) mask(p ...string)              { x.edits = append(x.edits, edit{'m', p, nil}) }

func obj(kv ...tree.Value) *tree.Map {
	m := tree.NewMap()
	for i := 0; i+1 < len(kv); i += 2 {
		m.Set(kv[i].(string), kv[i+1])
	}
	return m
}

func rotation() *tree.Map { return obj("max-size", "10m", "max-file", "3") }

// guard is whether the candidate is the original with the edits applied,
// masked paths aside on both. An edit that meets a value that is not a
// mapping where its path runs is a refusal.
func guard(orig, cand tree.Value, edits []edit) bool {
	want, got := orig, cand
	ok := true
	for _, e := range edits {
		switch e.kind {
		case 's':
			want, ok = setPath(want, e.path, e.val)
		case 'd':
			want, ok = delPath(want, e.path)
		case 'a':
			want, ok = appendAt(want, e.path, e.val)
		}
		if !ok {
			return false
		}
	}
	for _, e := range edits {
		if e.kind != 'm' {
			continue
		}
		if want, ok = delPath(want, e.path); !ok {
			return false
		}
		if got, ok = delPath(got, e.path); !ok {
			return false
		}
	}
	return equal(want, got)
}

// appendAt adds x to the list at p; null or absent there is an empty list.
func appendAt(v tree.Value, p []string, x tree.Value) (tree.Value, bool) {
	cur, bad := lookup(v, p...)
	if bad != "" {
		return nil, false
	}
	var xs []tree.Value
	switch c := cur.(type) {
	case nil:
	case []tree.Value:
		xs = append(xs, c...)
	default:
		return nil, false
	}
	return setPath(v, p, append(xs, x))
}

// setPath is v with x at p, making mappings where there was null; v itself
// is left as it was.
func setPath(v tree.Value, p []string, x tree.Value) (tree.Value, bool) {
	if len(p) == 0 {
		return x, true
	}
	var m *tree.Map
	switch c := v.(type) {
	case nil:
		m = tree.NewMap()
	case *tree.Map:
		m = c.Clone()
	default:
		return nil, false
	}
	child, _ := m.Get(p[0])
	nv, ok := setPath(child, p[1:], x)
	if !ok {
		return nil, false
	}
	m.Set(p[0], nv)
	return m, true
}

// delPath is v without the key at p: unchanged where the key or a mapping
// on the way is absent or null.
func delPath(v tree.Value, p []string) (tree.Value, bool) {
	switch c := v.(type) {
	case nil:
		return nil, true
	case *tree.Map:
		child, has := c.Get(p[0])
		if !has {
			return c, true
		}
		m := c.Clone()
		if len(p) == 1 {
			m.Delete(p[0])
			return m, true
		}
		nv, ok := delPath(child, p[1:])
		if !ok {
			return nil, false
		}
		m.Set(p[0], nv)
		return m, true
	}
	return nil, false
}

// equal compares two trees: mappings regardless of key order, numbers by
// value.
func equal(a, b tree.Value) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case tree.Number:
		y, ok := b.(tree.Number)
		return ok && (x == y || x.Float64() == y.Float64())
	case []tree.Value:
		y, ok := b.([]tree.Value)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case *tree.Map:
		y, ok := b.(*tree.Map)
		if !ok || x.Len() != y.Len() {
			return false
		}
		for _, k := range x.Keys() {
			xv, _ := x.Get(k)
			yv, ok := y.Get(k)
			if !ok || !equal(xv, yv) {
				return false
			}
		}
		return true
	}
	return false
}
