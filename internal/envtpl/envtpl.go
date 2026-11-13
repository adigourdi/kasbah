// Package envtpl reads env templates and .env files the way Compose does
// (docs/env-template.md) and answers drift between them.
package envtpl

import (
	"errors"
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
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
	lines := RawLines(data)
	for i, l := range lines {
		lines[i] = strings.TrimSuffix(l, "\r")
	}
	return lines
}

// RawLines is Lines with each line's bytes kept, CR included; a last line
// without a newline is data.
func RawLines(data []byte) []string {
	s := strings.ReplaceAll(string(data), "\x00", "")
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// Entry is one statement of a .env as compose reads it: lines[Line:End], a
// quoted value that runs past its line spanning to the closing quote (Value
// joined by "\n", inner CRs kept). Key is "" where Assign reads no key.
type Entry struct {
	Line, End  int
	Key, Value string
	badKey     bool
}

// Span reports an entry of more than one line.
func (e Entry) Span() bool { return e.End-e.Line > 1 }

// composeKey is compose's wider key rule (letters, digits, `_ . - [ ]`),
// which decides where its statements end even where kasbah reads no key.
var composeKey = regexp.MustCompile(`^[\pL\pN_.\[\]-]+[\t\v\f\r \x{85}\x{A0}]*[=:](.*)$`)

// composeValue is the value compose reads from a line Assign refuses, bad
// bytes taken as U+FFFD; ok false where compose reads no key either.
func composeValue(line string) (string, bool) {
	s := strings.TrimLeftFunc(strings.ToValidUTF8(line, "�"), unicode.IsSpace)
	if p := exportPrefix.FindString(s); p != "" {
		s = strings.TrimLeftFunc(s[len(p):], dotenvSpace)
	}
	m := composeKey.FindStringSubmatch(s)
	if m == nil {
		return "", false
	}
	return strings.TrimLeftFunc(m[1], dotenvSpace), true
}

var composeName = regexp.MustCompile(`^[\pL\pN_.\[\]-]+$`)

// composeRefuses reports a line whose key — before its first `=` or `:`, else
// the whole line — compose refuses the file for: a space, a byte not UTF-8, a
// character no key holds; compose's other blanks inside a key are let pass.
func composeRefuses(line string) bool {
	s := strings.TrimLeftFunc(line, unicode.IsSpace)
	if p := exportPrefix.FindString(s); p != "" {
		s = strings.TrimLeftFunc(s[len(p):], dotenvSpace)
	}
	if i := strings.IndexAny(s, "=:"); i >= 0 {
		s = s[:i]
	}
	k := strings.TrimRightFunc(s, dotenvSpace)
	if k == "" {
		return false
	}
	if !utf8.ValidString(k) || strings.Contains(k, " ") {
		return true
	}
	return !composeName.MatchString(strings.Map(func(r rune) rune {
		if dotenvSpace(r) {
			return -1
		}
		return r
	}, k))
}

// Entries reads lines (RawLines' or Lines') as compose groups them.
func Entries(lines []string) []Entry {
	// closer[q][j] is the first line from j holding a q no backslash escapes;
	// a line break ends any escape, so each line is scanned once.
	closer := map[byte][]int{}
	closeAt := func(q byte, j int) int {
		c, ok := closer[q]
		if !ok {
			c = make([]int, len(lines)+1)
			c[len(lines)] = len(lines)
			for k := len(lines) - 1; k >= 0; k-- {
				if c[k] = c[k+1]; hasQuote(lines[k], q) {
					c[k] = k
				}
			}
			closer[q] = c
		}
		return c[j]
	}
	var out []Entry
	for i := 0; i < len(lines); i++ {
		e := Entry{Line: i, End: i + 1}
		l := strings.TrimSuffix(lines[i], "\r")
		k, v, ok := Assign(l)
		if !ok {
			v, ok = composeValue(l)
		}
		if !ok && !Blank(l) && !Comment(l) {
			e.badKey = composeRefuses(l)
		}
		if ok {
			e.Key, e.Value = k, v
			if v != "" && (v[0] == '\'' || v[0] == '"') {
				if _, _, closed := quoted(v); !closed {
					if j := closeAt(v[0], i+1); j < len(lines) {
						cr := strings.TrimPrefix(lines[i], l)
						e.Value = strings.TrimSuffix(v+cr+"\n"+strings.Join(lines[i+1:j+1], "\n"), "\r")
						e.End = j + 1
					}
				}
			}
		}
		out = append(out, e)
		i = e.End - 1
	}
	return out
}

// hasQuote reports a q in s that no backslash escapes, as quoted scans.
func hasQuote(s string, q byte) bool {
	esc := false
	for i := 0; i < len(s); i++ {
		switch c := s[i]; {
		case c == q && !esc:
			return true
		case esc:
			esc = false
		case c == '\\':
			esc = true
		}
	}
	return false
}

// Refused is why compose's reading of the entry is not one kasbah can take
// whole — a key compose refuses, a quote never closed, text after the closing
// one, a span under a key kasbah reads none from — or nil. It never quotes
// the value.
func (e Entry) Refused() error {
	if e.badKey {
		return errors.New("a key compose refuses (a character no key holds), so compose refuses the file")
	}
	if e.Key == "" && e.Span() {
		return errors.New("a quoted value over several lines under a key kasbah does not read")
	}
	if e.Value != "" && (e.Value[0] == '\'' || e.Value[0] == '"') {
		return quoteErr(e.Value)
	}
	return nil
}

// Refused is the first entry of lines (RawLines') Entry.Refused refuses,
// named by line and key, or nil.
func Refused(lines []string) error {
	for _, e := range Entries(lines) {
		if err := e.Refused(); err != nil {
			if e.Key == "" {
				return fmt.Errorf("line %d: %v", e.Line+1, err)
			}
			return fmt.Errorf("line %d (%s): %v", e.Line+1, e.Key, err)
		}
	}
	return nil
}

// Continued marks each line a span holds past its first.
func Continued(lines []string) []bool {
	in := make([]bool, len(lines))
	for _, e := range Entries(lines) {
		for j := e.Line + 1; j < e.End; j++ {
			in[j] = true
		}
	}
	return in
}

// OneLine is an entry as one line compose reads the same: the line itself,
// CR stripped, or for a span KEY= and OneValue (a keyless span its first line).
func (e Entry) OneLine(lines []string) string {
	if !e.Span() || e.Key == "" {
		return strings.TrimSuffix(lines[e.Line], "\r")
	}
	return e.Key + "=" + e.OneValue()
}

// OneValue is Value on one line, as compose reads it: a span's line breaks
// escaped, a single-quoted span re-quoted double.
func (e Entry) OneValue() string {
	if !e.Span() || e.Key == "" {
		return e.Value
	}
	return oneLine(e.Value)
}

// Folded is a file's lines, each entry on one line (OneLine).
func Folded(data []byte) []string {
	lines := RawLines(data)
	var out []string
	for _, e := range Entries(lines) {
		out = append(out, e.OneLine(lines))
	}
	return out
}

func oneLine(v string) string {
	body, rest, _ := quoted(v)
	if v[0] == '\'' {
		r := strings.NewReplacer(`\`, `\\`, `"`, `\"`, "$", "$$", "\n", `\n`, "\r", `\r`)
		return `"` + r.Replace(body) + `"` + rest
	}
	var b strings.Builder
	b.WriteByte('"')
	esc := false
	for i := 1; i < len(v)-len(rest); i++ {
		c := v[i]
		switch {
		case c == '\n' || c == '\r':
			if esc {
				b.WriteByte('\\')
			}
			b.WriteString(map[byte]string{'\n': `\n`, '\r': `\r`}[c])
			esc = false
		case esc:
			b.WriteByte(c)
			esc = false
		default:
			b.WriteByte(c)
			esc = c == '\\'
		}
	}
	return b.String() + rest
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

// KeysOf is Keys over a file's bytes, a span's key once.
func KeysOf(data []byte) []string {
	var keys []string
	for _, e := range Entries(RawLines(data)) {
		if e.Key != "" {
			keys = append(keys, e.Key)
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

// ValuesOf is each key's last value in a .env as compose reads it (quotes,
// escapes, spans, " #" comments, interpolation from the keys above). An
// entry it cannot read sets nothing; err is the first.
func ValuesOf(data []byte) (vals map[string]string, err error) {
	vals = map[string]string{}
	lookup := func(k string) (string, bool) { v, ok := vals[k]; return v, ok }
	lines := RawLines(data)
	for _, e := range Entries(lines) {
		if e.Key == "" {
			l := strings.TrimSuffix(lines[e.Line], "\r")
			if !Blank(l) && !Comment(l) && err == nil {
				err = fmt.Errorf("line %d is not an assignment kasbah reads", e.Line+1)
			}
			continue
		}
		v, verr := dotenvValue(e.Value, lookup)
		if verr != nil {
			delete(vals, e.Key)
			if err == nil {
				err = fmt.Errorf("line %d (%s): %v", e.Line+1, e.Key, verr)
			}
			continue
		}
		vals[e.Key] = v
	}
	return vals, err
}

// afterQuote is what may follow a closing quote: blanks, a # comment, or one
// bare name, which compose reads as a key inherited from its environment.
var afterQuote = regexp.MustCompile(`^(#.*|[\pL\pN_.\[\]-]*)$`)

// dotenvValue is one value as compose reads it: single quotes literal but
// for \', double quotes with compose's escapes and interpolation, a quote
// closed by the first one no backslash escapes.
func dotenvValue(s string, lookup func(string) (string, bool)) (string, error) {
	if s != "" && (s[0] == '\'' || s[0] == '"') {
		if err := quoteErr(s); err != nil {
			return "", err
		}
		body, _, _ := quoted(s)
		if s[0] == '\'' {
			return body, nil
		}
		return Interpolate(expandEscapes(body), lookup)
	}
	s, _, _ = strings.Cut(s, " #")
	return Interpolate(strings.TrimRightFunc(s, unicode.IsSpace), lookup)
}

// quoteErr is why compose refuses the quoted value s, or reads more from it
// than one value; nil if neither.
func quoteErr(s string) error {
	kind := map[byte]string{'\'': "single", '"': "double"}[s[0]]
	_, rest, ok := quoted(s)
	if !ok {
		return fmt.Errorf("the %s quote is not closed", kind)
	}
	if !afterQuote.MatchString(strings.TrimFunc(rest, unicode.IsSpace)) {
		return fmt.Errorf("text follows the closing %s quote, which compose reads as another assignment", kind)
	}
	return nil
}

// quoted is compose's scan of a quoted value: body up to the first quote
// not escaped, a backslash dropped only before that quote; rest what
// follows it; ok false when no quote closes it.
func quoted(s string) (body, rest string, ok bool) {
	q := s[0]
	var b []byte
	esc := false
	for i := 1; i < len(s); i++ {
		c := s[i]
		switch {
		case c == q && esc:
			b, esc = append(b, c), false
		case c == q:
			return string(b), s[i+1:], true
		case esc:
			b, esc = append(b, '\\', c), false
		case c == '\\':
			esc = true
		default:
			b = append(b, c)
		}
	}
	return "", "", false
}

var escapeSeq = regexp.MustCompile(`\\(?:[abcfnrtv$"\\]|0\d{0,3})`)

// expandEscapes is compose's: the escapes escapeSeq finds that Go's
// UnquoteChar reads (\0NNN as octal NNN), \$ as $$; any other kept as written.
func expandEscapes(s string) string {
	return escapeSeq.ReplaceAllStringFunc(s, func(m string) string {
		if m == `\$` {
			return "$$"
		}
		if strings.HasPrefix(m, `\0`) {
			m = `\` + m[2:]
		}
		r, _, _, err := strconv.UnquoteChar(m, '"')
		if err != nil {
			return m
		}
		return string(r)
	})
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
