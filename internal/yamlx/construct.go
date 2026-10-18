package yamlx

import (
	"fmt"
	"math"
	"math/big"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/jv"
	"go.yaml.in/yaml/v3"
)

var sprintf = fmt.Sprintf

// obj is a constructed value as Python holds it, before json.dump and jq.
type obj struct {
	kind  kind
	b     bool
	i     *big.Int
	f     float64
	s     string // str, or a timestamp's isoformat
	items []*obj // list; a pair from !!omap/!!pairs is a two-item list
	keys  []*obj // dict, in first-insertion order
	vals  []*obj
	index map[string]int // dict: Python key identity → position
}

type kind int

const (
	kNone kind = iota
	kBool
	kInt
	kFloat
	kStr
	kTime
	kList
	kDict
)

type builder struct {
	built    map[*yaml.Node]*obj
	building map[*yaml.Node]bool
	pairs    map[*yaml.Node]*[]pair
	nans     int
}

func newBuilder() *builder {
	return &builder{built: map[*yaml.Node]*obj{}, building: map[*yaml.Node]bool{}, pairs: map[*yaml.Node]*[]pair{}}
}

const (
	tagStr       = "!!str"
	tagInt       = "!!int"
	tagFloat     = "!!float"
	tagBool      = "!!bool"
	tagNull      = "!!null"
	tagTimestamp = "!!timestamp"
	tagMap       = "!!map"
	tagSeq       = "!!seq"
	tagOmap      = "!!omap"
	tagPairs     = "!!pairs"
	tagMerge     = "!!merge"
)

func deref(n *yaml.Node) *yaml.Node {
	for n.Kind == yaml.AliasNode {
		n = n.Alias
	}
	return n
}

func explicitTag(n *yaml.Node) string {
	if n.Style&yaml.TaggedStyle != 0 {
		return n.Tag
	}
	return ""
}

func isPlain(n *yaml.Node) bool {
	return n.Style&(yaml.TaggedStyle|yaml.DoubleQuotedStyle|yaml.SingleQuotedStyle|yaml.LiteralStyle|yaml.FoldedStyle) == 0
}

// build constructs a node once, as PyYAML's constructor does: an alias is the
// same object again, and a node reached while it is being built is a cycle.
func (b *builder) build(n *yaml.Node) (*obj, error) {
	if n.Kind == yaml.DocumentNode {
		if len(n.Content) == 0 {
			return &obj{kind: kNone}, nil
		}
		return b.build(n.Content[0])
	}
	n = deref(n)
	if o, ok := b.built[n]; ok {
		return o, nil
	}
	if b.building[n] {
		return nil, refuse("yaml: line %d: found unconstructable recursive node", n.Line)
	}
	b.building[n] = true
	defer delete(b.building, n)
	o, err := b.construct(n)
	if err != nil {
		return nil, err
	}
	b.built[n] = o
	return o, nil
}

