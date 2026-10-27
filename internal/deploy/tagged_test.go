package deploy

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/vlog"
)

func git(t *testing.T, args ...string) {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"}, args...)...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git %v: %v %s", args, err, out)
	}
}

func write(t *testing.T, files map[string]string) {
	t.Helper()
	for n, b := range files {
		os.MkdirAll(filepath.Dir(n), 0o777)
		if err := os.WriteFile(n, []byte(b), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// history is a checkout where v1.0.0 and HEAD (v2.0.0) disagree about
// everything the invariant covers: sync list, images, hooks, fragment, client.
func history(t *testing.T, v1extra string) {
	t.Helper()
	t.Chdir(t.TempDir())
	write(t, map[string]string{
		"kasbah.yml": "schema: 1\nname: demo\nsync:\n  - compose.prod.yml -> compose.yml\n  - .env.prod.example\n  - conf/\n" +
			"hooks:\n  pre-rollback:\n    - 'demo-web echo v1-pre-rollback'\n  pre-deploy:\n    - 'demo-web echo v1-pre-deploy'\n" + v1extra,
		"compose.prod.yml":    "services:\n  web:\n    build: .\n    image: demo-web:current\n  cache:\n    build: .\n    image: demo-cache:current\n",
		".env.prod.example":   "A=1\n",
		"conf/app.conf":       "v1\n",
		"traefik-dynamic.yml": "# v1\n",
	})
	git(t, "init", "-q", ".")
	git(t, "add", "-A")
	git(t, "commit", "-qm", "one")
	git(t, "tag", "v1.0.0")
	os.RemoveAll("conf")
	write(t, map[string]string{
		"kasbah.yml":          "schema: 1\nname: demo\nclient: acme\nsync:\n  - compose.prod.yml -> compose.yml\n  - .env.prod.example\n  - extra.txt\nhooks:\n  pre-rollback:\n    - 'demo-web echo HEAD'\n",
		"compose.prod.yml":    "services:\n  web:\n    build: .\n    image: demo-web:current\n  worker:\n    build: .\n    image: demo-worker:current\n",
		"extra.txt":           "x\n",
		"traefik-dynamic.yml": "# HEAD\n",
	})
	git(t, "add", "-A")
	git(t, "commit", "-qm", "two")
	git(t, "tag", "v2.0.0")
}

func record(active, archive string, whole bool) *vlog.Record {
	r := &vlog.Record{ActivePath: "/apps/demo/versions.log", ArchivePath: "/apps/demo/versions.log.gz", ActiveState: "ok", ArchiveState: "missing"}
	if archive != "" || !whole {
		r.ArchiveState = "ok"
	}
	if !whole {
		r.Damaged, r.Reason = true, "ends in a truncated gzip member: whatever is inside it could not be decoded"
	}
	for _, e := range vlog.Entries(archive) {
		r.Items = append(r.Items, vlog.Item{Entry: e, Archived: true})
	}
	for _, e := range vlog.Entries(active) {
		r.Items = append(r.Items, vlog.Item{Entry: e})
	}
	return r
}

const twoDeploys = "2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup kasbah=0.1.0 digest=-\n" +
	"2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup kasbah=0.1.0 digest=-\n"

func runTagged(t *testing.T, f *fake, o Options, mode string) (error, string) {
	t.Helper()
	var errb bytes.Buffer
	out := &cli.Output{Stdout: &errb, Stderr: &errb}
	pwd, _ := os.Getwd()
	err := RunTagged(Ctx{
		Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: out},
		PWD: pwd, Version: "0.1.0",
		Dial: func(string) (Server, error) { return f, nil },
		Now:  func() time.Time { return time.Unix(0, 0) },
	}, o, mode)
	if err != nil {
		out.Report(err)
	}
	return err, errb.String()
}

func TestRollbackShipsTheTag(t *testing.T) {
	history(t, "")
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	prev := "{\"" + ReportKey + "\":1,\"version\":\"1.0.0\",\"prev_version\":\"2.0.0\",\"deployed_before\":true,\"backup\":\"no-backup\",\"digest\":\"-\"}\n"
	f := &fake{record: record(twoDeploys, "", true), out: &prev}
	err, out := runTagged(t, f, Options{Target: "d@h"}, "rollback")
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if !strings.Contains(out, "rolling back to 1.0.0 — the second-most-recent `deploy` entry") {
		t.Errorf("implicit target not announced\n%s", out)
	}
	sp := f.spec
	if sp.Mode != "rollback" || sp.Version != "1.0.0" || strings.Join(sp.Pre, "|") != "demo-web echo v1-pre-rollback" {
		t.Errorf("spec from v1.0.0's manifest: %+v", sp)
	}
	if strings.Join(sp.Images, ",") != "demo-cache,demo-web" {
		t.Errorf("images from v1.0.0's compose: %v", sp.Images)
	}
	var syncs []string
	for _, c := range f.calls {
		if s, ok := strings.CutPrefix(c, "sync "); ok {
			if !strings.HasPrefix(s, tmp) {
				t.Errorf("synced from outside the extraction: %s", s)
			}
			syncs = append(syncs, filepath.Base(s))
		}
	}
	if strings.Join(syncs, ",") != "compose.prod.yml,.env.prod.example,conf" {
		t.Errorf("v1.0.0's sync list: %v", syncs)
	}
	if last := f.calls[len(f.calls)-1]; last != "fragment /apps/traefik/dynamic/demo.yml" {
		t.Errorf("the fragment ships last: %v", f.calls)
	}
	if f.client != "demo" {
		t.Errorf("client from v1.0.0 (none: the name), got %q", f.client)
	}
	if !strings.Contains(out, "Rolled demo back to 1.0.0 on d@h") || !strings.Contains(out, "gave up: v1.0.0..v2.0.0 — no longer deployed") {
		t.Errorf("banner and what it gave up\n%s", out)
	}
	if v, _ := state.Get(state.File, "last_version"); v != "1.0.0" {
		t.Errorf("last_version %q", v)
	}
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("the extraction outlived the run: %v", ents)
	}
	if b, _ := os.ReadFile("traefik-dynamic.yml"); string(b) != "# HEAD\n" {
		t.Errorf("the working tree was touched")
	}
}

func TestDeployVersion(t *testing.T) {
	history(t, "client: 'bad client'\n")
	f := &fake{}
	err, out := runTagged(t, f, Options{Target: "d@h", Version: "1.0.0"}, "deploy")
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if f.called("record") {
		t.Error("a tagged deploy read the record")
	}
	if f.spec.Mode != "deploy" || strings.Join(f.spec.Pre, "|") != "demo-web echo v1-pre-deploy" {
		t.Errorf("spec %+v", f.spec)
	}
	if f.client != "demo" || !strings.Contains(out, "falling back to 'demo'") {
		t.Errorf("a tag's bad client: warns and falls back (%q)\n%s", f.client, out)
	}
	if !strings.Contains(out, "Deployed demo 1.0.0 to d@h") {
		t.Errorf("banner\n%s", out)
	}
}

func TestRollbackRefusals(t *testing.T) {
	cases := []struct {
		name string
		o    Options
		f    *fake
		want string
	}{
		{"never deployed", Options{Target: "d@h", Version: "1.0.0"},
			&fake{record: record("2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup\n", "", true)},
			"Version 1.0.0 was never deployed to this VPS."},
		{"half-read archive", Options{Target: "d@h", Version: "1.0.0"},
			&fake{record: record("2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup\n", "", false)},
			"is not in what kasbah could read of this VPS's deploy record"},
		{"a damaged line", Options{Target: "d@h", Version: "1.0.0"},
			&fake{record: record("2026-01-01T00:00:00+00:00 dep\n2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup\n", "", true)},
			"1 line(s) of it could not be read"},
		{"no earlier deploy", Options{Target: "d@h"},
			&fake{record: record("2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup\n", "", true)},
			"there is no earlier deploy of demo on d@h to roll back to"},
		{"empty, archive unread", Options{Target: "d@h"},
			&fake{record: record("", "", false)},
			"this is not evidence that"},
		{"image gone", Options{Target: "d@h", Version: "1.0.0"},
			&fake{record: record(twoDeploys, "", true), missing: []string{"demo-web", "demo-cache"}},
			"Image demo-cache:1.0.0 is no longer on the VPS (outside the"},
		{"no tag", Options{Target: "d@h", Version: "3.0.0"},
			&fake{record: record("2026-02-01T00:00:00+00:00 deploy 3.0.0 no-backup\n", "", true)},
			"v3.0.0 is not a tag in this repository"},
	}
	for _, c := range cases {
		history(t, "")
		err, out := runTagged(t, c.f, c.o, "rollback")
		if err == nil || !strings.Contains(out, c.want) {
			t.Errorf("%s: %v\n%s", c.name, err, out)
		}
		if c.f.called("prepare") || c.f.called("sync") || c.f.called("run") {
			t.Errorf("%s: reached the server's files: %v", c.name, c.f.calls)
		}
		noState(t, c.name)
	}
}

func TestTaggedRefChecks(t *testing.T) {
	history(t, "")
	write(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nsync:\n  - compose.prod.yml -> compose.yml\n  - gone.txt\n  - extra.txt/\n"})
	git(t, "add", "-A")
	git(t, "commit", "-qm", "three")
	git(t, "tag", "v3.0.0")
	f := &fake{}
	err, out := runTagged(t, f, Options{Target: "d@h", Version: "3.0.0"}, "deploy")
	if err == nil || !strings.Contains(out, "gone.txt — no such path at v3.0.0") || !strings.Contains(out, "listed with a trailing slash") {
		t.Errorf("inconsistent tag: %v\n%s", err, out)
	}
	if f.called("marker") {
		t.Error("a named deploy connected before judging the checkout")
	}

	history(t, "")
	write(t, map[string]string{".git/info/attributes": "conf/app.conf export-ignore\n"})
	err, out = runTagged(t, &fake{}, Options{Target: "d@h", Version: "1.0.0"}, "deploy")
	if err == nil || !strings.Contains(out, "conf/app.conf — in the tag's tree, not in the archive") {
		t.Errorf("export-ignore: %v\n%s", err, out)
	}
}

// A signal ends the process through atexit, which a defer never sees: the
// extraction is registered there for as long as it exists.
func TestExtractionGoesOnASignal(t *testing.T) {
	history(t, "")
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	m, err := manifest.Require(manifest.File, "0.1.0")
	if err != nil {
		t.Fatal(err)
	}
	var b bytes.Buffer
	r := &run{c: Ctx{Out: &cli.Output{Stdout: &b, Stderr: &b}, Version: "0.1.0"}, m: m, target: "d@h", version: "1.0.0", mode: "rollback"}
	tg := &tagged{}
	if err := r.readRef(tg); err != nil {
		t.Fatalf("%v\n%s", err, b.String())
	}
	if _, err := os.Stat(tg.extract); err != nil {
		t.Fatal("no extraction")
	}
	atexit.Run()
	if ents, _ := os.ReadDir(tmp); len(ents) != 0 {
		t.Errorf("the extraction survived the exit path: %v", ents)
	}
}

// The mail claim is the tag's: v1.0.0 claims tag.test, HEAD head.test.
func TestRollbackMailClaimIsTheTags(t *testing.T) {
	history(t, "mail:\n  domain: tag.test\n")
	write(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nmail:\n  domain: head.test\nsync:\n  - compose.prod.yml -> compose.yml\n"})
	git(t, "commit", "-qam", "head claims another domain")
	f := &fake{record: record(twoDeploys, "", true), mail: facts("primary_domain: tag.test\ndomains:\n  - tag.test\n", "running")}
	err, out := runTagged(t, f, Options{Target: "d@h", Version: "1.0.0"}, "rollback")
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if !strings.Contains(out, "mail: tag.test is served by the stack") || strings.Contains(out, "head.test") {
		t.Errorf("the claim checked was not v1.0.0's\n%s", out)
	}
}

// A symlink the tag carries ships as one, dangling or not, and the extraction
// keeps the tag's mtimes for the sync to carry on.
func TestRollbackShipsSymlinksAndMtimes(t *testing.T) {
	history(t, "")
	git(t, "checkout", "-q", "v1.0.0")
	os.Symlink("nowhere", "dangling")
	write(t, map[string]string{"kasbah.yml": "schema: 1\nname: demo\nsync:\n  - compose.prod.yml -> compose.yml\n  - dangling\n"})
	git(t, "add", "-A")
	git(t, "commit", "-qm", "a link")
	git(t, "tag", "v1.5.0")
	git(t, "checkout", "-q", "-")
	f := &fake{record: record(twoDeploys+"2026-03-01T00:00:00+00:00 deploy 1.5.0 no-backup\n2026-04-01T00:00:00+00:00 deploy 2.0.0 no-backup\n", "", true), mtimes: map[string]time.Time{}}
	err, out := runTagged(t, f, Options{Target: "d@h", Version: "1.5.0"}, "rollback")
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if !f.called("sync ") || f.mtimes["dangling"].IsZero() {
		t.Errorf("the link was not synced: %v", f.calls)
	}
	ct, _ := exec.Command("git", "log", "-1", "--format=%ct", "v1.5.0").Output()
	want := strings.TrimSpace(string(ct))
	if got := f.mtimes["compose.prod.yml"].Unix(); want == "" || fmt.Sprint(got) != want {
		t.Errorf("compose.prod.yml mtime %d, want the tag's %s", got, want)
	}
}

// An archive-only record is said as what it is, on both changelogs: not a
// first deploy, and not a last line that cannot be read.
func TestArchiveOnlyChangelogs(t *testing.T) {
	report := "{\"" + ReportKey + "\":1,\"version\":\"%s\",\"prev_version\":\"\",\"deployed_before\":true,\"backup\":\"no-backup\",\"digest\":\"-\",\"archive_only\":true}\n"
	history(t, "")
	r1 := fmt.Sprintf(report, "1.0.0")
	err, out := runTagged(t, &fake{record: record(twoDeploys, "", true), out: &r1}, Options{Target: "d@h", Version: "1.0.0"}, "rollback")
	if err != nil || !strings.Contains(out, "/apps/demo/versions.log held no entry — only") || strings.Contains(out, "last line") {
		t.Errorf("rollback: %v\n%s", err, out)
	}
	project(t, "")
	r2 := fmt.Sprintf(report, "1.0.0")
	err, out = deployWith(t, &fake{out: &r2}, Options{Target: "d@h"})
	if err != nil || !strings.Contains(out, "versions.log.gz does, so the active log was lost or replaced") || strings.Contains(out, "last line") || strings.Contains(out, "first deploy") {
		t.Errorf("deploy: %v\n%s", err, out)
	}
}

// A tag's hooks: may hold a key that is not a hook: it is named and ignored,
// so the version stays rollable; the working tree's manifest refuses it.
func TestDeployVersionUnknownHook(t *testing.T) {
	history(t, "  pre_deploy:\n    - 'ghost echo never'\n")
	f := &fake{}
	err, out := runTagged(t, f, Options{Target: "d@h", Version: "1.0.0"}, "deploy")
	if err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if strings.Join(f.spec.Pre, "|") != "demo-web echo v1-pre-deploy" {
		t.Errorf("spec %+v", f.spec)
	}
	if !strings.Contains(out, "the manifest in this version has hooks.pre_deploy, which is not a hook kasbah runs — ignored") {
		t.Errorf("no warning naming the key\n%s", out)
	}
}
