// Package tree holds a parsed document — JSON, or YAML through internal/yamlx —
// as plain values with ordered mappings, so a file kasbah rewrites keeps its
// key order.
package tree

import (
	"strconv"
)

// Value is one value: nil, bool, Number, string, []Value or *Map. Values may
// share structure (a YAML alias is one value reached twice); treat them as
// read-only.
type Value = any

// Number is a number kept as the text it was read or built from.
type Number string

// Int64 is the number as an int64, when it is an integer that fits one.
func (n Number) Int64() (int64, bool) {
	i, err := strconv.ParseInt(string(n), 10, 64)
	return i, err == nil
}

// Float64 is the number as the nearest double (±Inf past its range).
func (n Number) Float64() float64 {
	f, _ := strconv.ParseFloat(string(n), 64)
	return f
}

// Map is a mapping whose keys keep the position they were first set at;
// setting a key again replaces its value in place.
type Map struct {
	keys []string
	vals map[string]Value
}

// NewMap returns an empty mapping.
func NewMap() *Map { return &Map{vals: map[string]Value{}} }

// Set adds or replaces a key.
func (m *Map) Set(k string, v Value) {
	if _, ok := m.vals[k]; !ok {
		m.keys = append(m.keys, k)
	}
	m.vals[k] = v
}

// Get returns a key's value; ok reports whether the key is present.
func (m *Map) Get(k string) (v Value, ok bool) {
	v, ok = m.vals[k]
	return v, ok
}

// Has reports whether the key is present, whatever its value.
func (m *Map) Has(k string) bool { _, ok := m.vals[k]; return ok }

// Keys returns the keys in order.
func (m *Map) Keys() []string { return append([]string(nil), m.keys...) }

// Len is the number of keys.
func (m *Map) Len() int { return len(m.keys) }

// Delete removes a key.
func (m *Map) Delete(k string) {
	if _, ok := m.vals[k]; !ok {
		return
	}
	delete(m.vals, k)
	for i, key := range m.keys {
		if key == k {
			m.keys = append(m.keys[:i], m.keys[i+1:]...)
			break
		}
	}
}

// Clone is a shallow copy: the keys are new, the values are shared.
func (m *Map) Clone() *Map {
	c := &Map{keys: append([]string(nil), m.keys...), vals: make(map[string]Value, len(m.vals))}
	for k, v := range m.vals {
		c.vals[k] = v
	}
	return c
}

// Merge is l with r laid over it: l's keys in l's order, r's value where both
// have the key, then r's other keys in r's order. Neither input changes.
func Merge(l, r *Map) *Map {
	out := l.Clone()
	for _, k := range r.keys {
		out.Set(k, r.vals[k])
	}
	return out
}

// Lookup follows path through mappings (string elements) and lists (int
// elements, from 0); ok is false when a step is missing or meets a value of
// the other kind.
func Lookup(v Value, path ...any) (Value, bool) {
	for _, p := range path {
		switch p := p.(type) {
		case string:
			m, isMap := v.(*Map)
			if !isMap {
				return nil, false
			}
			var ok bool
			if v, ok = m.Get(p); !ok {
				return nil, false
			}
		case int:
			l, isList := v.([]Value)
			if !isList || p < 0 || p >= len(l) {
				return nil, false
			}
			v = l[p]
		default:
			panic("tree: path elements are string or int")
		}
	}
	return v, true
}

// String is v when it is a string.
func String(v Value) (string, bool) {
	s, ok := v.(string)
	return s, ok
}

// Bool is v when it is a boolean.
func Bool(v Value) (b, ok bool) {
	b, ok = v.(bool)
	return b, ok
}

// Text is v for a message or a field: a string as itself, anything else as
// compact JSON.
func Text(v Value) string {
	if s, ok := v.(string); ok {
		return s
	}
	return Compact(v)
}

// TextAt is Text of the value at path, "" when there is none or it is null.
func TextAt(v Value, path ...any) string {
	x, ok := Lookup(v, path...)
	if !ok || x == nil {
		return ""
	}
	return Text(x)
}

// Kind is a value's JSON type name: null, boolean, number, string, array or
// object.
func Kind(v Value) string {
	switch v.(type) {
	case nil:
		return "null"
	case bool:
		return "boolean"
	case Number:
		return "number"
	case string:
		return "string"
	case []Value:
		return "array"
	case *Map:
		return "object"
	}
	panic("tree: not a value")
}
