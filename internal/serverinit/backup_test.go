package serverinit

import (
	"bytes"
	"encoding/base64"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/tmpl"
)

func TestParseBackup(t *testing.T) {
	o, err := Parse([]string{"a@b", "--with-backup", "--backup-repo-base=s3:https://h/b/\r", "--backup-at=03:30",
		"--backup-jitter=900", "--backup-keep-daily=14", "--backup-keep-weekly=8", "--backup-keep-monthly=6",
		"--backup-timeout=120", "--backup-env=AWS_ACCESS_KEY_ID=k", "--backup-env=AWS_SECRET_ACCESS_KEY=s",
		"--backup-password=alpha=pw1", "--backup-password=beta=pw2", "--no-backup-env"})
	if err != nil {
		t.Fatal(err)
	}
	b := o.Bk
	if o.Backup != prompt.Yes || b.RepoBase != "s3:https://h/b/" || b.At != "03:30" || b.Jitter != "900" || b.Daily != "14" ||
		b.Weekly != "8" || b.Monthly != "6" || b.Timeout != "120" || !b.NoEnv ||
		strings.Join(b.Env, " ") != "AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s" || strings.Join(b.Pass, " ") != "alpha=pw1 beta=pw2" {
		t.Errorf("%+v", o)
	}
	for _, c := range []struct{ args, want string }{
		{"a@b|--with-backup|--no-backup", "--with-backup and --no-backup cannot both be given"},
		{"a@b|--backup-keep-daily=lots", "server init: --backup-keep-daily=lots"},
		{"a@b|--backup-password=s3cr3t-do-not-print", "must be <repo>=<password>"},
		{"a@b|--backup-env=bad key=s3cr3t-do-not-print", "not a variable name"},
		{"a@b|--backup-repo-base=rest:http://u:s3cr3t-do-not-print@h/b", "must end in '/'"},
		{"a@b|--backup-password=kasbah.probe=x", "is not a repository name"},
		{"a@b|--backup-timeout=10", "under 30 seconds"},
	} {
		_, err := Parse(strings.Split(c.args, "|"))
		if got := errText(err); !strings.Contains(got, c.want) || strings.Contains(got, "s3cr3t") {
			t.Errorf("%q: %q", c.args, got)
		}
	}
	if o, err := Parse([]string{"a@b", "--help", "--bogus"}); err != nil || !o.Help {
		t.Errorf("--help: %v", err)
	}
}

func TestUsage(t *testing.T) {
	for _, want := range []string{"--backup-keep-daily=N  retention, applied by \"server backup-prune\"",
		"one repository per \"client:\" plus one", "--backup-timeout=<s>", "/etc/kasbah/apps-path"} {
		if !strings.Contains(Usage, want) {
			t.Errorf("usage lacks %q", want)
		}
	}
}

func TestFlagsUnused(t *testing.T) {
	var errb bytes.Buffer
	o, _ := Parse([]string{"a@b", "--no-backup", "--backup-at=03:00", "--no-backup-env", "--backup-password=a=b"})
	FlagsUnused(&cli.Output{Stdout: &errb, Stderr: &errb}, o)
	if errb.String() != "warning: --backup-at= --backup-password= --no-backup-env had no effect: this run is not installing backups\n" {
		t.Errorf("%q", errb.String())
	}
}

func bkPrompter(in string) (*prompt.Prompter, *bytes.Buffer) {
	var b bytes.Buffer
	out := &cli.Output{Stdout: &b, Stderr: &b}
	return &prompt.Prompter{In: strings.NewReader(in), Out: out, TTY: in != ""}, &b
}

func fresh() *backup.ReadReport { f := backup.Fresh; return &f }