func (b *builder) construct(n *yaml.Node) (*obj, error) {
	tag := explicitTag(n)
	switch n.Kind {
	case yaml.ScalarNode:
		switch tag {
		case "":
			if isPlain(n) {
				return b.resolvePlain(n.Value)
			}
			return &obj{kind: kStr, s: n.Value}, nil
		case tagStr:
			return &obj{kind: kStr, s: n.Value}, nil
		case tagNull:
			return &obj{kind: kNone}, nil
		case tagBool:
			// PyYAML's bool_values, looked up lower-cased.
			switch strings.ToLower(n.Value) {
			case "yes", "true", "on":
				return &obj{kind: kBool, b: true}, nil
			case "no", "false", "off":
				return &obj{kind: kBool, b: false}, nil
			}
			return nil, refuse("yaml: line %d: KeyError: %q is not a boolean", n.Line, strings.ToLower(n.Value))
		case tagInt:
			return constructInt(n.Value, n.Line)
		case tagFloat:
			return b.constructFloat(n.Value, n.Line)
		case tagTimestamp:
			return constructTimestamp(n.Value, n.Line)
		case tagMap, tagSeq, tagOmap, tagPairs:
			return nil, refuse("yaml: line %d: %s on a scalar", n.Line, tag)
		}
		// !!binary, !!set, !!merge and every unknown or local tag: yq drops the
		// binary and set constructors, so the node is built by its kind.
		return &obj{kind: kStr, s: n.Value}, nil
	case yaml.SequenceNode:
		switch tag {
		case "", tagSeq:
		case tagOmap, tagPairs:
			return b.constructPairs(n)
		case tagStr, tagInt, tagFloat, tagBool, tagNull, tagTimestamp:
			return nil, refuse("yaml: line %d: expected a scalar node, but found sequence", n.Line)
		case tagMap:
			return nil, refuse("yaml: line %d: expected a mapping node, but found sequence", n.Line)
		}
		o := &obj{kind: kList, items: []*obj{}}
		for _, c := range n.Content {
			item, err := b.build(c)
			if err != nil {
				return nil, err
			}
			o.items = append(o.items, item)
		}
		return o, nil
	case yaml.MappingNode:
		switch tag {
		case tagStr, tagInt, tagFloat, tagBool, tagNull, tagTimestamp:
			return nil, refuse("yaml: line %d: expected a scalar node, but found mapping", n.Line)
		case tagSeq, tagOmap, tagPairs:
			return nil, refuse("yaml: line %d: expected a sequence node, but found mapping", n.Line)
		}
		return b.constructMapping(n)
	}
	return nil, refuse("yaml: line %d: unexpected node", n.Line)
}

type pair struct{ k, v *yaml.Node }

func isMergeKey(k *yaml.Node) bool {
	k = deref(k)
	if k.Kind != yaml.ScalarNode {
		return false
	}
	if t := explicitTag(k); t != "" {
		return t == tagMerge
	}
	return isPlain(k) && k.Value == "<<"
}

// pairsOf is a mapping's pair list as flatten has left it so far.
func (b *builder) pairsOf(n *yaml.Node) *[]pair {
	if ps, ok := b.pairs[n]; ok {
		return ps
	}
	ps := make([]pair, 0, len(n.Content)/2)
	for i := 0; i+1 < len(n.Content); i += 2 {
		ps = append(ps, pair{n.Content[i], n.Content[i+1]})
	}
	b.pairs[n] = &ps
	return &ps
}

// flatten is PyYAML's flatten_mapping, mutation included: a merge key is
// removed before its source is flattened (so `<<: *self` ends), and merged
// pairs go in front, a list of sources in reverse order.
func (b *builder) flatten(n *yaml.Node) error {
	ps := b.pairsOf(n)
	var merge []pair
	for i := 0; i < len(*ps); {
		k, v := (*ps)[i].k, (*ps)[i].v
		if !isMergeKey(k) {
			i++
			continue
		}
		*ps = append((*ps)[:i:i], (*ps)[i+1:]...)
		v = deref(v)
		switch v.Kind {
		case yaml.MappingNode:
			if err := b.flatten(v); err != nil {
				return err
			}
			merge = append(merge, *b.pairsOf(v)...)
		case yaml.SequenceNode:
			var subs [][]pair
			for _, s := range v.Content {
				s = deref(s)
				if s.Kind != yaml.MappingNode {
					return refuse("yaml: line %d: expected a mapping for merging, but found %s", s.Line, kindName(s))
				}
				if err := b.flatten(s); err != nil {
					return err
				}
				subs = append(subs, *b.pairsOf(s))
			}
			for j := len(subs) - 1; j >= 0; j-- {
				merge = append(merge, subs[j]...)
			}
		default:
			return refuse("yaml: line %d: expected a mapping or list of mappings for merging, but found %s", v.Line, kindName(v))
		}
	}
	if len(merge) > 0 {
		*ps = append(merge, *ps...)
	}
	return nil
}

func kindName(n *yaml.Node) string {
	switch n.Kind {
	case yaml.ScalarNode:
		return "scalar"
	case yaml.SequenceNode:
		return "sequence"
	}
	return "mapping"
}

