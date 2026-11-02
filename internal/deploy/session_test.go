package deploy

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// fakeRunSSH stands in for ssh: it keeps the spec line, asks when ASK is set,
// and records whether stdin then ends (eof) or stays open (open).
func fakeRunSSH(t *testing.T) (*SSH, string) {
	t.Helper()
	dir := t.TempDir()
	script := `#!/bin/sh
set -u
d=$(dirname "$0")
IFS= read -r spec; printf '%s\n' "$spec" > "$d/spec"
if [ -n "${ASK:-}" ]; then
	printf '{"kasbah_deploy_question":1,"step":"pre-deploy hook","error":"e"}\n'
	IFS= read -r ans; printf '%s\n' "$ans" > "$d/answer"
fi
# A read still blocked after half a second means stdin is open.
exec 3<&0
{ more=; if IFS= read -r more <&3 || [ -n "$more" ]; then printf 'more:%s\n' "$more"; else echo eof; fi > "$d/got.tmp"; mv "$d/got.tmp" "$d/got"; } >/dev/null 2>&1 &
i=0
while [ ! -e "$d/got" ] && [ "$i" -lt 10 ]; do sleep 0.05; i=$((i + 1)); done
if [ -e "$d/got" ]; then cat "$d/got"; else echo open; fi > "$d/rest"
kill "$!" 2>/dev/null
exit 0
`
	if err := os.WriteFile(filepath.Join(dir, "ssh"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	tgt, err := ssh.ParseTarget("deploy@vps")
	if err != nil {
		t.Fatal(err)
	}
	return &SSH{&env.SSH{Conn: &ssh.Conn{Target: tgt}}}, dir
}

// Run writes the spec as one line; a given --on-hook-failure= closes stdin
// after it, and without one stdin stays open for the answer.
func TestSSHRunFraming(t *testing.T) {
	for _, tc := range []struct {
		name, flag, ask, answer, rest string
	}{
		{"flag given", AnswerStop, "", "", "eof"},
		{"asked", "", "1", AnswerContinue, "open"},
	} {
		s, dir := fakeRunSSH(t)
		t.Setenv("ASK", tc.ask)
		sp := Spec{Mode: "deploy", Version: "1.0.0", OnHookFailure: tc.flag}
		var asked []Question
		s.Run("/apps/demo", sp, func(q Question) string { asked = append(asked, q); return tc.answer })
		want, _ := json.Marshal(sp)
		read := func(f string) string { b, _ := os.ReadFile(filepath.Join(dir, f)); return string(b) }
		if got := read("spec"); got != string(want)+"\n" {
			t.Errorf("%s: spec line %q, want %q", tc.name, got, want)
		}
		if got := strings.TrimSpace(read("rest")); got != tc.rest {
			t.Errorf("%s: stdin after the spec: %s, want %s", tc.name, got, tc.rest)
		}
		if tc.ask != "" && (len(asked) != 1 || strings.TrimSpace(read("answer")) != tc.answer) {
			t.Errorf("%s: asked %v, answered %q", tc.name, asked, read("answer"))
		}
	}
}