func TestBackupResolve(t *testing.T) {
	o, _ := Parse([]string{"deploy@vps", "--with-backup", "--backup-repo-base=rest:http://u:p@h/b/", "--no-backup-env",
		"--backup-password=acme=pw-a", "--backup-password=beta=pw-b", "--backup-password=mail=pw-m"})
	r := fresh()
	r.Mail = true
	r.Projects = []backuprec.Project{{Name: "alpha", Client: "acme"}, {Name: "beta", Client: ""}}
	p, said := bkPrompter("")
	v, err := BackupResolve(p.Out, p, o, r, nil)
	if err != nil {
		t.Fatal(err, said)
	}
	if v.At != "02:00" || v.Timeout != 900 || v.Daily != 7 || v.Weekly != 4 || v.Monthly != 3 || v.Jitter != backup.JitterFor("deploy@vps") ||
		strings.Join(v.Repos, " ") != "acme beta mail" || strings.Join(v.New, " ") != "acme beta mail" ||
		v.EnvOrigin != "none" || v.BaseOrigin != "flag" || strings.Join(v.Fallbacks, " ") != "beta" {
		t.Errorf("%+v", v)
	}
	if !strings.Contains(said.String(), "the repository base carries a credential: rest:http://u:***@h/b/") || strings.Contains(said.String(), "u:p@") {
		t.Errorf("%s", said)
	}

	// A password already there is never asked for nor rewritten.
	r.HasPass = []string{"acme"}
	p, said = bkPrompter("")
	v, err = BackupResolve(p.Out, p, o, r, nil)
	if err != nil || strings.Join(v.New, " ") != "beta mail" || !strings.Contains(said.String(), "--backup-password=acme= had no effect") {
		t.Errorf("%+v %v %s", v, err, said)
	}
	// A password for a repository nothing claims yet joins the set.
	o2, _ := Parse([]string{"deploy@vps", "--with-backup", "--backup-repo-base=b/", "--no-backup-env", "--backup-password=future=x"})
	v, err = BackupResolve(p.Out, p, o2, fresh(), nil)
	if err != nil || strings.Join(v.Repos, " ") != "future" {
		t.Errorf("%+v %v", v, err)
	}

	// Without a terminal each question fails naming its flag.
	for _, c := range []struct {
		args []string
		r    *backup.ReadReport
		want string
	}{
		{[]string{"a@b", "--with-backup"}, fresh(), "--backup-repo-base=<value>"},
		{[]string{"a@b", "--with-backup", "--backup-repo-base=b/"}, fresh(), "--backup-env=KEY=VALUE or --no-backup-env"},
		{[]string{"a@b", "--with-backup", "--backup-repo-base=b/", "--no-backup-env"}, &backup.ReadReport{Dir: "dir", Env: "present",
			Projects: []backuprec.Project{{Name: "x", Client: "acme"}}}, "--backup-password=acme=<value>"},
		{[]string{"a@b", "--with-backup", "--backup-repo-base=b/"}, &backup.ReadReport{Dir: "notdir"}, "exists and is not a directory"},
	} {
		o, _ := Parse(c.args)
		p, _ := bkPrompter("")
		if _, err := BackupResolve(p.Out, p, o, c.r, nil); !strings.Contains(errText(err), c.want) {
			t.Errorf("%v: %v", c.args, err)
		}
	}
	// An env file already there is the answer; the marker's values are reproduced.
	existing := marker.Backup{RepoBase: "s3:https://old/", At: "04:17", Jitter: 42, Timeout: 120, Retention: marker.Retention{Daily: 1, Weekly: 2, Monthly: 3}}
	m, _ := marker.Build(marker.Fields{KasbahVersion: "1", AppsPath: "/apps", DataPath: "/apps/data", CPULimit: "1", MemLimit: "1g"}, nil, &existing)
	o3, _ := Parse([]string{"a@b", "--with-backup"})
	v, err = BackupResolve(p.Out, p, o3, &backup.ReadReport{Dir: "dir", Env: "present"}, m)
	if err != nil || v.RepoBase != "s3:https://old/" || v.BaseOrigin != "marker" || v.At != "04:17" || v.Jitter != 42 ||
		v.Timeout != 120 || v.Daily != 1 || v.EnvOrigin != "file" {
		t.Errorf("%+v %v", v, err)
	}
	// Asked on a terminal: base, environment, one password.
	p, said = bkPrompter("rest:http://h/b/\ny\nAWS_KEY\nsecret\n\nhunter2\n")
	v, err = BackupResolve(p.Out, p, o3, &backup.ReadReport{Dir: "absent", Env: "absent", Projects: []backuprec.Project{{Name: "x"}}}, nil)
	if err != nil || v.BaseOrigin != "prompt" || v.EnvOrigin != "prompt" || strings.Join(v.Env, " ") != "AWS_KEY=secret" || v.Pass["x"] != "hunter2" {
		t.Errorf("%+v %v %s", v, err, said)
	}
}

