package check

import (
	"bytes"
	"errors"
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
	return fixedIn(t, map[string]string{"compose.prod.yml": compose}, want)
}

// fixedIn is fixed over a project with files as project writes them.
func fixedIn(t *testing.T, files map[string]string, want string) string {
	t.Helper()
	project(t, files)
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
			"    networks:\n      - default\n      - kasbah\n"+
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+
			"\nnetworks:\n  kasbah: {}")
}

// A block scalar's `#` and blank lines are its value: an insertion goes after
// the whole region, after the blanks only when `+` keeps them.
func TestFixBlockScalars(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah]\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"
	tail := "networks:\n  kasbah: {}\n"
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
			"        networks:\n            - default\n            - kasbah\n"+
			"\nnetworks:\n    kasbah: {}\n"))
}

// Values are rewritten where they stand: quoting and comments kept, and a
// quoted value that runs onto the next line is refused, never guessed.
func TestFixRewritesInPlace(t *testing.T) {
	o := fixed(t, "version: \"3\"\nservices:\n  demo-web:\n    image: x\n    container_name: demo-web\n"+
		"    restart: \"no\"   # spelled out\n    cpus: '1.5 # old box'\n    mem_limit: 512m # sized\n"+
		"    networks: [internal]\n    logging:\n      driver: local\n      options:\n        max-size:\n        max-file: \"3\"\n"+
		"networks:\n  internal: {}\n",
		"services:\n  demo-web:\n    image: x\n    container_name: demo-web\n"+
			"    restart: \"unless-stopped\"   # spelled out\n    cpus: '${KASBAH_CPU_LIMIT}'\n    mem_limit: 512m # sized\n"+
			"    networks: [internal, kasbah]\n    logging:\n      driver: json-file\n      options:\n        max-size: 10m\n        max-file: \"3\"\n"+
			"networks:\n  internal: {}\n  kasbah: {}\n")
	if !strings.Contains(o, "C01 demo-web — restart: no → unless-stopped") {
		t.Errorf("plan:\n%s", o)
	}

	compose := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah]\n" +
		"    restart: always\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: \"512m\n      more\"\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n" +
		"networks:\n  kasbah: {}\n"
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
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah]\n" +
		"    restart: always\n    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"
	tail := "networks:\n  kasbah: {}\n"
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

