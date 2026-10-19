// Package jv holds JSON values as jq holds them — ordered objects, numbers in
// jq's spelling — which is how kasbah's rules see every file, as yq/jq would.
package jv

import (
	"math/big"
	"strconv"
	"strings"
)

// Value is one JSON value: nil, bool, Number, string, []Value or *Map. Values
// produced by this module may share structure (a YAML alias is one value
// reached twice); treat them as read-only.
type Value = any

// Number is a JSON number spelled as jq prints it: an integer as its digits
// (any size), anything else in decNumber's canonical form (`1.0`, `1E+16`).
type Number string

// Int64 is the number as an int64, when it is an integer that fits one.
func (n Number) Int64() (int64, bool) {
	i, err := strconv.ParseInt(string(n), 10, 64)
	return i, err == nil
}

// Float64 is the number as jq computes with it, a double.
func (n Number) Float64() float64 {
	f, _ := strconv.ParseFloat(string(n), 64)
	return f
}

// Big is the number as an exact integer, when its spelling is one.
func (n Number) Big() (*big.Int, bool) {
	return new(big.Int).SetString(string(n), 10)
}

// Map is a JSON object. Keys are unique and keep the position they were first
// set at; setting one again replaces its value in place, as jq does.
type Map struct {
	keys []string
	vals map[string]Value
}

// NewMap returns an empty object.
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

// Add is jq's object `+`: the left operand's keys in its order, values from
// the right where both have one, then the right's new keys in its order.
func Add(l, r *Map) *Map {
	out := l.Clone()
	for _, k := range r.keys {
		out.Set(k, r.vals[k])
	}
	return out
}

// Type is jq's `type` of a value.
func Type(v Value) string {
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
	panic("jv: not a value")
}

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
func ToString(v Value) string {
	if s, ok := v.(string); ok {
		return s
	}
	return Compact(v)
}

// Raw is what `jq -r` prints for a value, without the trailing newline: a
// string as itself, anything else pretty-printed.
func Raw(v Value) string {
	if s, ok := v.(string); ok {
		return s
	}
	return Pretty(v)
}

// Compact renders a value as `jq -c` does.
func Compact(v Value) string {
	var b strings.Builder
	write(&b, v, "", false)
	return b.String()
}

// Pretty renders a value as jq does by default (two-space indent), without
// the trailing newline.
func Pretty(v Value) string {
	var b strings.Builder
	write(&b, v, "", true)
	return b.String()
}

func write(b *strings.Builder, v Value, indent string, pretty bool) {
	switch v := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		b.WriteString(strconv.FormatBool(v))
	case Number:
		b.WriteString(string(v))
	case string:
		quote(b, v)
	case []Value:
		if len(v) == 0 {
			b.WriteString("[]")
			return
		}
		b.WriteByte('[')
		inner := indent + "  "
		for i, e := range v {
			if i > 0 {
				b.WriteByte(',')
			}
			if pretty {
				b.WriteString("\n" + inner)
			}
			write(b, e, inner, pretty)
		}
		if pretty {
			b.WriteString("\n" + indent)
		}
		b.WriteByte(']')
	case *Map:
		if v.Len() == 0 {
			b.WriteString("{}")
			return
		}
		b.WriteByte('{')
		inner := indent + "  "
		for i, k := range v.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			if pretty {
				b.WriteString("\n" + inner)
			}
			quote(b, k)
			b.WriteByte(':')
			if pretty {
				b.WriteByte(' ')
			}
			write(b, v.vals[k], inner, pretty)
		}
		if pretty {
			b.WriteString("\n" + indent)
		}
		b.WriteByte('}')
	default:
		panic("jv: not a value")
	}
}

// quote escapes as jq does: its two-character escapes, \u00XX for the rest
// of C0 and DEL, U+FFFD for invalid UTF-8, everything else as raw UTF-8.
func quote(b *strings.Builder, s string) {
	const hex = "0123456789abcdef"
	s = FixUTF8(s)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 || c == 0x7f {
				b.WriteString(`\u00`)
				b.WriteByte(hex[c>>4])
				b.WriteByte(hex[c&0xf])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
}
