package deploy

import (
	"bytes"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/tree"
)

// fakeRestore is a RestoreServer: a repository with two snapshots, the newest
// holding two backups of the live 1.0.0 and a newer one of 0.9.0.
type fakeRestore struct {
	disabled bool
	facts    *RestoreFacts
	probe    *BackupFacts
	kv       map[string]string
	calls    []string
	envAll   bool
	keys     []string
	data     bool
	fetched  string
}

func newFakeRestore() *fakeRestore {
	return &fakeRestore{
		facts: &RestoreFacts{State: "running", Live: "1.0.0", Hooks: true, RestoreHook: true, Local: []string{},
			List: &backup.RestoreList{Repo: "acme", Snapshot: "bbbbbbbb", Path: "/apps/built-app/backups",
				Snapshots: []backup.Snapshot{{ID: "aaaaaaaa", Time: "2026-11-01T02:00:00Z"}, {ID: "bbbbbbbb", Time: "2026-11-02T02:00:00Z"}},
				Backups: []backup.Tarball{{Name: "0.9.0-20261102-000000.tar.gz", Size: 5}, {Name: "1.0.0-20261101-000000.tar.gz", Size: 6},
					{Name: "1.0.0-20261101-120000.tar.gz", Size: 7}}}},
		probe: &BackupFacts{Env: "yes", Changed: []string{"A"}, OnlyBackup: []string{}, OnlyLive: []string{"C"}},
		kv:    map[string]string{"restore": "done", "env": "restored", "data": "restored", "recreated": "yes"},
	}
}

func (f *fakeRestore) Marker() (*marker.Marker, error) {
	js := `{"backup":{"enabled":true}}`
	if f.disabled {
		js = `{}`
	}
	v, _ := tree.ParseOne([]byte(js))
	return &marker.Marker{JSON: v.(*tree.Map), AppsPath: "/apps", DataPath: "/apps/data"}, nil
}
func (f *fakeRestore) HoldServer(string, string) (func(), error) {
	f.calls = append(f.calls, "hold")
	return func() {}, nil
}
func (f *fakeRestore) RestoreList(apps, name, snapshot, from string) (*RestoreFacts, error) {
	f.calls = append(f.calls, "list "+snapshot+from)
	return f.facts, nil
}
func (f *fakeRestore) FetchBackup(dir, snapshot, name, from string) (string, error) {
	f.calls = append(f.calls, "fetch "+snapshot+" "+name+" "+from)
	f.fetched = name
	return "fetched", nil
}
func (f *fakeRestore) ProbeNamed(dir, name string) (*BackupFacts, error) {
	f.calls = append(f.calls, "probe "+name)
	p := *f.probe
	p.Backup = name
	return &p, nil
}
func (f *fakeRestore) Restore(dir, name, live string, envRestore bool, keys []string, data bool) (map[string]string, error) {
	f.calls = append(f.calls, "restore "+dir+" "+name+" "+live)
	f.envAll, f.keys, f.data = envRestore && keys == nil, keys, data
	return f.kv, nil
}
func (f *fakeRestore) Close() {}

func (f *fakeRestore) called(prefix string) bool {
	for _, c := range f.calls {
		if strings.HasPrefix(c, prefix) {
			return true
		}
	}
	return false
}

func runRestore(t *testing.T, f *fakeRestore, o RestoreOptions, tty bool, answers string) (string, string, error) {
	t.Helper()
	t.Chdir(t.TempDir())
	os.WriteFile("kasbah.yml", []byte("schema: 1\nkasbah_version: 0.1.0\nname: built-app\ndomain: built-app.test\n"), 0o644)
	var so, se bytes.Buffer
	out := &cli.Output{Stdout: &so, Stderr: &se}
	if o.Target == "" {
		o.Target = "deploy@vps"
	}
	err := RunRestore(RestoreCtx{Out: out, Prompter: &prompt.Prompter{In: strings.NewReader(answers), Out: out, TTY: tty}, Version: "0.1.0",
		Dial: func(string) (RestoreServer, error) { return f, nil }}, o)
	if err != nil {
		out.Report(err)
	}
	return so.String(), se.String(), err
}