func TestBackupMarker(t *testing.T) {
	v := &BackupValues{RepoBase: "rest:http://new/", At: "02:00", Jitter: 11, Timeout: 900, Daily: 7, Weekly: 4, Monthly: 3}
	old, _ := jv.ParseOne([]byte(`{"future_key":{"kept":[1,2]},"backup":{"enabled":true,"repo_base":"s3:https://old/","from_a_newer_kasbah":42,"retention":{"also_newer":1,"weekly":9}}}`))
	m, err := marker.Build(marker.Fields{KasbahVersion: "1", AppsPath: "/apps", DataPath: "/apps/data", CPULimit: "1", MemLimit: "1g"}, old.(*jv.Map), v.Marker())
	if err != nil {
		t.Fatal(err)
	}
	got := string(marker.Render(m))
	for _, want := range []string{`"repo_base": "rest:http://new/"`, `"from_a_newer_kasbah": 42`, `"also_newer": 1`, `"weekly": 4`, `"jitter": 11`, `"timeout": 900`, `"kept": [`} {
		if !strings.Contains(got, want) {
			t.Errorf("marker lacks %s:\n%s", want, got)
		}
	}
	m2, _ := marker.Build(marker.Fields{KasbahVersion: "1", AppsPath: "/apps", DataPath: "/apps/data", CPULimit: "1", MemLimit: "1g"}, m, v.Marker())
	if string(marker.Render(m2)) != got {
		t.Error("merging a backup marker into itself is not a no-op")
	}
}

func TestBackupRender(t *testing.T) {
	o, _ := Parse([]string{"a@b", "--with-backup"})
	v := &BackupValues{RepoBase: "rest:http://u:p@h/b/", At: "02:00", Jitter: 1234, Timeout: 900}
	compose, env, err := BackupRender(repoTemplates(t), o, v, fresh())
	if err != nil {
		t.Fatal(err)
	}
	if err := tmpl.CheckYAML(compose); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"image: " + backup.ResticImage, "KASBAH_BACKUP_JITTER: 1234", "KASBAH_BACKUP_AT: 02:00", "KASBAH_BACKUP_TIMEOUT: 900",
		`entrypoint: ["/apps/.kasbah/bin/kasbah", "remote", "backup"]`, `"/apps/.kasbah/bin/kasbah", "remote", "backup", "health"]`,
		`"/apps/.kasbah/backup/state:/apps/.kasbah/backup/state"`, `"/apps:/apps:ro"`, `"/apps/data:/apps/data:ro"`,
		"container_name: kasbah-backup", "name: kasbah-backup-cache"} {
		if !strings.Contains(compose, want) {
			t.Errorf("compose lacks %s", want)
		}
	}
	if strings.Count(compose, `:ro"`) != 3 || strings.Contains(compose, "u:p@h") || strings.Contains(compose, "\nversion:") || strings.Contains(compose, "backup.sh") {
		t.Errorf("compose:\n%s", compose)
	}
	if !strings.Contains(env, "\nKASBAH_BACKUP_REPO_BASE=rest:http://u:p@h/b/\n") {
		t.Errorf("env:\n%s", env)
	}
	o.Data = o.Apps
	same, _, err := BackupRender(repoTemplates(t), o, v, fresh())
	if err != nil || strings.Count(same, `:ro"`) != 2 || tmpl.CheckYAML(same) != nil {
		t.Errorf("data == apps: %v\n%s", err, same)
	}
	o.Data = "/mnt/vol1"
	if outside, _, _ := BackupRender(repoTemplates(t), o, v, fresh()); !strings.Contains(outside, `"/mnt/vol1:/mnt/vol1:ro"`) {
		t.Error("a data path outside apps is not mounted")
	}
	if _, _, err := BackupRender(repoTemplates(t), o, v, &backup.ReadReport{EnvOwned: "RESTIC_REPOSITORY"}); !strings.Contains(errText(err), "which kasbah sets itself") {
		t.Error(err)
	}
}

