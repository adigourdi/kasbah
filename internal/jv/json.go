package jv

import (
	"bytes"
	"errors"
	"fmt"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

// Parse reads a JSON stream as jq 1.7 does: a leading BOM, nan/inf and loose
// numbers (`01`, `.5`, `+1`) accepted, raw control characters in strings
// refused; a repeated key keeps its first position and its last value.
func Parse(data []byte) ([]Value, error) {
	p := &parser{s: string(bytes.TrimPrefix(data, []byte("\uFEFF")))}
	var out []Value
	for {
		p.space()
		if p.i == len(p.s) {
			return out, nil
		}
		v, err := p.value(0, 0)
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
		return nil, errors.New("expected exactly one JSON value")
	}
	return vs[0], nil
}

// DepthLimit is jq's parser limit: a container opens only while its enclosing
// arrays plus twice its enclosing objects (each holds a pending key) are fewer.
const DepthLimit = 256

type parser struct {
	s string
	i int
}

func (p *parser) errorf(format string, args ...any) error {
	return fmt.Errorf("json: offset %d: "+format, append([]any{p.i}, args...)...)
}

func (p *parser) space() {
	for p.i < len(p.s) && strings.IndexByte(" \t\n\r", p.s[p.i]) >= 0 {
		p.i++
	}
}

func (p *parser) value(arrays, objects int) (Value, error) {
	p.space()
	if p.i == len(p.s) {
		return nil, p.errorf("unfinished JSON term")
	}
	switch c := p.s[p.i]; {
	case c == '{' || c == '[':
		if arrays+2*objects >= DepthLimit {
			return nil, p.errorf("exceeds depth limit for parsing")
		}
		p.i++
		if c == '{' {
			return p.object(arrays, objects+1)
		}
		return p.array(arrays+1, objects)
	case c == '"':
		return p.str()
	}
	j := p.i
	for j < len(p.s) && strings.IndexByte(" \t\n\r,:[]{}\"", p.s[j]) < 0 {
		j++
	}
	lit := p.s[p.i:j]
	p.i = j
	switch lit {
	case "true":
		return true, nil
	case "false":
		return false, nil
	case "null":
		return nil, nil
	}
	switch strings.ToLower(strings.TrimLeft(lit, "+-")) {
	case "nan":
		return nil, nil
	case "inf", "infinity":
		if strings.HasPrefix(lit, "-") {
			return Number("-1.7976931348623157e+308"), nil
		}
		return Number("1.7976931348623157e+308"), nil
	}
	if !reLooseNumber.MatchString(lit) {
		return nil, p.errorf("invalid literal %q", lit)
	}
	return Number(CanonNumber(lit)), nil
}

var reLooseNumber = regexp.MustCompile(`^[-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?$`)

func (p *parser) object(arrays, objects int) (Value, error) {
	m := NewMap()
	p.space()
	if p.i < len(p.s) && p.s[p.i] == '}' {
		p.i++
		return m, nil
	}
	for {
		p.space()
		if p.i == len(p.s) || p.s[p.i] != '"' {
			return nil, p.errorf("object keys must be strings")
		}
		k, err := p.str()
		if err != nil {
			return nil, err
		}
		p.space()
		if p.i == len(p.s) || p.s[p.i] != ':' {
			return nil, p.errorf("expected ':' after an object key")
		}
		p.i++
		v, err := p.value(arrays, objects)
		if err != nil {
			return nil, err
		}
		m.Set(k, v)
		p.space()
		if p.i < len(p.s) && p.s[p.i] == ',' {
			p.i++
			continue
		}
		if p.i < len(p.s) && p.s[p.i] == '}' {
			p.i++
			return m, nil
		}
		return nil, p.errorf("expected ',' or '}' in an object")
	}
}

func (p *parser) array(arrays, objects int) (Value, error) {
	arr := []Value{}
	p.space()
	if p.i < len(p.s) && p.s[p.i] == ']' {
		p.i++
		return arr, nil
	}
	for {
		v, err := p.value(arrays, objects)
		if err != nil {
			return nil, err
		}
		arr = append(arr, v)
		p.space()
		if p.i < len(p.s) && p.s[p.i] == ',' {
			p.i++
			continue
		}
		if p.i < len(p.s) && p.s[p.i] == ']' {
			p.i++
			return arr, nil
		}
		return nil, p.errorf("expected ',' or ']' in an array")
	}
}

// str reads a string as jq does: invalid UTF-8 and a lone low surrogate
// become U+FFFD, a high surrogate alone or a raw C0 control is an error.
func (p *parser) str() (string, error) {
	p.i++
	var b strings.Builder
	for {
		if p.i >= len(p.s) {
			return "", p.errorf("unfinished string")
		}
		c := p.s[p.i]
		switch {
		case c == '"':
			p.i++
			return FixUTF8(b.String()), nil
		case c < 0x20:
			return "", p.errorf("control characters from U+0000 through U+001F must be escaped")
		case c == '\\':
			if p.i+1 >= len(p.s) {
				return "", p.errorf("unfinished string")
			}
			e := p.s[p.i+1]
			p.i += 2
			switch e {
			case '"', '\\', '/':
				b.WriteByte(e)
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			case 'u':
				r, ok := p.hex4()
				if !ok {
					return "", p.errorf("invalid \\u escape")
				}
				if utf16.IsSurrogate(r) && r < 0xdc00 {
					var lo rune = -1
					if strings.HasPrefix(p.s[p.i:], "\\u") {
						p.i += 2
						lo, ok = p.hex4()
					}
					if !ok || lo < 0xdc00 || lo > 0xdfff {
						return "", p.errorf("invalid \\uXXXX\\uXXXX surrogate pair escape")
					}
					r = utf16.DecodeRune(r, lo)
				} else if utf16.IsSurrogate(r) {
					r = utf8.RuneError
				}
				b.WriteRune(r)
			default:
				return "", p.errorf("invalid escape")
			}
		default:
			b.WriteByte(c)
			p.i++
		}
	}
}

func (p *parser) hex4() (rune, bool) {
	if p.i+4 > len(p.s) {
		return 0, false
	}
	v, err := strconv.ParseUint(p.s[p.i:p.i+4], 16, 32)
	if err != nil {
		return 0, false
	}
	p.i += 4
	return rune(v), true
}

// CanonNumber is a JSON number literal in decNumber's to-scientific-string
// form, which is how jq 1.7 prints a number it did not compute: `1.0` stays,
// `1e3` becomes `1E+3`, `0.00001` stays, `1e-7` becomes `1E-7`.
func CanonNumber(lit string) string {
	neg := strings.HasPrefix(lit, "-")
	s := strings.TrimLeft(lit, "+-")
	exp := 0
	if i := strings.IndexAny(s, "eE"); i >= 0 {
		e, err := strconv.Atoi(s[i+1:])
		if err != nil {
			return lit
		}
		exp = e
		s = s[:i]
	}
	intPart, frac, _ := strings.Cut(s, ".")
	exp -= len(frac)
	c := strings.TrimLeft(intPart+frac, "0")
	if c == "" {
		c = "0"
	}
	adj := exp + len(c) - 1
	var out string
	switch {
	case exp == 0:
		out = c
	case exp < 0 && adj >= -6:
		if p := len(c) + exp; p > 0 {
			out = c[:p] + "." + c[p:]
		} else {
			out = "0." + strings.Repeat("0", -p) + c
		}
	default:
		out = c[:1]
		if len(c) > 1 {
			out += "." + c[1:]
		}
		if adj >= 0 {
			out += "E+" + strconv.Itoa(adj)
		} else {
			out += "E-" + strconv.Itoa(-adj)
		}
	}
	if neg {
		out = "-" + out
	}
	return out
}

// FixUTF8 is jq's jvp_utf8_next repair: one U+FFFD per bad lead byte, per
// truncated sequence, and per complete sequence that decodes to an overlong
// form, a surrogate or a value past U+10FFFF.
func FixUTF8(s string) string {
	if utf8.ValidString(s) {
		return s
	}
	var b strings.Builder
	cont := func(c byte) bool { return c&0xc0 == 0x80 }
	for i := 0; i < len(s); {
		c := s[i]
		var n int
		var cp rune
		switch {
		case c < 0x80:
			b.WriteByte(c)
			i++
			continue
		case c >= 0xc2 && c <= 0xdf:
			n, cp = 2, rune(c&0x1f)
		case c >= 0xe0 && c <= 0xef:
			n, cp = 3, rune(c&0x0f)
		case c >= 0xf0 && c <= 0xf4:
			n, cp = 4, rune(c&0x07)
		default:
			b.WriteRune(utf8.RuneError)
			i++
			continue
		}
		if i+n > len(s) {
			b.WriteRune(utf8.RuneError)
			break
		}
		ok := true
		for k := 1; k < n; k++ {
			if !cont(s[i+k]) {
				ok, n = false, k
				break
			}
			cp = cp<<6 | rune(s[i+k]&0x3f)
		}
		min := [...]rune{0, 0, 0x80, 0x800, 0x10000}[n]
		if ok && (cp < min || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff) {
			ok = false
		}
		if ok {
			b.WriteString(s[i : i+n])
		} else {
			b.WriteRune(utf8.RuneError)
		}
		i += n
	}
	return b.String()
}
