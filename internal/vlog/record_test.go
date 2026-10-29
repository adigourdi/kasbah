package vlog

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func probe(t *testing.T, apps, name string) Probe {
	t.Helper()
	var out, errb bytes.Buffer
	if rc := Remote([]string{apps, name}, &out, &errb); rc != 0 {
		t.Fatalf("rc %d: %s", rc, errb.String())
	}
	var p Probe
	if err := json.Unmarshal(out.Bytes(), &p); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRemoteStates(t *testing.T) {
	apps := t.TempDir()
	dir := filepath.Join(apps, "demo")
	if p := probe(t, apps, "demo"); p.ActiveState != "missing" || p.ArchiveState != "missing" {
		t.Errorf("no project: %+v", p)
	}
	os.Mkdir(dir, 0o755)
	os.WriteFile(filepath.Join(dir, Log), nil, 0o644)
	os.Mkdir(filepath.Join(dir, Archive), 0o755)
	if p := probe(t, apps, "demo"); p.ActiveState != "empty" || p.ArchiveState != "notfile" {
		t.Errorf("empty, notfile: %+v", p)
	}
	os.WriteFile(filepath.Join(dir, Log), []byte("x\n"), 0o644)
	if p := probe(t, apps, "demo"); p.ActiveState != "ok" || p.ActiveB64 != base64.StdEncoding.EncodeToString([]byte("x\n")) {
		t.Errorf("ok: %+v", p)
	}
	os.WriteFile(filepath.Join(apps, "file"), nil, 0o644)
	if p := probe(t, apps, "file"); p.ActiveState != "notdir" {
		t.Errorf("a project path that is a file: %+v", p)
	}
	if os.Geteuid() != 0 {
		os.Chmod(filepath.Join(dir, Log), 0)
		if p := probe(t, apps, "demo"); p.ActiveState != "unreadable" {
			t.Errorf("unreadable: %+v", p)
		}
		os.Chmod(dir, 0o600)
		if p := probe(t, apps, "demo"); p.ActiveState != "noaccess" {
			t.Errorf("noaccess: %+v", p)
		}
		os.Chmod(dir, 0o755)
	}
}

func encode(active, activeState, archiveState string, archive []byte) []byte {
	b, _ := json.Marshal(Probe{activeState, base64.StdEncoding.EncodeToString([]byte(active)), archiveState, base64.StdEncoding.EncodeToString(archive)})
	return b
}

func TestReadProbe(t *testing.T) {
	if _, err := ReadProbe([]byte(`{"active_state":"ok"}`), "d@h", "/a/demo/versions.log"); err == nil || !strings.Contains(err.Error(), "reported no active_b64 archive_state archive_b64") {
		t.Errorf("missing keys: %v", err)
	}
	if _, err := ReadProbe(encode("", "noaccess", "missing", nil), "d@h", "/a/demo/versions.log"); err == nil || !strings.Contains(err.Error(), "cannot be read — the probe called it 'noaccess'") {
		t.Errorf("an unusable active log: %v", err)
	}
	var z bytes.Buffer
	zw := gzip.NewWriter(&z)
	zw.Write([]byte("2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup\n2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup\n"))
	zw.Close()
	cut := z.Bytes()[:z.Len()-30]
	r, err := ReadProbe(encode("2026-08-01T00:00:00+00:00 rollback 1.0.0 no-backup\r\n \n", "ok", "ok", cut), "d@h", "/a/demo/versions.log")
	if err != nil {
		t.Fatal(err)
	}
	if !r.Damaged || r.Whole() || !strings.HasPrefix(r.Note(), "/a/demo/versions.log.gz ends in a truncated gzip member") || len(r.Warnings) != 3 {
		t.Errorf("truncated archive: %+v", r)
	}
	if arch, act := r.Count(); act != 1 || arch < 1 || r.Items[len(r.Items)-1].Archived {
		t.Errorf("counts %d %d", arch, act)
	}
	if i := r.LastActive(); i < 0 || r.Items[i].Version != "1.0.0" || r.Items[i].Action != "rollback" {
		t.Errorf("last active %d", i)
	}
	r, _ = ReadProbe(encode(" \n\n", "ok", "ok", []byte("plain")), "d@h", "/a/demo/versions.log")
	if r.ActiveState != "empty" || r.Reason != "is not gzip: no archived entry could be decoded" || len(r.Items) != 0 {
		t.Errorf("blank active, not-gzip archive: %+v", r)
	}
	b, _ := json.Marshal(Probe{"missing", "", "ok", "%%%"})
	r, _ = ReadProbe(b, "d@h", "/a/demo/versions.log")
	if r.Reason != "did not arrive as base64 from d@h" {
		t.Errorf("not base64: %+v", r)
	}
	b, _ = json.Marshal(Probe{"missing", "", "unreadable", ""})
	r, _ = ReadProbe(b, "d@h", "/a/demo/versions.log")
	if r.Whole() || r.Note() != "/a/demo/versions.log.gz could not be read (the probe called it 'unreadable'), so this is not the whole record" {
		t.Errorf("unreadable archive: %q", r.Note())
	}
}

func TestQueries(t *testing.T) {
	r := &Record{}
	for i, l := range []string{
		"2026-01-01T00:00:00+00:00 deploy 1.0.0 no-backup",
		"2026-02-01T00:00:00+00:00 deploy 2.0.0 no-backup",
		"2026-03-01T00:00:00+00:00 rollback 1.0.0 no-backup",
		"2026-04-01T00:00:00+00:00 deploy 3.0",
	} {
		r.Items = append(r.Items, Item{Parse(l), i < 1})
	}
	if i, skipped := r.PrevDeploy(); i != 0 || skipped != 1 {
		t.Errorf("PrevDeploy = %d %d", i, skipped)
	}
	if i, skipped := r.FindVersion("1.0.0"); i != 2 || skipped != 1 {
		t.Errorf("a rollback entry proves a version ran: %d %d", i, skipped)
	}
	if i, _ := r.FindVersion("9.9.9"); i != -1 {
		t.Errorf("absent: %d", i)
	}
	if i := r.LastActive(); i != 3 || r.Items[i].OK {
		t.Errorf("LastActive %d", i)
	}
}

func TestFailedEntries(t *testing.T) {
	e := Parse("2026-01-02T00:00:00+00:00 deploy-failed 1.1.0 no-backup kasbah=1.0.0 digest=- by=al reason=post-hook mode=rollback")
	if !e.IsFailed() || e.Reason != "post-hook" || e.Mode != "rollback" || e.By != "al" || e.DeployLike() {
		t.Errorf("parsed %+v", e)
	}
	r := &Record{}
	for _, l := range []string{"2026-01-01T00:00:00+00:00 deploy 1.0.0 -", "2026-01-02T00:00:00+00:00 deploy-failed 1.1.0 - reason=up"} {
		r.Items = append(r.Items, Item{Parse(l), false})
	}
	if i, _ := r.FindVersion("1.1.0"); i != -1 {
		t.Errorf("a version that only failed is a rollback target (%d)", i)
	}
	if i, _ := r.FindVersion("1.0.0"); i != 0 {
		t.Errorf("FindVersion(1.0.0) = %d", i)
	}
}

func TestPrevDeploySkipsDirty(t *testing.T) {
	rec := func(lines ...string) *Record {
		r := &Record{}
		for _, l := range lines {
			r.Items = append(r.Items, Item{Parse(l), false})
		}
		return r
	}
	const d = "2026-01-01T00:00:00+00:00 deploy "
	const f = "2026-01-02T00:00:00+00:00 deploy-failed "
	for _, tt := range []struct {
		lines []string
		want  int
	}{
		// The running one counts as the latest even when dirty; an earlier dirty one is never the target.
		{[]string{d + "1.0.0 -", d + "1.1.0-dirty.20260101000000 -", d + "1.1.0 -"}, 0},
		{[]string{d + "1.0.0 -", d + "1.1.0-dirty.20260101000000 -"}, 0},
		{[]string{d + "1.0.0-dirty.20260101000000 -", d + "1.1.0 -"}, -1},
		{[]string{d + "1.0.0 -", d + "1.0.0-dirty.20260101000000 -", d + "1.0.0-dirty.20260102000000 -"}, 0},
		// A failed deploy is the running one when newest, never the target;
		// a failed rollback, like a rollback, is not counted at all.
		{[]string{d + "1.0.0 -", d + "1.1.0 -", f + "1.2.0 - reason=post-hook"}, 1},
		{[]string{d + "1.0.0 -", f + "1.1.0 - reason=revert", f + "1.1.0 - reason=post-hook"}, 0},
		{[]string{f + "1.0.0 - reason=post-hook", d + "1.1.0 -"}, -1},
		{[]string{d + "1.0.0 -", f + "1.1.0 - reason=revert", d + "1.1.0 -"}, 0},
		{[]string{d + "1.0.0 -", d + "1.1.0 -", f + "1.0.0 - reason=post-hook mode=rollback"}, 0},
	} {
		if i, _ := rec(tt.lines...).PrevDeploy(); i != tt.want {
			t.Errorf("PrevDeploy over %q = %d, want %d", tt.lines, i, tt.want)
		}
	}
}

// The cases the retired Bash suite held: an active log that is not base64,
// a last line with no newline, a zero-byte log this user cannot read.
func TestReadProbeEdges(t *testing.T) {
	b, _ := json.Marshal(Probe{"ok", "%%%", "missing", ""})
	if _, err := ReadProbe(b, "d@h", "/a/demo/versions.log"); err == nil ||
		!strings.Contains(err.Error(), "sent /a/demo/versions.log back as something that is not base64") {
		t.Errorf("active not base64: %v", err)
	}
	r, err := ReadProbe(encode("2026-08-01T00:00:00+00:00 deploy 1.0.0 no-backup\n2026-08-02T00:00:00+00:00 deploy 1.1.0 no-backup", "ok", "missing", nil), "d@h", "/a/demo/versions.log")
	if err != nil || len(r.Items) != 2 || r.Items[1].Version != "1.1.0" || !r.Items[1].OK {
		t.Errorf("a final line without a newline: %+v %v", r, err)
	}

	apps := t.TempDir()
	dir := filepath.Join(apps, "demo")
	os.Mkdir(dir, 0o755)
	os.WriteFile(filepath.Join(dir, Log), nil, 0)
	if os.Geteuid() != 0 {
		if p := probe(t, apps, "demo"); p.ActiveState != "unreadable" {
			t.Errorf("an unreadable zero-byte log reads %s, not unreadable", p.ActiveState)
		}
	}
}
