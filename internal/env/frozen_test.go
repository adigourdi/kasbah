package env

import (
	"bytes"
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// The engine's case table; its outputs are frozen in testdata/frozen.json.
// -update rewrites the file from this engine.

var update = flag.Bool("update", false, "rewrite testdata/frozen.json")

func frozen(t *testing.T, got map[string]string) {
	t.Helper()
	p := filepath.Join("testdata", "frozen.json")
	if *update {
		old := map[string]string{}
		if b, err := os.ReadFile(p); err == nil {
			json.Unmarshal(b, &old)
		}
		for k, v := range got {
			old[k] = v
		}
		b, _ := json.MarshalIndent(old, "", "  ")
		os.MkdirAll("testdata", 0o755)
		if err := os.WriteFile(p, append(b, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]string{}
	if err := json.Unmarshal(b, &want); err != nil {
		t.Fatal(err)
	}
	for k, v := range got {
		w, ok := want[k]
		if !ok {
			t.Errorf("%s: no frozen output", k)
		} else if v != w {
			t.Errorf("%s:\ngot  %q\nwant %q", k, v, w)
		}
	}
}

// normOut drops the run's directory and orders the removed-key list, which
// bash prints in hash order.
func normOut(s, dir string) string {
	s = strings.ReplaceAll(s, dir, "<dir>")
	lines := strings.Split(s, "\n")
	for i := 0; i < len(lines); {
		j := i
		for j < len(lines) && strings.HasPrefix(lines[j], "      - ") {
			j++
		}
		if j > i {
			slices.Sort(lines[i:j])
			i = j
		} else {
			i++
		}
	}
	return strings.Join(lines, "\n")
}

type setupCase struct {
	name    string
	tmpl    *string
	env     *string
	in      string
	rc      int
	want    *string // the .env expected; nil checks only parity
	absent  bool
	envMode os.FileMode
}

func str(s string) *string { return &s }

const basic = "# --- App ---\nAPP_NAME=myapp\nAPP_PORT=3000\nAPP_DEBUG=false\n"

var setupCases = []setupCase{
	{name: "first run, defaults", tmpl: str(basic), in: "\n\n\n",
		want: str("# --- App ---\nAPP_NAME=myapp\nAPP_PORT=3000\nAPP_DEBUG=false\n")},
	{name: "first run, custom", tmpl: str(basic), in: "app\n8080\ntrue\n",
		want: str("# --- App ---\nAPP_NAME=app\nAPP_PORT=8080\nAPP_DEBUG=true\n")},
	{name: "update only, new var default", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\n"), in: "\n\n",
		want: str("# --- App ---\nAPP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=false\n")},
	{name: "update only, new var typed", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\n"), in: "\nyes\n",
		want: str("# --- App ---\nAPP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=yes\n")},
	{name: "dropped vars removed", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\nOLD=1\nOLDER=2\n"), in: "\n",
		want: str("# --- App ---\nAPP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n")},
	{name: "mixed new and dropped", tmpl: str(basic), env: str("APP_NAME=x\nGONE=1\n"), in: "\n9\n\n"},
	{name: "no drift, declined", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n"), in: "n",
		want: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n")},
	{name: "no drift, Enter declines", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n"), in: "\n"},
	{name: "no drift, reconfigure", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n"), in: "ynew\n\n\n",
		want: str("# --- App ---\nAPP_NAME=new\nAPP_PORT=1\nAPP_DEBUG=t\n")},
	{name: "no drift, EOF at the menu", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n"), in: "", rc: 1,
		want: str("APP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=t\n")},
	{name: "drift, EOF at the menu", tmpl: str(basic), env: str("APP_NAME=x\n"), in: "", rc: 1, want: str("APP_NAME=x\n")},
	{name: "abort with q", tmpl: str(basic), env: str("APP_NAME=x\n"), in: "q", want: str("APP_NAME=x\n")},
	{name: "abort with Q, newline left", tmpl: str(basic), env: str("APP_NAME=x\n"), in: "Q\n", want: str("APP_NAME=x\n")},
	{name: "reconfigure all", tmpl: str(basic), env: str("APP_NAME=x\nAPP_PORT=1\n"), in: "a\n\nz\n",
		want: str("# --- App ---\nAPP_NAME=x\nAPP_PORT=1\nAPP_DEBUG=z\n")},
	{name: "reconfigure all keeps a kept $$", tmpl: str("P=a\nQ=b\nR=! echo g\nS=# h\nT=\n"),
		env: str("P=a$$b\nQ=c$$\nR=$$r\nS=$$s\nT=$$t\nX=1\n"), in: "a\n\n\n\n\n",
		want: str("P=a$$b\nQ=c$$\nR=$$r\nS=$$s\nT=$$t\n")},
	{name: "a typed $ is escaped over a live value", tmpl: str("P=a\n"), env: str("P=a$$b\nX=1\n"), in: "ap$\n",
		want: str("P=p$$\n")},
	{name: "update only keeps $$ as is", tmpl: str("P=a\nQ=\n"), env: str("P=a$$b\n"), in: "\n\n", want: str("P=a$$b\nQ=\n")},
	{name: "a multibyte key at the menu", tmpl: str(basic), env: str("APP_NAME=x\n"), in: "é\n\n"},
	{name: "a blank at the menu", tmpl: str(basic), env: str("APP_NAME=x\n"), in: " \n\n"},
	{name: "structure preserved",
		tmpl: str("# ===== Top =====\n\n# --- DB ---\n# free comment\nDB=pg\n  # indented comment\ngarbage line\n   \nexport EXP=1\n  LEAD=2\n#--- tight ---\n# -- two --\n"),
		in:   "\n\n\n",
		want: str("# ===== Top =====\n\n# --- DB ---\n# free comment\nDB=pg\n  # indented comment\ngarbage line\n   \nEXP=1\nLEAD=2\n#--- tight ---\n# -- two --\n")},
	{name: "hint type", tmpl: str("MAIL_HOST=# Your SMTP host\nMAIL_PASSWORD=# SMTP password\n"), in: "smtp\n\n",
		want: str("MAIL_HOST=smtp\nMAIL_PASSWORD=\n")},
	{name: "hint type, current kept", tmpl: str("MAIL_HOST=# host\nMAIL_KEY=# k\nNEW=\n"), env: str("MAIL_HOST=h\nMAIL_KEY=s3\n"), in: "a\n\n\n\n"},
	{name: "inline comment type", tmpl: str("APP_URL=https://x # Full URL # more\nAPI_KEY=k1 # secret\n"), in: "\n\n",
		want: str("APP_URL=https://x\nAPI_KEY=k1\n")},
	{name: "empty type", tmpl: str("DEBUG_TOKEN=\nOTHER=\n"), env: str("DEBUG_TOKEN=live\n"), in: "a\n\nv\n"},
	{name: "sensitive defaults masked", tmpl: str("DB_PASSWORD=hunter2\nAPP_SECRET=s # c\nAPI_KEY=! echo gen\nPLAIN=p\n"), env: str("DB_PASSWORD=old\nAPI_KEY=k\nX=1\n"), in: "a\n\n\n\n\n"},
	{name: "generator on Enter", tmpl: str("TOKEN=! echo gen-$((1+1))\nOTHER=! printf 'a\\n\\n'\n"), in: "\n\n",
		want: str("TOKEN=gen-2\nOTHER=a\n")},
	{name: "generator typed over", tmpl: str("TOKEN=! echo gen\n"), in: "mine\n", want: str("TOKEN=mine\n")},
	{name: "generator keeps a live value", tmpl: str("TOKEN=! echo gen\nN=\n"), env: str("TOKEN=live\n"), in: "a\n\n\n"},
	{name: "generator that fails", tmpl: str("X=! echo part; false\nY=! false | true\n"), in: "\n\n"},
	{name: "generator that ends the shell", tmpl: str("X=! echo $UNSET_VAR_FOR_TEST\nY=\n"), env: str("Y=1\n"), in: "\n\n", rc: 1,
		want: str("Y=1\n")},
	{name: "generator that exits 3", tmpl: str("A=1\nX=! echo out; exit 3\n"), in: "\n\n", rc: 3, absent: true},
	{name: "generator sees the setup's $1", tmpl: str("X=! echo \"${1:+set}\"\n"), in: "\n"},
	{name: "generator reads the rest of stdin", tmpl: str("PW=! read -r p; echo \"got:$p\"\nNEXT=n\n"), in: "\nsecret\nafter\n",
		want: str("PW=got:secret\nNEXT=after\n")},
	{name: "dollar escaped", tmpl: str("A=x\n"), in: "p$ss$\n", want: str("A=p$$ss$$\n")},
	{name: "CRLF in both files", tmpl: str("# --- S ---\r\nA=1\r\nB=2\r\n"), env: str("A=live\r\n"), in: "\n\n",
		want: str("# --- S ---\nA=live\nB=2\n")},
	{name: "missing template", in: "", rc: 1, absent: true},
	{name: "EOF at a value prompt", tmpl: str("A=1\nB_SECRET=2\nC=3\n"), in: "\n", want: str("A=1\nB_SECRET=2\nC=3\n")},
	{name: "a last answer without a newline", tmpl: str("A=1\nB=2\n"), in: "\nlast", want: str("A=1\nB=last\n")},
	{name: "answers trimmed", tmpl: str("A=1\n"), in: "  x y \t\n", want: str("A=x y\n")},
	{name: "a CR in an answer is dropped", tmpl: str("A=1\nB=2\n"), in: "v\r\n\r\n", want: str("A=v\nB=2\n")},
	{name: "the generator sees KEY, TARGET_DIR, OUTPUT", tmpl: str("GEN=! echo \"$KEY:${OUTPUT#\"$TARGET_DIR\"}:${EXAMPLE#\"$TARGET_DIR\"}\"\n"), in: "\n",
		want: str("GEN=GEN:/.env:/.env.prod.example\n")},
	{name: "an unreadable .env is not a first run", tmpl: str("A=1\n"), env: str("A=live\n"), envMode: 0o200, in: "\n", rc: 1, want: str("A=live\n")},
	{name: "final lines without newline", tmpl: str("A=1\nB=2"), env: str("A=x\nB=y"), in: "n"},
	{name: "final template line without newline", tmpl: str("A=1\nB=2"), in: "\n\n", want: str("A=1\nB=2\n")},
	{name: "reserved keys never prompted", tmpl: str("KASBAH_CPU_LIMIT=1\nA=1\n"), in: "\n", want: str("A=1\n")},
	{name: "reserved keys in .env are not live values", tmpl: str("A=1\n"), env: str("KASBAH_CPU_LIMIT=2\n"), in: "\n", want: str("A=1\n")},
	{name: "the block does not survive a setup", tmpl: str("A=1\n"),
		env: str("A=x\n" + ManagedBegin + "\nKASBAH_CPU_LIMIT=1\n" + ManagedEnd + "\n"), in: "y\n\n",
		want: str("A=x\n")},
	{name: "empty template", tmpl: str(""), in: "", want: str("\n")},
	{name: "comment-only template", tmpl: str("# nothing\n"), in: "", want: str("# nothing\n")},
	{name: "a key twice", tmpl: str("A=1\nA=2\n"), env: str("B=1\n"), in: "\n\n\n"},
	{name: "unicode spaces (R1)", tmpl: str(" A=1\n B=2\n"), in: "\n\n"},
	{name: "invalid UTF-8 line", tmpl: str("A=\xff\nB=1\n"), in: "\n\n"},
	{name: "existing .env with no assignments", tmpl: str("A=1\n"), env: str("# only a comment\n\n"), in: "\n", want: str("A=1\n")},
	{name: "a commented live key", tmpl: str("A=1\n"), env: str("  # A=gone\nA=live\n"), in: "n", want: str("  # A=gone\nA=live\n")},
	{name: "the last assignment wins", tmpl: str("A=1\nB=\n"), env: str("A=one\nexport A=two\n"), in: "\n\n"},
}

func TestSetupFrozen(t *testing.T) {
	got := map[string]string{}
	for _, tc := range setupCases {
		t.Run(tc.name, func(t *testing.T) {
			dir := filepath.Join(t.TempDir(), "go")
			os.Mkdir(dir, 0o755)
			if tc.tmpl != nil {
				write(t, dir+"/.env.prod.example", *tc.tmpl)
			}
			if tc.env != nil {
				write(t, dir+"/.env", *tc.env)
				if tc.envMode != 0 {
					os.Chmod(dir+"/.env", tc.envMode)
				}
			}
			in := filepath.Join(t.TempDir(), "stdin")
			write(t, in, tc.in)
			f, err := os.Open(in)
			if err != nil {
				t.Fatal(err)
			}
			var o bytes.Buffer
			rc := (&Setup{Dir: dir, In: f, Out: &o, Err: &bytes.Buffer{}}).Run()
			f.Close()
			os.Chmod(dir+"/.env", 0o600)
			data, err := os.ReadFile(dir + "/.env")
			if rc != tc.rc {
				t.Errorf("exit %d, want %d", rc, tc.rc)
			}
			if tc.absent && err == nil {
				t.Errorf(".env written: %q", data)
			}
			if tc.want != nil && string(data) != *tc.want {
				t.Errorf(".env = %q, want %q", data, *tc.want)
			}
			b, _ := json.Marshal([]any{rc, err == nil, string(data), normOut(o.String(), dir)})
			got["setup/"+tc.name] = string(b)
		})
	}
	frozen(t, got)
}

func TestDriftFrozen(t *testing.T) {
	cases := []struct {
		name      string
		tmpl, env *string
		envDir    bool
	}{
		{name: "neither"},
		{name: "template only", tmpl: str("A=1\n")},
		{name: "env only", env: str("A=1\n")},
		{name: "in sync, reserved either side", tmpl: str("A=1\nKASBAH_X=1\n"), env: str("A=2\nKASBAH_CPU_LIMIT=1\n")},
		{name: "both directions", tmpl: str("B=1\nA=1\nC=\n"), env: str("export A=1\nD=1\n  E=1\nC=\n")},
		{name: "CRLF and no final newline", tmpl: str("A=1\r\nB=2"), env: str("A=1\r\n")},
		{name: "MY_KASBAH is the user's", tmpl: str("MY_KASBAH_URL=1\n"), env: str("KASBAH_A=1\n")},
		{name: ".env is a directory", tmpl: str("A=1\n"), envDir: true},
		{name: "unicode spaces (R1)", tmpl: str(" A=1\n B=2\nb=1\nB=1\n"), env: str("")},
	}
	got := map[string]string{}
	for _, tc := range cases {
		dir := t.TempDir()
		if tc.tmpl != nil {
			write(t, dir+"/.env.prod.example", *tc.tmpl)
		}
		if tc.env != nil {
			write(t, dir+"/.env", *tc.env)
		}
		if tc.envDir {
			os.Mkdir(dir+"/.env", 0o755)
		}
		out, err := Report(dir)
		b, _ := json.Marshal([]any{err == nil, strings.ReplaceAll(out, dir, "<dir>")})
		got["drift/"+tc.name] = string(b)
	}
	frozen(t, got)
}

func TestInjectFrozen(t *testing.T) {
	pairs := []string{"KASBAH_CPU_LIMIT=14.4", "KASBAH_MEM_LIMIT=54g"}
	block := ManagedBegin + "\nKASBAH_CPU_LIMIT=1\n" + ManagedEnd + "\n"
	cases := []struct {
		name    string
		env     *string
		mode    os.FileMode
		pairs   []string
		symlink bool
	}{
		{name: "no .env yet"},
		{name: "appended", env: str("A=1\n# c\n\n  spaced = odd\n")},
		{name: "rewritten where it stands", env: str("A=1\n" + block + "B=2\n")},
		{name: "two blocks collapse", env: str(block + "A=1\n" + block + "B=2\n")},
		{name: "a begin with no end", env: str("A=1\n" + ManagedBegin + "\nB=2\n")},
		{name: "strays removed, MY_KASBAH kept", env: str("export KASBAH_CPU_LIMIT=9\n  KASBAH_MEM_LIMIT=1\nMY_KASBAH_URL=u\n# KASBAH_X=c\nKASBAH_=e\n")},
		{name: "CRLF sentinels and lines kept", env: str("A=1\r\n" + strings.ReplaceAll(block, "\n", "\r\n") + "B=2\r\n")},
		{name: "no final newline", env: str("A=1")},
		{name: "idempotent input", env: str("A=1\n" + ManagedBegin + "\n" + strings.Join(pairs, "\n") + "\n" + ManagedEnd + "\n")},
		{name: "mode kept", env: str("A=1\n"), mode: 0o640},
		{name: "through a symlink", env: str("A=1\n"), symlink: true},
		{name: "a bad pair", env: str("A=1\n"), pairs: []string{"KASBAH_A=1", "OTHER=2"}},
		{name: "no pairs", env: str("A=1\n"), pairs: []string{}},
		{name: "a value with spaces and $", env: str(""), pairs: []string{"KASBAH_A=a b$c"}},
	}
	got := map[string]string{}
	for _, tc := range cases {
		p := pairs
		if tc.pairs != nil {
			p = tc.pairs
		}
		dir := filepath.Join(t.TempDir(), "p")
		os.Mkdir(dir, 0o755)
		file := dir + "/.env"
		if tc.symlink {
			os.Mkdir(dir+"/real", 0o755)
			os.Symlink("real/env", file)
			file = dir + "/real/env"
		}
		if tc.env != nil {
			write(t, file, *tc.env)
			if tc.mode != 0 {
				os.Chmod(file, tc.mode)
			}
		}
		rc := Inject(dir+"/.env", p, &bytes.Buffer{})
		data, _ := os.ReadFile(file)
		mode := "absent"
		if fi, err := os.Stat(file); err == nil {
			mode = fi.Mode().String()
		}
		if fi, err := os.Lstat(dir + "/.env"); tc.symlink && (err != nil || fi.Mode()&os.ModeSymlink == 0) {
			t.Errorf("%s: the symlink was replaced", tc.name)
		}
		left, _ := filepath.Glob(dir + "/*kasbah-inject*")
		b, _ := json.Marshal([]any{rc, mode, string(data), len(left)})
		got["inject/"+tc.name] = string(b)
	}
	frozen(t, got)
}
