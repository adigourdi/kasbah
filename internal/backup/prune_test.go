package backup

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
)

func TestParsePrune(t *testing.T) {
	o, err := ParsePrune([]string{"deploy@vps\r"})
	if err != nil || o.Target != "deploy@vps" || o.RepoBase != "" || o.Daily != "" {
		t.Fatalf("%+v %v", o, err)
	}
	o, err = ParsePrune([]string{"deploy@vps", "--repo-base=s3:https://h/b/", "--env=AWS_ACCESS_KEY_ID=k", "--repo=acme",
		"--repo=mail", "--repo=kasbah.probe", "--keep-daily=1", "--dry-run", "--yes", "--docker-network=some-net"})
	if err != nil || o.RepoBase != "s3:https://h/b/" || strings.Join(o.Env, " ") != "AWS_ACCESS_KEY_ID=k" ||
		strings.Join(o.Only, " ") != "acme mail kasbah.probe" || !o.DryRun || !o.Yes || o.Network != "some-net" || o.Daily != "1" {
		t.Fatalf("%+v %v", o, err)
	}
	for _, c := range []struct{ args, want string }{
		{"", "USER@HOST is required"},
		{"a@b|c@d", "unexpected argument 'c@d'"},
		{"a@b|--docker-network=bad net", "is not a docker network name"},
		{"a@b|--repo=Bad", "is not a repository name"},
		{"a@b|--bogus=hunter2", "unknown flag '--bogus'"},
		{"a@b|--keep-daily=lots", "server backup-prune: --keep-daily=lots"},
		{"a@b|--repo-base=rest:http://u:hunter2@h/b", "must end in '/'"},
		{"a@b|--env=RESTIC_PASSWORD=hunter2", "is a key kasbah owns"},
	} {
		_, err := ParsePrune(strings.Split(c.args, "|"))
		if got := errText(err); !strings.Contains(got, c.want) || strings.Contains(got, "hunter2") {
			t.Errorf("%q: %q", c.args, got)
		}
	}
	if o, _ := ParsePrune([]string{"--help"}); !o.Help {
		t.Error("--help")
	}
}

type fakePrune struct {
	marker string
	repos  ReposReport
	rc     int
	closed bool
}

func (f *fakePrune) Marker() (*marker.Marker, string, error) {
	m, err := marker.Validate([]byte(f.marker), "/apps/.kasbah/server.json", "deploy@vps", "kasbah server init deploy@vps")
	return m, "/apps/.kasbah/server.json", err
}

func (f *fakePrune) Repos(string) ([]byte, int) {
	b, _ := json.Marshal(f.repos)
	return b, f.rc
}

func (f *fakePrune) Close() { f.closed = true }

const prunedMarker = `{"kasbah_version":"1.0.0","apps_path":"/apps","data_path":"/apps/data","cpu_limit":"1","mem_limit":"1g",
"backup":{"enabled":true,"repo_base":"rest:http://u:vps@h/b/","retention":{"daily":1,"weekly":1,"monthly":1}}}`

type call struct {
	repo string
	args string
	env  string
	pass string
}

func prune(t *testing.T, f *fakePrune, o PruneOptions, fail map[string]int) (string, string, []call, error) {
	var out, errb bytes.Buffer
	var calls []call
	t.Setenv("TMPDIR", t.TempDir())
	c := PruneCtx{
		Out:      &cli.Output{Stdout: &out, Stderr: &errb},
		Prompter: &prompt.Prompter{In: strings.NewReader(""), Out: &cli.Output{Stdout: &out, Stderr: &errb}},
		Dial:     func(string) (PruneSession, error) { return f, nil },
		Restic: func(dir, network, repo string, args ...string) (string, int) {
			env, _ := os.ReadFile(dir + "/env/" + repo + ".env")
			pass, _ := os.ReadFile(dir + "/pw/" + repo + ".pass")
			fi, _ := os.Stat(dir + "/env/" + repo + ".env")
			if fi.Mode().Perm() != 0o600 {
				t.Errorf("%s env is %v", repo, fi.Mode())
			}
			calls = append(calls, call{repo, strings.Join(args, " "), string(env), string(pass)})
			if rc := fail[repo+" "+args[1]]; rc != 0 {
				return "Fatal: no", rc
			}
			return "keep 1 snapshot, remove 1 snapshot", 0
		},
	}
	if o.Target == "" {
		o.Target = "deploy@vps"
	}
	err := Prune(c, o)
	if ents, _ := os.ReadDir(os.Getenv("TMPDIR")); len(ents) != 0 {
		t.Errorf("staged credentials left behind: %v", ents)
	}
	return out.String(), errb.String(), calls, err
}

