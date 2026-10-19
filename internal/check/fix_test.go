package check

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

// fix runs `check --fix`, answered by yes; no terminal is attached.
func fix(t *testing.T, yes bool) (string, string, int) {
	t.Helper()
	var o, e bytes.Buffer
	out := &cli.Output{Stdout: &o, Stderr: &e}
	code := Run(Env{Out: out, PWD: "/p", Version: "1", Fix: true, Yes: yes,
		Prompt: &prompt.Prompter{In: strings.NewReader(""), Out: out}})
	return o.String(), e.String(), code
}

func fixed(t *testing.T, compose, want string) string {
	t.Helper()
	project(t, map[string]string{"compose.prod.yml": compose})
	o, e, code := fix(t, true)
	got, _ := os.ReadFile(composeFile)
	if string(got) != want {
		t.Fatalf("compose.prod.yml:\n%s\nwant:\n%s\nstdout:\n%s\nstderr:\n%s", got, want, o, e)
	}
	if code != 0 {
		t.Fatalf("exit %d\n%s%s", code, o, e)
	}
	// A second run finds nothing to do and changes nothing.
	o2, _, _ := fix(t, true)
	again, _ := os.ReadFile(composeFile)
	if string(again) != want || !strings.Contains(o2, "nothing --fix can change") {
		t.Fatalf("second run changed the file or found work:\n%s\n%s", again, o2)
	}
	return o
}

// Four insertions share one anchor, the service's last line, at four
// indentations; they come out deepest first or a key lands in the wrong block.
func TestFixAnchorsDeepestFirst(t *testing.T) {
	fixed(t, "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n"+
		"    logging:\n      options:\n        max-file: \"3\"",
		"services:\n  demo-web:\n    image: x\n    container_name: demo-web\n"+
			"    logging:\n      options:\n        max-file: \"3\"\n        max-size: \"10m\"\n"+
			"      driver: json-file\n    restart: unless-stopped\n"+
			"    networks:\n      - default\n      - kasbah-net\n"+
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+
			"\nnetworks:\n  kasbah-net:\n    external: true")
}

// A block scalar's `#` and blank lines are its value: an insertion goes after
// the whole region, after the blanks only when `+` keeps them.
func TestFixBlockScalars(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah-net]\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"
	tail := "networks:\n  kasbah-net: {external: true}\n"
	fixed(t, head+"    entrypoint: |\n      set -e\n      # text, not a comment\n\n  # a comment\n"+tail,
		head+"    entrypoint: |\n      set -e\n      # text, not a comment\n    restart: unless-stopped\n\n  # a comment\n"+tail)
	fixed(t, head+"    command: |+\n      echo hi\n\n\n"+tail,
		head+"    command: |+\n      echo hi\n\n\n    restart: unless-stopped\n"+tail)
}

// CRLF in, CRLF out, at the file's own 4-space step.
func TestFixCRLF(t *testing.T) {
	crlf := func(s string) string { return strings.ReplaceAll(s, "\n", "\r\n") }
	fixed(t, crlf("services:\n    demo-web:\n        image: x\n        container_name: demo-web\n"+
		"        restart: always\n        cpus: ${KASBAH_CPU_LIMIT}\n        mem_limit: ${KASBAH_MEM_LIMIT}\n"+
		"        logging:\n            driver: json-file\n            options: {max-size: 1m, max-file: \"1\"}\n"),
		crlf("services:\n    demo-web:\n        image: x\n        container_name: demo-web\n"+
			"        restart: always\n        cpus: ${KASBAH_CPU_LIMIT}\n        mem_limit: ${KASBAH_MEM_LIMIT}\n"+
			"        logging:\n            driver: json-file\n            options: {max-size: 1m, max-file: \"1\"}\n"+
			"        networks:\n            - default\n            - kasbah-net\n"+
			"\nnetworks:\n    kasbah-net:\n        external: true\n"))
}

