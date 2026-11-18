package deploy

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/remote"
)

// renderDir writes apps/demo's template and .env, the two a render reads.
func renderDir(t *testing.T, tmpl, env string) (apps, dir string) {
	t.Helper()
	apps = t.TempDir()
	dir = filepath.Join(apps, "demo")
	os.MkdirAll(filepath.Join(apps, "traefik", "dynamic"), 0o755)
	os.MkdirAll(dir, 0o755)
	os.WriteFile(filepath.Join(dir, ".env.prod.example"), []byte(tmpl), 0o644)
	if env != "" {
		os.WriteFile(filepath.Join(dir, ".env"), []byte(env), 0o600)
	}
	return apps, dir
}

const authFrag = "http:\n  middlewares:\n    demo-auth:\n      basicAuth:\n        users: [\"${AUTH_USERS}\"]\n"

func TestRenderFragment(t *testing.T) {
	_, dir := renderDir(t, "AUTH_USERS=\nEMPTY=\nUNSET=\nTPL=\nQUOTE=\nNL=\nCR=\nUSER=\nKV=\nODD=\nANCHOR=\nTAG=\nBRACE=\nFLOW=\nFLOW2=\n",
		"AUTH_USERS='admin:$apr1$x$y'\nEMPTY=\nTPL='{{ env \"X\" }}'\nQUOTE='a\"b'\nKASBAH_CPU_LIMIT=1\n"+
			"NL=\"x\\n      evil: {}\"\nCR=\"x\\ry\"\nUSER='q\", \"injected'\nKV='k3y: v4l'\nODD='a: b # c [d] \"e\"'\n"+
			"ANCHOR='*s3cretanchor'\nTAG='!!int s3cret'\nBRACE='{ env \"X\" }}'\nFLOW='x\", b: \"y'\nFLOW2='x\", c: \"y'\n")
	ok := map[string]string{
		authFrag: "http:\n  middlewares:\n    demo-auth:\n      basicAuth:\n        users: [\"admin:$apr1$x$y\"]\n",
		// A bare $, an $apr1$ hash, a regex group and $$ are left alone; $${ is ${.
		"a: '$apr1$q$r ^/x$ ${1} $$x $${AUTH_USERS} ${AUTH_USERS}'\n": "a: '$apr1$q$r ^/x$ ${1} $$x ${AUTH_USERS} admin:$apr1$x$y'\n",
		// Nothing to fill: the bytes as written, even ones YAML refuses.
		"a: [\n# $HOME\n":              "a: [\n# $HOME\n",
		"a: 1\r\nb: ${AUTH_USERS}\r\n": "a: 1\r\nb: admin:$apr1$x$y\r\n",
		// : # [ and quotes stay one scalar where the fragment quotes for them.
		"a: '${KV}'\nb: [\"${KV}\"]\n":       "a: 'k3y: v4l'\nb: [\"k3y: v4l\"]\n",
		"a: '${ODD}'\n":                      "a: 'a: b # c [d] \"e\"'\n",
		"a: ${AUTH_USERS} # ${AUTH_USERS}\n": "a: admin:$apr1$x$y # admin:$apr1$x$y\n",
	}
	for in, want := range ok {
		got, kept, err := RenderFragment(dir, []byte(in), "d@h", false)
		if err != nil || string(got) != want || kept != nil {
			t.Errorf("%q: got %q %v, %v", in, got, kept, err)
		}
	}
	bad := map[string][]string{
		"a: ${UNSET}\n":            {"${UNSET} is not set in " + dir + "/.env", "`kasbah env set UNSET d@h` sets it"},
		"a: ${EMPTY}\n":            {"${EMPTY} is empty in " + dir + "/.env", "`kasbah env set EMPTY d@h`"},
		"a: ${NOPE}\n":             {"${NOPE} is not declared in " + dir + "/.env.prod.example", "kasbah help T12"},
		"a: ${KASBAH_CPU_LIMIT}\n": {"${KASBAH_CPU_LIMIT} is a KASBAH_ key"},
		"a: ${TPL}\n":              {"${TPL}'s value", "Go template", "`kasbah env set TPL d@h` sets one without it"},
		"a: \"${QUOTE}\"\n":        {"does not parse as YAML once ${QUOTE} on line 1 is filled", "single quotes", "`kasbah env set QUOTE d@h`"},
		"a: ${UNSET} ${NOPE}\n":    {"${UNSET} is not set", "; ${NOPE} is not declared"},
		// A value cannot add structure: no line break, no key, no list item.
		authFrag + "    x: ${NL}\n": {"${NL}'s value", "spans lines", "`kasbah env set NL d@h` sets one"},
		"a: \"${CR}\"\n":            {"${CR}'s value", "spans lines"},
		"http:\n  middlewares:\n    a: {basicAuth: {users: [\"${USER}\"]}}\n": {"the value of ${USER} on line 3 changes the fragment's YAML structure", "`kasbah env set USER d@h`"},
		"a: {b: \"${FLOW}\"}\n":  {"the value of ${FLOW} on line 1 changes the fragment's YAML structure"},
		"a: {b: \"${FLOW2}\"}\n": {"the value of ${FLOW2} on line 1 changes the fragment's YAML structure"},
		"a: 1\nb: ${KV}\n":       {"does not parse as YAML once ${KV} on line 2 is filled"},
		// YAML's own message would quote the value: the line and key only.
		"a: ${ANCHOR}\n": {"does not parse as YAML once ${ANCHOR} on line 1 is filled"},
		"a: ${TAG}\n":    {"does not parse as YAML once ${TAG} on line 1 is filled"},
		// A {{ made of the template's { and the value's.
		"a: '{${BRACE}'\n": {"filling ${BRACE} on line 1 makes a {{ the template does not have"},
		// A template YAML cannot read cannot be held to its shape.
		"a: {b: ${KV}}\n": {"does not parse as YAML as written", "quote each ${KEY}"},
	}
	secrets := []string{"apr1$x$y", "a\"b", "evil", "injected", "k3y", "v4l", "s3cret", "env \"X\"", "x\", b"}
	for in, want := range bad {
		got, _, err := RenderFragment(dir, []byte(in), "d@h", false)
		for _, w := range want {
			if err == nil || !strings.Contains(err.Error(), w) {
				t.Errorf("%q: want %q, got %q %v", in, w, got, err)
			}
		}
		for _, v := range secrets {
			if err != nil && strings.Contains(err.Error(), v) {
				t.Errorf("%q: the refusal quotes a value (%q): %v", in, v, err)
			}
		}
	}
	if _, _, err := RenderFragment(dir, []byte("a: ${AUTH_USERS}\n"), "", false); err != nil {
		t.Error(err)
	}
	_, nodot := renderDir(t, "K=\n", "")
	if _, _, err := RenderFragment(nodot, []byte("a: ${K}\n"), "", false); err == nil || !strings.Contains(err.Error(), "cannot be read — `kasbah env set K` sets it") {
		t.Errorf("no .env: %v", err)
	}
	// A value beside the text's {{ opens an action: "{{{" counts as two.
	_, br := renderDir(t, "B=\n", "B={\n")
	if _, _, err := RenderFragment(br, []byte("a: '${B}{{ env \"X\" }}'\n"), "d@h", false); err == nil || !strings.Contains(err.Error(), "makes a {{ the template does not have") {
		t.Errorf("{ beside {{: %v", err)
	}
	// An .env line that does not read is not quoted, nor is another key's.
	_, unread := renderDir(t, "A=\nB=\n", "B=s3cret${x\n")
	if _, _, err := RenderFragment(unread, []byte("a: ${A}\n"), "d@h", false); err == nil || !strings.Contains(err.Error(), "a line of "+unread+"/.env does not read") || strings.Contains(err.Error(), "s3cret") {
		t.Errorf("unreadable .env line: %v", err)
	}
	if got := FragmentKeys([]byte("${B} $${A} ${A} ${B} ${1}")); strings.Join(got, ",") != "B,A" {
		t.Errorf("keys %v", got)
	}
}

