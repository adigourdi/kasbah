package backup

import (
	"errors"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

func errText(err error) string {
	var e *cli.Error
	if errors.As(err, &e) {
		return e.Error()
	}
	if err != nil {
		return err.Error()
	}
	return ""
}

func TestRedact(t *testing.T) {
	for in, want := range map[string]string{
		"rest:http://u:p@10.0.0.1:8000/b/":  "rest:http://u:***@10.0.0.1:8000/b/",
		"s3:https://s3.example.com/bucket/": "s3:https://s3.example.com/bucket/",
		"/srv/backups/":                     "/srv/backups/",
		"rest:http://user@host/b/":          "rest:http://user@host/b/",
		"rest:http://u:p@h/a:b@c/":          "rest:http://u:***@h/a:b@c/",
		"rest:http://u:p@x@h/":              "rest:http://u:***@h/",
		"rest:http://u:hunter2@h":           "rest:http://u:***@h",
	} {
		if got := Redact(in); got != want {
			t.Errorf("Redact(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestChecks(t *testing.T) {
	const c = "server init"
	for _, tc := range []struct {
		err  error
		want string
	}{
		{CheckRepoBase(c, "--backup-repo-base=", ""), "must not be empty"},
		{CheckRepoBase(c, "--backup-repo-base=", "s3:a\tb/"), "control characters"},
		{CheckRepoBase(c, "--backup-repo-base=", "s3:a b/"), "whitespace"},
		{CheckRepoBase(c, "--backup-repo-base=", "s3:a　b/"), "whitespace"},
		{CheckRepoBase(c, "--backup-repo-base=", "rest:http://u:hunter2@h/b"), "--backup-repo-base=rest:http://u:***@h/b must end in '/'"},
		{CheckRepoBase(c, "--backup-repo-base=", "s3:https://h/b/"), ""},
		{CheckAt(c, "24:00"), "--backup-at=24:00 is not a time of day"},
		{CheckAt(c, "02:00"), ""},
		{CheckRepoName(c, "--backup-password=", "Acme"), "is not a repository name"},
		{CheckRepoName(c, "--backup-password=", "traefik"), "is a directory kasbah owns"},
		{CheckRepoName(c, "--backup-password=", "mail"), ""},
		{CheckRepoName(c, "--repo=", ProbeRepo), "is not a repository name"},
		{CheckRepoRef(pruneCmd, "--repo=", ProbeRepo), ""},
		{CheckEnvEntry(c, "--backup-env=", "NOEQUALS"), "must be KEY=VALUE"},
		{CheckEnvEntry(c, "--backup-env=", "1A=x"), "is '1A', which is not a variable name"},
		{CheckEnvEntry(c, "--backup-env=", "KASBAH_BACKUP_REPO_BASE=x"), "kasbah owns and rewrites"},
		{CheckEnvEntry(c, "--backup-env=", "RESTIC_REPOSITORY=x"), "is a key kasbah owns"},
		{CheckEnvEntry(c, "--backup-env=", "RESTIC_PASSWORD_COMMAND=x"), "is a key kasbah owns"},
		{CheckEnvEntry(c, "--backup-env=", "AWS_KEY=a\rb"), "must not contain a newline"},
		{CheckEnvEntry(c, "--backup-env=", "RESTIC_CACHE_DIR=/tmp/x"), ""},
		{CheckPassword(c, "acme", "a\nb"), "first line"},
		{CheckPassword(c, "acme", ""), "must not be empty"},
	} {
		if got := errText(tc.err); (tc.want == "") != (got == "") || !strings.Contains(got, tc.want) {
			t.Errorf("got %q, want %q", got, tc.want)
		}
	}
	if _, err := CheckJitter(c, "86400"); !strings.Contains(errText(err), "a day or more") {
		t.Error(err)
	}
	if n, err := CheckJitter(c, "0042"); err != nil || n != 42 {
		t.Error(n, err)
	}
	if _, err := CheckTimeout(c, "29"); !strings.Contains(errText(err), "under 30 seconds") {
		t.Error(err)
	}
	if _, err := CheckTimeout(c, "99999999999999999999"); !strings.Contains(errText(err), "under 30 seconds") {
		t.Error(err)
	}
	if _, err := CheckKeep(c, "--backup-keep-daily=", "lots"); errText(err) != "server init: --backup-keep-daily=lots is not a whole number of snapshots to keep" {
		t.Error(err)
	}
	// A password is never quoted back, valid or not.
	for _, given := range []string{"s3cr3t-do-not-print", "Bad=s3cr3t-do-not-print", "acme=s3cr3t-do-not-print\n"} {
		_, _, err := SplitPassword(c, given)
		if err == nil || strings.Contains(errText(err), "s3cr3t") {
			t.Errorf("%q: %v", given, err)
		}
	}
	if err := CheckEnvEntry(c, "--backup-env=", "bad key=s3cr3t"); strings.Contains(errText(err), "s3cr3t") {
		t.Error(err)
	}
}

func TestJitter(t *testing.T) {
	// cksum(1) of "stevedore@rig\n" is 3373562828; the Bash tool rendered 1628.
	if c := Cksum([]byte("stevedore@rig\n")); c%3600 != 1628 {
		t.Errorf("cksum %d", c)
	}
	if Cksum([]byte("")) != 4294967295 {
		t.Errorf("cksum of nothing is %d", Cksum(nil))
	}
	a, b := JitterFor("deploy@vps1"), JitterFor("deploy@vps2")
	if a == b || a != JitterFor("deploy@vps1") || a < 0 || a >= 3600 {
		t.Errorf("%d %d", a, b)
	}
}

func TestMergeEnv(t *testing.T) {
	def := "# head\nKASBAH_BACKUP_REPO_BASE=rest:http://new/\n# yours\n"
	if got := MergeEnv(def, "", "rest:http://new/", []string{"A=1", "A=2"}); got != def+"A=1\nA=2\n" {
		t.Errorf("first run: %q", got)
	}
	cur := "KASBAH_BACKUP_REPO_BASE=rest:http://old/\r\n# yours below\nAWS_ACCESS_KEY_ID=theirs\r\nAWS_SECRET_ACCESS_KEY=alsotheirs\n"
	got := MergeEnv(def, cur, "rest:http://new/", []string{"AWS_ACCESS_KEY_ID=fresh", "NEW_ONE=v"})
	want := "KASBAH_BACKUP_REPO_BASE=rest:http://new/\n# yours below\nAWS_ACCESS_KEY_ID=fresh\nAWS_SECRET_ACCESS_KEY=alsotheirs\nNEW_ONE=v\n"
	if got != want {
		t.Errorf("merge:\n%q\nwant\n%q", got, want)
	}
	if again := MergeEnv(def, got, "rest:http://new/", []string{"AWS_ACCESS_KEY_ID=fresh", "NEW_ONE=v"}); again != got {
		t.Errorf("not idempotent: %q", again)
	}
	// A file without its trailing newline is normalised once, then stable;
	// one ending in a blank line keeps it and gains nothing.
	if got := MergeEnv(def, "X=1", "b/", nil); got != "X=1\nKASBAH_BACKUP_REPO_BASE=b/\n" {
		t.Errorf("%q", got)
	}
	if got := MergeEnv(def, "KASBAH_BACKUP_REPO_BASE=b/\n\n", "b/", nil); got != "KASBAH_BACKUP_REPO_BASE=b/\n\n" {
		t.Errorf("%q", got)
	}
}

func TestFirstOwned(t *testing.T) {
	if k := FirstOwned("# RESTIC_REPOSITORY=x\nKASBAH_BACKUP_REPO_BASE=b/\nRESTIC_CACHE_DIR=/c\nRESTIC_PASSWORD=p\r\n"); k != "RESTIC_PASSWORD" {
		t.Errorf("%q", k)
	}
	if k := FirstOwned("AWS_ACCESS_KEY_ID=k\n"); k != "" {
		t.Errorf("%q", k)
	}
	if e := OwnedEnvError("/apps", "RESTIC_REPOSITORY"); !strings.Contains(e.Error(), "which kasbah sets itself") || !strings.Contains(e.Error(), "Remove the line") {
		t.Error(e)
	}
}

func TestOperatorLines(t *testing.T) {
	got := operatorLines("# c\nKASBAH_BACKUP_REPO_BASE=b/\nAWS_ACCESS_KEY_ID=theirs\r\nRESTIC_REPOSITORY=sneaky\nKASBAH_BACKUP_SOMETHING=x\nnot a line\n\n")
	if strings.Join(got, "|") != "AWS_ACCESS_KEY_ID=theirs" {
		t.Errorf("%q", got)
	}
	if b := envBase("KASBAH_BACKUP_REPO_BASE=a/\nKASBAH_BACKUP_REPO_BASE=b/\r\n"); b != "b/" {
		t.Errorf("%q", b)
	}
}

func TestScan(t *testing.T) {
	n, first := scan("abcdef01\r\nwarning: x\n0123\nzz\n")
	if n != 2 || first != "abcdef01" {
		t.Errorf("%d %q", n, first)
	}
}
