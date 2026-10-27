// Package jv exists for internal/check alone: jq's vocabulary (`//`, truth,
// tostring, -r, type) over internal/tree values, for the rules still asked as
// jq filters. It goes with check's rewrite; nothing else imports it.
package jv

import "github.com/adigourdi/kasbah/internal/tree"

// Value, Number and Map are internal/tree's.
type (
	Value  = tree.Value
	Number = tree.Number
	Map    = tree.Map
)

// NewMap returns an empty object.
func NewMap() *Map { return tree.NewMap() }

// ParseOne reads exactly one JSON value.
func ParseOne(data []byte) (Value, error) { return tree.ParseOne(data) }

// Type is jq's `type` of a value.
func Type(v Value) string { return tree.Kind(v) }

// Get is jq's `.a.b[0]` over object keys (string) and indexes (int): absent
// or null along the way is nil; ok is false where jq would raise an error.
func Get(v Value, path ...any) (out Value, ok bool) {
	for _, p := range path {
		switch p := p.(type) {
		case string:
			switch c := v.(type) {
			case nil:
			case *Map:
				v, _ = c.Get(p)
				continue
			default:
				return nil, false
			}
			v = nil
		case int:
			switch c := v.(type) {
			case nil:
			case []Value:
				if p < 0 {
					p += len(c)
				}
				if p >= 0 && p < len(c) {
					v = c[p]
					continue
				}
			default:
				return nil, false
			}
			v = nil
		default:
			panic("jv: path elements are string or int")
		}
	}
	return v, true
}

// Truthy is jq's truth: everything but null and false.
func Truthy(v Value) bool {
	switch v := v.(type) {
	case nil:
		return false
	case bool:
		return v
	}
	return true
}

// Alt is jq's `a // b` for a single value.
func Alt(v, def Value) Value {
	if Truthy(v) {
		return v
	}
	return def
}

// ToString is jq's `tostring`: a string as itself, anything else compact.
func ToString(v Value) string { return tree.Text(v) }

// Raw is what `jq -r` prints for a value, without the trailing newline: a
// string as itself, anything else indented.
func Raw(v Value) string {
	if s, ok := v.(string); ok {
		return s
	}
	return tree.Indent(v)
}

// Compact is a value as one line of JSON.
func Compact(v Value) string { return tree.Compact(v) }
