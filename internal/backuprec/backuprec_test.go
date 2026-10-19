package backuprec

import (
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestEpoch(t *testing.T) {
	for v, want := range map[string]bool{
		"0": true, "1": true, "1787000000": true, "999999999999999999": true,
		"01700000000": false, "01999000009": false, "1000000000000000000": false,
		"999999999999999999999999": false, "": false, "abc": false, "12a": false,
		"-1": false, "+1": false, " 1": false, "1 ": false, "007": false,
	} {
		if _, ok := Epoch(v); ok != want {
			t.Errorf("Epoch(%q) = %v, want %v", v, ok, want)
		}
	}
}

// The runner's is_epoch is the other implementation of the rule; the two
// must agree value for value.
func TestEpochMatchesRunner(t *testing.T) {
	src, err := os.ReadFile("../../templates/backup/backup.sh")
	if err != nil {
		t.Skip("no runner template")
	}
	var fn []string
	in := false
	for _, l := range strings.Split(string(src), "\n") {
		if l == "is_epoch() {" {
			in = true
		}
		if in {
			fn = append(fn, l)
			if l == "}" {
				break
			}
		}
	}
	if len(fn) < 4 {
		t.Fatal("is_epoch not found in the runner")
	}
	script := strings.Join(fn, "\n") + "\nif is_epoch \"$1\"; then echo yes; else echo no; fi\n"
	for _, v := range []string{"0", "1", "1787000000", "999999999999999999", "01700000000", "01999000009",
		"1000000000000000000", "999999999999999999999999", "", "abc", "12a", "-1", "+1", " 1", "1 ", "007"} {
		out, err := exec.Command("sh", "-c", script, "sh", v).Output()
		if err != nil {
			t.Fatalf("runner on %q: %v", v, err)
		}
		_, ok := Epoch(v)
		if (strings.TrimSpace(string(out)) == "yes") != ok {
			t.Errorf("%q: runner says %s, Epoch says %v", v, out, ok)
		}
	}
}

func TestRead(t *testing.T) {
	ok := "state=sleeping\nsince=1999990000\ndeadline=2000086400\nnext_run=2000082800\nlast_run_started=1999980000\nlast_run_finished=1999983600\nlast_run_status=ok\nlast_run_repos= demo mail\r\n"
	for _, tc := range []struct {
		name, dir, file, content, now string
		verdict, reason               string
	}{
		{"ok", "dir", "file", ok, "2000000000", OK, ""},
		{"no stack", "absent", "file", ok, "2000000000", NoStack, "is not there"},
		{"stack not a dir", "notdir", "file", ok, "2000000000", NoStack, "exists and is not a directory"},
		{"no record", "dir", "absent", "", "2000000000", NoRecord, ""},
		{"empty", "dir", "empty", "", "2000000000", Unreadable, "is empty"},
		{"unreadable", "dir", "unreadable", "", "2000000000", Unreadable, "cannot be read by the ssh user"},
		{"not a file", "dir", "notfile", "", "2000000000", Unreadable, "exists and is not a regular file"},
		{"a directory", "dir", "dir", "", "2000000000", Unreadable, "is a directory"},
		{"unknown state", "dir", "weird", "", "2000000000", Unreadable, "is in a state this kasbah does not know ('weird')"},
		{"bytes lost", "dir", "file", "\n\n", "2000000000", Unreadable, "did not come back as readable bytes"},
		{"no state", "dir", "file", "deadline=1\n", "2000000000", Unparsed, "carries no scheduler state"},
		{"no deadline", "dir", "file", "state=x\n", "2000000000", Unparsed, "carries no deadline, which is the one field a verdict rests on"},
		{"octal deadline", "dir", "file", "state=x\ndeadline=01999000009\n", "2000000000", Unparsed, "records deadline='01999000009', which is not a unix time this kasbah can compare"},
		{"unknown status", "dir", "file", "state=x\ndeadline=2000086400\nlast_run_status=maybe\n", "2000000000", Unparsed, "records last_run_status='maybe', which this kasbah does not know"},
		{"never", "dir", "file", "state=running\ndeadline=2000086400\nlast_run_status=-\n", "2000000000", Never, ""},
		{"never, no status", "dir", "file", "state=running\ndeadline=2000086400\n", "2000000000", Never, ""},
		{"overdue", "dir", "file", "state=running\ndeadline=1999999000\nlast_run_status=ok\n", "2000000000", Overdue, ""},
		{"failed outranks overdue", "dir", "file", "state=running\ndeadline=1999999000\nlast_run_status=failed\n", "2000000000", Failed, ""},
		{"a deadline at the cap", "dir", "file", "state=x\ndeadline=999999999999999999\nlast_run_status=ok\n", "2000000000", OK, ""},
	} {
		r := Read(tc.dir, tc.file, tc.content, tc.now)
		if r.Verdict != tc.verdict || r.Reason != tc.reason {
			t.Errorf("%s: %s %q, want %s %q", tc.name, r.Verdict, r.Reason, tc.verdict, tc.reason)
		}
	}
	r := Read("dir", "file", ok, "2000000000")
	if r.Age != 16400 || r.Overdue != 0 || r.Repos != " demo mail" || r.Clock != "server" || r.NextRun != 2000082800 {
		t.Errorf("fields: %+v", r)
	}
	if r := Read("dir", "file", ok, "x"); r.Clock != "local" || r.Now < 1700000000 {
		t.Errorf("an unusable server clock falls back to this one, said: %+v", r)
	}
	if r := Read("dir", "file", "state=x\ndeadline=2000086400\nlast_run_finished=2000000500\nlast_run_status=ok\n", "2000000000"); r.Age != 0 {
		t.Errorf("a clock that went backwards is age 0, got %d", r.Age)
	}
}

func TestAgo(t *testing.T) {
	for s, want := range map[int64]string{-1: "unknown", 0: "0s", 59: "59s", 60: "1m", 3599: "59m", 3600: "1h", 172799: "47h", 172800: "2 day(s)"} {
		if got := Ago(s); got != want {
			t.Errorf("Ago(%d) = %q, want %q", s, got, want)
		}
	}
}

func TestRepoSet(t *testing.T) {
	ps := []Project{{"blog", "acme"}, {"demo", ""}, {"shop", "acme"}, {"x", "?"}, {"mail", ""}}
	if got := RepoSet(ps, true); !reflect.DeepEqual(got, []string{"acme", "demo", "x", "mail"}) {
		t.Errorf("got %v", got)
	}
	if got := RepoSet(nil, true); !reflect.DeepEqual(got, []string{"mail"}) {
		t.Errorf("got %v", got)
	}
	missing, orphan := Diff([]string{"acme", "demo"}, []string{"demo", "gone"})
	if !reflect.DeepEqual(missing, []string{"acme"}) || !reflect.DeepEqual(orphan, []string{"gone"}) {
		t.Errorf("got %v %v", missing, orphan)
	}
}

func TestCollect(t *testing.T) {
	apps := t.TempDir()
	data := filepath.Join(apps, "data")
	for _, d := range []string{".kasbah/backup/state", ".kasbah/backup/repos", "data", "traefik", "mail", "alpha", "beta", "gamma", "delta", "eps", ".hidden"} {
		os.MkdirAll(filepath.Join(apps, d), 0o755)
	}
	w := func(p, s string) { os.WriteFile(filepath.Join(apps, p), []byte(s), 0o600) }
	w(".kasbah/backup/state/status", "state=sleeping\n")
	w(".kasbah/backup/repos/alpha.pass", "x")
	w(".kasbah/backup/repos/acme.pass", "x")
	w(".kasbah/backup/repos/.x.pass", "x")
	w(".kasbah/backup/repos/note", "x")
	w("alpha/.kasbah-client", "acme\r\n")
	w("beta/.kasbah-client", "Acme\n")
	w("gamma/.kasbah-client", "traefik\n")
	w("delta/.kasbah-client", "acme")
	w("afile", "x")
	f := Collect(apps, data)
	if f.Dir != "dir" || f.Record != "file" || f.Content() != "state=sleeping\n" || !f.Mail || f.Now == "" {
		t.Errorf("facts: %+v", f)
	}
	if !reflect.DeepEqual(f.HasPass, []string{"acme", "alpha"}) {
		t.Errorf("haspass %v", f.HasPass)
	}
	want := []Project{{"alpha", "acme"}, {"beta", "?"}, {"delta", ""}, {"eps", ""}, {"gamma", "?"}}
	if !reflect.DeepEqual(f.Projects, want) {
		t.Errorf("projects %v, want %v", f.Projects, want)
	}
}
