package envtpl

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestLines(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want []string
	}{
		{"", nil},
		{"\n", []string{""}},
		{"a\nb", []string{"a", "b"}},
		{"a\r\nb\r\n", []string{"a", "b"}},
		{"a\r\r\n", []string{"a\r"}},
		{"A=1\x00B\n", []string{"A=1B"}},
	} {
		if got := Lines([]byte(tc.in)); !slices.Equal(got, tc.want) {
			t.Errorf("Lines(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}

func TestAssign(t *testing.T) {
	for _, tc := range []struct {
		line, key, val string
		ok             bool
	}{
		{"FOO=bar", "FOO", "bar", true},
		{"export FOO=1", "FOO", "1", true},
		{"  \tBAR=a=b # c", "BAR", "a=b # c", true},
		// What `docker compose config` reads (compose-go's dotenv parser).
		{"A = 1", "A", "1", true},
		{"A =1", "A", "1", true},
		{"A= 1", "A", "1", true},
		{"A: 1", "A", "1", true},
		{"A:1", "A", "1", true},
		{"A :1", "A", "1", true},
		{"A\t:\t1", "A", "1", true},
		{"export  A : 1", "A", "1", true},
		{"export\tA=1", "A", "1", true},
		{"A = \"x y\" # c", "A", "\"x y\" # c", true},
		{"A = ", "A", "", true},
		{"A:", "A", "", true},
		{"A==1", "A", "=1", true},
		{"A=:1", "A", ":1", true},
		{"A:=1", "A", "=1", true},
		{"A : b : c", "A", "b : c", true},
		{"A\v=\f1", "A", "1", true},
		{"A\u0085=1", "A", "1", true},
		{"\u00a0NB=\u00a01", "NB", "1", true}, // no-break spaces too
		{"\u2007NB=1", "NB", "1", true},
		{" EM=1", "EM", "1", true},
		{"export=1", "export", "1", true},
		{"exportA=1", "exportA", "1", true},
		// Refused by compose, or read with a key kasbah does not take: none.
		{"A\u2007=1", "", "", false},
		{"FOO BAR=baz", "", "", false},
		{"A/B=1", "", "", false},
		{"export =1", "", "", false}, // compose's key is ""
		{"export\u00a0A=1", "", "", false},
		{"A-B=1", "", "", false},
		{"A.B=1", "", "", false},
		{"=v", "", "", false},
		{"1FOO=x", "", "", false},
		{"A", "", "", false},
		{"K=\xff", "", "", false}, // nor matches across a bad byte
		{"_a=", "_a", "", true},
	} {
		k, v, ok := Assign(tc.line)
		if k != tc.key || v != tc.val || ok != tc.ok {
			t.Errorf("Assign(%q) = %q, %q, %v; want %q, %q, %v", tc.line, k, v, ok, tc.key, tc.val, tc.ok)
		}
	}
	if !Blank(" \t") || Blank(" x") || !Comment("  # x") || Comment("x#") ||
		!Blank("\u00a0") || !Blank("\u2007\u202f\u0085") || !Comment("\u00a0#c") || !Comment("\u202f#x") || Comment("\u00a0x#") {
		t.Error("Blank/Comment misread")
	}
	if Len("é") != 1 || Len("\xff") != 1 {
		t.Error("Len counts characters, a bad byte as one")
	}
}

func write(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestKeysAndDrift(t *testing.T) {
	dir := t.TempDir()
	tpl := write(t, dir, "tpl", "# c\nexport DB_HOST=x\nAPPLE=1\nAPP_KEY=! gen\nKASBAH_CPU_LIMIT=1\nAPPLE=2\nbad line\n")
	env := write(t, dir, "env", "DB_HOST=y\r\nEXTRA=1\r\nKASBAH_MEM_LIMIT=2g\r\n")
	if got, want := Keys(tpl), []string{"DB_HOST", "APPLE", "APP_KEY", "KASBAH_CPU_LIMIT", "APPLE"}; !slices.Equal(got, want) {
		t.Errorf("Keys = %q, want %q", got, want)
	}
	if Keys(filepath.Join(dir, "absent")) != nil || Keys(dir) != nil {
		t.Error("an absent path or a directory has keys")
	}
	// Byte order in every locale; KASBAH_* is invisible in both directions.
	missing, extra := Drift(tpl, env)
	if want := []string{"APPLE", "APP_KEY"}; !slices.Equal(missing, want) {
		t.Errorf("missing = %q, want %q", missing, want)
	}
	if want := []string{"EXTRA"}; !slices.Equal(extra, want) {
		t.Errorf("extra = %q, want %q", extra, want)
	}
	if m, e := Drift(tpl, tpl); m != nil || e != nil {
		t.Errorf("a template drifts from itself: %q %q", m, e)
	}
}

// The values `docker compose config` reads back from the same .env.
func TestValuesOf(t *testing.T) {
	vals, err := ValuesOf([]byte("A= 8081 # dev\r\nB=\"80\\\"8$$2\" # x\nC='$x' trailing\nD=$$y\nE=${A}0\nF=a#b\nG=a\t#tab\nexport H=1\nQ=\"8082\"\nBAD=${NOPE:?unset}\nI=${BAD:-9}\n# A=1\n"))
	want := map[string]string{"A": "8081", "B": `80"8$2`, "C": "$x", "D": "$y", "E": "80810", "F": "a#b", "G": "a\t#tab", "H": "1", "Q": "8082", "I": "9"}
	if !reflect.DeepEqual(vals, want) {
		t.Errorf("values: %q", vals)
	}
	if err == nil || err.Error() != "line 10 (BAD): required variable NOPE is missing a value: unset" {
		t.Errorf("err: %v", err)
	}
}

func TestValuesOfUnreadLine(t *testing.T) {
	for _, in := range []string{"WEB.PORT=8080\n", "WEB_PORT\u2007= 8080\n", "A=\"line1\nline2\n"} {
		if _, err := ValuesOf([]byte("OK=1\n" + in)); err == nil {
			t.Errorf("%q: no error for a line kasbah cannot read", in)
		}
	}
	if vals, err := ValuesOf([]byte("\n  \n# c\n  # c\n\u00a0\n\u00a0# c\nA=1\nB = 2 # c\nC: '3'\nD=4\u00a0\n")); err != nil || !reflect.DeepEqual(vals, map[string]string{"A": "1", "B": "2", "C": "3", "D": "4"}) {
		t.Errorf("blank, comment and compose's other forms: %q %v", vals, err)
	}
}

func TestInterpolate(t *testing.T) {
	env := map[string]string{"R": "8080", "E": ""}
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }
	for in, want := range map[string]string{
		"plain": "plain", "$R:80": "8080:80", "${R}:80": "8080:80", "$$R": "$R", "a$": "a$", "$-": "$-",
		"${X:-${R}}": "8080", "${X:-${Y:-7}}0": "70", "${E:-1}": "1", "${E-1}": "", "${X-1}": "1",
		"${R:?msg}": "8080", "${E?msg}": "", "${R:+9000}": "9000", "${E:+9000}": "", "${E+9000}": "9000", "${X+1}": "",
	} {
		if got, err := Interpolate(in, lookup); err != nil || got != want {
			t.Errorf("%q: %q %v, want %q", in, got, err, want)
		}
	}
	for in, want := range map[string]string{
		"${X:?no port}": "required variable X is missing a value: no port",
		"${E:?}":        "required variable E is missing a value: ",
		"${X?${R}}":     "required variable X is missing a value: 8080",
		"${R":           `"${R" has a ${ that is not closed`,
		"${}":           "${} names no variable",
		"${R:3}":        "${R:3} is not an interpolation compose knows",
	} {
		if _, err := Interpolate(in, lookup); err == nil || err.Error() != want {
			t.Errorf("%q: %v, want %q", in, err, want)
		}
	}
}

// What `docker compose config` (compose v5.6.1) read from each .env, every
// case measured: the value it gave V (and B), or its refusal of the file
// (refused: ValuesOf errs and sets no V). One deliberate difference: text
// after a closing quote that compose reads as another assignment is refused.
func TestValuesOfAsCompose(t *testing.T) {
	const refused = "\x00refused"
	for _, tc := range []struct{ name, env, v, b string }{
		{"sq escaped quote", `V='a\'b'`, `a'b`, ""},
		{"sq two backslashes", `V='a\\b'`, `a\\b`, ""},
		{"sq trailing backslash", `V='a\'`, refused, ""},
		{"sq trailing two backslashes", `V='a\\'`, `a\\`, ""},
		{"sq \\n literal", `V='a\nb'`, `a\nb`, ""},
		{"sq dollars literal", "W=w\nV='a$W b$$c'", `a$W b$$c`, ""},
		{"sq text after the escaped quote", `V='a\'b'c'`, refused, ""},
		{"dq escaped quote", `V="a\"b"`, `a"b`, ""},
		{"dq two backslashes", `V="a\\b"`, `a\b`, ""},
		{"dq trailing backslash", `V="a\"`, refused, ""},
		{"dq trailing two backslashes", `V="a\\"`, `a\`, ""},
		{"dq backslash then escaped quote", `V="a\\\"b"`, `a\"b`, ""},
		{"dq \\n", `V="a\nb"`, "a\nb", ""},
		{"dq \\t", `V="a\tb"`, "a\tb", ""},
		{"dq \\r", `V="a\rb"`, "a\rb", ""},
		{"dq unknown escapes kept", `V="a\qb\'c"`, `a\qb\'c`, ""},
		{"dq \\$", "W=w\nV=\"a\\$W\"", `a$W`, ""},
		{"dq $$", "W=w\nV=\"a$$W\"", `a$W`, ""},
		{"dq interpolation", "W=w\nV=\"a${W}b$W\"", `awbw`, ""},
		{"dq \\${}", "W=w\nV=\"a\\${W}\"", `a${W}`, ""},
		{"dq \\\\ then $W", "W=w\nV=\"a\\\\$W\"", `a\w`, ""},
		{"dq \\\\n", `V="a\\nb"`, `a\nb`, ""},
		{"dq octal and the rest", `V="a\0101b\012c\0d\c\x41\u00e9\U00e9"`, `aAb\12c\d\c\x41\u00e9\U00e9`, ""},
		{"dq \\a \\b \\f \\v \\0", `V="a\a\b\f\v\0"`, "a\a\b\f\v\\", ""},
		{"dq span", "V=\"a\nb\"\nB=y", "a\nb", "y"},
		{"dq span, comment after", "V=\"a\nb\" # c\nB=y", "a\nb", "y"},
		{"dq span with escapes", "V=\"a\\n\nb\\\"c\"\nB=y", "a\n\nb\"c", "y"},
		{"dq span, backslash at a line end", "V=\"a\\\nb\"\nB=y", "a\\\nb", "y"},
		{"dq span interpolated", "W=w\nV=\"a$W\n$$b\"\nB=y", "aw\n$b", "y"},
		{"dq span holding KEY= lines", "V=\"-----BEGIN\nX=1\n-----END\"\nB=y", "-----BEGIN\nX=1\n-----END", "y"},
		{"dq span, no final newline", "V=\"a\nb\"", "a\nb", ""},
		{"sq span", "V='a\nb'\nB=y", "a\nb", "y"},
		{"sq span, escaped quote", "V='a\\\nb\\'c'\nB=y", "a\\\nb'c", "y"},
		{"dq never closed", "B=y\nV=\"a\nb", refused, "y"},
		{"sq never closed", "B=y\nV='a", refused, "y"},
		{"comment after the quote", "V=\"a\" #c\nB=y", "a", "y"},
		{"comment glued to the quote", "V=\"a\"#c\nB=y", "a", "y"},
		{"bare name after the quote", "V=\"a\" junk\nB=y", "a", "y"},
		{"sq bare name glued", "V='a'x\nB=y", "a", "y"},
		{"assignment after the quote", "V=\"a\" C=z", refused, ""},
		{"crlf bare", "V=a\r\nB=y\r", "a", "y"},
		{"crlf dq", "V=\"a\"\r\nB=y\r", "a", "y"},
		{"crlf sq", "V='a'\r\nB=y\r", "a", "y"},
		{"crlf dq span keeps the CR", "V=\"a\r\nb\"\r\nB=y\r", "a\r\nb", "y"},
		{"crlf sq span keeps the CR", "V='a\r\nb'\r\nB=y\r", "a\r\nb", "y"},
		{"quote inside a bare value", "V=a\"b\nB=y", `a"b`, "y"},
		{"empty dq", "V=\"\"\nB=y", "", "y"},
		{"blank before the quote", "V= \"a\"\nB=y", "a", "y"},
		{"sq inside dq", `V="it's"`, "it's", ""},
		{"dq inside sq", `V='say "hi"'`, `say "hi"`, ""},
	} {
		vals, err := ValuesOf([]byte(tc.env + "\n"))
		v, ok := vals["V"]
		switch {
		case tc.v == refused && (err == nil || ok):
			t.Errorf("%s: compose refuses %q, kasbah read V=%q (err %v)", tc.name, tc.env, v, err)
		case tc.v != refused && (err != nil || !ok || v != tc.v):
			t.Errorf("%s: %q read V=%q (err %v), compose reads %q", tc.name, tc.env, v, err, tc.v)
		case tc.b != "" && vals["B"] != tc.b:
			t.Errorf("%s: B=%q, compose reads %q", tc.name, vals["B"], tc.b)
		}
	}
}

func TestEntries(t *testing.T) {
	lines := RawLines([]byte("A=1\nPEM=\"-----BEGIN\r\nX=1\n-----END\" # k\nexport B='x\nC=2\n#'\nD=\"never\nE=3\n"))
	type e struct {
		line, end int
		key       string
	}
	var got []e
	for _, en := range Entries(lines) {
		got = append(got, e{en.Line, en.End, en.Key})
	}
	want := []e{{0, 1, "A"}, {1, 4, "PEM"}, {4, 7, "B"}, {7, 8, "D"}, {8, 9, "E"}}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("Entries = %v, want %v", got, want)
	}
	if got := KeysOf([]byte("A=1\nPEM=\"-----BEGIN\nX=1\n-----END\"\nB=2\n")); !slices.Equal(got, []string{"A", "PEM", "B"}) {
		t.Errorf("KeysOf reads a span's lines as keys: %q", got)
	}
	if c := Continued(lines); !slices.Equal(c, []bool{false, false, true, true, false, true, true, false, false}) {
		t.Errorf("Continued = %v", c)
	}
}

// A span folded to one line reads as compose reads the span.
func TestOneLine(t *testing.T) {
	for _, in := range []string{
		"V=\"a\nb\"", "V=\"a\\\nb\"", "V=\"a\r\nb\" # c", "V=\"$W\n$$x\\$y\\\"z\\\\\"", "V=\"\\0\n12\"",
		"V='a\nb'", "V='a\\'\n\"$W\\\\'", "V='a\r\nb' junk", "V=\"-----BEGIN\nX=1\n-----END\"",
	} {
		data := []byte("W=w\n" + in + "\n")
		lines := RawLines(data)
		ents := Entries(lines)
		folded := ents[1].OneLine(lines)
		if strings.ContainsAny(folded, "\r\n") {
			t.Errorf("%q folds to %q, not one line", in, folded)
		}
		want, err := ValuesOf(data)
		got, err2 := ValuesOf([]byte("W=w\n" + folded + "\n"))
		if err != nil || err2 != nil || got["V"] != want["V"] {
			t.Errorf("%q folds to %q: V=%q (%v), the span reads %q (%v)", in, folded, got["V"], err2, want["V"], err)
		}
	}
}

// compose ends a statement at the closing quote whatever key opened it.
func TestEntriesUnderComposeKeys(t *testing.T) {
	for _, in := range []string{
		"APP.KEY=\"a\nKASBAH_CPU_LIMIT=9\nV=x\n\"\nB=1\n",
		"a-b[0]: 'a\nV=x\n'\nB=1\n",
		"V=\"\xff\nW=1\n\"\nB=1\n",
	} {
		lines := RawLines([]byte(in))
		es := Entries(lines)
		if got := KeysOf([]byte(in)); !slices.Equal(got, []string{"B"}) || len(es) != 2 || es[0].Key != "" || !es[0].Span() {
			t.Errorf("%q: keys %q, entries %+v", in, got, es)
		}
		if err := Refused(lines); err == nil || !strings.Contains(err.Error(), "line 1:") {
			t.Errorf("%q: refused %v", in, err)
		}
		if got := Folded([]byte(in)); len(got) != 2 {
			t.Errorf("%q: folded %q", in, got)
		}
	}
	// A key compose refuses opens nothing, and the file is refused at it.
	for _, in := range []string{"A B=\"x\nC=1\n\"\n", "A\xffB=\"x\nC=1\n\"\n", "export A\u2007=\"x\nC=1\n\"\n", "Z=1\nmy key: \"x\nC=1\n\"\n"} {
		lines := RawLines([]byte(in))
		if got := KeysOf([]byte(in)); !slices.Contains(got, "C") {
			t.Errorf("%q: %q", in, got)
		}
		err := Refused(lines)
		if err == nil || !strings.Contains(err.Error(), ": a key compose refuses") || strings.Contains(err.Error(), "x") {
			t.Errorf("%q: refused %v", in, err)
		}
	}
	// compose refuses a bare line it cannot take as a key, as it does a key.
	for _, in := range []string{"A=1\nno equals sign\n", "A=1\na/b\n"} {
		if err := Refused(RawLines([]byte(in))); err == nil {
			t.Errorf("%q: not refused", in)
		}
	}
	// A bad byte in the value, a bare key, a tab inside a key: compose reads them.
	for _, in := range []string{"V=\xff\n", "A=1\nNOEQ\n", "U=http://x:1\n", "A\tB=1\n"} {
		if err := Refused(RawLines([]byte(in))); err != nil {
			t.Errorf("%q: %v", in, err)
		}
	}
}

func TestRefused(t *testing.T) {
	for in, want := range map[string]string{
		"A=1\nPEM=\"-----BEGIN\nbody\n":  `line 2 (PEM): the double quote is not closed`,
		"V=\"a\" C=z\n":                  `line 1 (V): text follows the closing double quote, which compose reads as another assignment`,
		"K='x\ny' B=2\n":                 `line 1 (K): text follows the closing single quote`,
		"APP.KEY=\"open\n":               `line 1: the double quote is not closed`,
		"A=\"x\" # c\nB='y' name\nC=1\n": "",
	} {
		err := Refused(RawLines([]byte(in)))
		if want == "" && err != nil || want != "" && (err == nil || !strings.HasPrefix(err.Error(), want)) {
			t.Errorf("%q: %v, want %q", in, err, want)
		}
		if err != nil && (strings.Contains(err.Error(), "BEGIN") || strings.Contains(err.Error(), "C=z")) {
			t.Errorf("%q: a value in %v", in, err)
		}
	}
}

// A quote that never closes is scanned once, not once per line after it.
func TestEntriesLinear(t *testing.T) {
	in := []byte("A=\"x\n" + strings.Repeat("B=1\n", 16<<10))
	start := time.Now()
	if keys := KeysOf(in); len(keys) != 1+16<<10 {
		t.Fatalf("%d keys", len(keys))
	}
	if d := time.Since(start); d > time.Second {
		t.Errorf("KeysOf over %d KiB took %v", len(in)>>10, d)
	}
}

func BenchmarkKeysOfUnclosed(b *testing.B) {
	in := []byte("A=\"x\n" + strings.Repeat("B=1\n", 64<<10/4))
	for b.Loop() {
		KeysOf(in)
	}
}