func (b *builder) constructMapping(n *yaml.Node) (*obj, error) {
	if err := b.flatten(n); err != nil {
		return nil, err
	}
	o := &obj{kind: kDict, index: map[string]int{}}
	for _, p := range *b.pairsOf(n) {
		k, err := b.build(p.k)
		if err != nil {
			return nil, err
		}
		v, err := b.build(p.v)
		if err != nil {
			return nil, err
		}
		id, err := b.hashKey(k)
		if err != nil {
			return nil, refuse("yaml: line %d: %v", p.k.Line, err)
		}
		if i, ok := o.index[id]; ok {
			o.vals[i] = v
			continue
		}
		o.index[id] = len(o.keys)
		o.keys = append(o.keys, k)
		o.vals = append(o.vals, v)
	}
	return o, nil
}

// constructPairs is construct_yaml_omap / construct_yaml_pairs: a sequence of
// one-pair mappings, kept as [key, value] lists.
func (b *builder) constructPairs(n *yaml.Node) (*obj, error) {
	o := &obj{kind: kList, items: []*obj{}}
	for _, c := range n.Content {
		c = deref(c)
		if c.Kind != yaml.MappingNode || len(*b.pairsOf(c)) != 1 {
			return nil, refuse("yaml: line %d: expected a single mapping item for an ordered map", c.Line)
		}
		p := (*b.pairsOf(c))[0]
		k, err := b.build(p.k)
		if err != nil {
			return nil, err
		}
		v, err := b.build(p.v)
		if err != nil {
			return nil, err
		}
		o.items = append(o.items, &obj{kind: kList, items: []*obj{k, v}})
	}
	return o, nil
}

// hashKey is a Python dict key's identity: 1, 1.0 and True are one key.
func (b *builder) hashKey(k *obj) (string, error) {
	switch k.kind {
	case kNone:
		return "n", nil
	case kStr:
		return "s" + k.s, nil
	case kTime:
		return "t" + k.s, nil
	case kBool:
		if k.b {
			return "i1", nil
		}
		return "i0", nil
	case kInt:
		return "i" + k.i.String(), nil
	case kFloat:
		switch {
		case math.IsNaN(k.f):
			b.nans++
			return "nan" + strconv.Itoa(b.nans), nil
		case math.IsInf(k.f, 0):
			return "f" + strconv.FormatFloat(k.f, 'g', -1, 64), nil
		case k.f == math.Trunc(k.f):
			i, _ := big.NewFloat(k.f).Int(nil)
			return "i" + i.String(), nil
		}
		return "f" + strconv.FormatFloat(k.f, 'g', -1, 64), nil
	case kList:
		return "", fmt.Errorf("TypeError: unhashable type: 'list'")
	}
	return "", fmt.Errorf("TypeError: unhashable type: 'dict'")
}

// --- plain scalars: yq's YAML 1.2 core resolvers -------------------------------

var (
	reBool  = regexp.MustCompile(`^(?:true|True|TRUE|false|False|FALSE)$`)
	reInt   = regexp.MustCompile(`^(?:0o[0-7]+|[-+]?[0-9]+|0x[0-9a-fA-F]+)$`)
	reFloat = regexp.MustCompile(`^(?:[-+]?(?:\.[0-9]+|[0-9]+(?:\.[0-9]*)?)(?:[eE][-+]?[0-9]+)?|[-+]?\.(?:inf|Inf|INF)|\.(?:nan|NaN|NAN))$`)
	reNull  = regexp.MustCompile(`^(?:~|null|Null|NULL)$`)
)

func (b *builder) resolvePlain(v string) (*obj, error) {
	if v == "" {
		return &obj{kind: kNone}, nil
	}
	switch c := v[0]; {
	case c == 't' || c == 'T' || c == 'f' || c == 'F':
		if reBool.MatchString(v) {
			return &obj{kind: kBool, b: v[0] == 't' || v[0] == 'T'}, nil
		}
	case c == '-' || c == '+' || (c >= '0' && c <= '9') || c == '.':
		if c != '.' && reInt.MatchString(v) {
			return constructInt(v, 0)
		}
		if reFloat.MatchString(v) {
			return b.constructFloat(v, 0)
		}
	case c == '~' || c == 'n' || c == 'N':
		if reNull.MatchString(v) {
			return &obj{kind: kNone}, nil
		}
	}
	return &obj{kind: kStr, s: v}, nil
}