func probeFacts(stage, mid, after string) Facts {
	return Facts{"probe_repo": "rest:http://u:hunter2@h/b/kasbah.probe", "probe_stage": stage, "probe_mid": mid,
		"probe_after": after, "probe_rc": "0", "probe_when": "after",
		"probe_log_b64": base64.StdEncoding.EncodeToString([]byte("restic said\n"))}
}

func TestProbeVerdict(t *testing.T) {
	v := &BackupValues{RepoBase: "rest:http://u:hunter2@h/b/", Timeout: 900}
	if err := ProbeVerdict(probeFacts("deleted", "2", "2"), "a@b", "/apps", v, false); err != nil {
		t.Errorf("append-only refused: %v", err)
	}
	for _, c := range []struct {
		f       Facts
		had     bool
		want    []string
		mustNot string
	}{
		{probeFacts("deleted", "2", "1"), false, []string{"can DELETE", "No backup stack was started", "| restic said", "u:***@h"}, "hunter2"},
		{probeFacts("deleted", "2", "1"), true, []string{"is still running", "kasbah-backup down"}, "No backup stack was started"},
		{probeFacts("reach", "0", "0"), false, []string{"cannot reach", "--backup-env=KEY=VALUE", "--backup-timeout="}, "hunter2"},
		{probeFacts("write", "0", "0"), false, []string{"cannot write"}, "can DELETE"},
		{probeFacts("unlisted", "2", "0"), false, []string{"could not list", "after the delete attempt", "--backup-timeout="}, "can DELETE"},
		{probeFacts("deleted", "1", "1"), false, []string{"would have proved nothing"}, ""},
		{probeFacts("bogus", "2", "2"), false, []string{"which this kasbah does not know"}, ""},
	} {
		got := errText(ProbeVerdict(c.f, "a@b", "/apps", v, c.had))
		for _, w := range c.want {
			if !strings.Contains(got, w) {
				t.Errorf("%v: lacks %q in %q", c.f["probe_stage"], w, got)
			}
		}
		if c.mustNot != "" && strings.Contains(got, c.mustNot) {
			t.Errorf("%v: has %q in %q", c.f["probe_stage"], c.mustNot, got)
		}
	}
	other := probeFacts("deleted", "2", "2")
	other["probe_repo"] = "rest:http://elsewhere/kasbah.probe"
	if !strings.Contains(errText(ProbeVerdict(other, "a@b", "/apps", v, false)), "are not the same repository") {
		t.Error("a probe of another repository passed")
	}
}

