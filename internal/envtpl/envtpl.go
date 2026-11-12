// Package envtpl reads env templates and .env files the way Compose does
// (docs/env-template.md) and answers drift between them.
package envtpl

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strings"
	"unicode"
	"unicode/utf8"
)

// ReservedPrefix marks kasbah's own keys: never prompted, invisible to drift
// in both directions.
const ReservedPrefix = "KASBAH_"

// Space is `[[:space:]]` as glibc's C.UTF-8 classes it: ASCII's six and the
// Unicode spaces, not the no-break ones — check's template hints and line scan,
// whatever the caller's locale. Assign reads blanks as compose does instead.
const Space = `[\t\n\v\f\r \x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}\x{3000}]`

var (
	// What follows compose's leading blanks: an optional `export `, the key,
	// the blanks compose allows before `=` or `:` (YAML style), the value.
	exportPrefix = regexp.MustCompile(`^export[\t\n\f\r ]+`)
	assign       = regexp.MustCompile(`^([A-Za-z_][A-Za-z0-9_]*)[\t\v\f\r \x{85}\x{A0}]*[=:](.*)$`)
)

// dotenvSpace is compose's dotenv isSpace: what it trims after `export `,
// around the key and ahead of a value. Line starts and value ends trim
// unicode.IsSpace, no-break spaces included.
func dotenvSpace(r rune) bool { return strings.ContainsRune("\t\v\f\r \u0085\u00a0", r) }

// Len is `${#s}` in a UTF-8 locale: characters, a bad byte counting one.
func Len(s string) int { return utf8.RuneCountInString(s) }

