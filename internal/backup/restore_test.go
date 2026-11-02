package backup

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

// resticRestoreStub answers snapshots, ls and dump as restic 0.18 prints
// them: three snapshots out of order, one not holding alpha's backups/.
const resticRestoreStub = `printf '%s\n' "$*" >> "$STUB_LOG"
case $1 in
snapshots) cat <<EOF
[{"time":"2026-11-02T03:00:00.5+01:00","paths":["APPS/alpha/backups","APPS/alpha/.env"],"id":"bbbbbbbb22222222","short_id":"bbbbbbbb"},
 {"time":"2026-11-01T02:00:00Z","paths":["APPS/alpha/backups"],"id":"aaaaaaaa11111111","short_id":"aaaaaaaa"},
 {"time":"2026-11-03T02:00:00Z","paths":["APPS/beta/.env"],"id":"cccccccc33333333","short_id":"cccccccc"}]
EOF
;;
ls) echo '{"time":"x","struct_type":"snapshot","message_type":"snapshot"}'
    for n in 1.0.0-20261101-000000.tar.gz 0.9.0-20261102-000000.tar.gz notes.txt; do
      printf '{"name":"%s","type":"file","path":"%s/%s","size":7,"message_type":"node"}\n' "$n" "$4" "$n"
    done
    printf '{"name":"1.0.0-20261101-000001.tar.gz","type":"dir","path":"%s/1.0.0-20261101-000001.tar.gz"}\n' "$4"
    printf '{"name":"1.0.0-20261101-000002.tar.gz","type":"file","path":"%s/sub/1.0.0-20261101-000002.tar.gz"}\n' "$4" ;;
dump) [ -z "$DUMP_TMP" ] || ls -A "$DUMP_TMP" >> "$STUB_LOG.tmp"
    [ -z "$DUMP_FAIL" ] || exit 1; printf 'tarball bytes of %s' "$3" ;;
esac
`

func restoreRunner(t *testing.T) (*Runner, *bytes.Buffer, *bytes.Buffer, string, string) {
	apps, data := appsTree(t)
	write(t, apps+"/.kasbah/backup/env", "KASBAH_BACKUP_REPO_BASE=rest:http://h/b/\n")
	r, out, errb, _ := runner(apps, data, time.Now())
	logf := t.TempDir() + "/log"
	r.Restic = stub(t, strings.ReplaceAll(resticRestoreStub, "APPS", apps))
	r.Environ = append(r.Environ, "STUB_LOG="+logf)
	return r, out, errb, apps, logf
}

// The newest snapshot holding the project's backups/ is listed by default, a
// prefix chooses another, and only the backups directly in backups/ count.
func TestRestoreList(t *testing.T) {
	for _, tc := range []struct {
		args       []string
		snap, ids  string
		wantBackup string
	}{
		{nil, "bbbbbbbb", "aaaaaaaa bbbbbbbb", "0.9.0-20261102-000000.tar.gz 1.0.0-20261101-000000.tar.gz"},
		{[]string{"--snapshot", "aaaa"}, "aaaaaaaa", "aaaaaaaa bbbbbbbb", "0.9.0-20261102-000000.tar.gz 1.0.0-20261101-000000.tar.gz"},
	} {
		r, out, errb, apps, logf := restoreRunner(t)
		if rc := r.Run(append([]string{"restore-list", "--project", "alpha"}, tc.args...)); rc != 0 {
			t.Fatalf("%v: rc %d %s", tc.args, rc, errb)
		}
		var l RestoreList
		if err := json.Unmarshal(out.Bytes(), &l); err != nil {
			t.Fatalf("%v: %v %s", tc.args, err, out)
		}
		var ids, names []string
		for _, s := range l.Snapshots {
			ids = append(ids, s.ID)
		}
		for _, b := range l.Backups {
			names = append(names, b.Name)
		}
		if l.Repo != "acme" || l.Snapshot != tc.snap || strings.Join(ids, " ") != tc.ids || strings.Join(names, " ") != tc.wantBackup || l.Path != apps+"/alpha/backups" {
			t.Errorf("%v: %+v", tc.args, l)
		}
		if l.Snapshots[1].Time != "2026-11-02T02:00:00Z" {
			t.Errorf("time not in UTC: %+v", l.Snapshots)
		}
		if calls := read(t, logf); !strings.Contains(calls, "ls --json "+tc.snap) {
			t.Errorf("ls of the wrong snapshot:\n%s", calls)
		}
	}
	r, out, errb, _, _ := restoreRunner(t)
	for _, args := range [][]string{{"--project", "alpha", "--snapshot", "cccc"}, {"--project", "nope"}, {"--project", "alpha", "--snapshot", "XYZ"}, {"alpha"}} {
		out.Reset()
		errb.Reset()
		if rc := r.Run(append([]string{"restore-list"}, args...)); rc != 1 || out.Len() != 0 || errb.Len() == 0 {
			t.Errorf("%v: rc %d out %q err %q", args, rc, out, errb)
		}
	}
}