func TestReportBackup(t *testing.T) {
	var b bytes.Buffer
	o, _ := Parse([]string{"a@b"})
	v := &BackupValues{RepoBase: "rest:http://u:p@h/b/", BaseOrigin: "flag", At: "04:17", Jitter: 42, Timeout: 900, Daily: 7, Weekly: 4, Monthly: 3,
		EnvOrigin: "none", Repos: []string{"acme", "zeta"}, Pass: map[string]string{"acme": "x"}, Fallbacks: []string{"zeta"}}
	reportBackup(&cli.Output{Stdout: &b, Stderr: &b}, o, v, bkReport{Env: "written", Probed: "rest:http://u:p@h/b/kasbah.probe", Changed: []string{"compose.yml"},
		Start: Facts{"backup_container": "kasbah-backup", "backup_state": "running", "backup_restarts": "0", "backup_image": backup.ResticImage, "backup_legacy": "removed"}})
	for _, want := range []string{"  backup: /apps/.kasbah/backup (shipped compose.yml, removed the old backup.sh, env written)",
		"daily at 04:17 plus 42s jitter, 900s per restic call", "credentials: append-only (probed against rest:http://u:***@h/b/kasbah.probe)",
		"back up now: ssh a@b 'docker exec kasbah-backup /apps/.kasbah/bin/kasbah remote backup once'",
		"warning: no restic password for: zeta — those repositories are NOT backed up", "warning: no client record for: zeta"} {
		if !strings.Contains(b.String(), want) {
			t.Errorf("lacks %q in\n%s", want, b.String())
		}
	}
	if strings.Contains(b.String(), "u:p@") {
		t.Error("a credential was printed")
	}
}

func TestProbeVerdictCounts(t *testing.T) {
	v := &BackupValues{RepoBase: "rest:http://u:hunter2@h/b/", Timeout: 900}
	// The count decides, not restic's status: a forget that failed having
	// removed one is a deletion.
	f := probeFacts("deleted", "2", "1")
	f["probe_rc"] = "1"
	if !strings.Contains(errText(ProbeVerdict(f, "a@b", "/apps", v, false)), "can DELETE") {
		t.Error("a non-zero forget that removed a snapshot passed")
	}
	f = probeFacts("deleted", "2", "2")
	f["probe_rc"] = "1"
	if err := ProbeVerdict(f, "a@b", "/apps", v, false); err != nil {
		t.Errorf("a refused forget is append-only: %v", err)
	}
	f = probeFacts("unlisted", "0", "0")
	f["probe_when"] = "before"
	if got := errText(ProbeVerdict(f, "a@b", "/apps", v, false)); !strings.Contains(got, "(before the delete attempt)") {
		t.Errorf("%q", got)
	}
}

func TestStartBranches(t *testing.T) {
	if !strings.Contains(errText(resetNeedsRestart(false)), "the reset would outlive nothing") || resetNeedsRestart(true) != nil {
		t.Error("reset precondition")
	}
	got := errText(traefikStartFailed("a@b", 1, Facts{"acme_reset": "done", "acme_archive": "/d/acme.json.20261019T000000Z"}))
	if !strings.Contains(got, "could not start Traefik on a@b (the remote step exited 1") || !strings.Contains(got, "previous store is at /d/acme.json.20261019T000000Z") {
		t.Errorf("%q", got)
	}
	if got := errText(traefikStartFailed("a@b", 1, Facts{"acme_reset": "skipped"})); strings.Contains(got, "previous store") {
		t.Errorf("%q", got)
	}
}

// htpasswd reads the password on stdin; it is never in argv.
func TestBcryptStdin(t *testing.T) {
	dir := t.TempDir()
	log := dir + "/log"
	os.WriteFile(dir+"/htpasswd", []byte("#!/bin/sh\nprintf '%s\\n' \"$*\" > "+log+"\nIFS= read -r p\nprintf '%s\\n' \"$p\" >> "+log+"\nprintf '%s:$2y$05$abcdefghijklmnopqrstuv\\n' \"$2\"\n"), 0o755)
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	line, err := Bcrypt("dash", "hunter2-pw")
	if err != nil || line != "dash:$2y$05$abcdefghijklmnopqrstuv" {
		t.Fatalf("%q %v", line, err)
	}
	b, _ := os.ReadFile(log)
	if lines := strings.Split(string(b), "\n"); lines[0] != "-niB dash" || lines[1] != "hunter2-pw" {
		t.Errorf("argv/stdin: %q", b)
	}
	os.WriteFile(dir+"/htpasswd", []byte("#!/bin/sh\necho 'dash:plain'\n"), 0o755)
	if _, err := Bcrypt("dash", "hunter2-pw"); !strings.Contains(errText(err), "could not produce a bcrypt hash") || strings.Contains(errText(err), "hunter2") {
		t.Errorf("%v", err)
	}
}

