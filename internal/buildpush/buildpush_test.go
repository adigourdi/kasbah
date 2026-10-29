package buildpush

import (
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

func TestParse(t *testing.T) {
	for in, want := range map[string]string{
		"":                     "target= build=false nopush=false",
		"u@h":                  "target=u@h build=false nopush=false",
		"u@h\r":                "target=u@h build=false nopush=false",
		"--build-only":         "target= build=true nopush=false",
		"--no-git-push u@h":    "target=u@h build=false nopush=true",
		"--help":               "help",
		"-h --nope":            "help",
		"--nope --help":        "error: build-push: unknown flag '--nope'",
		"--nope=1":             "error: build-push: unknown flag '--nope'",
		"--build-only=yes":     "error: build-push: --build-only takes no value",
		"--no-git-push=true":   "error: build-push: --no-git-push takes no value",
		"u@h 1.4.2":            "error: build-push: too many arguments ('1.4.2')",
		"--dirty u@h":          "target=u@h build=false nopush=false dirty=true",
		"--dirty=1":            "error: build-push: --dirty takes no value",
		"--bump=minor u@h":     "target=u@h build=false nopush=false dirty=false bump=minor",
		"--bump=minor\r":       "target= build=false nopush=false dirty=false bump=minor",
		"--bump=huge":          "error: build-push: --bump=huge is not a bump",
		"--bump":               "error: build-push: --bump takes its value with '='",
		"--bump=patch --dirty": "error: build-push: --dirty ships under no tag",
	} {
		var args []string
		if in != "" {
			args = strings.Split(in, " ")
		}
		o, err := Parse(args)
		var got string
		switch {
		case err == ErrHelp:
			got = "help"
		case err != nil:
			got = "error: " + err.Error()
		default:
			got = "target=" + o.Target + " build=" + bstr(o.BuildOnly) + " nopush=" + bstr(o.NoGitPush) + " dirty=" + bstr(o.Dirty) + " bump=" + o.Bump
		}
		if !strings.HasPrefix(got, want) {
			t.Errorf("Parse(%q) = %q, want %q", in, got, want)
		}
	}
}

func bstr(b bool) string {
	if b {
		return "true"
	}
	return "false"
}

func TestBase(t *testing.T) {
	for in, want := range map[string]string{
		"built-app-web:current":                     "built-app-web",
		"built-app-bare":                            "built-app-bare",
		"reg.example:5000/built-app-worker:current": "reg.example:5000/built-app-worker",
		"reg.example:5000/built-app-ported":         "reg.example:5000/built-app-ported",
		"a/b/c:7":                                   "a/b/c",
	} {
		if got := Base(in); got != want {
			t.Errorf("Base(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestBuilt(t *testing.T) {
	for _, tt := range []struct{ name, yaml, want string }{
		{"keys order, stock skipped", `
services:
  worker: {build: ., image: "reg.example:5000/w:current"}
  cache: {image: redis:7-alpine}
  web: {build: {context: .}, image: web:current}
  bare: {build: ., image: bare}
`, "bare=bare->bare:1.2.3 web=web:current->web:1.2.3 worker=reg.example:5000/w:current->reg.example:5000/w:1.2.3"},
		{"build: null still builds", "services:\n  web:\n    build:\n    image: web:current\n", "web=web:current->web:1.2.3"},
		{"empty file", "", ""},
		{"no services", "name: x\n", ""},
		{"services null", "services:\n", ""},
		{"crlf", "services:\r\n  web:\r\n    build: .\r\n    image: web:current\r\n", "web=web:current->web:1.2.3"},
		{"no image", "services:\n  web: {build: .}\n", "error: compose.prod.yml: service 'web' builds an image but does not name one"},
		{"image null", "services:\n  web: {build: ., image: null}\n", "error: compose.prod.yml: service 'web' builds"},
		{"service a string", "services:\n  web: nginx\n", "error: compose.prod.yml: could not read service 'web'"},
		{"services a list", "services: [a]\n", "error: compose.prod.yml: could not read its services"},
		{"top level a list", "- a\n", "error: compose.prod.yml: could not read its services"},
	} {
		docs, err := yamlx.Load([]byte(tt.yaml))
		if err != nil {
			t.Fatalf("%s: %v", tt.name, err)
		}
		var doc any
		if len(docs) > 0 {
			doc = docs[0]
		}
		images, err := Built(doc, "demo", "1.2.3")
		var parts []string
		for _, im := range images {
			parts = append(parts, im.Service+"="+im.Source+"->"+im.Ref)
		}
		got := strings.Join(parts, " ")
		if err != nil {
			got = "error: " + err.Error()
		}
		if !strings.HasPrefix(got, tt.want) || (tt.want == "" && got != "") {
			t.Errorf("%s: got %q, want %q", tt.name, got, tt.want)
		}
	}
	docs, _ := yamlx.Load([]byte("services:\n  web: {build: .}\n"))
	_, err := Built(docs[0], "demo", "1.2.3")
	if e, ok := err.(*cli.Error); !ok || e.Code != 1 || !strings.Contains(e.Error(), "image: demo-web:current") {
		t.Errorf("no image: got %v, want exit 1 suggesting image: demo-web:current", err)
	}
}

// fakeDocker puts a docker first on PATH: `load` copies its stdin to
// $dir/loaded and writes $dir/load-done only if it is not killed before its
// stdin closes; `image inspect` fails for $FAKE_MISSING, `create` for
// $FAKE_UNCREATABLE.
func fakeDocker(t *testing.T) string {
	dir := t.TempDir()
	script := `#!/bin/sh
d=$(dirname "$0")
echo "$*" >> "$d/calls"
case "$1" in
load) cat > "$d/loaded"; echo done > "$d/load-done"; exit "${FAKE_LOAD_RC:-0}" ;;
image) [ "$3" = "${FAKE_MISSING:-}" ] && exit 1; exit 0 ;;
create) for a; do [ "$a" = true ] && break; img=$a; done
	[ "$img" = "${FAKE_UNCREATABLE:-}" ] && exit 1; echo "cid-$img"; exit 0 ;;
rm) exit 0 ;;
esac
exit 9
`
	if err := os.WriteFile(filepath.Join(dir, "docker"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return dir
}

func gz(t *testing.T, b []byte) []byte {
	var buf bytes.Buffer
	w := gzip.NewWriter(&buf)
	w.Write(b)
	w.Close()
	return buf.Bytes()
}

func TestLoad(t *testing.T) {
	tarball := bytes.Repeat([]byte("layer-bytes "), 50000)
	whole := gz(t, tarball)
	for _, tt := range []struct {
		name    string
		in      []byte
		env     map[string]string
		rc      int
		stdout  string
		stderr  string
		loaded  bool // the fake load saw its stdin close without being killed first
		inspect bool
	}{
		{name: "whole", in: whole, rc: 0, stdout: "loaded=2\n", loaded: true, inspect: true},
		{name: "empty", in: nil, rc: 1, stderr: "no image stream arrived"},
		{name: "not gzip", in: tarball, rc: 1, stderr: "not gzip"},
		{name: "truncated", in: whole[:len(whole)/2], rc: 1, stderr: "cut short or corrupted"},
		// Every byte of the tar reaches the fake; it is killed before EOF.
		{name: "no trailer", in: whole[:len(whole)-8], rc: 1, stderr: "cut short or corrupted"},
		{name: "load fails", in: whole, env: map[string]string{"FAKE_LOAD_RC": "3"}, rc: 1, stderr: "docker load exited 3", loaded: true},
		{name: "not unpacked", in: whole, env: map[string]string{"FAKE_UNCREATABLE": "b:1"}, rc: 1, stdout: "incomplete=b:1\n", stderr: "left b:1 unusable", loaded: true, inspect: true},
		{name: "image missing", in: whole, env: map[string]string{"FAKE_MISSING": "b:1"}, rc: 1, stderr: "b:1 is not on this server", loaded: true, inspect: true},
	} {
		t.Run(tt.name, func(t *testing.T) {
			dir := fakeDocker(t)
			for k, v := range tt.env {
				t.Setenv(k, v)
			}
			var out, errb bytes.Buffer
			rc := Load([]string{"a:1", "b:1"}, bytes.NewReader(tt.in), &out, &errb)
			if rc != tt.rc || out.String() != tt.stdout || !strings.Contains(errb.String(), tt.stderr) {
				t.Errorf("rc %d stdout %q stderr %q; want %d %q %q", rc, out.String(), errb.String(), tt.rc, tt.stdout, tt.stderr)
			}
			_, derr := os.Stat(filepath.Join(dir, "load-done"))
			if (derr == nil) != tt.loaded {
				t.Errorf("fake docker load finished unkilled: %v, want %v", derr == nil, tt.loaded)
			}
			if tt.loaded && tt.env == nil {
				got, _ := os.ReadFile(filepath.Join(dir, "loaded"))
				if !bytes.Equal(got, tarball) {
					t.Errorf("docker load read %d bytes, want the %d-byte tar", len(got), len(tarball))
				}
			}
			calls, _ := os.ReadFile(filepath.Join(dir, "calls"))
			if strings.Contains(string(calls), "image inspect") != tt.inspect {
				t.Errorf("inspect calls: %q", calls)
			}
		})
	}
	for _, tt := range []struct {
		args      []string
		rc        int
		out, errs string
	}{
		{nil, 1, "", "no images named"},
		{[]string{"--help"}, 0, "usage: kasbah remote load IMAGE...", ""},
		{[]string{"a:1", "-h"}, 0, "usage: kasbah remote load IMAGE...", ""},
		{[]string{"--force", "a:1"}, 1, "", "unknown flag '--force'"},
	} {
		dir := fakeDocker(t)
		var out, errb bytes.Buffer
		// stdin would block were it read: the refusals and --help never touch it.
		rc := Load(tt.args, blocking{}, &out, &errb)
		if rc != tt.rc || !strings.Contains(out.String(), tt.out) || !strings.Contains(errb.String(), tt.errs) {
			t.Errorf("Load(%q): rc %d stdout %q stderr %q", tt.args, rc, out.String(), errb.String())
		}
		if calls, _ := os.ReadFile(filepath.Join(dir, "calls")); len(calls) != 0 {
			t.Errorf("Load(%q) ran docker: %q", tt.args, calls)
		}
	}
}

type blocking struct{}

func (blocking) Read([]byte) (int, error) { select {} }