// min_kasbah is the author's: --fix keeps it as written.
func TestFixKeepsMinKasbah(t *testing.T) {
	project(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nmin_kasbah: 0.1.0 # noRoll\ndomain: demo.example.com\n"})
	var o, e bytes.Buffer
	out := &cli.Output{Stdout: &o, Stderr: &e}
	if code := Run(Env{Out: out, PWD: "/p", Version: "2.0.0", Fix: true, Yes: true,
		Prompt: &prompt.Prompter{In: strings.NewReader(""), Out: out}}); code != 0 {
		t.Fatalf("exit %d\n%s%s", code, &o, &e)
	}
	got, _ := os.ReadFile("kasbah.yml")
	if want := "schema: 1\nkasbah_version: 2.0.0\nname: demo\nmin_kasbah: 0.1.0 # noRoll\ndomain: demo.example.com\n"; string(got) != want {
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
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks: [kasbah]\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"
	tail := "networks:\n  kasbah: {}\n"
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
		"networks:\n  internal: {}\n",
		"services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    networks:\n    - internal\n    - kasbah\n"+
			"    restart: always\n    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n"+
			"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n"+
			"networks:\n  internal: {}\n  kasbah: {}\n")
}

// The same, as the service's last key and with restart: missing: both land on
// the list's last line at one indentation, and the entry has to come first.
func TestFixFlushSequenceLast(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n    networks:\n    - internal\n"
	tail := "networks:\n  internal: {}\n"
	fixed(t, head+tail, head+"    - kasbah\n    restart: unless-stopped\n"+tail+"  kasbah: {}\n")
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
		"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n    networks: [kasbah]\n"
	tail := "networks:\n  kasbah: {}\n"
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

// A rotation value that is not one is replaced.
func TestFixRotation(t *testing.T) {
	head := "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    restart: always\n" +
		"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n    networks: [kasbah]\n" +
		"    logging:\n      driver: json-file\n      options:\n"
	fixed(t, head+"        max-size: false\n        max-file: 3\nnetworks:\n  kasbah: {}\n",
		head+"        max-size: 10m\n        max-file: 3\nnetworks:\n  kasbah: {}\n")
}

// A service on the shared kasbah-net moves to kasbah: the key swapped where it
// stands, options and comments kept, and the kasbah-net declaration dropped.
func TestFixMovesOffSharedNet(t *testing.T) {
	svc := func(nets string) string {
		return "services:\n  demo-web:\n    image: x\n    container_name: demo-web\n    restart: always\n" +
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
			"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n" + nets
	}
	for _, tc := range []struct{ name, in, want, plan string }{
		{"a flow list", svc("    networks: [internal, kasbah-net]\nnetworks:\n  internal: {}\n  kasbah-net: {external: true}\n"),
			svc("    networks: [internal, kasbah, default]\nnetworks:\n  internal: {}\n  kasbah: {}\n"), "C03 demo-web — move it from kasbah-net to kasbah; it keeps reaching its former kasbah-net peers over the project's default network"},
		{"a block list, its comment kept", svc("    networks:\n      - 'kasbah-net'  # shared\n      - internal\nnetworks:\n  kasbah-net:\n    external: true\n  internal: {}\n"),
			svc("    networks:\n      - kasbah  # shared\n      - internal\n      - default\nnetworks:\n  internal: {}\n  kasbah: {}\n"), "C03 — drop the top-level kasbah-net network no service joins any more"},
		{"a mapping, its aliases kept", svc("    networks:\n      kasbah-net:\n        aliases: [demo-www]\nnetworks:\n  kasbah-net:\n    external: true\n"),
			svc("    networks:\n      kasbah:\n        aliases: [demo-www]\n      default:\nnetworks:\n  kasbah: {}\n"), "C04 — declare the project's kasbah: {} network"},
		{"already on kasbah", svc("    networks: [kasbah-net, kasbah]\nnetworks:\n  kasbah: {}\n  kasbah-net: {external: true}\n"),
			svc("    networks: [default, kasbah]\nnetworks:\n  kasbah: {}\n"), "C03 demo-web — drop kasbah-net, it is on kasbah already"},
		{"already on kasbah and default", svc("    networks: [kasbah, kasbah-net, default]\nnetworks:\n  kasbah: {}\n  kasbah-net: {external: true}\n"),
			svc("    networks: [kasbah, default]\nnetworks:\n  kasbah: {}\n"), "C03 demo-web — drop kasbah-net, it is on kasbah already"},
		{"CRLF", strings.ReplaceAll(svc("    networks:\n      - kasbah-net\nnetworks:\n  kasbah-net: {external: true}\n"), "\n", "\r\n"),
			strings.ReplaceAll(svc("    networks:\n      - kasbah\n      - default\nnetworks:\n  kasbah: {}\n"), "\n", "\r\n"), "C03 demo-web — move it from kasbah-net to kasbah"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if o := fixed(t, tc.in, tc.want); !strings.Contains(o, tc.plan) {
				t.Errorf("plan:\n%s", o)
			}
		})
	}
	// What it cannot locate it names, and moves nothing it would leave
	// undeclared.
	for _, tc := range []struct{ name, in, left string }{
		{"an inline top-level networks:", svc("    networks: [kasbah-net]\nnetworks: {kasbah-net: {external: true}}\n"),
			"C03 — the top-level networks: is written inline; move the services on kasbah-net to kasbah by hand"},
		{"a default network named kasbah-net", svc("networks:\n  default: {name: kasbah-net, external: true}\n"),
			"C03 — the network 'default' is named kasbah-net; drop its name: and external: by hand, so compose names it demo_default, and move only the routed services to kasbah"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			project(t, map[string]string{"compose.prod.yml": tc.in})
			o, _, code := fix(t, true)
			got, _ := os.ReadFile(composeFile)
			if code == 0 || string(got) != tc.in || !strings.Contains(o, tc.left) {
				t.Errorf("exit %d, file:\n%s\nstdout:\n%s", code, got, o)
			}
		})
	}
}

