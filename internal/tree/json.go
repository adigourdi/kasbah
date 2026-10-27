package tree

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
)

// maxDepth is encoding/json's own nesting limit.
const maxDepth = 10000

// Parse reads a stream of JSON values as encoding/json does, numbers kept as
// their text; a repeated key keeps its first position and its last value.
func Parse(data []byte) ([]Value, error) {
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	var out []Value
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		v, err := value(dec, tok, 0)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
	}
}

// ParseOne reads exactly one JSON value.
func ParseOne(data []byte) (Value, error) {
	vs, err := Parse(data)
	if err != nil {
		return nil, err
	}
	if len(vs) != 1 {
		return nil, fmt.Errorf("json: %d values where one was expected", len(vs))
	}
	return vs[0], nil
}

func value(dec *json.Decoder, tok json.Token, depth int) (Value, error) {
	switch t := tok.(type) {
	case nil, bool, string:
		return t, nil
	case json.Number:
		return Number(t), nil
	case json.Delim:
		if depth++; depth > maxDepth {
			return nil, errors.New("json: exceeded max depth")
		}
		if t == '{' {
			m := NewMap()
			for dec.More() {
				kt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				vt, err := dec.Token()
				if err != nil {
					return nil, err
				}
				v, err := value(dec, vt, depth)
				if err != nil {
					return nil, err
				}
				m.Set(kt.(string), v)
			}
			_, err := dec.Token()
			return m, err
		}
		l := []Value{}
		for dec.More() {
			vt, err := dec.Token()
			if err != nil {
				return nil, err
			}
			v, err := value(dec, vt, depth)
			if err != nil {
				return nil, err
			}
			l = append(l, v)
		}
		_, err := dec.Token()
		return l, err
	}
	return nil, fmt.Errorf("json: unexpected %v", tok)
}

// Compact is v as encoding/json writes it with HTML escaping off.
func Compact(v Value) string {
	var b bytes.Buffer
	write(&b, v, "", false)
	return b.String()
}

// Indent is Compact indented by two spaces per level, as json.MarshalIndent
// writes it; no trailing newline.
func Indent(v Value) string {
	var b bytes.Buffer
	write(&b, v, "", true)
	return b.String()
}

func write(b *bytes.Buffer, v Value, indent string, pretty bool) {
	switch v := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if v {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case Number:
		b.WriteString(string(v))
	case string:
		quote(b, v)
	case []Value:
		if len(v) == 0 {
			b.WriteString("[]")
			return
		}
		inner := indent + "  "
		b.WriteByte('[')
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
		inner := indent + "  "
		b.WriteByte('{')
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
		panic("tree: not a value")
	}
}

func quote(b *bytes.Buffer, s string) {
	var q strings.Builder
	enc := json.NewEncoder(&q)
	enc.SetEscapeHTML(false)
	enc.Encode(s)
	b.WriteString(strings.TrimSuffix(q.String(), "\n"))
}
