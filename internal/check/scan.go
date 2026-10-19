package check

import (
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/envtpl"
)

// text is a file `check --fix` edits, as lines, with the edits staged against
// it. Only the parsed documents decide what is true; this only finds where a
// key is written, and anything it cannot find is refused by the caller.
type text struct {
	// lines keep their CR, so a CRLF file comes back CRLF; matching strips it.
	lines []string
	// eol is what an inserted line ends with: CR when any line of the file does.
	eol     string
	finalNL bool

	del    []bool
	rep    []string
	hasRep []bool
	ins    []insertion
}

// insertion is one or more lines after line at. Several can share an anchor —
// a service's last line is also the last line of its last sub-block — and they
// come out deepest-indent first, or a service key lands inside that block.
type insertion struct {
	at, ind int
	lines   []string
}

// maxIndent is the deepest indentation insertions are sorted by; one deeper is
// never emitted.
const maxIndent = 64

func readText(data []byte) *text {
	t := &text{finalNL: len(data) == 0 || data[len(data)-1] == '\n'}
	s := string(data)
	if s != "" {
		t.lines = strings.Split(strings.TrimSuffix(s, "\n"), "\n")
	}
	for _, l := range t.lines {
		if strings.HasSuffix(l, "\r") {
			t.eol = "\r"
		}
	}
	n := len(t.lines)
	t.del, t.rep, t.hasRep = make([]bool, n), make([]string, n), make([]bool, n)
	return t
}

// render is the edited file's bytes.
func (t *text) render() []byte {
	anchored := make([]bool, len(t.lines))
	for _, in := range t.ins {
		anchored[in.at] = true
	}
	var out []string
	for i, l := range t.lines {
		switch {
		case t.del[i]:
		case t.hasRep[i]:
			out = append(out, t.rep[i])
		default:
			out = append(out, l)
		}
		if !anchored[i] {
			continue
		}
		// Within one indentation, sequence entries first: they continue a
		// flush list that ends on this line, which a key emitted first would cut.
		for lvl := maxIndent; lvl >= 0; lvl-- {
			for _, entries := range []bool{true, false} {
				for _, in := range t.ins {
					if in.at == i && in.ind == lvl && isEntry(noCR(in.lines[0])[in.ind:]) == entries {
						out = append(out, in.lines...)
					}
				}
			}
		}
	}
	if len(out) == 0 {
		return nil
	}
	s := strings.Join(out, "\n")
	if t.finalNL {
		s += "\n"
	}
	return []byte(s)
}

// insertAfter stages s — already-indented lines, newline-separated, no CR —
// after line idx, each line ending as the file's own do.
func (t *text) insertAfter(idx int, s string) {
	ls := strings.Split(s, "\n")
	for i := range ls {
		ls[i] += t.eol
	}
	t.ins = append(t.ins, insertion{at: idx, ind: indent(s), lines: ls})
}

// isSpace is `[[:space:]]` under C.UTF-8 (envtpl.Space).
func isSpace(r rune) bool {
	switch {
	case r == ' ', r >= '\t' && r <= '\r', r == 0x1680, r >= 0x2000 && r <= 0x2006,
		r >= 0x2008 && r <= 0x200A, r == 0x2028, r == 0x2029, r == 0x205F, r == 0x3000:
		return true
	}
	return false
}

var (
	reBlank   = regexp.MustCompile(`^` + envtpl.Space + `*$`)
	reComment = regexp.MustCompile(`^` + envtpl.Space + `*#`)
	notSpace  = strings.Replace(envtpl.Space, "[", "[^", 1)
	// A `key: value` line: the key unquoted and without blanks.
	reKeyLine = regexp.MustCompile(`^(` + envtpl.Space + `*` + strings.Replace(notSpace, "]", ":]", 1) + `+:)(.*)$`)
	reFlowSeq = regexp.MustCompile(`^(.*\[)([^\]]*)(\].*)$`)
)

func noCR(s string) string { return strings.TrimSuffix(s, "\r") }

// indent is the count of leading spaces; YAML indents with nothing else.
func indent(s string) int {
	s = noCR(s)
	return len(s) - len(strings.TrimLeft(s, " "))
}

func isBlank(s string) bool   { return reBlank.MatchString(noCR(s)) }
func isComment(s string) bool { return reComment.MatchString(noCR(s)) }

func spaces(n int) string { return strings.Repeat(" ", n) }