// constructInt is PyYAML's construct_yaml_int, over Python's int().
func constructInt(value string, line int) (*obj, error) {
	bad := func() (*obj, error) {
		return nil, refuse("yaml: line %d: ValueError: invalid literal for int(): %q", line, value)
	}
	v := strings.ReplaceAll(value, "_", "")
	if v == "" {
		return bad()
	}
	neg := v[0] == '-'
	if v[0] == '-' || v[0] == '+' {
		v = v[1:]
	}
	var i *big.Int
	var ok bool
	switch {
	case v == "0":
		i, ok = big.NewInt(0), true
	case strings.HasPrefix(v, "0b"):
		i, ok = pyInt(v[2:], 2)
	case strings.HasPrefix(v, "0x"):
		i, ok = pyInt(v[2:], 16)
	case strings.HasPrefix(v, "0"):
		// A leading zero is octal, the 1.1 rule the 1.2 resolver still feeds:
		// `0755` is 493, and `09` does not convert at all.
		i, ok = pyInt(v, 8)
	case strings.Contains(v, ":"):
		i, ok = big.NewInt(0), true
		base := big.NewInt(1)
		parts := strings.Split(v, ":")
		for j := len(parts) - 1; j >= 0; j-- {
			d, dok := pyInt(parts[j], 10)
			if !dok {
				return bad()
			}
			i.Add(i, d.Mul(d, base))
			base = new(big.Int).Mul(base, big.NewInt(60))
		}
	default:
		i, ok = pyInt(v, 10)
	}
	if !ok {
		return bad()
	}
	if neg {
		i.Neg(i)
	}
	return &obj{kind: kInt, i: i}, nil
}

// pyInt is Python's int(s, base): surrounding whitespace, a sign, and the
// base's own prefix are allowed.
func pyInt(s string, base int) (*big.Int, bool) {
	s = strings.TrimSpace(s)
	neg := false
	if s != "" && (s[0] == '-' || s[0] == '+') {
		neg = s[0] == '-'
		s = s[1:]
	}
	if len(s) > 2 && s[0] == '0' {
		p := s[1] | 0x20
		if (base == 16 && p == 'x') || (base == 8 && p == 'o') || (base == 2 && p == 'b') {
			s = s[2:]
		}
	}
	if s == "" || s[0] == '+' || s[0] == '-' {
		return nil, false
	}
	i, ok := new(big.Int).SetString(s, base)
	if ok && neg {
		i.Neg(i)
	}
	return i, ok
}

// constructFloat is PyYAML's construct_yaml_float, over Python's float().
func (b *builder) constructFloat(value string, line int) (*obj, error) {
	v := strings.ToLower(strings.ReplaceAll(value, "_", ""))
	bad := func() (*obj, error) {
		return nil, refuse("yaml: line %d: ValueError: could not convert string to float: %q", line, value)
	}
	if v == "" {
		return bad()
	}
	sign := 1.0
	if v[0] == '-' {
		sign = -1
	}
	if v[0] == '-' || v[0] == '+' {
		v = v[1:]
	}
	switch {
	case v == ".inf":
		return &obj{kind: kFloat, f: sign * math.Inf(1)}, nil
	case v == ".nan":
		return &obj{kind: kFloat, f: math.NaN()}, nil
	case strings.Contains(v, ":"):
		parts := strings.Split(v, ":")
		f, base := 0.0, 1.0
		for j := len(parts) - 1; j >= 0; j-- {
			d, ok := pyFloat(parts[j])
			if !ok {
				return bad()
			}
			f += d * base
			base *= 60
		}
		return &obj{kind: kFloat, f: sign * f}, nil
	}
	f, ok := pyFloat(v)
	if !ok {
		return bad()
	}
	return &obj{kind: kFloat, f: sign * f}, nil
}

