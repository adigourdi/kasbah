// Package envtpl reads env templates and .env files the way Compose does
// (docs/env-template.md) and answers drift between them.
package envtpl

import (
	"os"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"
)

// ReservedPrefix marks kasbah's own keys: never prompted, invisible to drift
// in both directions.
const ReservedPrefix = "KASBAH_"

// Space is `[[:space:]]` as glibc's C.UTF-8 classes it: ASCII's six and the
// Unicode spaces, but not the no-break ones. kasbah reads every file the same
// way whatever the caller's locale.
const Space = `[\t\n\v\f\r \x{1680}\x{2000}-\x{2006}\x{2008}-\x{200A}\x{2028}\x{2029}\x{205F}\x{3000}]`

var (
	// "a line that assigns a variable": leading blanks trimmed, an optional
	// `export `, the last assignment wins.
	assign  = regexp.MustCompile(`^` + Space + `*(export` + Space + `+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$`)
	blank   = regexp.MustCompile(`^` + Space + `*$`)
	comment = regexp.MustCompile(`^` + Space + `*#`)
)

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

// Assign parses one line (CR already stripped) as an assignment. A line with
// an invalid UTF-8 byte is none: a UTF-8 regex engine cannot match across it.
func Assign(line string) (key, value string, ok bool) {
	if !utf8.ValidString(line) {
		return "", "", false
	}
	m := assign.FindStringSubmatch(line)
	if m == nil {
		return "", "", false
	}
	return m[2], m[3], true
}

// Blank reports a line of whitespace only; Comment one opening with `#`.
func Blank(line string) bool   { return blank.MatchString(line) }
func Comment(line string) bool { return comment.MatchString(line) }

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
