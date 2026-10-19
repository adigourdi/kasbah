// Package yamlx reads YAML as the JSON `yq -c .` prints (kislyuk yq 3.1.0:
// libyaml, PyYAML constructors, jq). yq resolves plain scalars by YAML 1.2
// core — `yes`, `on`, `1:30` are strings — yet `0755` is octal 493.
package yamlx

import (
	"bytes"
	"io"
	"os"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/jv"
	"go.yaml.in/yaml/v3"
)

// Error is a document yq would not convert. The loader drops the whole
// file on any such failure, including a later document of a stream whose
// earlier ones converted.
type Error struct {
	Msg string
}

func (e *Error) Error() string { return e.Msg }

func refuse(format string, args ...any) error {
	return &Error{Msg: sprintf(format, args...)}
}

// yq's --max-expansion-factor default: a document whose JSON outgrows its
// source this many times over is refused.
const expansionFactor = 1024

// Load converts a YAML stream into its documents. An empty or comment-only
// stream is no documents; a document that does not convert fails the lot.
func Load(data []byte) ([]jv.Value, error) {
	// yq reads its input as a text file: strict UTF-8, universal newlines.
	if !utf8.Valid(data) {
		return nil, refuse("yaml: input is not valid UTF-8")
	}
	data, err := normalize(data)
	if err != nil {
		return nil, err
	}

	dec := yaml.NewDecoder(bytes.NewReader(data))
	var nodes []*yaml.Node
	for {
		n := new(yaml.Node)
		err := dec.Decode(n)
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, &Error{Msg: err.Error()}
		}
		nodes = append(nodes, n)
	}

	starts := rootStarts(data, nodes)
	docs := make([]jv.Value, 0, len(nodes))
	for i, n := range nodes {
		if err := checkAnchors(n); err != nil {
			return nil, err
		}
		o, err := newBuilder().build(n)
		if err != nil {
			return nil, err
		}
		// yq hands the JSON to jq, whose parser refuses it past this depth.
		if (o.kind == kList || o.kind == kDict) && depth(o, map[*obj]int{}) >= jv.DepthLimit {
			return nil, refuse("yaml: line %d: nested deeper than jq's parser allows", n.Line)
		}
		// yq divides by the source between this root's end and the last one's;
		// starts bound that from above, so this is never stricter than yq.
		prev := 0
		if i > 0 {
			prev = starts[i-1]
		}
		if pySize(o, map[*obj]int{}) > (starts[i+1]-prev+2)*expansionFactor {
			return nil, refuse("yaml: detected unsafe YAML entity expansion")
		}
		v, err := o.value(map[*obj]jv.Value{})
		if err != nil {
			return nil, err
		}
		docs = append(docs, v)
	}
	return docs, nil
}

// rootStarts is each document root's offset in characters, then the stream's
// length in characters.
func rootStarts(data []byte, docs []*yaml.Node) []int {
	lines := []int{0}
	chars := 0
	for _, r := range string(data) {
		chars++
		if r == '\n' {
			lines = append(lines, chars)
		}
	}
	out := make([]int, 0, len(docs)+1)
	for _, d := range docs {
		n := d
		if len(d.Content) > 0 {
			n = d.Content[0]
		}
		off := 0
		if n.Line >= 1 && n.Line <= len(lines) {
			off = lines[n.Line-1] + max(n.Column-1, 0)
		}
		out = append(out, off)
	}
	return append(out, chars)
}

// LoadFile is Load over a file's content.
func LoadFile(path string) ([]jv.Value, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return Load(data)
}

// Render is `yq -c .`'s stdout for the documents: one compact line each.
func Render(docs []jv.Value) string {
	var b strings.Builder
	for _, d := range docs {
		b.WriteString(jv.Compact(d))
		b.WriteByte('\n')
	}
	return b.String()
}

// normalize is what reaches libyaml in yq, in a shape yaml.v3 reads alike:
// universal newlines, a line-opening byte-order mark as the column libyaml
// skips it as, and `%YAML 1.2` (libyaml accepts it, yaml.v3 refuses) as 1.1.
func normalize(data []byte) ([]byte, error) {
	if bytes.ContainsRune(data, '\r') {
		data = bytes.ReplaceAll(data, []byte("\r\n"), []byte("\n"))
		data = bytes.ReplaceAll(data, []byte("\r"), []byte("\n"))
	}
	data, err := lineBOMs(data)
	if err != nil {
		return nil, err
	}
	return yaml12(data), nil
}

func isBreak(r rune) bool { return r == '\n' || r == 0x85 || r == 0x2028 || r == 0x2029 }

var reDocStart = regexp.MustCompile(`^---(?:[ \t]+(?:#.*)?)?$`)