// The dump is announced, size and sha256, before its bytes; a failed dump
// writes nothing on stdout.
func TestRestoreDump(t *testing.T) {
	r, out, errb, apps, logf := restoreRunner(t)
	if rc := r.Run([]string{"restore-dump", "--project", "alpha", "bbbb", "1.0.0-20261101-000000.tar.gz"}); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb)
	}
	body := "tarball bytes of " + apps + "/alpha/backups/1.0.0-20261101-000000.tar.gz"
	sum := sha256.Sum256([]byte(body))
	if want := fmt.Sprintf("%s size=%d sha256=%s\n%s", DumpKey, len(body), hex.EncodeToString(sum[:]), body); out.String() != want {
		t.Errorf("got %q\nwant %q", out, want)
	}
	if calls := read(t, logf); !strings.Contains(calls, "dump bbbbbbbb22222222 "+apps+"/alpha/backups/1.0.0-20261101-000000.tar.gz") {
		t.Errorf("calls:\n%s", calls)
	}
	r.Environ = append(r.Environ, "DUMP_FAIL=1")
	out.Reset()
	if rc := r.Run([]string{"restore-dump", "--project", "alpha", "--snapshot", "bbbb", "bbbb", "1.0.0-20261101-000000.tar.gz"}); rc != 1 || out.Len() != 0 {
		t.Errorf("--snapshot accepted by restore-dump: rc %d", rc)
	}
	for _, args := range [][]string{{"--project", "alpha", "bbbb", "1.0.0-20261101-000000.tar.gz"}, {"--project", "alpha", "bbbb", "../etc/passwd"},
		{"--project", "alpha", "dddd", "1.0.0-20261101-000000.tar.gz"}, {"--project", "alpha", "bbbb"}} {
		out.Reset()
		if rc := r.Run(append([]string{"restore-dump"}, args...)); rc != 1 || out.Len() != 0 {
			t.Errorf("%v: rc %d out %q", args, rc, out)
		}
	}
}

// The dump's temp file is never on disk under a name: unlinked before restic
// writes into it, so no exit can leave it.
func TestRestoreDumpTempUnlinked(t *testing.T) {
	r, _, errb, _, logf := restoreRunner(t)
	tmp := t.TempDir()
	t.Setenv("TMPDIR", tmp)
	r.Environ = append(r.Environ, "DUMP_TMP="+tmp)
	if rc := r.Run([]string{"restore-dump", "--project", "alpha", "bbbb", "1.0.0-20261101-000000.tar.gz"}); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb)
	}
	if during := read(t, logf+".tmp"); during != "" {
		t.Errorf("during the dump %s held: %q", tmp, during)
	}
	if es, _ := os.ReadDir(tmp); len(es) != 0 {
		t.Errorf("after the dump %s holds %v", tmp, es)
	}
}

// With no snapshot at the paths looked at, the listing names the paths in the
// repository's snapshots that hold tarballs; --from-path chooses one, and one
// no snapshot holds is refused.
func TestRestoreListFromPath(t *testing.T) {
	r, out, errb, apps, _ := restoreRunner(t)
	if rc := r.Run([]string{"restore-list", "--project", "beta"}); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb)
	}
	var l RestoreList
	if err := json.Unmarshal(out.Bytes(), &l); err != nil || len(l.Snapshots) != 0 || l.Snapshot != "" ||
		strings.Join(l.Looked, " ") != apps+"/beta/backups" || strings.Join(l.Elsewhere, " ") != apps+"/alpha/backups" {
		t.Fatalf("%v %+v", err, l)
	}
	out.Reset()
	if rc := r.Run([]string{"restore-list", "--project", "beta", "--from-path", apps + "/alpha/backups", "--snapshot", "aaaa"}); rc != 0 {
		t.Fatalf("rc %d %s", rc, errb)
	}
	l = RestoreList{}
	if err := json.Unmarshal(out.Bytes(), &l); err != nil || l.Snapshot != "aaaaaaaa" || len(l.Snapshots) != 2 || l.Path != apps+"/alpha/backups" || len(l.Backups) != 2 {
		t.Fatalf("%v %+v", err, l)
	}
	out.Reset()
	if rc := r.Run([]string{"restore-dump", "--project", "beta", "--from-path", apps + "/alpha/backups", "bbbb", "1.0.0-20261101-000000.tar.gz"}); rc != 0 ||
		!strings.Contains(out.String(), "tarball bytes of "+apps+"/alpha/backups/1.0.0-20261101-000000.tar.gz") {
		t.Errorf("rc %d %q %s", rc, out, errb)
	}
	for _, args := range [][]string{{"--from-path", "/nowhere/backups"}, {"--from-path", "rel"}, {"--from-path", "/a/../b"}, {"--from-path", "/a", "--from-path", "/b"}} {
		out.Reset()
		errb.Reset()
		if rc := r.Run(append([]string{"restore-list", "--project", "beta"}, args...)); rc != 1 || out.Len() != 0 {
			t.Errorf("%v: rc %d %q", args, rc, out)
		}
	}
	if !strings.Contains(errb.String(), "usage: restore-list") {
		t.Errorf("stderr: %s", errb)
	}
}