// The newest backup of the live version is the default; a named one of
// another version is allowed with a warning.
func TestRestoreChoosing(t *testing.T) {
	f := newFakeRestore()
	_, se, err := runRestore(t, f, RestoreOptions{Env: prompt.Yes, Data: prompt.Yes}, false, "")
	if err != nil || f.fetched != "1.0.0-20261101-120000.tar.gz" || !f.envAll || !f.data || strings.Contains(se, "may not fit") {
		t.Fatalf("%v fetched %q %v\n%s", err, f.fetched, f.calls, se)
	}
	if want := "hold, list"; f.calls[0] != "hold" || f.calls[1] != "list " {
		t.Errorf("calls %v (want %s first)", f.calls, want)
	}
	for _, w := range []string{"from snapshot bbbbbbbb (2026-11-02T02:00:00Z) of repository acme", "values differ:      A", "Restored built-app on deploy@vps", "recreated on the restored .env"} {
		if !strings.Contains(se, w) {
			t.Errorf("missing %q:\n%s", w, se)
		}
	}
	f = newFakeRestore()
	_, se, err = runRestore(t, f, RestoreOptions{Snapshot: "aaaa", Backup: "0.9.0-20261102-000000.tar.gz", Env: prompt.No, Data: prompt.Yes}, false, "")
	if err != nil || f.fetched != "0.9.0-20261102-000000.tar.gz" || f.calls[1] != "list aaaa" || !strings.Contains(se, "its data may not fit 1.0.0's schema") {
		t.Errorf("%v %v\n%s", err, f.calls, se)
	}
	// A name the snapshot does not hold, or no backup of the live version.
	f = newFakeRestore()
	_, se, err = runRestore(t, f, RestoreOptions{Backup: "1.0.0-20200101-000000.tar.gz"}, false, "")
	if err == nil || !strings.Contains(se, "holds no backup 1.0.0-20200101-000000.tar.gz") || f.called("fetch") {
		t.Errorf("%v %v\n%s", err, f.calls, se)
	}
	f = newFakeRestore()
	f.facts.Live = "2.0.0"
	_, se, err = runRestore(t, f, RestoreOptions{Env: prompt.Yes, Data: prompt.Yes}, false, "")
	if err == nil || !strings.Contains(se, "holds no backup of 2.0.0, the version live") || !strings.Contains(se, "--backup=NAME") || f.called("fetch") {
		t.Errorf("%v %v\n%s", err, f.calls, se)
	}
}

// --list prints the snapshots and the chosen one's backups, and changes nothing.
func TestRestoreList(t *testing.T) {
	f := newFakeRestore()
	f.facts.Local = []string{"1.0.0-20261101-000000.tar.gz"}
	so, se, err := runRestore(t, f, RestoreOptions{List: true}, false, "")
	if err != nil || f.called("fetch") || f.called("restore") {
		t.Fatalf("%v %v\n%s", err, f.calls, se)
	}
	for _, w := range []string{"  aaaaaaaa  2026-11-01T02:00:00Z\n", "  bbbbbbbb  2026-11-02T02:00:00Z  (listed below)\n",
		"Backups in snapshot bbbbbbbb (/apps/built-app/backups):", "  1.0.0-20261101-120000.tar.gz  7 bytes  (the default: newest of the live version 1.0.0)\n",
		"  1.0.0-20261101-000000.tar.gz  6 bytes  (already on deploy@vps)\n"} {
		if !strings.Contains(so, w) {
			t.Errorf("missing %q:\n%s", w, so)
		}
	}
	// Nothing live still lists, and says what to do.
	f = newFakeRestore()
	f.facts.Live = ""
	if so, _, err := runRestore(t, f, RestoreOptions{List: true}, false, ""); err != nil || !strings.Contains(so, "deploy first, then restore") {
		t.Errorf("%v\n%s", err, so)
	}
}