// lineBOMs accepts a line-opening byte-order mark only where it opens a
// document (stream start, or after a bare `---`), as one column of indent.
// Elsewhere libyaml's reading depends on the scalar it interrupts: refused.
func lineBOMs(data []byte) ([]byte, error) {
	const bom = "\uFEFF"
	s := string(data)
	if len(s) < 2 || !strings.Contains(s[1:], bom) {
		return data, nil
	}
	var out strings.Builder
	line, lineStart, prevLine := 1, 0, -1
	for i, r := range s {
		if r == 0xFEFF && i > 0 && lineStart == i {
			prev := ""
			if prevLine >= 0 {
				prev = strings.TrimRightFunc(s[prevLine:lineStart], isBreak)
			}
			onlyBreaks := strings.TrimFunc(s[:i], func(r rune) bool { return isBreak(r) || r == 0xFEFF }) == ""
			if !onlyBreaks && !reDocStart.MatchString(prev) {
				return nil, refuse("yaml: line %d: a byte-order mark opens a line inside a document", line)
			}
			out.WriteByte(' ')
			continue
		}
		out.WriteRune(r)
		if isBreak(r) {
			prevLine, lineStart = lineStart, i+utf8.RuneLen(r)
			line++
		}
	}
	return []byte(out.String()), nil
}

// yaml12 rewrites `%YAML 1.2` only on directive lines: at the stream's start
// or after a `...`, before the `---` that opens the document.
func yaml12(data []byte) []byte {
	if !bytes.Contains(data, []byte("%YAML")) {
		return data
	}
	lines := strings.SplitAfter(string(data), "\n")
	directives := true
	for i, l := range lines {
		body := strings.TrimSuffix(strings.TrimPrefix(l, "\uFEFF"), "\n")
		trimmed := strings.TrimSpace(body)
		switch {
		case directives && strings.HasPrefix(body, "%"):
			lines[i] = reYAML12.ReplaceAllString(l, "${1}1${2}")
		case directives && (trimmed == "" || strings.HasPrefix(trimmed, "#")):
		case directives:
			directives = false
		case body == "..." || strings.HasPrefix(body, "... ") || strings.HasPrefix(body, "...\t"):
			directives = true
		}
	}
	return []byte(strings.Join(lines, ""))
}

var reYAML12 = regexp.MustCompile(`^(\x{FEFF}?%YAML[ \t]+1\.)2([ \t\n]|$)`)

// checkAnchors applies PyYAML's composer rules that yaml.v3 does not: an
// anchor defined twice in one document is an error, and an alias resolves only
// against anchors of its own document, defined before it.
func checkAnchors(doc *yaml.Node) error {
	defined := map[*yaml.Node]bool{}
	names := map[string]bool{}
	var walk func(n *yaml.Node) error
	walk = func(n *yaml.Node) error {
		if n.Kind == yaml.AliasNode {
			if !defined[n.Alias] {
				return refuse("yaml: line %d: found undefined alias %q", n.Line, n.Value)
			}
			return nil
		}
		if n.Anchor != "" {
			if names[n.Anchor] {
				return refuse("yaml: line %d: found duplicate anchor %q", n.Line, n.Anchor)
			}
			names[n.Anchor] = true
			defined[n] = true
		}
		for _, c := range n.Content {
			if err := walk(c); err != nil {
				return err
			}
		}
		return nil
	}
	return walk(doc)
}

// File is one YAML file read once: every question about it is answered from
// Docs, never by reading it again (CLAUDE.md, "Read a YAML file once").
type File struct {
	Path string
	Docs []jv.Value
	// Err is the read or conversion failure; Docs is empty when it is set.
	Err error
}

// Cache holds files by the path they were asked for, and is not safe for
// concurrent use. Nothing checks a file against its mtime: whatever rewrites
// a file it has read calls Forget.
type Cache struct {
	files map[string]*File
}

// Get returns the file, reading it on first use.
func (c *Cache) Get(path string) *File {
	if f, ok := c.files[path]; ok {
		return f
	}
	if c.files == nil {
		c.files = map[string]*File{}
	}
	docs, err := LoadFile(path)
	f := &File{Path: path, Docs: Reread(docs), Err: err}
	if err != nil {
		f.Docs = nil
	}
	c.files[path] = f
	return f
}

// Reread is the documents as jq reads them back from yq's output, which is
// what a yq | jq reader holds: there an infinity is the literal yq printed
// for it, and jq spells a literal the decNumber way.
func Reread(docs []jv.Value) []jv.Value {
	for i, d := range docs {
		docs[i] = reread(d)
	}
	return docs
}

func reread(v jv.Value) jv.Value {
	switch c := v.(type) {
	case jv.Number:
		switch c {
		case "1.7976931348623157e+308":
			return jv.Number("1.7976931348623157E+308")
		case "-1.7976931348623157e+308":
			return jv.Number("-1.7976931348623157E+308")
		}
	case []jv.Value:
		for i, x := range c {
			c[i] = reread(x)
		}
	case *jv.Map:
		for _, k := range c.Keys() {
			x, _ := c.Get(k)
			c.Set(k, reread(x))
		}
	}
	return v
}

// Forget drops a path, so the next Get reads it again.
func (c *Cache) Forget(path string) { delete(c.files, path) }