// Values are rewritten where they stand: quoting and comments kept, and a
// quoted value that runs onto the next line is refused, never guessed.
func TestFixRewritesInPlace(t *testing.T) {
	o := fixed(t, "version: \"3\"\nservices:\n  demo-web:\n    image: x\n    container_name: demo-web\n"+
		"    restart: \"no\"   # spelled out\n    cpus: '1.5 # old box'\n    mem_limit: 512m # sized\n"+
		"    networks: [internal]\n    logging:\n      driver: local\n      options:\n        max-size:\n        max-file: \"3\"\n"+
		"networks:\n  internal: {}\n  kasbah-net: {}\n",
		"services:\n  demo-web:\n    image: x\n    container_name: demo-web\n"+
			"    restart: \"unless-stopped\"   # spelled out\n    cpus: '${KASBAH_CPU_LIMIT}'\n    mem_limit: ${KASBAH_MEM_LIMIT} # sized\n"+
			"    networks: [internal, kasbah-net]\n    logging:\n      driver: json-file\n      options:\n        max-size: 10m\n        max-file: \"3\"\n"+
			"networks:\n  internal: {}\n  kasbah-net: {external: true}\n")
	if !strings.Contains(o, "C01 demo-web — restart: no → unless-stopped") {
		t.Errorf("plan:\n%s", o)
	}

	compose := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah-net]\n" +
		"    restart: always\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: \"512m\n      more\"\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n" +
		"networks:\n  kasbah-net: {external: true}\n"
	project(t, map[string]string{"compose.prod.yml": compose})
	o, _, code := fix(t, true)
	got, _ := os.ReadFile(composeFile)
	if code != 6 || string(got) != compose ||
		!strings.Contains(o, "R02 demo-web — its mem_limit: is written in a shape --fix cannot rewrite") ||
		strings.Contains(o, "nothing --fix can change") {
		t.Fatalf("exit %d, file:\n%s\nstdout:\n%s", code, got, o)
	}
}

// Without --yes and without a terminal the run stops naming the flag, after
// the diff, and leaves nothing behind.
func TestFixAsks(t *testing.T) {
	compose := strings.Replace(goodCompose, "    restart: unless-stopped\n", "", 1)
	project(t, map[string]string{"compose.prod.yml": compose})
	if err := os.Chmod(composeFile, 0o640); err != nil {
		t.Fatal(err)
	}
	o, e, code := fix(t, false)
	if code != 1 || !strings.Contains(e, "cannot ask: Apply these edits?") || !strings.Contains(e, "pass --yes instead") ||
		!strings.Contains(o, "+    restart: unless-stopped") {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", code, o, e)
	}
	if got, _ := os.ReadFile(composeFile); string(got) != compose {
		t.Fatalf("file changed:\n%s", got)
	}
	if left, _ := filepath.Glob("*.kasbah-fix.*"); len(left) != 0 {
		t.Fatalf("candidates left: %v", left)
	}
	if _, _, code := fix(t, true); code != 0 {
		t.Fatalf("--yes: exit %d", code)
	}
	if fi, _ := os.Stat(composeFile); fi.Mode().Perm() != 0o640 {
		t.Fatalf("mode %v, want the original's 0640", fi.Mode().Perm())
	}
}

func TestFixManifestBackfill(t *testing.T) {
	project(t, map[string]string{"kasbah.yml": "# m\r\nschema: 1\r\nname: demo\r\ndomain: demo.example.com\r\n"})
	if _, _, code := fix(t, true); code != 0 {
		t.Fatalf("exit %d", code)
	}
	got, _ := os.ReadFile("kasbah.yml")
	if want := "# m\r\nschema: 1\r\nkasbah_version: 1\r\nname: demo\r\ndomain: demo.example.com\r\n"; string(got) != want {
		t.Fatalf("kasbah.yml:\n%q", got)
	}
}

func TestSplitValue(t *testing.T) {
	for _, c := range []struct {
		in, val, cmt string
		ok           bool
	}{
		{"", "", "", true},
		{" x", "x", "", true},
		{" x  # c", "x", "  # c", true},
		{" app#1", "app#1", "", true},
		{"\tx\t#c", "x", "\t#c", true},
		{" # only", "", " # only", true},
		{` "a # b" # c`, `"a # b"`, " # c", true},
		{` "a \" # b"`, `"a \" # b"`, "", true},
		{` 'it''s' #`, `'it''s'`, " #", true},
		{` "open`, "", "", false},
		{` "a" b`, "", "", false},
	} {
		v, cm, ok := splitValue(c.in)
		if v != c.val || cm != c.cmt || ok != c.ok {
			t.Errorf("splitValue(%q) = %q, %q, %v; want %q, %q, %v", c.in, v, cm, ok, c.val, c.cmt, c.ok)
		}
	}
}