// An unrouted service only loses kasbah-net, its other networks kept, or its
// networks: where none is left; kasbah-net's empty entry beside kasbah sets
// nothing; a kasbah-net declaration no service joins goes.
func TestFixUnroutedOffSharedNet(t *testing.T) {
	block := func(name, nets string) string {
		return "  " + name + ":\n    image: x\n    restart: always\n" +
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
			"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n" + nets
	}
	web := block("demo-web", "    container_name: demo-web\n    networks: [kasbah-net]\n")
	movedWeb := block("demo-web", "    container_name: demo-web\n    networks: [kasbah, default]\n")
	for _, tc := range []struct{ name, in, want, plan string }{
		{"several", "services:\n" + web + block("demo-db", "    networks: [internal, kasbah-net]\n") + "networks:\n  internal: {}\n  kasbah-net: {external: true}\n",
			"services:\n" + movedWeb + block("demo-db", "    networks: [internal, default]\n") + "networks:\n  internal: {}\n  kasbah: {}\n", "C04 demo-db — drop kasbah-net, which nothing routes to it over; it keeps reaching its former kasbah-net peers over the project's default network"},
		{"a block mapping", "services:\n" + web + block("demo-db", "    networks:\n      internal: {}\n      kasbah-net:\n        aliases: [db]\n") + "networks:\n  internal: {}\n  kasbah-net: {external: true}\n",
			"services:\n" + movedWeb + block("demo-db", "    networks:\n      internal: {}\n      default:\n") + "networks:\n  internal: {}\n  kasbah: {}\n", "C04 demo-db — drop kasbah-net"},
		{"on default already", "services:\n" + web + block("demo-db", "    networks: [default, internal, kasbah-net]\n") + "networks:\n  internal: {}\n  kasbah-net: {external: true}\n",
			"services:\n" + movedWeb + block("demo-db", "    networks: [default, internal]\n") + "networks:\n  internal: {}\n  kasbah: {}\n", "C04 demo-db — drop kasbah-net"},
		{"none left", "services:\n" + web + block("demo-db", "    networks:\n      - kasbah-net\n") + "networks:\n  kasbah-net: {external: true}\n",
			"services:\n" + movedWeb + block("demo-db", "") + "networks:\n  kasbah: {}\n", "C04 demo-db — drop its networks: kasbah-net, leaving it on the project's default network, over which it keeps reaching its former kasbah-net peers"},
		{"only unrouted, the networks: going", "services:\n" + block("demo-web", "    container_name: demo-web\n    networks: [kasbah]\n") + block("demo-db", "    networks: [kasbah-net]\n") + "networks:\n  kasbah-net: {external: true}\n",
			"services:\n" + block("demo-web", "    container_name: demo-web\n    networks: [kasbah]\n") + block("demo-db", "") + "networks:\n  kasbah: {}\n", "C03 — drop the top-level kasbah-net network no service joins any more"},
		{"an empty entry beside kasbah", "services:\n" + block("demo-web", "    container_name: demo-web\n    networks:\n      kasbah:\n      kasbah-net: {}\n") + "networks:\n  kasbah: {}\n  kasbah-net: {external: true}\n",
			"services:\n" + block("demo-web", "    container_name: demo-web\n    networks:\n      kasbah:\n      default:\n") + "networks:\n  kasbah: {}\n", "C03 demo-web — drop kasbah-net, it is on kasbah already"},
		{"an unused declaration", "services:\n" + movedWeb + "networks:\n  kasbah: {}\n  kasbah-net: {external: true}\n",
			"services:\n" + movedWeb + "networks:\n  kasbah: {}\n", "C04 — drop the top-level kasbah-net network no service joins"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if o := fixed(t, tc.in, tc.want); !strings.Contains(o, tc.plan) {
				t.Errorf("plan:\n%s", o)
			}
		})
	}
	// With no fragment read, nothing on kasbah-net is known unrouted: left.
	in0 := "services:\n" + block("demo-db", "    networks: [kasbah-net]\n") + "networks:\n  kasbah-net: {external: true}\n"
	project(t, map[string]string{"compose.prod.yml": in0, "traefik-dynamic.yml": ""})
	o0, _, _ := fix(t, true)
	if got, _ := os.ReadFile(composeFile); string(got) != in0 || !strings.Contains(o0, "C03 demo-db — traefik-dynamic.yml missing, so whether it is routed is unknown; take it off kasbah-net by hand") {
		t.Errorf("no fragment:\n%s\n%s", got, o0)
	}
	// Unrouted alone, nothing joins kasbah and nothing is declared: the
	// top-level networks: goes too, as compose refuses a null one.
	in := "services:\n" + block("demo-db", "    networks: [kasbah-net]\n") + "networks:\n  kasbah-net: {external: true}\n"
	project(t, map[string]string{"compose.prod.yml": in, "kasbah.yml": "schema: 1\nname: demo\nrouted: false\n", "traefik-dynamic.yml": ""})
	o, e, _ := fix(t, true)
	if got, _ := os.ReadFile(composeFile); string(got) != "services:\n"+block("demo-db", "") {
		t.Errorf("unrouted alone:\n%s\n%s%s", got, o, e)
	}
}

