package env

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/envtpl"
)

// A hand-written quoted span: its lines look like keys and a sentinel.
const span = "TLS_KEY=\"-----BEGIN KEY-----\r\nKASBAH_CPU_LIMIT=9\r\n" + ManagedBegin + "\r\nAPI_SECRET=x\r\n-----END KEY-----\" # k\r\n"

func TestInjectKeepsSpans(t *testing.T) {
	p := t.TempDir() + "/.env"
	write(t, p, "A=1\n"+span+"KASBAH_STRAY='a\nb'\nZ=2\n")
	if rc := Inject(p, []string{"KASBAH_CPU_LIMIT=1"}, &bytes.Buffer{}); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	want := "A=1\n" + span + "Z=2\n" + ManagedBegin + "\nKASBAH_CPU_LIMIT=1\n" + ManagedEnd + "\n"
	if got := readFile(t, p); got != want {
		t.Fatalf("got %q, want %q", got, want)
	}
	if rc := Inject(p, []string{"KASBAH_CPU_LIMIT=2"}, &bytes.Buffer{}); rc != 0 || readFile(t, p) != strings.Replace(want, "LIMIT=1", "LIMIT=2", 1) {
		t.Errorf("re-inject: %d %q", rc, readFile(t, p))
	}
	if cpu, mem, ok := ManagedLimits(p); !ok || cpu != "2" || mem != "" {
		t.Errorf("ManagedLimits: %q %q %v", cpu, mem, ok)
	}
}

func TestManagedLimitsIgnoresSpans(t *testing.T) {
	p := t.TempDir() + "/.env"
	write(t, p, "PEM='\n"+ManagedBegin+"\nKASBAH_CPU_LIMIT=9\n"+ManagedEnd+"\n'\n")
	if cpu, mem, ok := ManagedLimits(p); !ok || cpu != "" || mem != "" {
		t.Errorf("a span's text read as the managed block: %q %q", cpu, mem)
	}
}

func TestMergeEnvSpans(t *testing.T) {
	cur := "A=new\n" + span + "B=keep\n"
	old := "A='old\nX=1'\nTLS_KEY=v\n"
	got := strings.Join(MergeEnv([]byte(cur), []byte(old), []string{"A", "TLS_KEY"}), "\n")
	if want := "A=\"old\\nX=1\"\nTLS_KEY=v\nB=keep"; got != want {
		t.Errorf("got %q, want %q", got, want)
	}
	got = strings.Join(MergeEnv([]byte(cur), []byte(old), []string{"B"}), "\n")
	if want := "A=new\n" + strings.TrimSuffix(span, "\n"); got != want {
		t.Errorf("an unmerged span moved: %q", got)
	}
	if c, o, l := EnvDiff([]byte(span), []byte(span)); c != nil || o != nil || l != nil {
		t.Errorf("a span differs from itself: %q %q %q", c, o, l)
	}
}

func TestParseSeedSpan(t *testing.T) {
	vals, err := ParseSeed([]byte("A=1\n" + span + "B='x\ny'\n"))
	if err != nil || len(vals) != 3 || vals["B"] != `"x\ny"` || strings.ContainsAny(vals["TLS_KEY"], "\r\n") {
		t.Fatalf("%q %v", vals, err)
	}
	back, err := envtpl.ValuesOf([]byte("TLS_KEY=" + vals["TLS_KEY"] + "\n"))
	if want, _ := envtpl.ValuesOf([]byte(span)); err != nil || back["TLS_KEY"] != want["TLS_KEY"] {
		t.Errorf("seed value reads %q, the span %q", back["TLS_KEY"], want["TLS_KEY"])
	}
}

// The setup keeps a span's value, on one line, and never asks for its lines.
func TestSetupFoldsSpans(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "A=\nTLS_KEY=\nNEW=\n")
	write(t, dir+"/.env", "A=1\n"+span)
	if rc := runSetup(t, dir, "\nv\n"); rc != 0 {
		t.Fatalf("rc %d", rc)
	}
	got := readFile(t, dir+"/.env")
	vals, err := envtpl.ValuesOf([]byte(got))
	want, _ := envtpl.ValuesOf([]byte(span))
	if err != nil || vals["TLS_KEY"] != want["TLS_KEY"] || vals["NEW"] != "v" || len(envtpl.RawLines([]byte(got))) != 3 {
		t.Errorf(".env %q: %q %v", got, vals, err)
	}
}

// Injection refuses a .env kasbah cannot read as compose does, naming the
// line and key, never a value, and leaves it byte for byte.
func TestInjectRefusesUnreadable(t *testing.T) {
	for in, want := range map[string]string{
		"APP.KEY=\"a\nKASBAH_CPU_LIMIT=9\n\"\n":                                             "line 1: a quoted value over several lines",
		"V=\"\xff\nKASBAH_MEM_LIMIT=1g\n\"\n":                                               "line 1: a quoted value over several lines",
		"KASBAH_X=\"open\nA=1\nB=\"b\"\n":                                                   "line 1 (KASBAH_X): text follows the closing double quote",
		"KASBAH_MEM_LIMIT=\"1\nSECRET=s\" B=2\nZ=1\n":                                       "line 1 (KASBAH_MEM_LIMIT): text follows the closing double quote",
		"A=1\nPEM=\"s3cr3t\n" + ManagedBegin + "\nKASBAH_CPU_LIMIT=1\n" + ManagedEnd + "\n": "line 2 (PEM): the double quote is not closed",
		"A B=1\n": "line 1: a key compose refuses",
	} {
		p := t.TempDir() + "/.env"
		write(t, p, in)
		var errb bytes.Buffer
		if rc := Inject(p, []string{"KASBAH_CPU_LIMIT=1"}, &errb); rc != 1 || !strings.Contains(errb.String(), want) {
			t.Errorf("%q: rc %d %s", in, rc, errb.String())
		}
		if strings.Contains(errb.String(), "s3cr3t") || strings.Contains(errb.String(), "SECRET") {
			t.Errorf("%q: a value in %s", in, errb.String())
		}
		if got := readFile(t, p); got != in {
			t.Errorf("%q: rewritten %q", in, got)
		}
	}
}

