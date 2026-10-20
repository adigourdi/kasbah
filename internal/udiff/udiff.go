// Package udiff writes unified diffs of line-oriented text, in the shape GNU
// `diff -u --label A --label B` prints and GNU `patch` applies.
package udiff

import (
	"bytes"
	"strconv"
)

// context is the number of unchanged lines around each change, diff -u's.
const context = 3

// Unified is the unified diff turning a into b under the two labels, or nil
// when they are equal. Lines are split on \n and compared with it, so a last
// line without one differs from the same text with one, as in GNU diff.
func Unified(labelA, labelB string, a, b []byte) []byte {
	if bytes.Equal(a, b) {
		return nil
	}
	la, lb := split(a), split(b)
	ops := script(la, lb)

	var out bytes.Buffer
	out.WriteString("--- " + labelA + "\n+++ " + labelB + "\n")
	for lo := 0; lo < len(ops); {
		first := next(ops, lo)
		if first < 0 {
			break
		}
		// A hunk runs until the unchanged gap to the next change is wider
		// than the two contexts it would need.
		last := first
		for {
			n := next(ops, last+1)
			if n < 0 || n-last-1 > 2*context {
				break
			}
			last = n
		}
		start := max(first-context, lo)
		end := min(last+1+context, len(ops))
		hunk(&out, ops[start:end], la, lb)
		lo = end
	}
	return out.Bytes()
}

// op is one step of the edit script: kind is ' ', '-' or '+', at line ai of
// a and bj of b (the line a '+' goes before, for a; likewise for '-').
type op struct {
	kind   byte
	ai, bj int
}

// next is the index of the first change at or after i, or -1.
func next(ops []op, i int) int {
	for ; i < len(ops); i++ {
		if ops[i].kind != ' ' {
			return i
		}
	}
	return -1
}

func hunk(out *bytes.Buffer, ops []op, la, lb []string) {
	na, nb := 0, 0
	for _, o := range ops {
		if o.kind != '+' {
			na++
		}
		if o.kind != '-' {
			nb++
		}
	}
	out.WriteString("@@ -" + rng(ops[0].ai, na) + " +" + rng(ops[0].bj, nb) + " @@\n")
	for _, o := range ops {
		line := ""
		if o.kind == '+' {
			line = lb[o.bj]
		} else {
			line = la[o.ai]
		}
		out.WriteByte(o.kind)
		out.WriteString(line)
		if len(line) == 0 || line[len(line)-1] != '\n' {
			out.WriteString("\n\\ No newline at end of file\n")
		}
	}
}

// rng is GNU's range: an empty one names the line before it, one line has no
// count.
func rng(start, n int) string {
	switch n {
	case 0:
		return strconv.Itoa(start) + ",0"
	case 1:
		return strconv.Itoa(start + 1)
	}
	return strconv.Itoa(start+1) + "," + strconv.Itoa(n)
}

// split keeps each line's \n; only the last line can lack one.
func split(s []byte) []string {
	var l []string
	for len(s) > 0 {
		i := bytes.IndexByte(s, '\n') + 1
		if i == 0 {
			i = len(s)
		}
		l = append(l, string(s[:i]))
		s = s[i:]
	}
	return l
}

// script is the edit script from la to lb, deletions before insertions within
// each change.
func script(la, lb []string) []op {
	del, ins := lcs(la, lb)
	ops := make([]op, 0, len(la)+len(lb))
	i, j := 0, 0
	for i < len(la) || j < len(lb) {
		switch {
		case i < len(la) && del[i]:
			ops = append(ops, op{'-', i, j})
			i++
		case j < len(lb) && ins[j]:
			ops = append(ops, op{'+', i, j})
			j++
		default:
			ops = append(ops, op{' ', i, j})
			i++
			j++
		}
	}
	return ops
}

// lcs marks the lines a shortest edit script deletes and inserts. A line with
// no equal on the other side can never match, so it is marked up front and
// Myers runs on the rest, which keeps two unrelated files linear.
func lcs(la, lb []string) (del, ins []bool) {
	id := map[string]int{}
	inA := map[int]bool{}
	ia := make([]int, len(la))
	for i, s := range la {
		n, ok := id[s]
		if !ok {
			n = len(id)
			id[s] = n
		}
		ia[i] = n
		inA[n] = true
	}
	inB := map[int]bool{}
	ib := make([]int, len(lb))
	for j, s := range lb {
		n, ok := id[s]
		if !ok {
			n = len(id)
			id[s] = n
		}
		ib[j] = n
		inB[n] = true
	}

	del, ins = make([]bool, len(la)), make([]bool, len(lb))
	var xs, ys, xmap, ymap []int
	for i, n := range ia {
		if inB[n] {
			xs, xmap = append(xs, n), append(xmap, i)
		} else {
			del[i] = true
		}
	}
	for j, n := range ib {
		if inA[n] {
			ys, ymap = append(ys, n), append(ymap, j)
		} else {
			ins[j] = true
		}
	}
	m := newMyers(xs, ys)
	m.compare(0, len(xs), 0, len(ys))
	for i, d := range m.del {
		if d {
			del[xmap[i]] = true
		}
	}
	for j, d := range m.ins {
		if d {
			ins[ymap[j]] = true
		}
	}
	return del, ins
}