func TestPrune(t *testing.T) {
	b64 := func(s string) string { return base64.StdEncoding.EncodeToString([]byte(s)) }
	f := &fakePrune{marker: prunedMarker, repos: ReposReport{Repos: []string{"alpha", "mail"},
		Pass: map[string]string{"alpha": b64("pw-alpha\n"), "mail": b64("pw-mail\n")}}}
	out, errb, calls, err := prune(t, f, PruneOptions{RepoBase: "rest:http://u:admin@h/b/", Env: []string{"AWS_ACCESS_KEY_ID=k"}, Yes: true}, nil)
	if err != nil {
		t.Fatal(err, errb)
	}
	for _, want := range []string{"Retention on deploy@vps: keep 1 daily, 1 weekly, 1 monthly",
		"  base: rest:http://u:***@h/b/   restic: restic/restic:0.18.0, run here and not on the VPS",
		"  alpha — what would be removed:", "    keep 1 snapshot, remove 1 snapshot", "  alpha — forgetting and pruning:",
		"  kasbah.probe — forgetting and pruning:", "Pruned 3 repositories on deploy@vps",
		"there is no way to remove one over the wire"} {
		if !strings.Contains(out, want) {
			t.Errorf("missing %q in\n%s", want, out)
		}
	}
	if errb != "" || strings.Contains(out, "admin") {
		t.Errorf("stderr %q / out leaks: %s", errb, out)
	}
	if len(calls) != 6 || calls[5].args != "forget --prune --keep-daily 1 --keep-weekly 1 --keep-monthly 1" || calls[5].repo != ProbeRepo {
		t.Errorf("%+v", calls)
	}
	if calls[0].env != "AWS_ACCESS_KEY_ID=k\nRESTIC_REPOSITORY=rest:http://u:admin@h/b/alpha\nRESTIC_PASSWORD_FILE=/pw/alpha.pass\n" || calls[0].pass != "pw-alpha\n" {
		t.Errorf("%q %q", calls[0].env, calls[0].pass)
	}
	if calls[5].pass != ProbePassword+"\n" || !f.closed {
		t.Error("probe password / session not closed")
	}

	// No --env: the env question is unanswerable without a terminal.
	_, _, _, err = prune(t, f, PruneOptions{RepoBase: "r/", Yes: true}, nil)
	if !strings.Contains(errText(err), "--env=KEY=VALUE or --no-env") {
		t.Error(err)
	}
	// The marker's base, warned about; a dry run that failed is skipped.
	out, errb, calls, err = prune(t, f, PruneOptions{NoEnv: true, Yes: true}, map[string]int{"alpha --dry-run": 3})
	if err != nil || !strings.Contains(errb, "using the repository base the server records: rest:http://u:***@h/b/") ||
		!strings.Contains(errb, "alpha — restic exited 3 above; this repository is skipped") || !strings.Contains(out, "Pruned 2 repositories") {
		t.Errorf("%v\n%s\n%s", err, out, errb)
	}
	for _, c := range calls {
		if c.repo == "alpha" && strings.HasPrefix(c.args, "forget --prune") {
			t.Error("pruned a repository whose plan failed")
		}
		if strings.HasSuffix(c.env, "\n\n") || strings.HasPrefix(c.env, "\n") {
			t.Errorf("blank line in %q", c.env)
		}
	}
	_, _, _, err = prune(t, f, PruneOptions{NoEnv: true}, map[string]int{"alpha --dry-run": 3, "mail --dry-run": 3, "kasbah.probe --dry-run": 3})
	if !strings.Contains(errText(err), "no repository could be read") {
		t.Error(err)
	}
	out, _, calls, err = prune(t, f, PruneOptions{NoEnv: true, DryRun: true}, nil)
	if err != nil || !strings.Contains(out, "--dry-run: nothing was removed") || len(calls) != 3 {
		t.Error(err, out)
	}
	_, _, _, err = prune(t, f, PruneOptions{NoEnv: true}, nil)
	if !strings.Contains(errText(err), "--yes") {
		t.Errorf("an unanswerable confirmation: %v", err)
	}
	_, errb, _, err = prune(t, f, PruneOptions{NoEnv: true, Yes: true}, map[string]int{"mail --prune": 1})
	if !strings.Contains(errText(err), "1 of 3 repositories were not pruned") || !strings.Contains(errb, "mail — restic exited 1") {
		t.Error(err, errb)
	}
	_, _, calls, err = prune(t, f, PruneOptions{NoEnv: true, Yes: true, Only: []string{ProbeRepo}}, nil)
	if err != nil || len(calls) != 2 || calls[1].repo != ProbeRepo {
		t.Error(err, calls)
	}
	_, _, _, err = prune(t, f, PruneOptions{NoEnv: true, Only: []string{"zeta"}}, nil)
	if !strings.Contains(errText(err), "has no 'zeta' repository (it has: alpha mail kasbah.probe)") {
		t.Error(err)
	}

	off := &fakePrune{marker: strings.Replace(prunedMarker, `"enabled":true`, `"enabled":false`, 1)}
	if _, _, _, err := prune(t, off, PruneOptions{NoEnv: true}, nil); !strings.Contains(errText(err), "says backup.enabled is false") {
		t.Error(err)
	}
	leak := &fakePrune{marker: prunedMarker, rc: 0}
	leak.repos = ReposReport{Repos: []string{"alpha"}, Pass: map[string]string{}}
	if _, _, _, err := prune(t, leak, PruneOptions{NoEnv: true, Yes: true}, nil); !strings.Contains(errText(err), "sent no password") {
		t.Error(err)
	}
}