func setupSaid(t *testing.T, dir, input string) (int, string, string) {
	t.Helper()
	in := filepath.Join(t.TempDir(), "stdin")
	write(t, in, input)
	f, err := os.Open(in)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out, errb bytes.Buffer
	rc := (&Setup{Dir: dir, In: f, Out: &out, Err: &errb}).Run()
	return rc, out.String(), errb.String()
}

// The setup refuses, before any prompt, a .env or template it cannot read
// as compose does, naming line and key, never a value.
func TestSetupRefusesUnreadable(t *testing.T) {
	for _, c := range []struct{ tmpl, env, want string }{
		{"A=\nPEM=\n", "A=1\nPEM=\"-----BEGIN\nMIIEsecret\n", ".env line 2 (PEM): the double quote is not closed"},
		{"A=\nPEM=\n", "A=1\nPEM=\"s3cr3t\" C=z\n", ".env line 2 (PEM): text follows the closing double quote"},
		{"A=\nPEM=\"-----BEGIN\nMIIEsecret\n", "A=1\n", ".env.prod.example line 2 (PEM): the double quote is not closed"},
		{"A=\nAPP.KEY=\"x\nMIIEsecret\n\"\n", "", ".env.prod.example line 2: a quoted value over several lines"},
	} {
		dir := t.TempDir()
		write(t, dir+"/.env.prod.example", c.tmpl)
		if c.env != "" {
			write(t, dir+"/.env", c.env)
		}
		rc, out, errs := setupSaid(t, dir, "y\na\nx\ny\n")
		all := out + errs
		if rc != SetupFail || !strings.Contains(errs, c.want) || strings.Contains(all, "secret") || strings.Contains(all, "s3cr3t") {
			t.Errorf("%q / %q: rc %d, said %q", c.tmpl, c.env, rc, all)
		}
		if c.env != "" && readFile(t, dir+"/.env") != c.env {
			t.Errorf("%q: .env rewritten", c.env)
		}
	}
}

// A current value is shown masked, the template's default empty or not.
func TestSetupMasksCurrent(t *testing.T) {
	dir := t.TempDir()
	write(t, dir+"/.env.prod.example", "API_SECRET=\nDB_PASSWORD=# hint\nAPP_KEY=dflt\nNEW=\n")
	write(t, dir+"/.env", "API_SECRET=s3cr3t-1\nDB_PASSWORD=s3cr3t-2\nAPP_KEY=s3cr3t-3\n")
	rc, out, errs := setupSaid(t, dir, "a\n\n\n\nv\n")
	if rc != SetupOK || strings.Contains(out+errs, "s3cr3t") || !strings.Contains(out, "API_SECRET [current: ****]") {
		t.Errorf("rc %d, said %q %q", rc, out, errs)
	}
}

// env set refuses a .env whose quote another assignment follows, and a value
// kasbah could not read back.
func TestSetKeyRefusesUnreadable(t *testing.T) {
	dir := setDir(t, "API_SECRET=\"a\" C=z\n")
	if _, err := SetKey(dir, "API_SECRET", "new"); err == nil || !strings.Contains(err.Error(), "line 1 (API_SECRET): text follows the closing double quote, which compose reads as another assignment") || strings.Contains(err.Error(), "C=z") {
		t.Errorf("%v", err)
	}
	if readFile(t, dir+"/.env") != "API_SECRET=\"a\" C=z\n" {
		t.Error(".env rewritten")
	}
	dir = setDir(t, "API_SECRET=x\n")
	if _, err := SetKey(dir, "API_SECRET", "a\xffb"); err == nil || !strings.Contains(err.Error(), "not UTF-8") {
		t.Errorf("non-UTF-8: %v", err)
	}
}

func TestRestoreRefusesUnreadable(t *testing.T) {
	for _, c := range []struct{ cur, old string }{{"A=\"open\nB=1\n", "A=1\n"}, {"A=1\n", "A=\"x\" B=2\n"}} {
		dir := t.TempDir()
		write(t, dir+"/.env", c.cur)
		if err := RestoreEnv(dir, []byte(c.old), []string{"A"}); err == nil || !strings.Contains(err.Error(), "line 1 (A)") || readFile(t, dir+"/.env") != c.cur {
			t.Errorf("%q / %q: %v", c.cur, c.old, err)
		}
	}
}

func TestParseSeedRefusesUnreadable(t *testing.T) {
	if _, err := ParseSeed([]byte("A=1\nB='open\n")); err == nil || !strings.Contains(err.Error(), "line 2 (B): the single quote is not closed") {
		t.Errorf("%v", err)
	}
}