// A service is routed as check judges it — by container_name, kasbah alias or
// kasbah-net alias too — and a routed one's kasbah-net aliases move with it.
func TestFixRoutedByOtherNames(t *testing.T) {
	block := func(name, rest string) string {
		return "services:\n  " + name + ":\n    image: x\n    restart: always\n" +
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
			"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n" + rest
	}
	front := strings.Replace(goodFragment, "demo-web:80", "demo-front:80", 1)
	pass := []string{"  ✓ C03 All routed services join the project's kasbah network", "  ✓ T07 "}
	for _, tc := range []struct{ name, in, frag, want, plan string }{
		{"a container_name on kasbah-net", block("demo-app", "    container_name: demo-web\n    networks: [kasbah-net]\nnetworks:\n  kasbah-net: {external: true}\n"), "",
			block("demo-app", "    container_name: demo-web\n    networks: [kasbah, default]\nnetworks:\n  kasbah: {}\n"), "C03 demo-app — move it from kasbah-net to kasbah"},
		{"a kasbah-net alias beside an empty kasbah", block("demo-web", "    networks:\n      kasbah:\n      kasbah-net:\n        aliases: [demo-front]\nnetworks:\n  kasbah: {}\n  kasbah-net: {external: true}\n"), front,
			block("demo-web", "    networks:\n      kasbah:\n        aliases: [demo-front]\n      default:\nnetworks:\n  kasbah: {}\n"), "C03 demo-web — drop kasbah-net, it is on kasbah already, its aliases demo-front joining its kasbah entry"},
		{"a kasbah-net alias joining kasbah's block list", block("demo-web", "    networks:\n      kasbah-net:\n        aliases: [demo-front, demo-a]\n      kasbah:\n        aliases:\n          - demo-a\nnetworks:\n  kasbah: {}\n  kasbah-net: {external: true}\n"), front,
			block("demo-web", "    networks:\n      default:\n      kasbah:\n        aliases:\n          - demo-a\n          - demo-front\nnetworks:\n  kasbah: {}\n"), "its aliases demo-front joining its kasbah entry"},
		{"a kasbah-net alias joining kasbah's flow list", block("demo-web", "    networks:\n      kasbah:\n        aliases: [demo-a]\n      kasbah-net: {aliases: [demo-front]}\nnetworks:\n  kasbah: {}\n  kasbah-net: {external: true}\n"), front,
			block("demo-web", "    networks:\n      kasbah:\n        aliases: [demo-a, demo-front]\n      default:\nnetworks:\n  kasbah: {}\n"), "its aliases demo-front joining its kasbah entry"},
		{"a kasbah alias", block("demo-api", "    networks:\n      kasbah:\n        aliases: [demo-front]\n      kasbah-net:\nnetworks:\n  kasbah: {}\n  kasbah-net: {external: true}\n"), front,
			block("demo-api", "    networks:\n      kasbah:\n        aliases: [demo-front]\n      default:\nnetworks:\n  kasbah: {}\n"), "C03 demo-api — drop kasbah-net, it is on kasbah already"},
		{"a container_name on no kasbah network", block("demo-app", "    container_name: demo-web\n    networks: [internal]\nnetworks:\n  internal: {}\n"), "",
			block("demo-app", "    container_name: demo-web\n    networks: [internal, kasbah]\nnetworks:\n  internal: {}\n  kasbah: {}\n"), "C03 demo-app — add kasbah to its networks list"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			files := map[string]string{"compose.prod.yml": tc.in}
			if tc.frag != "" {
				files["traefik-dynamic.yml"] = tc.frag
			}
			o := fixedIn(t, files, tc.want)
			for _, w := range append(pass, tc.plan) {
				if !strings.Contains(o, w) {
					t.Errorf("no %q in:\n%s", w, o)
				}
			}
		})
	}
	// A kasbah-net entry that sets more than aliases, or a kasbah entry a line
	// edit cannot extend, is merged by hand; a duplicate alias is named.
	for _, tc := range []struct{ name, nets, left string }{
		{"options beside the aliases", "      kasbah:\n      kasbah-net: {aliases: [demo-front], priority: 2}\n",
			"C03 demo-web — it is on kasbah already, and its kasbah-net entry sets more than aliases; take it off kasbah-net by hand, onto kasbah and the project's default network"},
		{"an inline kasbah entry", "      kasbah: {aliases: [demo-a]}\n      kasbah-net: {aliases: [demo-front]}\n",
			"C03 demo-web — it is on kasbah already, and its kasbah-net aliases cannot be added to its kasbah entry as written; take it off kasbah-net by hand"},
		{"a duplicate alias", "      kasbah:\n      kasbah-net:\n        aliases: [demo-front, demo-front]\n",
			"C03 demo-web — its kasbah-net aliases list demo-front twice; remove the duplicate alias demo-front from demo-web's kasbah-net entry"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			in := block("demo-web", "    networks:\n"+tc.nets+"networks:\n  kasbah: {}\n  kasbah-net: {external: true}\n")
			project(t, map[string]string{"compose.prod.yml": in, "traefik-dynamic.yml": front})
			o, _, _ := fix(t, true)
			if got, _ := os.ReadFile(composeFile); string(got) != in || !strings.Contains(o, tc.left) {
				t.Errorf("file:\n%s\nstdout:\n%s", got, o)
			}
		})
	}
}

