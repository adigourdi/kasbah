package check

import (
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/jv"
)

// The Bash rules asked their questions as jq filters over each document of a
// file, and what a rule decided depended on jq's exact answer: its errors, its
// output across several documents, its fallbacks. These are the operations
// those filters used, with jq 1.7's semantics and messages.

// result is one `yaml_query FILE FILTER`: stdout as jq -r wrote it, and the
// exit status — 0, 2 (the file did not load), 3 (the filter did not compile)
// or 5 (it failed at runtime on some document).
type result struct {
	out string
	rc  int
	msg string
}

// gen runs a filter on one document, emitting its outputs in order. An error
// ends that document; the next one still runs, as in jq.
type gen func(doc jv.Value, emit func(jv.Value)) error

func run(docs []jv.Value, f gen) result {
	var b strings.Builder
	var r result
	for i, d := range docs {
		err := f(d, func(v jv.Value) {
			b.WriteString(jv.Raw(v))
			b.WriteByte('\n')
		})
		if err != nil {
			r.rc = 5
			r.msg = fmt.Sprintf("jq: error (at <stdin>:%d): %v", i+1, err)
		}
	}
	r.out = b.String()
	return r
}

// sub is `$(…)` of the query alone: trailing newlines stripped.
func (r result) sub() string { return strings.TrimRight(r.out, "\n") }

// or is `$(query || echo FALLBACK)`.
func (r result) or(fallback string) string {
	if r.rc != 0 {
		return strings.TrimRight(r.out+fallback+"\n", "\n")
	}
	return r.sub()
}

type jqError string

func (e jqError) Error() string { return string(e) }

func errf(format string, args ...any) error { return jqError(fmt.Sprintf(format, args...)) }

// literal decodes a name spliced into a filter as `["NAME"]`, the way jq reads
// the string literal; ok is false where the filter would not compile.
func literal(name string) (string, bool) {
	if strings.ContainsRune(name, '"') {
		return "", false
	}
	if !strings.ContainsRune(name, '\\') {
		return name, true
	}
	var b strings.Builder
	for i := 0; i < len(name); i++ {
		c := name[i]
		if c != '\\' {
			b.WriteByte(c)
			continue
		}
		i++
		if i >= len(name) {
			return "", false
		}
		switch name[i] {
		case '\\', '/':
			b.WriteByte(name[i])
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
			if i+4 >= len(name) {
				return "", false
			}
			n, err := strconv.ParseUint(name[i+1:i+5], 16, 16)
			if err != nil {
				return "", false
			}
			b.WriteRune(rune(n))
			i += 4
		default:
			return "", false
		}
	}
	return b.String(), true
}

func describe(v jv.Value) string {
	s := jv.Compact(v)
	if len(s) > 11 {
		s = s[:10] + "..."
	}
	return jv.Type(v) + " (" + s + ")"
}

// index is `.[key]` for a string key.
func index(v jv.Value, key string) (jv.Value, error) {
	switch c := v.(type) {
	case nil:
		return nil, nil
	case *jv.Map:
		x, _ := c.Get(key)
		return x, nil
	}
	return nil, errf("Cannot index %s with %q", jv.Type(v), key)
}

// path is `.a.b.c`.
func path(v jv.Value, keys ...string) (jv.Value, error) {
	var err error
	for _, k := range keys {
		if v, err = index(v, k); err != nil {
			return nil, err
		}
	}
	return v, nil
}

// keys is jq's `keys`: an object's sorted by codepoint, an array's indices.
func keys(v jv.Value) ([]jv.Value, error) {
	switch c := v.(type) {
	case *jv.Map:
		ks := c.Keys()
		sort.Strings(ks)
		out := make([]jv.Value, len(ks))
		for i, k := range ks {
			out[i] = k
		}
		return out, nil
	case []jv.Value:
		out := make([]jv.Value, len(c))
		for i := range c {
			out[i] = jv.Number(strconv.Itoa(i))
		}
		return out, nil
	}
	return nil, errf("%s has no keys", describe(v))
}

// iter is `.[]`; with opt, `.[]?`.
func iter(v jv.Value, opt bool) ([]jv.Value, error) {
	switch c := v.(type) {
	case []jv.Value:
		return c, nil
	case *jv.Map:
		out := make([]jv.Value, 0, c.Len())
		for _, k := range c.Keys() {
			x, _ := c.Get(k)
			out = append(out, x)
		}
		return out, nil
	}
	if opt {
		return nil, nil
	}
	return nil, errf("Cannot iterate over %s", describe(v))
}

// entries is `to_entries[]` as key/value pairs, in the object's own order.
func entries(v jv.Value) (ks []jv.Value, vs []jv.Value, err error) {
	switch c := v.(type) {
	case *jv.Map:
		for _, k := range c.Keys() {
			x, _ := c.Get(k)
			ks, vs = append(ks, k), append(vs, x)
		}
		return ks, vs, nil
	case []jv.Value:
		for i, x := range c {
			ks, vs = append(ks, jv.Number(strconv.Itoa(i))), append(vs, x)
		}
		return ks, vs, nil
	}
	return nil, nil, errf("%s has no keys", describe(v))
}

// has is `has(key)` for a string key; jq 1.7 answers false on null.
func has(v jv.Value, key string) (bool, error) {
	switch c := v.(type) {
	case nil:
		return false, nil
	case *jv.Map:
		return c.Has(key), nil
	}
	return false, errf("Cannot check whether %s has a string key", jv.Type(v))
}

// length is jq's `length`, as the number it prints.
func length(v jv.Value) (jv.Value, error) {
	var n float64
	switch c := v.(type) {
	case nil:
	case bool:
		return nil, errf("%s has no length", describe(v))
	case jv.Number:
		n = math.Abs(c.Float64())
	case string:
		n = float64(utf8.RuneCountInString(c))
	case []jv.Value:
		n = float64(len(c))
	case *jv.Map:
		n = float64(c.Len())
	}
	if n == math.Trunc(n) && n < 1e17 {
		return jv.Number(strconv.FormatFloat(n, 'f', 0, 64)), nil
	}
	return jv.Number(strconv.FormatFloat(n, 'g', 17, 64)), nil
}

// anyEq is `any(. == s)` over `.[]`.
func anyEq(v jv.Value, s string) (bool, error) {
	xs, err := iter(v, false)
	if err != nil {
		return false, err
	}
	for _, x := range xs {
		if y, ok := x.(string); ok && y == s {
			return true, nil
		}
	}
	return false, nil
}