// splitValue takes apart what a key line carries after its colon: the scalar
// without the blanks around it, and the trailing comment with the whitespace
// before it. ok is false when the two cannot be told apart — a quoted scalar
// that does not close on this line, or text after its closing quote.
func splitValue(s string) (val, cmt string, ok bool) {
	n := len(s)
	lead := 0
	for lead < n && (s[lead] == ' ' || s[lead] == '\t') {
		lead++
	}
	if lead == n {
		return "", "", true
	}
	if s[lead] == '#' {
		return "", s, true
	}
	if q := s[lead]; q == '"' || q == '\'' {
		i := lead + 1
		for i < n {
			c := s[i]
			if q == '"' && c == '\\' {
				i += 2
				continue
			}
			if c == q {
				if q == '\'' && i+1 < n && s[i+1] == '\'' {
					i += 2
					continue
				}
				break
			}
			i++
		}
		if i >= n {
			return "", "", false
		}
		tail := s[i+1:]
		if tt := strings.TrimLeftFunc(tail, isSpace); tt != "" && tt[0] != '#' {
			return "", "", false
		}
		return s[lead : i+1], tail, true
	}
	j := n
	for i := lead; i < n; i++ {
		if s[i] == '#' && i > 0 && (s[i-1] == ' ' || s[i-1] == '\t') {
			j = i
			break
		}
	}
	k := j
	for k > lead && (s[k-1] == ' ' || s[k-1] == '\t') {
		k--
	}
	return s[lead:k], s[k:], true
}

// rawValue is the scalar written after the line's first colon (the whole line
// when it has none); empty when the key opens a block. A value splitValue
// refuses still counts as one.
func (t *text) rawValue(idx int) string {
	s := noCR(t.lines[idx])
	rest := s
	if _, after, found := strings.Cut(s, ":"); found {
		rest = after
	}
	if v, _, ok := splitValue(rest); ok {
		return v
	}
	return strings.TrimLeftFunc(rest, isSpace)
}

// inline is whether the key at idx carries its value on its own line.
func (t *text) inline(idx int) bool { return t.rawValue(idx) != "" }

// scalarHeader reads line idx as a block-scalar header — `|` or `>` with its
// indicators, after any `- ` entries, a `key:`, anchors and tags. ind is the
// column its content is deeper than: the key's, or the last entry's dash.
func (t *text) scalarHeader(idx int) (ok bool, ind int, keep bool) {
	s := noCR(t.lines[idx])
	col := indent(s)
	v := s[col:]
	ind = col
	for isEntry(v) {
		ind = col
		n := 1
		for n < len(v) && (v[n] == ' ' || v[n] == '\t') {
			n++
		}
		col, v = col+n, v[n:]
	}
	if v == "" {
		return false, 0, false
	}
	if c := v[0]; c != '|' && c != '>' && c != '&' && c != '!' {
		_, rest, found := strings.Cut(v, ":")
		if !found {
			return false, 0, false
		}
		ind, v = col, rest
	}
	for {
		v = strings.TrimLeft(v, " \t")
		if v == "" || (v[0] != '&' && v[0] != '!') {
			break
		}
		i := strings.IndexAny(v, " \t")
		if i < 0 {
			return false, 0, false
		}
		v = v[i:]
	}
	val, _, okv := splitValue(v)
	if !okv || val == "" || (val[0] != '|' && val[0] != '>') || strings.Trim(val[1:], "-+0123456789") != "" {
		return false, 0, false
	}
	return true, ind, strings.Contains(val, "+")
}

// isEntry is whether s, its indentation removed, is a sequence entry.
func isEntry(s string) bool {
	s = noCR(s)
	return s == "-" || strings.HasPrefix(s, "- ") || strings.HasPrefix(s, "-\t")
}

// scalarEnd is the last line of the block scalar opened at idx: every
// following line that is blank or deeper than ind, as YAML reads it. The
// trailing blanks belong to it only under `+`, which keeps them as its value.
func (t *text) scalarEnd(idx, ind int, keep bool) int {
	last, lastNB := idx, idx
	for i := idx + 1; i < len(t.lines); i++ {
		if isBlank(t.lines[i]) {
			last = i
			continue
		}
		if indent(t.lines[i]) <= ind {
			break
		}
		last, lastNB = i, i
	}
	if keep {
		return last
	}
	return lastNB
}

// firstChild is the first content line after start, or -1.
func (t *text) firstChild(start int) int {
	for i := start + 1; i < len(t.lines); i++ {
		if !isBlank(t.lines[i]) && !isComment(t.lines[i]) {
			return i
		}
	}
	return -1
}

