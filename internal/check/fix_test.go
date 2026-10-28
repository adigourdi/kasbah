package check

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/udiff"
	"github.com/adigourdi/kasbah/internal/udiff/udifftest"
)

// fix runs `check --fix`, answered by yes; no terminal is attached. A file it
// wrote was shown as its diff, and that diff, through GNU patch, is the file.
func fix(t *testing.T, yes bool) (string, string, int) {
	t.Helper()
	files := []string{composeFile, manifest.File}
	before := map[string][]byte{}
	for _, f := range files {
		before[f], _ = os.ReadFile(f)
	}
	var o, e bytes.Buffer
	out := &cli.Output{Stdout: &o, Stderr: &e}
	code := Run(Env{Out: out, PWD: "/p", Version: "1", Fix: true, Yes: yes,
		Prompt: &prompt.Prompter{In: strings.NewReader(""), Out: out}})
	for _, f := range files {
		after, err := os.ReadFile(f)
		if err != nil || bytes.Equal(after, before[f]) {
			continue
		}
		d := udiff.Unified("a/"+f, "b/"+f, before[f], after)
		if !strings.Contains(o.String(), string(d)) {
			t.Fatalf("%s was written but its diff was not shown:\n%s\nstdout:\n%s", f, d, o.String())
		}
		if udifftest.GNU(t) {
			if got := udifftest.Patch(t, before[f], d); !bytes.Equal(got, after) {
				t.Fatalf("%s: the shown diff patches to\n%q\nnot\n%q", f, got, after)
			}
			t.Logf("patch round trip: %s", f)
		}
	}
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
			"    restart: \"unless-stopped\"   # spelled out\n    cpus: '${KASBAH_CPU_LIMIT}'\n    mem_limit: 512m # sized\n"+
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

// A literal limit is the author's per-service choice: --fix keeps it and adds
// only the reference a service is missing.
func TestFixLeavesLiterals(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah-net]\n" +
		"    restart: always\n    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"
	tail := "networks:\n  kasbah-net: {external: true}\n"
	o := fixed(t, head+"    cpus: 0.5\n"+tail, head+"    cpus: 0.5\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+tail)
	if strings.Contains(o, "R01 demo-web") || !strings.Contains(o, "R02 demo-web — add mem_limit: ${KASBAH_MEM_LIMIT}") {
		t.Errorf("plan:\n%s", o)
	}
	fixed(t, head+"    cpus: \"2\"\n    mem_limit: 0\n"+tail, head+"    cpus: \"2\"\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+tail)
	fixed(t, head+"    mem_limit: 1.5g\n    deploy: {resources: {limits: {cpus: .5}}}\n"+tail, head+"    mem_limit: 1.5g\n    deploy: {resources: {limits: {cpus: .5}}}\n"+tail)

	// A deploy-form limit it would fail is the author's to fix: a top-level
	// key beside it is what compose refuses.
	compose := head + "    cpus: 1\n    deploy: {resources: {limits: {memory: lots}}}\n" + tail
	project(t, map[string]string{"compose.prod.yml": compose})
	o, _, code := fix(t, true)
	got, _ := os.ReadFile(composeFile)
	if code != 6 || string(got) != compose ||
		!strings.Contains(o, "R02 demo-web — deploy.resources.limits.memory is malformed or differs from mem_limit:; fix it by hand — --fix writes no mem_limit: beside it") {
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
	if !guard(m, cand, set) {
		t.Error("the planned edit alone was refused")
	}
	lost := obj("a", obj("s", "x", "restart", "unless-stopped"), "keep", "y-")
	if guard(m, lost, set) {
		t.Error("a value the plan did not touch changed, and the guard let it through")
	}
	if guard(m, cand, []edit{{'s', []string{"keep", "restart"}, "x"}}) {
		t.Error("an edit through a string was accepted")
	}
	q := obj("a\"b", obj("s", "x"))
	if !guard(q, obj("a\"b", obj("s", "x", "restart", "unless-stopped")), []edit{{'s', []string{"a\"b", "restart"}, "unless-stopped"}}) {
		t.Error("a name holding a quote was refused")
	}
	if guard(m, obj("a", obj("s", "x"), "keep", "y"), []edit{{'m', []string{"keep", "x"}, nil}}) {
		t.Error("a mask through a string was accepted")
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

// A name holding a quote or a backslash is edited like any other.
func TestFixNameWithQuote(t *testing.T) {
	head := "services:\n  demo-a\"b\\c:\n    image: x\n    container_name: demo-web\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n    networks: [kasbah-net]\n"
	tail := "networks:\n  kasbah-net: {external: true}\n"
	fixed(t, head+tail, head+"    restart: unless-stopped\n"+tail)
}

// A compose file of several documents is left alone, said why.
func TestFixSeveralDocuments(t *testing.T) {
	compose := "services:\n  demo-web:\n    image: x\n---\nservices:\n  demo-db:\n    image: y\n"
	project(t, map[string]string{"compose.prod.yml": compose})
	o, _, _ := fix(t, true)
	got, _ := os.ReadFile(composeFile)
	if !strings.Contains(o, "compose.prod.yml holds 2 YAML documents, where kasbah reads one — --fix will not pattern-match") || string(got) != compose {
		t.Fatalf("stdout:\n%s\nfile:\n%s", o, got)
	}
}

// A rotation value that is not one is replaced; a quoted "true" is not
// external, and is rewritten bare.
func TestFixRotationAndExternal(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    restart: always\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n    networks: [kasbah-net]\n" +
		"    logging:\n      driver: json-file\n      options:\n"
	fixed(t, head+"        max-size: false\n        max-file: 3\nnetworks:\n  kasbah-net:\n    external: \"true\"\n",
		head+"        max-size: 10m\n        max-file: 3\nnetworks:\n  kasbah-net:\n    external: true\n")
}
