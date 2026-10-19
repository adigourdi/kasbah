package check

import (
	"github.com/adigourdi/kasbah/internal/jv"
)

// The guard: a candidate is written only when its parsed tree is the
// original's with exactly the planned edits applied. A text edit that lands
// where the scanner misread the file — inside a block scalar, under an alias —
// changes some other value, and that is refused rather than shipped. The
// comparison has jq's setpath / delpaths semantics, over every document of the
// file.

// edit is one planned change to the tree: set a value, delete a key, append to
// a sequence (null is an empty one), or mask — a rewritten scalar, whose new
// value the re-plan proves, compared on neither side.
type edit struct {
	kind byte // 's', 'd', 'a', 'm'
	path []string
	val  jv.Value
}

func (x *fixer) set(v jv.Value, p ...string) { x.edits = append(x.edits, edit{'s', p, v}) }
func (x *fixer) del(p ...string)             { x.edits = append(x.edits, edit{'d', p, nil}) }
func (x *fixer) app(v jv.Value, p ...string) { x.edits = append(x.edits, edit{'a', p, v}) }
func (x *fixer) mask(p ...string)            { x.edits = append(x.edits, edit{'m', p, nil}) }

func obj(kv ...jv.Value) *jv.Map {
	m := jv.NewMap()
	for i := 0; i+1 < len(kv); i += 2 {
		m.Set(kv[i].(string), kv[i+1])
	}
	return m
}

func rotation() *jv.Map { return obj("max-size", "10m", "max-file", "3") }

// guard is whether each candidate document is its original with the edits
// applied, masked paths aside on both. A path that would not compile into the
// jq filter, or an edit jq would fail on, is a refusal.
func guard(orig, cand []jv.Value, edits []edit) bool {
	if len(orig) != len(cand) {
		return false
	}
	es := make([]edit, len(edits))
	for i, e := range edits {
		es[i] = edit{kind: e.kind, val: e.val, path: make([]string, len(e.path))}
		for j, k := range e.path {
			d, ok := literal(k)
			if !ok {
				return false
			}
			es[i].path[j] = d
		}
	}
	for i := range orig {
		want, got := orig[i], cand[i]
		var err error
		for _, e := range es {
			if e.kind != 'm' {
				if want, err = applyEdit(want, e); err != nil {
					return false
				}
			}
		}
		for _, e := range es {
			if e.kind == 'm' {
				if want, err = delPath(want, e.path); err != nil {
					return false
				}
				if got, err = delPath(got, e.path); err != nil {
					return false
				}
			}
		}
		if !equal(want, got) {
			return false
		}
	}
	return true
}

func applyEdit(v jv.Value, e edit) (jv.Value, error) {
	switch e.kind {
	case 's':
		return setPath(v, e.path, e.val)
	case 'd':
		return delPath(v, e.path)
	}
	cur, err := path(v, e.path...)
	if err != nil {
		return nil, err
	}
	var xs []jv.Value
	switch c := cur.(type) {
	case nil:
	case []jv.Value:
		xs = append(xs, c...)
	default:
		return nil, errf("%s and array cannot be added", describe(cur))
	}
	return setPath(v, e.path, append(xs, e.val))
}

// setPath is jq's setpath: objects made where there was null.
func setPath(v jv.Value, p []string, x jv.Value) (jv.Value, error) {
	if len(p) == 0 {
		return x, nil
	}
	var m *jv.Map
	switch c := v.(type) {
	case nil:
		m = jv.NewMap()
	case *jv.Map:
		m = c.Clone()
	default:
		return nil, errf("Cannot index %s with %q", jv.Type(v), p[0])
	}
	child, _ := m.Get(p[0])
	nv, err := setPath(child, p[1:], x)
	if err != nil {
		return nil, err
	}
	m.Set(p[0], nv)
	return m, nil
}

// delPath is jq's delpaths of one path: nothing to do under null or a missing
// key, an error under anything that is not an object.
func delPath(v jv.Value, p []string) (jv.Value, error) {
	switch c := v.(type) {
	case nil:
		return nil, nil
	case *jv.Map:
		child, ok := c.Get(p[0])
		if !ok {
			return c, nil
		}
		m := c.Clone()
		if len(p) == 1 {
			m.Delete(p[0])
			return m, nil
		}
		nv, err := delPath(child, p[1:])
		if err != nil {
			return nil, err
		}
		m.Set(p[0], nv)
		return m, nil
	}
	return nil, errf("Cannot delete field at object index of %s", jv.Type(v))
}

// equal is jq's ==: objects regardless of key order, numbers by value.
func equal(a, b jv.Value) bool {
	switch x := a.(type) {
	case nil:
		return b == nil
	case bool:
		y, ok := b.(bool)
		return ok && x == y
	case string:
		y, ok := b.(string)
		return ok && x == y
	case jv.Number:
		y, ok := b.(jv.Number)
		return ok && (x == y || x.Float64() == y.Float64())
	case []jv.Value:
		y, ok := b.([]jv.Value)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !equal(x[i], y[i]) {
				return false
			}
		}
		return true
	case *jv.Map:
		y, ok := b.(*jv.Map)
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