// A newline refusal names the field, never the secret.
func TestNewlineRefusalsDoNotEcho(t *testing.T) {
	for _, args := range [][]string{
		{"a@b", "--traefik-auth=dash:hun\nter2"},
		{"a@b", "--postmaster-password=hun\nter2"},
		{"a@b", "--backup-password=acme=hun\nter2"},
		{"a@b", "--backup-env=AWS=hun\nter2"},
	} {
		_, err := Parse(args)
		if got := errText(err); !strings.Contains(got, "newline") || strings.Contains(got, "hun") || strings.Contains(got, "ter2") {
			t.Errorf("%q: %q", args[1][:12], got)
		}
	}
}

func TestProbeAcmeStore(t *testing.T) {
	f := goodFacts()
	var b strings.Builder
	for k, v := range f {
		if k != "acme_store" {
			b.WriteString(k + "=" + v + "\n")
		}
	}
	if _, err := ParseProbe("a@b", b.String()); !strings.Contains(errText(err), "reported no acme_store") {
		t.Errorf("a truncated probe: %v", err)
	}
	if _, err := ParseProbe("a@b", b.String()+"acme_store=weird\n"); !strings.Contains(errText(err), "acme_store='weird', which this kasbah does not know") {
		t.Errorf("an unknown store: %v", err)
	}
}

func TestTemplatesCRLFAndLints(t *testing.T) {
	crlf := strings.ReplaceAll(sharedDoc, "\n", "\r\n")
	if a, err := ExtractAuth(crlf); err != nil || a != "dash:$2y$05$OURS" {
		t.Errorf("CRLF _shared.yml: %q %v", a, err)
	}
	if d, err := DashboardApex(crlf); err != nil || d != "example.com" {
		t.Errorf("CRLF apex: %q %v", d, err)
	}
	static := "certificatesResolvers:\r\n  letsencrypt:\r\n    acme:\r\n      email: ops@example.com\r\n      caServer: https://acme-staging-v02.api.letsencrypt.org/directory\r\n"
	if e, err := StaticField(static, "email"); err != nil || e != "ops@example.com" {
		t.Errorf("CRLF traefik.yml: %q %v", e, err)
	}
	r, err := Render(repoTemplates(t), Options{Apps: "/apps", Data: "/apps/data"},
		Values{Image: TraefikImage, Domain: "example.com", Email: "ops@example.com", AuthEntry: "dash:$2y$05$x", Acme: Acme{CA: CAProduction}})
	if err != nil {
		t.Fatal(err)
	}
	// The dashboard is reached through its authenticated router only.
	if v, err := yamlGet(r["traefik.yml"], field("api", "insecure")); err != nil || (v != "" && v != "false") {
		t.Errorf("api.insecure is %q (%v)", v, err)
	}
	if v, _ := yamlGet(r["traefik.yml"], field("api", "dashboard")); v != "true" {
		t.Errorf("api.dashboard is %q", v)
	}
	for _, w := range []string{"minVersion: VersionTLS12", "maxVersion: VersionTLS13", `contentSecurityPolicyReportOnly: "default-src 'self'"`} {
		if !strings.Contains(r["dynamic/_shared.yml"], w) {
			t.Errorf("_shared.yml lacks %q", w)
		}
	}
}