func TestScalarHeader(t *testing.T) {
	for in, want := range map[string]int{
		"a: |": 0, "a: >-": 0, "a: |2+": 0, "a: | # c": 0, "a: |  ": 0,
		"- |": 0, "  - >-": 2, "- - |": 2, "- &a |": 0, "  - key: |": 4,
		"key: &a |": 0, "key: !!str >-": 0, "key: !tag |2": 0, "key: &a !t >": 0,
		"a: |x": -1, "a: '|'": -1, "a: b": -1, "- a": -1, "a: &x": -1, "a: !!str": -1, "- '|'": -1,
	} {
		ok, ind, _ := readText([]byte(in)).scalarHeader(0)
		if !ok {
			ind = -1
		}
		if ind != want {
			t.Errorf("scalarHeader(%q) = %v, %d; want indent %d", in, ok, ind, want)
		}
	}
}

// The reviewer's three: a header after `- `, an anchor or a tag. Each scalar
// keeps its `#` lines and the key lands after it.
func TestFixScalarHeaders(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah-net]\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"
	tail := "networks:\n  kasbah-net: {external: true}\n"
	for _, body := range []string{
		"    command:\n      - sh\n      - |\n        set -e\n        # done\n",
		"    entrypoint: &ep |\n      set -e\n      # done\n",
		"    healthcheck:\n      test: !!str >-\n        curl -f x\n        # || exit 1\n",
		"    command:\n    - sh\n    - - |\n        x\n        # done\n",
	} {
		fixed(t, head+body+tail, head+body+"    restart: unless-stopped\n"+tail)
	}
}

// A sequence written at its key's own indentation is still the key's.
func TestFixFlushSequence(t *testing.T) {
	fixed(t, "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks:\n    - internal\n"+
		"    restart: always\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"+
		"networks:\n  internal: {}\n  kasbah-net: {external: true}\n",
		"services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks:\n    - internal\n    - kasbah-net\n"+
			"    restart: always\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+
			"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"+
			"networks:\n  internal: {}\n  kasbah-net: {external: true}\n")
}

// The same, as the service's last key and with restart: missing: both land on
// the list's last line at one indentation, and the entry has to come first.
func TestFixFlushSequenceLast(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n    networks:\n    - internal\n"
	tail := "networks:\n  internal: {}\n  kasbah-net: {external: true}\n"
	fixed(t, head+tail, head+"    - kasbah-net\n    restart: unless-stopped\n"+tail)
}

// The guard refuses a candidate whose tree differs from the plan's, and a
// digest-pinned image is not retagged.
func TestFixGuard(t *testing.T) {
	m := obj("a", obj("s", "x"), "keep", "y")
	cand := obj("a", obj("s", "x", "restart", "unless-stopped"), "keep", "y")
	set := []edit{{'s', []string{"a", "restart"}, "unless-stopped"}}
	if !guard([]any{m}, []any{cand}, set) {
		t.Error("the planned edit alone was refused")
	}
	lost := obj("a", obj("s", "x", "restart", "unless-stopped"), "keep", "y-")
	if guard([]any{m}, []any{lost}, set) {
		t.Error("a value the plan did not touch changed, and the guard let it through")
	}
	if guard([]any{m}, []any{cand}, []edit{{'s', []string{"a\"", "restart"}, "x"}}) {
		t.Error("a path that does not compile was accepted")
	}

	compose := "services:\n  demo-web:\n    build: .\n    image: x@sha256:abc\n"
	project(t, map[string]string{"compose.prod.yml": compose})
	o, _, _ := fix(t, true)
	got, _ := os.ReadFile(composeFile)
	if !strings.Contains(o, "C08 demo-web — its image: is pinned by digest (x@sha256:abc)") ||
		!strings.Contains(string(got), "image: x@sha256:abc\n") {
		t.Fatalf("stdout:\n%s\nfile:\n%s", o, got)
	}
}