// Lines splits a file as a `while read -r line || [ -n "$line" ]` loop does,
// NUL bytes dropped, with one trailing CR off each line.
func Lines(data []byte) []string {
	s := strings.ReplaceAll(string(data), "\x00", "")
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

// Assign reads one line (CR stripped) as compose's dotenv does: `KEY=v`,
// `KEY = v`, `KEY: v`, an optional `export `, the value past compose's blanks.
// A key with other characters (`A.B`, `1A`) or a byte not UTF-8 is none.
func Assign(line string) (key, value string, ok bool) {
	if !utf8.ValidString(line) {
		return "", "", false
	}
	s := strings.TrimLeftFunc(line, unicode.IsSpace)
	if p := exportPrefix.FindString(s); p != "" {
		s = strings.TrimLeftFunc(s[len(p):], dotenvSpace)
	}
	m := assign.FindStringSubmatch(s)
	if m == nil {
		return "", "", false
	}
	return m[1], strings.TrimLeftFunc(m[2], dotenvSpace), true
}

// Blank reports a line of whitespace only, no-break spaces included, as
// compose skips it; Comment one opening with `#` past such whitespace.
func Blank(line string) bool { return strings.TrimLeftFunc(line, unicode.IsSpace) == "" }
func Comment(line string) bool {
	return strings.HasPrefix(strings.TrimLeftFunc(line, unicode.IsSpace), "#")
}

// Keys is every key a file assigns, in file order, duplicates kept. An
// unreadable path or a directory has none.
func Keys(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return KeysOf(data)
}

// KeysOf is Keys over a file's bytes.
func KeysOf(data []byte) []string {
	var keys []string
	for _, l := range Lines(data) {
		if k, _, ok := Assign(l); ok {
			keys = append(keys, k)
		}
	}
	return keys
}

func driftKeys(keys []string) []string {
	var out []string
	for _, k := range keys {
		if !strings.HasPrefix(k, ReservedPrefix) {
			out = append(out, k)
		}
	}
	return SortUniq(out)
}

// Drift is what the template has and the .env lacks (missing), and the
// reverse (extra), each in byte order. Values are never compared.
func Drift(template, env string) (missing, extra []string) {
	return DriftKeys(Keys(template), Keys(env))
}

// DriftKeys is Drift over the two files' keys, as Keys or KeysOf read them.
func DriftKeys(template, env []string) (missing, extra []string) {
	t, e := driftKeys(template), driftKeys(env)
	in := func(ss []string) map[string]bool {
		m := map[string]bool{}
		for _, s := range ss {
			m[s] = true
		}
		return m
	}
	ti, ei := in(t), in(e)
	for _, k := range t {
		if !ei[k] {
			missing = append(missing, k)
		}
	}
	for _, k := range e {
		if !ti[k] {
			extra = append(extra, k)
		}
	}
	return missing, extra
}

// SortUniq is `LC_ALL=C.UTF-8 sort -u`: byte order, each string once.
func SortUniq(ss []string) []string {
	return slices.Compact(slices.Sorted(slices.Values(ss)))
}

// ValuesOf is each key's last value in a .env as compose reads it: quotes,
// " #" comments, interpolation from the keys above. A line it cannot read
// (a multi-line quote, a key Assign refuses) sets nothing; err is the first.
func ValuesOf(data []byte) (vals map[string]string, err error) {
	vals = map[string]string{}
	lookup := func(k string) (string, bool) { v, ok := vals[k]; return v, ok }
	for i, l := range Lines(data) {
		k, raw, ok := Assign(l)
		if !ok {
			if !Blank(l) && !Comment(l) && err == nil {
				err = fmt.Errorf("line %d is not an assignment kasbah reads", i+1)
			}
			continue
		}
		v, verr := dotenvValue(raw, lookup)
		if verr != nil {
			delete(vals, k)
			if err == nil {
				err = fmt.Errorf("line %d (%s): %v", i+1, k, verr)
			}
			continue
		}
		vals[k] = v
	}
	return vals, err
}

func dotenvValue(s string, lookup func(string) (string, bool)) (string, error) {
	switch {
	case strings.HasPrefix(s, "'"):
		end := strings.IndexByte(s[1:], '\'')
		if end < 0 {
			return "", errors.New("the single quote is not closed on its line")
		}
		return s[1 : end+1], nil
	case strings.HasPrefix(s, `"`):
		var b strings.Builder
		for i := 1; i < len(s); i++ {
			switch c := s[i]; {
			case c == '"':
				return Interpolate(b.String(), lookup)
			case c == '\\' && i+1 < len(s):
				i++
				switch s[i] {
				case 'n':
					b.WriteByte('\n')
				case 'r':
					b.WriteByte('\r')
				case 't':
					b.WriteByte('\t')
				case '\\', '"':
					b.WriteByte(s[i])
				default:
					b.WriteByte('\\')
					b.WriteByte(s[i])
				}
			default:
				b.WriteByte(c)
			}
		}
		return "", errors.New("the double quote is not closed on its line")
	}
	s, _, _ = strings.Cut(s, " #")
	return Interpolate(strings.TrimRightFunc(s, unicode.IsSpace), lookup)
}

// Interpolate is s as compose interpolates it: `$$` is `$`; $VAR, ${VAR},
// ${VAR:-d}, ${VAR-d}, ${VAR:?e}, ${VAR?e}, ${VAR:+v} and ${VAR+v} read
// lookup, with d, e and v interpolated in turn; err is a form left unresolved.
func Interpolate(s string, lookup func(string) (string, bool)) (string, error) {
	if !strings.Contains(s, "$") {
		return s, nil
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] != '$' || i+1 == len(s) {
			b.WriteByte(s[i])
			continue
		}
		switch c := s[i+1]; {
		case c == '$':
			b.WriteByte('$')
			i++
		case c == '{':
			depth, end := 1, -1
			for j := i + 2; j < len(s) && end < 0; j++ {
				switch {
				case s[j] == '$' && j+1 < len(s) && s[j+1] == '{':
					depth++
					j++
				case s[j] == '}':
					if depth--; depth == 0 {
						end = j
					}
				}
			}
			if end < 0 {
				return "", fmt.Errorf("%q has a ${ that is not closed", s)
			}
			v, err := braced(s[i+2:end], lookup)
			if err != nil {
				return "", err
			}
			b.WriteString(v)
			i = end
		case isNameStart(c):
			j := i + 1
			for j < len(s) && isNameByte(s[j]) {
				j++
			}
			v, _ := lookup(s[i+1 : j])
			b.WriteString(v)
			i = j - 1
		default:
			b.WriteByte('$')
		}
	}
	return b.String(), nil
}

// braced is one ${…} body interpolated.
func braced(body string, lookup func(string) (string, bool)) (string, error) {
	n := 0
	for n < len(body) && (isNameByte(body[n]) && (n > 0 || isNameStart(body[n]))) {
		n++
	}
	name, op := body[:n], body[n:]
	if name == "" {
		return "", fmt.Errorf("${%s} names no variable", body)
	}
	v, set := lookup(name)
	if op == "" {
		return v, nil
	}
	colon := strings.HasPrefix(op, ":")
	op = strings.TrimPrefix(op, ":")
	if op == "" || !strings.ContainsRune("-?+", rune(op[0])) {
		return "", fmt.Errorf("${%s} is not an interpolation compose knows", body)
	}
	arg := op[1:]
	given := set && (!colon || v != "")
	switch op[0] {
	case '-':
		if given {
			return v, nil
		}
		return Interpolate(arg, lookup)
	case '+':
		if given {
			return Interpolate(arg, lookup)
		}
		return "", nil
	}
	if given {
		return v, nil
	}
	msg, err := Interpolate(arg, lookup)
	if err != nil {
		return "", err
	}
	return "", fmt.Errorf("required variable %s is missing a value: %s", name, msg)
}

func isNameStart(c byte) bool { return c == '_' || c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' }
func isNameByte(c byte) bool  { return isNameStart(c) || c >= '0' && c <= '9' }
