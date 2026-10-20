package udiff

import (
	"bytes"
	"fmt"
	"math/rand"
	"os"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/udiff/udifftest"
)

func TestGolden(t *testing.T) {
	for _, c := range []struct{ name, a, b, want string }{
		{"equal", "x\n", "x\n", ""},
		{"from empty", "", "x\ny\n", "@@ -0,0 +1,2 @@\n+x\n+y\n"},
		{"to empty", "x\n", "", "@@ -1 +0,0 @@\n-x\n"},
		{"newline added", "x", "x\n", "@@ -1 +1 @@\n-x\n\\ No newline at end of file\n+x\n"},
		{"newline dropped", "a\nx\n", "a\nx", "@@ -1,2 +1,2 @@\n a\n-x\n+x\n\\ No newline at end of file\n"},
		{"both lack it", "a\nb", "c\nb", "@@ -1,2 +1,2 @@\n-a\n+c\n b\n\\ No newline at end of file\n"},
		{"insert at end", "1\n2\n3\n4\n5\n", "1\n2\n3\n4\n5\n6\n", "@@ -3,3 +3,4 @@\n 3\n 4\n 5\n+6\n"},
		{"gap of six merges", "a\n1\n2\n3\n4\n5\n6\nb\n", "A\n1\n2\n3\n4\n5\n6\nB\n",
			"@@ -1,8 +1,8 @@\n-a\n+A\n 1\n 2\n 3\n 4\n 5\n 6\n-b\n+B\n"},
		{"gap of seven splits", "a\n1\n2\n3\n4\n5\n6\n7\nb\n", "A\n1\n2\n3\n4\n5\n6\n7\nB\n",
			"@@ -1,4 +1,4 @@\n-a\n+A\n 1\n 2\n 3\n@@ -6,4 +6,4 @@\n 5\n 6\n 7\n-b\n+B\n"},
		{"crlf", "a\r\nb\r\n", "a\r\nc\r\n", "@@ -1,2 +1,2 @@\n a\r\n-b\r\n+c\r\n"},
	} {
		got := string(Unified("a/f", "b/f", []byte(c.a), []byte(c.b)))
		want := ""
		if c.want != "" {
			want = "--- a/f\n+++ b/f\n" + c.want
		}
		if got != want {
			t.Errorf("%s:\n%q\nwant\n%q", c.name, got, want)
		}
	}
}

// --- The corpus ---------------------------------------------------------------

var vocabs = [][]string{
	{"a", "b", "c", "", "}", "  - x"},
	{"services:", "  web:", "    image: nginx", "    restart: unless-stopped", "", "# comment",
		"networks:", "  kasbah-net:", "    external: true", "      - default"},
	{"x\x00y", "\xff\xfe\x80", "caf\xc3\xa9", "\t", " ", "\\ No newline at end of file", "--- a/f", "@@ -1 +1 @@", "-", "+"},
}

func line(r *rand.Rand, v []string) string {
	switch r.Intn(40) {
	case 0:
		return strings.Repeat("long-", 1000+r.Intn(4000))
	case 1:
		return "u" + strconv.Itoa(r.Int())
	case 2:
		return string([]byte{byte(r.Intn(256)), byte(r.Intn(256)), 0, byte(r.Intn(256))})
	}
	return v[r.Intn(len(v))]
}