// --fix takes every service off kasbah-net or none: one it must leave there
// would share no network with those it moved to default. Each it leaves is
// named with why, and the declaration stays.
func TestFixSharedNetAllOrNothing(t *testing.T) {
	block := func(name, rest string) string {
		return "  " + name + ":\n    image: x\n    restart: always\n" +
			"    cpus: ${KASBAH_CPU_LIMIT}\n    mem_limit: ${KASBAH_MEM_LIMIT}\n" +
			"    logging: {driver: json-file, options: {max-size: 1m, max-file: \"1\"}}\n" + rest
	}
	front := strings.Replace(goodFragment, "demo-web:80", "demo-front:80", 1)
	db := block("demo-db", "    networks: [kasbah-net]\n")
	for _, tc := range []struct {
		name, in, frag string
		left           []string
	}{
		{"a routed service with options on kasbah-net",
			"services:\n" + block("demo-web", "    networks:\n      kasbah: {}\n      kasbah-net:\n        priority: 2\n        aliases: [demo-front]\n") + db +
				"networks:\n  kasbah: {}\n  kasbah-net: {external: true}\n", front,
			[]string{"C03 demo-web — it is on kasbah already, and its kasbah-net entry sets more than aliases; take it off kasbah-net by hand, onto kasbah and the project's default network",
				"C03 — --fix takes no service off kasbah-net while it must leave demo-web on it"}},
		{"one of three written inline",
			"services:\n" + block("demo-web", "    container_name: demo-web\n    networks: [kasbah-net]\n") +
				block("demo-api", "    networks: {internal: {}, kasbah-net: {}}\n") + db +
				"networks:\n  internal: {}\n  kasbah-net: {external: true}\n", "",
			[]string{"C04 demo-api — its networks: is written inline as {internal: {}, kasbah-net: {}}; take it off kasbah-net by hand, onto the project's default network",
				"C03 — --fix takes no service off kasbah-net while it must leave demo-api on it"}},
		{"a service on another key named kasbah-net",
			"services:\n" + block("demo-web", "    container_name: demo-web\n    networks: [kasbah-net]\n") +
				block("demo-db", "    networks: [shared]\n") +
				"networks:\n  kasbah-net: {external: true}\n  shared: {name: kasbah-net, external: true}\n", "",
			[]string{"C04 demo-db — it joins 'shared', which is named kasbah-net; take it off kasbah-net by hand, onto the project's default network",
				"C03 — --fix takes no service off kasbah-net while it must leave demo-db on it"}},
		{"a default network named kasbah-net",
			"services:\n" + block("demo-web", "    container_name: demo-web\n") + db +
				"networks:\n  default: {name: kasbah-net, external: true}\n  kasbah-net: {external: true}\n", "",
			[]string{"C03 — the network 'default' is named kasbah-net; drop its name: and external: by hand, so compose names it demo_default, and move only the routed services to kasbah"}},
		{"a default network named kasbah-net, a service on kasbah-net written inline",
			"services:\n" + block("demo-web", "    container_name: demo-web\n") +
				"  demo-db: {image: x, restart: always, networks: [kasbah-net]}\n" +
				"networks:\n  default: {name: kasbah-net, external: true}\n  kasbah-net: {external: true}\n", "",
			[]string{"compose: service 'demo-db' is written inline"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			files := map[string]string{"compose.prod.yml": tc.in}
			if tc.frag != "" {
				files["traefik-dynamic.yml"] = tc.frag
			}
			project(t, files)
			o, _, code := fix(t, true)
			got, _ := os.ReadFile(composeFile)
			// The declaration stays while any service joins kasbah-net.
			if code == 0 || string(got) != tc.in || strings.Contains(o, "peers") || strings.Contains(o, "drop the top-level") {
				t.Errorf("exit %d, file:\n%s\nstdout:\n%s", code, got, o)
			}
			for _, l := range tc.left {
				if !strings.Contains(o, l) {
					t.Errorf("no %q in:\n%s", l, o)
				}
			}
		})
	}
}

// A path that is not a regular file is refused as such, not as "does not
// exist"; a missing one keeps the OS's reason.
func TestReadRegular(t *testing.T) {
	dir := t.TempDir()
	if _, err := readRegular(dir); !errors.Is(err, errNotRegular) {
		t.Errorf("a directory: %v", err)
	}
	if _, err := readRegular(dir + "/missing"); err == nil || errors.Is(err, errNotRegular) || !errors.Is(err, os.ErrNotExist) {
		t.Errorf("a missing file: %v", err)
	}
}