func pyFloat(s string) (float64, bool) {
	s = strings.TrimSpace(s)
	if s == "" || strings.ContainsAny(s, "xXpP_") {
		return 0, false
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil {
		if ne, ok := err.(*strconv.NumError); ok && ne.Err == strconv.ErrRange {
			return f, true
		}
		return 0, false
	}
	return f, true
}

var reTimestamp = regexp.MustCompile(`^([0-9]{4})-([0-9]{1,2})-([0-9]{1,2})` +
	`(?:(?:[Tt]|[ \t]+)([0-9]{1,2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]*))?` +
	`(?:[ \t]*(Z|([-+])([0-9]{1,2})(?::([0-9]{2}))?))?)?$`)

// constructTimestamp is PyYAML's construct_yaml_timestamp, rendered as the
// isoformat() yq's JSON encoder writes for it.
func constructTimestamp(value string, line int) (*obj, error) {
	m := reTimestamp.FindStringSubmatch(value)
	if m == nil {
		return nil, refuse("yaml: line %d: not a timestamp: %q", line, value)
	}
	atoi := func(s string) int { i, _ := strconv.Atoi(s); return i }
	year, month, day := atoi(m[1]), atoi(m[2]), atoi(m[3])
	if month < 1 || month > 12 || year < 1 || day < 1 || day > daysIn(year, month) {
		return nil, refuse("yaml: line %d: ValueError: date out of range: %q", line, value)
	}
	date := fmt.Sprintf("%04d-%02d-%02d", year, month, day)
	if m[4] == "" {
		return &obj{kind: kTime, s: date}, nil
	}
	hour, minute, second := atoi(m[4]), atoi(m[5]), atoi(m[6])
	if hour > 23 || minute > 59 || second > 59 {
		return nil, refuse("yaml: line %d: ValueError: time out of range: %q", line, value)
	}
	s := fmt.Sprintf("%sT%02d:%02d:%02d", date, hour, minute, second)
	if frac := m[7]; frac != "" {
		if len(frac) > 6 {
			frac = frac[:6]
		}
		if us := atoi(frac + strings.Repeat("0", 6-len(frac))); us != 0 {
			s += fmt.Sprintf(".%06d", us)
		}
	}
	switch {
	case m[9] != "":
		off := time.Duration(atoi(m[10]))*time.Hour + time.Duration(atoi(m[11]))*time.Minute
		if off >= 24*time.Hour {
			return nil, refuse("yaml: line %d: ValueError: offset out of range: %q", line, value)
		}
		sign := "+"
		if m[9] == "-" && off != 0 {
			sign = "-"
		}
		s += fmt.Sprintf("%s%02d:%02d", sign, int(off.Hours()), int(off.Minutes())%60)
	case m[8] != "":
		s += "+00:00"
	}
	return &obj{kind: kTime, s: s}, nil
}

func daysIn(year, month int) int {
	return time.Date(year, time.Month(month)+1, 0, 0, 0, 0, 0, time.UTC).Day()
}

// --- Python → JSON → jq ------------------------------------------------------

// value is json.dump followed by jq's re-reading: NaN becomes null, an
// infinity the largest double, a float Python's repr in jq's spelling, a key
// its json.dump string with jq keeping a repeated one's last value.
func (o *obj) value(memo map[*obj]jv.Value) (jv.Value, error) {
	if v, ok := memo[o]; ok {
		return v, nil
	}
	var v jv.Value
	switch o.kind {
	case kNone:
		v = nil
	case kBool:
		v = o.b
	case kInt:
		v = jv.Number(o.i.String())
	case kFloat:
		switch {
		case math.IsNaN(o.f):
			v = nil
		case math.IsInf(o.f, 1):
			v = jv.Number("1.7976931348623157e+308")
		case math.IsInf(o.f, -1):
			v = jv.Number("-1.7976931348623157e+308")
		default:
			v = jv.Number(jv.CanonNumber(pyRepr(o.f)))
		}
	case kStr, kTime:
		v = o.s
	case kList:
		arr := make([]jv.Value, 0, len(o.items))
		for _, it := range o.items {
			e, err := it.value(memo)
			if err != nil {
				return nil, err
			}
			arr = append(arr, e)
		}
		v = arr
	case kDict:
		m := jv.NewMap()
		for i, k := range o.keys {
			ks, err := k.jsonKey()
			if err != nil {
				return nil, err
			}
			e, err := o.vals[i].value(memo)
			if err != nil {
				return nil, err
			}
			m.Set(ks, e)
		}
		v = m
	}
	memo[o] = v
	return v, nil
}

func (o *obj) jsonKey() (string, error) {
	switch o.kind {
	case kStr:
		return o.s, nil
	case kNone:
		return "null", nil
	case kBool:
		return strconv.FormatBool(o.b), nil
	case kInt:
		return o.i.String(), nil
	case kFloat:
		switch {
		case math.IsNaN(o.f):
			return "NaN", nil
		case math.IsInf(o.f, 1):
			return "Infinity", nil
		case math.IsInf(o.f, -1):
			return "-Infinity", nil
		}
		return pyRepr(o.f), nil
	}
	return "", refuse("yaml: TypeError: keys must be str, int, float, bool or None")
}

// pyRepr is Python's repr() of a float: the shortest round-tripping digits,
// positional while the decimal point sits in (-4, 16], exponent otherwise.
func pyRepr(f float64) string {
	e := strconv.FormatFloat(f, 'e', -1, 64)
	neg := strings.HasPrefix(e, "-")
	e = strings.TrimPrefix(e, "-")
	mant, exps, _ := strings.Cut(e, "e")
	exp, _ := strconv.Atoi(exps)
	digits := strings.Replace(mant, ".", "", 1)
	decpt := exp + 1
	var s string
	switch {
	case decpt > -4 && decpt <= 16:
		switch {
		case decpt <= 0:
			s = "0." + strings.Repeat("0", -decpt) + digits
		case decpt >= len(digits):
			s = digits + strings.Repeat("0", decpt-len(digits)) + ".0"
		default:
			s = digits[:decpt] + "." + digits[decpt:]
		}
	default:
		s = digits[:1]
		if len(digits) > 1 {
			s += "." + digits[1:]
		}
		x := decpt - 1
		sign := "+"
		if x < 0 {
			sign, x = "-", -x
		}
		s += fmt.Sprintf("e%s%02d", sign, x)
	}
	if neg {
		s = "-" + s
	}
	return s
}

// pySize is the length of json.dumps(o) with yq's encoder: `, ` and `: `
// separators, non-ASCII escaped. Shared objects are counted once and the
// result saturates, so an alias bomb is measured without being expanded.
func pySize(o *obj, memo map[*obj]int) int {
	if n, ok := memo[o]; ok {
		return n
	}
	const ceiling = 1 << 50
	n := 0
	switch o.kind {
	case kNone, kBool:
		n = 4
		if o.kind == kBool && !o.b {
			n = 5
		}
	case kInt:
		n = len(o.i.String())
	case kFloat:
		switch {
		case math.IsNaN(o.f):
			n = 3
		case math.IsInf(o.f, 1):
			n = 8
		case math.IsInf(o.f, -1):
			n = 9
		default:
			n = len(pyRepr(o.f))
		}
	case kStr, kTime:
		n = pyStrSize(o.s)
	case kList:
		n = 2
		for i, it := range o.items {
			if i > 0 {
				n += 2
			}
			n = min(n+pySize(it, memo), ceiling)
		}
	case kDict:
		n = 2
		for i, k := range o.keys {
			if i > 0 {
				n += 2
			}
			ks, _ := k.jsonKey()
			n = min(n+pyStrSize(ks)+2+pySize(o.vals[i], memo), ceiling)
		}
	}
	memo[o] = n
	return n
}

func pyStrSize(s string) int {
	n := 2
	for _, r := range s {
		switch {
		case r == '"' || r == '\\' || r == '\n' || r == '\r' || r == '\t' || r == '\b' || r == '\f':
			n += 2
		case r < 0x20 || (r > 0x7f && r <= 0xffff):
			n += 6
		case r > 0xffff:
			n += 12
		default:
			n++
		}
	}
	return n
}

// depth is how far jq's depth count reaches inside a container: each array
// it opens through adds one, each object two (jv.DepthLimit).
func depth(o *obj, memo map[*obj]int) int {
	if d, ok := memo[o]; ok {
		return d
	}
	step, kids := 1, o.items
	if o.kind == kDict {
		step, kids = 2, o.vals
	}
	d := 0
	for _, c := range kids {
		if c.kind == kList || c.kind == kDict {
			d = max(d, step+depth(c, memo))
		}
	}
	memo[o] = d
	return d
}