// sample is one randomised pair: b is a mutated a, or now and then unrelated.
func sample(r *rand.Rand) (a, b []byte) {
	v := vocabs[r.Intn(len(vocabs))]
	if r.Intn(4) == 0 {
		v = append(append([]string{}, v...), vocabs[r.Intn(len(vocabs))]...)
	}
	eol := []string{"\n", "\r\n", ""}[r.Intn(3)] // "" mixes per line
	term := func() string {
		if eol != "" {
			return eol
		}
		return []string{"\n", "\r\n"}[r.Intn(2)]
	}
	n := r.Intn(40)
	if r.Intn(10) == 0 {
		n = r.Intn(300)
	}
	if r.Intn(15) == 0 {
		n = 0
	}
	la := make([]string, n)
	for i := range la {
		la[i] = line(r, v) + term()
	}
	lb := append([]string{}, la...)
	if r.Intn(12) == 0 {
		lb = make([]string, r.Intn(40))
		for i := range lb {
			lb[i] = line(r, v) + term()
		}
	}
	for k := 1 + r.Intn(6); k > 0; k-- {
		p := r.Intn(len(lb) + 1)
		q := min(len(lb), p+1+r.Intn(4))
		switch r.Intn(7) {
		case 0, 1: // insert
			var ins []string
			for j := r.Intn(4) + 1; j > 0; j-- {
				ins = append(ins, line(r, v)+term())
			}
			lb = append(lb[:p], append(ins, lb[p:]...)...)
		case 2: // delete
			lb = append(lb[:p], lb[q:]...)
		case 3: // replace
			for j := p; j < q; j++ {
				lb[j] = line(r, v) + term()
			}
		case 4: // move a block
			blk := append([]string{}, lb[p:q]...)
			lb = append(lb[:p], lb[q:]...)
			to := r.Intn(len(lb) + 1)
			lb = append(lb[:to], append(blk, lb[to:]...)...)
		case 5: // duplicate a line
			if p < len(lb) {
				lb = append(lb[:p+1], lb[p:]...)
			}
		case 6: // blank lines
			lb = append(lb[:p], append([]string{term(), term()}, lb[p:]...)...)
		}
	}
	join := func(l []string, strip bool) []byte {
		s := strings.Join(l, "")
		if strip {
			s = strings.TrimSuffix(s, "\n")
		}
		return []byte(s)
	}
	return join(la, r.Intn(5) == 0), join(lb, r.Intn(5) == 0)
}

// edges are the shapes worth naming, beside the random ones.
var edges = [][2]string{
	{"", ""}, {"", "x"}, {"x", ""}, {"", "\n"}, {"\n", ""}, {"x", "x\n"}, {"x\n", "x"},
	{"x", "y"}, {"a\nx", "a\ny"}, {"\n\n\n", "\n\n"}, {"a\r\n", "a\n"}, {"a\r", "a"},
	{"\x00", "\x00\n"}, {"a\nb\nc\n", "c\nb\na\n"}, {"x\nx\nx\nx\n", "x\nx\n"},
	{strings.Repeat("l\n", 50), strings.Repeat("l\n", 50) + "end"},
}

// --- Proofs -------------------------------------------------------------------

