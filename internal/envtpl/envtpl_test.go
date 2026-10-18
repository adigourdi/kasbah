package envtpl

import (
	"os"
	"path/filepath"
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