// An old version's text keeps an undeclared or KASBAH_ ${…} as written; a
// declared key still needs its value, and a current deploy refuses either.
func TestRenderFragmentTagged(t *testing.T) {
	_, dir := renderDir(t, "AUTH_USERS=\nUNSET=\n", "AUTH_USERS=admin\n")
	in := "a: '^/(?P<x>.*)${1}${LEGACY}'\nb: ${AUTH_USERS}\n# ${KASBAH_OLD}\n"
	got, kept, err := RenderFragment(dir, []byte(in), "d@h", true)
	if err != nil || string(got) != "a: '^/(?P<x>.*)${1}${LEGACY}'\nb: admin\n# ${KASBAH_OLD}\n" || strings.Join(kept, " ") != "LEGACY KASBAH_OLD" {
		t.Errorf("tagged: %q %v %v", got, kept, err)
	}
	if _, _, err := RenderFragment(dir, []byte(in), "d@h", false); err == nil || !strings.Contains(err.Error(), "${LEGACY} is not declared") {
		t.Errorf("current: %v", err)
	}
	if _, _, err := RenderFragment(dir, []byte(in+"c: ${UNSET}\n"), "d@h", true); err == nil || !strings.Contains(err.Error(), "${UNSET} is not set") {
		t.Errorf("tagged, declared and unset: %v", err)
	}
}

