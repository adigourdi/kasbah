package envtpl

import (
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"testing"
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
	for _, in := range []string{"WEB.PORT=8080\n", "WEB_PORT\u2007= 8080\n", "A=\"line1\nline2\"\n"} {
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