// apply is a strict reader of the diff: every hunk at the place its header
// names, counts exact, context full unless at a file's edge, hunks apart.
func apply(a, d []byte) ([]byte, error) {
	la := split(a)
	ls := strings.SplitAfter(string(d), "\n")
	if len(ls) < 3 || ls[0] != "--- a/f\n" || ls[1] != "+++ b/f\n" || ls[len(ls)-1] != "" {
		return nil, fmt.Errorf("bad header or no final newline")
	}
	hdr := regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@\n$`)
	num := func(s string, def int) int {
		if s == "" {
			return def
		}
		n, _ := strconv.Atoi(s)
		return n
	}
	var out []string
	pos, i, lastChangeEnd := 0, 2, -1
	for i < len(ls)-1 {
		m := hdr.FindStringSubmatch(ls[i])
		if m == nil {
			return nil, fmt.Errorf("line %d: not a hunk header: %q", i, ls[i])
		}
		an, bn := num(m[2], 1), num(m[4], 1)
		as, bs := num(m[1], 0)-1, num(m[3], 0)-1
		if an == 0 {
			as++
		}
		if bn == 0 {
			bs++
		}
		if as < pos || as > len(la) {
			return nil, fmt.Errorf("hunk at %d overlaps or is out of range", as)
		}
		out = append(out, la[pos:as]...)
		pos = as
		if len(out) != bs {
			return nil, fmt.Errorf("hunk names +%d, output is at %d", bs+1, len(out))
		}
		i++
		var kinds []byte
		ga, gb := 0, 0
		for ga < an || gb < bn {
			if i >= len(ls)-1 || ls[i] == "" {
				return nil, fmt.Errorf("hunk short")
			}
			k, text := ls[i][0], ls[i][1:]
			i++
			if i < len(ls)-1 && ls[i] == "\\ No newline at end of file\n" {
				text = strings.TrimSuffix(text, "\n")
				i++
			}
			switch k {
			case ' ', '-':
				if pos >= len(la) || la[pos] != text {
					return nil, fmt.Errorf("line %d does not match: %q", pos+1, text)
				}
				if k == ' ' {
					out = append(out, text)
					gb++
				}
				pos++
				ga++
			case '+':
				out = append(out, text)
				gb++
			default:
				return nil, fmt.Errorf("bad line %q", ls[i-1])
			}
			kinds = append(kinds, k)
		}
		if ga != an || gb != bn {
			return nil, fmt.Errorf("counts %d,%d against header %d,%d", ga, gb, an, bn)
		}
		lead := bytes.IndexAny(kinds, "-+")
		trail := len(kinds) - 1 - bytes.LastIndexAny(kinds, "-+")
		if lead < 0 || lead > context || trail > context ||
			(lead < context && as != 0) || (trail < context && pos != len(la)) ||
			bytes.Contains(kinds, bytes.Repeat([]byte{' '}, 2*context+1)) {
			return nil, fmt.Errorf("hunk context %q", kinds)
		}
		if lastChangeEnd >= 0 && as+lead-lastChangeEnd <= 2*context {
			return nil, fmt.Errorf("hunks %d lines apart should have merged", as+lead-lastChangeEnd)
		}
		lastChangeEnd = pos - trail
	}
	out = append(out, la[pos:]...)
	return []byte(strings.Join(out, "")), nil
}

// shortest is the size of a shortest edit script, by the textbook LCS table.
func shortest(a, b []byte) int {
	la, lb := split(a), split(b)
	prev, cur := make([]int, len(lb)+1), make([]int, len(lb)+1)
	for i := range la {
		for j := range lb {
			if la[i] == lb[j] {
				cur[j+1] = prev[j] + 1
			} else {
				cur[j+1] = max(prev[j+1], cur[j])
			}
		}
		prev, cur = cur, prev
	}
	return len(la) + len(lb) - 2*prev[len(lb)]
}

// Every diff of the corpus reads back to b under the strict reader, and is a
// shortest edit script.
func TestCorpus(t *testing.T) {
	r := rand.New(rand.NewSource(1))
	n := 20000
	check := func(a, b []byte) {
		t.Helper()
		d := Unified("a/f", "b/f", a, b)
		if d == nil {
			if !bytes.Equal(a, b) {
				t.Fatalf("no diff for %q → %q", a, b)
			}
			return
		}
		got, err := apply(a, d)
		if err != nil || !bytes.Equal(got, b) {
			t.Fatalf("%v\na: %q\nb: %q\ndiff:\n%s\ngot: %q", err, a, b, d, got)
		}
		if c, s := udifftest.Count(d), shortest(a, b); c != s {
			t.Fatalf("%d changed lines, the shortest script has %d\na: %q\nb: %q\n%s", c, s, a, b, d)
		}
	}
	for _, e := range edges {
		check([]byte(e[0]), []byte(e[1]))
	}
	for range n {
		check(sample(r))
	}
}

// Past the cost cap the script may grow, but it still reads back exactly.
func TestCostCap(t *testing.T) {
	r := rand.New(rand.NewSource(4))
	for _, c := range []int{1, 2, 3} {
		costCap = c
		cut := 0
		for range 5000 {
			a, b := sample(r)
			if bytes.Equal(a, b) {
				continue
			}
			d := Unified("a/f", "b/f", a, b)
			if got, err := apply(a, d); err != nil || !bytes.Equal(got, b) {
				costCap = 0
				t.Fatalf("cap %d: %v\na: %q\nb: %q\ndiff:\n%s", c, err, a, b, d)
			}
			if udifftest.Count(d) > shortest(a, b) {
				cut++
			}
		}
		t.Logf("cap %d: %d of 5000 scripts longer than the shortest, all exact", c, cut)
		if cut == 0 {
			t.Errorf("cap %d never cut a search short", c)
		}
	}
	costCap = 0
}

// Every diff of the corpus is applied by GNU patch exactly, and is never
// larger than GNU diff's own.
func TestGNURoundTrip(t *testing.T) {
	if !udifftest.GNU(t) {
		t.Skip("GNU patch/diff not on PATH — tests/udiff_test.sh runs this on the host")
	}
	n := 10000
	if s := os.Getenv("KASBAH_UDIFF_CORPUS"); s != "" {
		var err error
		if n, err = strconv.Atoi(s); err != nil || n < 1 {
			t.Fatalf("KASBAH_UDIFF_CORPUS=%q is not a positive count", s)
		}
	}
	r := rand.New(rand.NewSource(2))
	var cases [][2][]byte
	for _, e := range edges {
		cases = append(cases, [2][]byte{[]byte(e[0]), []byte(e[1])})
	}
	for range n {
		a, b := sample(r)
		cases = append(cases, [2][]byte{a, b})
	}
	same, fewer, identical, patched := 0, 0, 0, 0
	var savings []int
	for _, c := range cases {
		a, b := c[0], c[1]
		d := Unified("a", "b", a, b)
		gnu := udifftest.Diff(t, a, b)
		if bytes.Equal(d, gnu) {
			identical++
		}
		if d == nil {
			if len(gnu) != 0 {
				t.Fatalf("no diff, GNU found one:\n%s", gnu)
			}
			continue
		}
		if got := udifftest.Patch(t, a, d); !bytes.Equal(got, b) {
			t.Fatalf("patch result differs\na: %q\nb: %q\ndiff:\n%s\ngot: %q", a, b, d, got)
		}
		patched++
		switch g, w := udifftest.Count(d), udifftest.Count(gnu); {
		case g == w:
			same++
		case g < w:
			fewer++
			savings = append(savings, w-g)
		default:
			t.Errorf("%d changed lines, GNU diff has %d\na: %q\nb: %q\nours:\n%s\nGNU:\n%s", g, w, a, b, d, gnu)
		}
	}
	sort.Ints(savings)
	t.Logf("corpus %d: patch round trips %d, all exact; changed lines equal to GNU %d, fewer %d (by %v), more 0; byte-identical to GNU %d",
		len(cases), patched, same, fewer, savings, identical)
}

// --- Cost -----------------------------------------------------------------------

func lines(n int, f func(i int) string) []byte {
	var b strings.Builder
	for i := range n {
		b.WriteString(f(i) + "\n")
	}
	return []byte(b.String())
}

func TestCost(t *testing.T) {
	r := rand.New(rand.NewSource(3))
	base := lines(10000, func(i int) string { return fmt.Sprintf("line %d: %d", i, r.Intn(50)) })
	edited := strings.Split(string(base), "\n")
	for range 200 {
		p := r.Intn(len(edited))
		switch r.Intn(3) {
		case 0:
			edited[p] = "changed"
		case 1:
			edited = append(edited[:p], edited[p+1:]...)
		default:
			edited = append(edited[:p], append([]string{"added"}, edited[p:]...)...)
		}
	}
	tiny := func(int) string { return []string{"a", "b"}[r.Intn(2)] }
	for _, c := range []struct {
		name  string
		a, b  []byte
		limit time.Duration
	}{
		{"10k lines, 200 scattered edits", base, []byte(strings.Join(edited, "\n")), time.Second},
		{"10k lines against 10k unrelated", base, lines(10000, func(i int) string { return "other " + strconv.Itoa(i) }), time.Second},
		{"10k lines of two values each", lines(10000, tiny), lines(10000, tiny), 5 * time.Second},
		{"50k lines of two values each", lines(50000, tiny), lines(50000, tiny), 20 * time.Second},
	} {
		start := time.Now()
		d := Unified("a/f", "b/f", c.a, c.b)
		took := time.Since(start)
		if got, err := apply(c.a, d); err != nil || !bytes.Equal(got, c.b) {
			t.Fatalf("%s: does not read back: %v", c.name, err)
		}
		t.Logf("%s: %v, %d changed lines", c.name, took, udifftest.Count(d))
		if took > c.limit {
			t.Errorf("%s: %v, over %v", c.name, took, c.limit)
		}
	}
}