// Refusals change nothing: no off-box backups, no scheduler, nothing live,
// --with-data without a restore hook, and unanswerable questions.
func TestRestoreRefusals(t *testing.T) {
	for _, tc := range []struct {
		name  string
		set   func(*fakeRestore)
		o     RestoreOptions
		want  []string
		fetch bool
	}{
		{"no off-box", func(f *fakeRestore) { f.disabled = true }, RestoreOptions{}, []string{"has no off-box backups", "--with-backup", "kasbah rollback deploy@vps <version>", "by hand"}, false},
		{"no container", func(f *fakeRestore) { f.facts = &RestoreFacts{State: "exited"} }, RestoreOptions{}, []string{"the kasbah-backup container is exited there", "--with-backup", "kasbah rollback"}, false},
		{"nothing live", func(f *fakeRestore) { f.facts.Live = "" }, RestoreOptions{}, []string{"has no live version", "Deploy first"}, false},
		{"no snapshot", func(f *fakeRestore) { f.facts.List.Snapshot, f.facts.List.Snapshots = "", nil }, RestoreOptions{}, []string{"holds no snapshot of built-app's backups"}, false},
		{"with-data, no hook", func(f *fakeRestore) { f.facts.RestoreHook = false }, RestoreOptions{Data: prompt.Yes}, []string{"--with-data, and built-app 1.0.0 has no restore hook", "pass --no-data"}, false},
		{"no tty, data", nil, RestoreOptions{Env: prompt.No}, []string{"stdin is not a terminal", "pass --with-data or --no-data."}, false},
		{"no tty, both", nil, RestoreOptions{}, []string{"pass --with-env or --no-env, and --with-data or --no-data."}, false},
		{"no tty, env", func(f *fakeRestore) { f.facts.RestoreHook = false }, RestoreOptions{}, []string{"pass --with-env or --no-env. The fetched tarball was added to /apps/built-app/backups/; nothing else was changed."}, true},
	} {
		f := newFakeRestore()
		if tc.set != nil {
			tc.set(f)
		}
		_, se, err := runRestore(t, f, tc.o, false, "")
		if err == nil || f.called("restore") || f.called("fetch") != tc.fetch {
			t.Errorf("%s: %v %v\n%s", tc.name, err, f.calls, se)
		}
		for _, w := range tc.want {
			if !strings.Contains(se, w) {
				t.Errorf("%s: missing %q:\n%s", tc.name, w, se)
			}
		}
	}
}

// Terminal answers reach the server's restore; nothing chosen restores nothing.
func TestRestoreAnswers(t *testing.T) {
	for _, tc := range []struct {
		name, answers string
		o             RestoreOptions
		restored      bool
		envAll        bool
		keys          string
		data          bool
	}{
		{"restore, yes", "1\ny\n", RestoreOptions{}, true, true, "", true},
		{"per key, no", "per-key\nbackup\nserver\nn\n", RestoreOptions{}, true, false, "A", false},
		{"keep, no", "keep\nn\n", RestoreOptions{}, false, false, "", false},
		{"flags", "", RestoreOptions{Env: prompt.No, Data: prompt.Yes}, true, false, "", true},
	} {
		f := newFakeRestore()
		_, se, err := runRestore(t, f, tc.o, true, tc.answers)
		if err != nil || f.called("restore") != tc.restored || f.envAll != tc.envAll || strings.Join(f.keys, ",") != tc.keys || f.data != tc.data {
			t.Errorf("%s: %v %v all %v keys %v data %v\n%s", tc.name, err, f.calls, f.envAll, f.keys, f.data, se)
		}
		if !tc.restored && !strings.Contains(se, "Nothing to restore") {
			t.Errorf("%s: not said:\n%s", tc.name, se)
		}
		// The questions come after the fetch and the probe, the restore last.
		if c := strings.Join(f.calls, "\n"); tc.restored && !(strings.Index(c, "fetch") < strings.Index(c, "probe") && strings.Index(c, "probe") < strings.Index(c, "restore")) {
			t.Errorf("%s: order %v", tc.name, f.calls)
		}
	}
}

// A failed restore says where it stopped and what became of the data, .env
// and the stack.
func TestRestoreFailure(t *testing.T) {
	for _, tc := range []struct {
		kv     map[string]string
		want   []string
		absent []string
	}{
		{map[string]string{"restore": "failed", "step": "hook", "env": "put-back", "data": "partial", "stack": "untouched"},
			[]string{"the restore hook failed on deploy@vps", "what the restore hook did to the data is left as it is", "was put back as it was before this restore", "the fetched backup stays"},
			[]string{"brought up", "came back"}},
		{map[string]string{"restore": "failed", "step": "health", "env": "put-back", "data": "restored", "stack": "up"},
			[]string{"did not come back up", "the data is 1.0.0-20261101-120000.tar.gz's: 1.0.0's restore hook replaced it, and it now runs under the server's previous .env.", "was put back", "brought up on it again"}, nil},
		{map[string]string{"restore": "failed", "step": "up", "env": "put-back", "data": "restored", "stack": "down"},
			[]string{"the data is 1.0.0-20261101-120000.tar.gz's: 1.0.0's restore hook replaced it.", "failed too, so it may be down", "`docker compose -p built-app up -d` in /apps/built-app on deploy@vps"},
			[]string{"brought up on it again", "runs under"}},
		{map[string]string{"restore": "failed", "step": "up", "env": "put-back-failed", "data": "kept", "stack": "as-left"},
			[]string{"still holds the values restored from", "kasbah env set", "the data was not touched", "as the failed recreate left it"}, nil},
		{map[string]string{"restore": "failed", "step": "hook", "env": "kept", "data": "partial", "stack": "untouched"}, []string{".env on deploy@vps was not changed"}, nil},
		{map[string]string{"restore": "failed", "step": "hook", "env": "put-back", "data": "partial", "stack": "untouched", "signal": "yes"},
			[]string{"a signal stopped the restore on deploy@vps at its hook step", "was put back"}, nil},
		{map[string]string{"restore": "refused"}, []string{"refused (see above)", "The fetched tarball was added to /apps/built-app/backups/; nothing else was changed."}, []string{"Nothing was changed"}},
	} {
		f := newFakeRestore()
		f.kv = tc.kv
		_, se, err := runRestore(t, f, RestoreOptions{Env: prompt.Yes, Data: prompt.Yes}, false, "")
		if err == nil {
			t.Errorf("%v: no error", tc.kv)
		}
		for _, w := range tc.want {
			if !strings.Contains(se, w) {
				t.Errorf("%v: missing %q:\n%s", tc.kv, w, se)
			}
		}
		for _, w := range tc.absent {
			if strings.Contains(se, w) {
				t.Errorf("%v: says %q:\n%s", tc.kv, w, se)
			}
		}
	}
}