func fragmentArm(t *testing.T, apps string, body []byte, tagged bool) (int, string, string) {
	t.Helper()
	size, sum := remote.Digest(body)
	var out, errb bytes.Buffer
	args := []string{"fragment", apps, "demo", size, sum, "d@h"}
	if tagged {
		args = append(args, "--tagged")
	}
	rc := Remote(args, bytes.NewReader(body), &out, &errb)
	return rc, out.String(), errb.String()
}

// The arm installs the rendered fragment at 640, leaves identical bytes
// alone, and a render that fails leaves the live file as it was.
func TestFragmentArm(t *testing.T) {
	apps, dir := renderDir(t, "AUTH_USERS=\n", "AUTH_USERS='admin:$apr1$x$y'\n")
	dest := filepath.Join(apps, "traefik", "dynamic", "demo.yml")
	rc, out, errs := fragmentArm(t, apps, []byte(authFrag), false)
	b, _ := os.ReadFile(dest)
	fi, _ := os.Stat(dest)
	if rc != 0 || out != "fragment=written\n" || !strings.Contains(string(b), `users: ["admin:$apr1$x$y"]`) || fi.Mode().Perm() != FragmentMode {
		t.Fatalf("rc %d %q %q %q %v", rc, out, errs, b, fi.Mode())
	}
	if rc, out, _ := fragmentArm(t, apps, []byte(authFrag), false); rc != 0 || out != "fragment=unchanged\n" {
		t.Errorf("second run: rc %d %q", rc, out)
	}
	// A live file at the old 644 is rewritten at 640, same bytes.
	os.Chmod(dest, 0o644)
	if rc, out, _ := fragmentArm(t, apps, []byte(authFrag), false); rc != 0 || out != "fragment=written\n" {
		t.Errorf("mode fix: rc %d %q", rc, out)
	}

	os.WriteFile(filepath.Join(dir, ".env"), []byte("AUTH_USERS=\n"), 0o600)
	rc, out, errs = fragmentArm(t, apps, []byte(authFrag), false)
	if after, _ := os.ReadFile(dest); rc != 1 || out != "" || !bytes.Equal(after, b) ||
		!strings.Contains(errs, "${AUTH_USERS} is empty") || !strings.Contains(errs, "kasbah env set AUTH_USERS d@h") || !strings.Contains(errs, dest+" was left as it was") {
		t.Errorf("empty key: rc %d %q %q, live %q", rc, out, errs, after)
	}
	os.WriteFile(filepath.Join(dir, ".env"), []byte("AUTH_USERS='a\"b'\n"), 0o600)
	if rc, _, errs := fragmentArm(t, apps, []byte(authFrag), false); rc != 1 || !strings.Contains(errs, "does not parse as YAML") {
		t.Errorf("parse failure: rc %d %q", rc, errs)
	}
	if after, _ := os.ReadFile(dest); !bytes.Equal(after, b) {
		t.Errorf("a parse failure replaced the live file: %q", after)
	}
	ents, _ := os.ReadDir(filepath.Dir(dest))
	if len(ents) != 1 {
		t.Errorf("staging left behind: %v", ents)
	}

	// Empty is a fragment too; a cut stream is not.
	if rc, out, errs := fragmentArm(t, apps, nil, false); rc != 0 || out != "fragment=written\n" {
		t.Errorf("empty: rc %d %q %q", rc, out, errs)
	}
	size, sum := remote.Digest([]byte(authFrag))
	var o, e bytes.Buffer
	if rc := Remote([]string{"fragment", apps, "demo", size, sum, "d@h"}, strings.NewReader(authFrag[:10]), &o, &e); rc != 1 || !strings.Contains(e.String(), "was left as it was") {
		t.Errorf("cut: rc %d %q", rc, e.String())
	}
	if rc := Remote([]string{"fragment", apps, "../x", size, sum, "d@h"}, strings.NewReader(authFrag), &o, &e); rc != 1 {
		t.Errorf("bad name: rc %d", rc)
	}
	// --tagged keeps an old version's undeclared ${…} as written.
	legacy := []byte("a: '${LEGACY}'\n")
	if rc, _, errs := fragmentArm(t, apps, legacy, false); rc != 1 || !strings.Contains(errs, "${LEGACY} is not declared") {
		t.Errorf("legacy, current: rc %d %q", rc, errs)
	}
	if rc, out, errs := fragmentArm(t, apps, legacy, true); rc != 0 || out != "fragment=written\n" {
		t.Errorf("legacy, tagged: rc %d %q %q", rc, out, errs)
	}
	if got, _ := os.ReadFile(dest); !bytes.Equal(got, legacy) {
		t.Errorf("legacy installed as %q", got)
	}
	os.Remove(dest)
	os.Mkdir(dest, 0o755)
	if rc, _, errs := fragmentArm(t, apps, legacy, true); rc != 1 || !strings.Contains(errs, "is a directory, not a route file: move it aside") || !strings.Contains(errs, "re-run the deploy") {
		t.Errorf("directory: rc %d %q", rc, errs)
	}
}

