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
		{" EM=1", "EM", "1", true}, // glibc counts the em space as space
		{" NB=1", "", "", false},   // and not the no-break one
		{"K=\xff", "", "", false},  // nor matches across a bad byte
		{"export=1", "export", "1", true},
		{"FOO BAR=baz", "", "", false},
		{"=v", "", "", false},
		{"1FOO=x", "", "", false},
		{"_a=", "_a", "", true},
	} {
		k, v, ok := Assign(tc.line)
		if k != tc.key || v != tc.val || ok != tc.ok {
			t.Errorf("Assign(%q) = %q, %q, %v; want %q, %q, %v", tc.line, k, v, ok, tc.key, tc.val, tc.ok)
		}
	}
	if !Blank(" \t") || Blank(" x") || !Comment("  # x") || Comment("x#") {
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
	for _, in := range []string{"WEB_PORT = 8080\n", "WEB_PORT: 8080\n", "A=\"line1\nline2\"\n"} {
		if _, err := ValuesOf([]byte("OK=1\n" + in)); err == nil {
			t.Errorf("%q: no error for a line kasbah cannot read", in)
		}
	}
	if _, err := ValuesOf([]byte("\n  \n# c\n  # c\nA=1\n")); err != nil {
		t.Errorf("blank and comment lines: %v", err)
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