// myers is the linear-space O(ND) algorithm after GNU diffseq.h. Past
// tooExpensive steps a split takes the furthest-reaching diagonal instead:
// bounded cost, at the price of a script that may not be the shortest.
type myers struct {
	x, y         []int
	del, ins     []bool
	fd, bd       []int
	off          int
	tooExpensive int
}

// costCap replaces the computed bound when set; the tests use it to drive
// the cut-off path through small inputs.
var costCap int

func newMyers(x, y []int) *myers {
	n := len(x) + len(y) + 3
	te := 1
	for d := n; d != 0; d >>= 2 {
		te <<= 1
	}
	te = max(4096, te)
	if costCap > 0 {
		te = costCap
	}
	return &myers{x: x, y: y, del: make([]bool, len(x)), ins: make([]bool, len(y)),
		fd: make([]int, n), bd: make([]int, n), off: len(y) + 1, tooExpensive: te}
}

func (m *myers) compare(xoff, xlim, yoff, ylim int) {
	for xoff < xlim && yoff < ylim && m.x[xoff] == m.y[yoff] {
		xoff++
		yoff++
	}
	for xlim > xoff && ylim > yoff && m.x[xlim-1] == m.y[ylim-1] {
		xlim--
		ylim--
	}
	switch {
	case xoff == xlim:
		for j := yoff; j < ylim; j++ {
			m.ins[j] = true
		}
	case yoff == ylim:
		for i := xoff; i < xlim; i++ {
			m.del[i] = true
		}
	default:
		xmid, ymid := m.diag(xoff, xlim, yoff, ylim)
		if xmid+ymid <= xoff+yoff || xmid+ymid >= xlim+ylim {
			// No progress: replace the region whole rather than loop.
			for i := xoff; i < xlim; i++ {
				m.del[i] = true
			}
			for j := yoff; j < ylim; j++ {
				m.ins[j] = true
			}
			return
		}
		m.compare(xoff, xmid, yoff, ymid)
		m.compare(xmid, xlim, ymid, ylim)
	}
}

// diag finds the midpoint of a shortest edit path through the region, as an
// (x, y) on it; fd and bd are indexed by diagonal x-y, shifted by off.
func (m *myers) diag(xoff, xlim, yoff, ylim int) (int, int) {
	const huge = int(^uint(0) >> 1)
	fd, bd, o := m.fd, m.bd, m.off
	dmin, dmax := xoff-ylim, xlim-yoff
	fmid, bmid := xoff-yoff, xlim-ylim
	fmin, fmax, bmin, bmax := fmid, fmid, bmid, bmid
	odd := (fmid-bmid)&1 != 0
	fd[o+fmid] = xoff
	bd[o+bmid] = xlim
	for c := 1; ; c++ {
		if fmin > dmin {
			fmin--
			fd[o+fmin-1] = -1
		} else {
			fmin++
		}
		if fmax < dmax {
			fmax++
			fd[o+fmax+1] = -1
		} else {
			fmax--
		}
		for d := fmax; d >= fmin; d -= 2 {
			tlo, thi := fd[o+d-1], fd[o+d+1]
			x := thi
			if tlo >= thi {
				x = tlo + 1
			}
			y := x - d
			for x < xlim && y < ylim && m.x[x] == m.y[y] {
				x++
				y++
			}
			fd[o+d] = x
			if odd && bmin <= d && d <= bmax && bd[o+d] <= x {
				return x, y
			}
		}

		if bmin > dmin {
			bmin--
			bd[o+bmin-1] = huge
		} else {
			bmin++
		}
		if bmax < dmax {
			bmax++
			bd[o+bmax+1] = huge
		} else {
			bmax--
		}
		for d := bmax; d >= bmin; d -= 2 {
			tlo, thi := bd[o+d-1], bd[o+d+1]
			x := thi - 1
			if tlo < thi {
				x = tlo
			}
			y := x - d
			for xoff < x && yoff < y && m.x[x-1] == m.y[y-1] {
				x--
				y--
			}
			bd[o+d] = x
			if !odd && fmin <= d && d <= fmax && x <= fd[o+d] {
				return x, y
			}
		}

		if c >= m.tooExpensive {
			fxy, fx := -1, 0
			for d := fmax; d >= fmin; d -= 2 {
				x := min(fd[o+d], xlim)
				y := x - d
				if ylim < y {
					x, y = ylim+d, ylim
				}
				if fxy < x+y {
					fxy, fx = x+y, x
				}
			}
			bxy, bx := huge, 0
			for d := bmax; d >= bmin; d -= 2 {
				x := max(xoff, bd[o+d])
				y := x - d
				if y < yoff {
					x, y = yoff+d, yoff
				}
				if x+y < bxy {
					bxy, bx = x+y, x
				}
			}
			if (xlim+ylim)-bxy < fxy-(xoff+yoff) {
				return fx, fxy - fx
			}
			return bx, bxy - bx
		}
	}
}