// With no snapshot at the paths looked at, the refusal lists the paths that
// hold backups; --from-path reaches the listing and the fetch.
func TestRestoreFromPath(t *testing.T) {
	f := newFakeRestore()
	f.facts.List.Snapshot, f.facts.List.Snapshots, f.facts.List.Backups = "", []backup.Snapshot{}, []backup.Tarball{}
	f.facts.List.Looked = []string{"/apps/built-app/backups"}
	f.facts.List.Elsewhere = []string{"/srv/apps/built-app/backups", "/srv/data/built-app/backups"}
	_, se, err := runRestore(t, f, RestoreOptions{Env: prompt.Yes, Data: prompt.Yes}, false, "")
	for _, w := range []string{"holds no snapshot of built-app's backups at /apps/built-app/backups — nothing was changed",
		"hold backup tarballs at: /srv/apps/built-app/backups /srv/data/built-app/backups", "--from-path=PATH", "re-creating the backups/ link"} {
		if err == nil || !strings.Contains(se, w) {
			t.Errorf("missing %q:\n%s", w, se)
		}
	}
	if f.called("fetch") {
		t.Errorf("fetched: %v", f.calls)
	}
	f = newFakeRestore()
	_, se, err = runRestore(t, f, RestoreOptions{From: "/srv/data/built-app/backups", Env: prompt.Yes, Data: prompt.Yes}, false, "")
	if err != nil || !f.called("list /srv/data/built-app/backups") || !f.called("fetch bbbbbbbb 1.0.0-20261101-120000.tar.gz /srv/data/built-app/backups") {
		t.Errorf("%v %v\n%s", err, f.calls, se)
	}
	if o, err := ParseRestore([]string{"--from-path=/srv/data/x/backups", "--list"}); err != nil || o.From != "/srv/data/x/backups" {
		t.Errorf("%+v %v", o, err)
	}
	for _, p := range []string{"backups", "/srv/../x", "/srv/x/", "/", "/a b", "/a\tb", ""} {
		if _, err := ParseRestore([]string{"--from-path=" + p}); err == nil {
			t.Errorf("--from-path=%q accepted", p)
		}
	}
}

func TestParseRestore(t *testing.T) {
	o, err := ParseRestore([]string{"d@h", "--snapshot=abcd", "--backup=1.0.0-20261101-000000.tar.gz\r", "--with-env", "--no-data"})
	if err != nil || o.Target != "d@h" || o.Snapshot != "abcd" || o.Backup != "1.0.0-20261101-000000.tar.gz" || o.Env != prompt.Yes || o.Data != prompt.No {
		t.Fatalf("%+v %v", o, err)
	}
	if o, err := ParseRestore([]string{"--list"}); err != nil || !o.List {
		t.Errorf("%+v %v", o, err)
	}
	if _, err := ParseRestore([]string{"--help"}); err != ErrHelp {
		t.Errorf("help: %v", err)
	}
	for _, args := range [][]string{{"--snapshot=XYZ"}, {"--backup=../x.tar.gz"}, {"--snapshot", "abcd"}, {"--with-env", "--no-env"},
		{"--list", "--with-data"}, {"--force"}, {"1.0.0"}, {"a@b", "c@d"}} {
		if _, err := ParseRestore(args); err == nil || err == ErrHelp {
			t.Errorf("%q accepted", args)
		}
	}
}