// The engine renders the fragment before anything changes: a key the .env
// lacks stops the run with nothing started, naming the step that sets it.
func TestEnginePreflightRendersTheFragment(t *testing.T) {
	r := newRig(t)
	os.WriteFile(filepath.Join(r.dir, "versions.log"), []byte("2026-10-01T00:00:00+00:00 deploy 0.9.0 no-backup kasbah=0.1.0 digest=-\n"), 0o640)
	r.running("demo-web=running")
	os.WriteFile(filepath.Join(r.dir, ".env.prod.example"), []byte("AUTH_USERS=\n"), 0o644)
	sp := r.spec()
	sp.Fragment, sp.Target = authFrag, "d@h"
	for _, env := range []string{"", "AUTH_USERS=\n", "OTHER=1\n"} {
		os.WriteFile(filepath.Join(r.dir, ".env"), []byte(env), 0o600)
		os.Remove(r.log)
		rc, out, errs := r.run(sp)
		if rc != 1 || !strings.Contains(errs, "${AUTH_USERS}") || !strings.Contains(errs, "`kasbah env set AUTH_USERS d@h` sets it") || strings.Contains(out, ReportKey) {
			t.Errorf("%q: rc %d %q", env, rc, errs)
		}
		for _, c := range r.calls() {
			if strings.HasPrefix(c, "hook") || strings.Contains(c, "compose") || strings.Contains(c, " tag ") {
				t.Errorf("%q: ran %q before the preflight refused", env, c)
			}
		}
	}
	sp.Fragment = "a: ${KASBAH_CPU_LIMIT}\n"
	if rc, _, errs := r.run(sp); rc != 1 || !strings.Contains(errs, "is a KASBAH_ key") {
		t.Errorf("reserved: rc %d %q", rc, errs)
	}
	sp.Fragment = authFrag
	os.WriteFile(filepath.Join(r.dir, ".env"), []byte("AUTH_USERS=admin:x\n"), 0o600)
	if rc, out, errs := r.run(sp); rc != 0 || !strings.Contains(out, ReportKey) {
		t.Errorf("set: rc %d %q", rc, errs)
	}
	// An old version's undeclared ${…} is kept as written, with one warning.
	sp.Fragment, sp.Tagged = authFrag+"# ^/(.*)${LEGACY}\n", true
	if rc, _, errs := r.run(sp); rc != 0 || strings.Count(errs, "keeps ${LEGACY} as written") != 1 {
		t.Errorf("tagged: rc %d %q", rc, errs)
	}
}