// flushSeq is whether the key at start holds a sequence written at its own
// indentation (`key:` then `- a` under it, unindented), which YAML allows.
func (t *text) flushSeq(start int) bool {
	ind := indent(t.lines[start])
	i := t.firstChild(start)
	return i >= 0 && t.rawValue(start) == "" && !isEntry(noCR(t.lines[start])[ind:]) &&
		indent(t.lines[i]) == ind && isEntry(noCR(t.lines[i])[ind:])
}

// blockEnd is the last content line of the block opened at start, -1 when it
// has no children. Blank and comment lines are stepped over, so an insertion
// lands above a trailing comment; a block scalar's region is skipped whole,
// because its `#` and blank lines are the value.
func (t *text) blockEnd(start int) int {
	ind := indent(t.lines[start])
	flush := t.flushSeq(start)
	end := -1
	for i := start + 1; i < len(t.lines); i++ {
		if isBlank(t.lines[i]) || isComment(t.lines[i]) {
			continue
		}
		in := indent(t.lines[i])
		if in < ind || in == ind && !(flush && isEntry(noCR(t.lines[i])[ind:])) {
			break
		}
		end = i
		if ok, sind, keep := t.scalarHeader(i); ok {
			end = t.scalarEnd(i, sind, keep)
			i = end
		}
	}
	return end
}

// childIndent is where the block's children are written, from the first one,
// and its step from the block; a block with none gets two. It stops at the
// first child, so it never enters a block scalar: the header comes first.
func (t *text) childIndent(start int) (ci, step int) {
	ind := indent(t.lines[start])
	if t.flushSeq(start) {
		return ind, 0
	}
	if i := t.firstChild(start); i >= 0 && indent(t.lines[i]) > ind {
		in := indent(t.lines[i])
		return in, in - ind
	}
	return ind + 2, 2
}

// keyAt is whether s is `KEY:` — bare, double- or single-quoted — then the
// end of the line or a blank.
func keyAt(s, pre, key string) bool {
	for _, k := range []string{key, `"` + key + `"`, "'" + key + "'"} {
		head := pre + k + ":"
		if !strings.HasPrefix(s, head) {
			continue
		}
		rest := s[len(head):]
		if rest == "" {
			return true
		}
		if r, _ := utf8.DecodeRuneInString(rest); isSpace(r) {
			return true
		}
	}
	return false
}

// locateChild is the line of KEY at exactly indentation ind between start and
// end, or -1: a deeper key of the same name is never taken for it.
func (t *text) locateChild(key string, start, end, ind int) int {
	pre := spaces(ind)
	for i := start + 1; i <= end; i++ {
		if keyAt(noCR(t.lines[i]), pre, key) {
			return i
		}
	}
	return -1
}

// locateTop is the line of a top-level KEY, or -1.
func (t *text) locateTop(key string) int {
	for i, l := range t.lines {
		if keyAt(noCR(l), "", key) {
			return i
		}
	}
	return -1
}

// setValue rewrites the scalar at idx in place: indentation, the key as
// spelled, quoting and a trailing comment all kept. False when the line is
// not a `key: value` this can take apart.
func (t *text) setValue(idx int, val string) bool {
	s, cr := t.lines[idx], ""
	if strings.HasSuffix(s, "\r") {
		s, cr = s[:len(s)-1], "\r"
	}
	m := reKeyLine.FindStringSubmatch(s)
	if m == nil {
		return false
	}
	old, cmt, ok := splitValue(m[2])
	if !ok {
		return false
	}
	q := ""
	if len(old) >= 2 && (old[0] == '"' || old[0] == '\'') && old[len(old)-1] == old[0] {
		q = old[:1]
	}
	t.rep[idx] = m[1] + " " + q + val + q + cmt + cr
	t.hasRep[idx] = true
	return true
}

// deleteKey removes the key at idx, everything under it, and the comments
// after it written deeper than it. A comment above it stays: it cannot be
// told from a file header.
func (t *text) deleteKey(idx int) {
	ind := indent(t.lines[idx])
	last := t.blockEnd(idx)
	if last < idx {
		last = idx
	}
	for i := last + 1; i < len(t.lines); i++ {
		if !isComment(t.lines[i]) || indent(t.lines[i]) <= ind {
			break
		}
		last = i
	}
	for i := idx; i <= last; i++ {
		t.del[i] = true
	}
}
