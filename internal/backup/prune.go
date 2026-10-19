package backup

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
)

const pruneCmd = "server backup-prune"

// PruneOptions is `server backup-prune`'s command line.
type PruneOptions struct {
	Target   string
	RepoBase string
	Env      []string
	NoEnv    bool
	Only     []string
	Daily    string
	Weekly   string
	Monthly  string
	DryRun   bool
	Yes      bool
	Network  string
	Help     bool
}

// PruneUsage is `server backup-prune --help`.
const PruneUsage = `Usage: kasbah server backup-prune USER@HOST [flags]

Applies the retention policy to this server's restic repositories, with the
full-access credentials — which stay on this machine. USER@HOST says which
repositories exist and hands over their encryption passwords; restic itself
runs here, in a container, and talks to the storage directly.

Prints what would be removed and asks once before removing anything.

Flags:
  --repo-base=<url>      the repository base to prune against. Defaults to the
                         one in the server marker, which for a target whose
                         credential lives in the URL is the VPS's append-only
                         one — pass the full-access spelling here.
  --env=KEY=VALUE        environment for restic; repeatable. This is where an
                         S3 full-access key pair goes.
  --no-env               state that restic needs no environment for this target
  --repo=<name>          prune only this repository; repeatable. Default: every
                         repository the server has a password for, plus
                         kasbah.probe.
  --keep-daily=N         retention. Each defaults to the server marker's, which
  --keep-weekly=N        ` + "`server init --with-backup`" + ` recorded.
  --keep-monthly=N
  --dry-run              print the plan and stop, asking nothing
  --yes                  answer the confirmation, for scripts
  --docker-network=<net> run restic on this Docker network. The default is
                         docker's own, which reaches the internet and so reaches
                         object storage; pass this when the repository is only
                         reachable from a particular network on this machine —
                         a MinIO beside it, a VPN sidecar, a test rig.

Repositories are never removed, only emptied: there is no way to delete one
over the wire (docs/backup.md → Handover).
`

var reNetwork = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*$`)

// ParsePrune checks every value before anything is opened; a credential in
// a value is never echoed.
func ParsePrune(args []string) (PruneOptions, error) {
	var o PruneOptions
	for _, a := range args {
		name, val, hasVal := strings.Cut(a, "=")
		var err error
		switch {
		case hasVal && name == "--repo-base":
			o.RepoBase = strings.TrimSuffix(val, "\r")
			err = CheckRepoBase(pruneCmd, "--repo-base=", o.RepoBase)
		case hasVal && name == "--env":
			if err = CheckEnvEntry(pruneCmd, "--env=", val); err == nil {
				o.Env = append(o.Env, val)
			}
		case a == "--no-env":
			o.NoEnv = true
		case hasVal && name == "--repo":
			if err = CheckRepoRef(pruneCmd, "--repo=", val); err == nil {
				o.Only = append(o.Only, val)
			}
		case hasVal && name == "--keep-daily":
			o.Daily = val
			_, err = CheckKeep(pruneCmd, "--keep-daily=", val)
		case hasVal && name == "--keep-weekly":
			o.Weekly = val
			_, err = CheckKeep(pruneCmd, "--keep-weekly=", val)
		case hasVal && name == "--keep-monthly":
			o.Monthly = val
			_, err = CheckKeep(pruneCmd, "--keep-monthly=", val)
		case a == "--dry-run":
			o.DryRun = true
		case a == "--yes":
			o.Yes = true
		case hasVal && name == "--docker-network":
			o.Network = strings.TrimSuffix(val, "\r")
			if !reNetwork.MatchString(o.Network) {
				err = cli.Fail("server backup-prune: --docker-network=%s is not a docker network name", o.Network)
			}
		case a == "-h", a == "--help":
			o.Help = true
			return o, nil
		case strings.HasPrefix(a, "-"):
			return o, cli.Fail("server backup-prune: unknown flag '%s' (expected --repo-base=, --env=/--no-env, --repo=, --keep-daily=, --keep-weekly=, --keep-monthly=, --docker-network=, --dry-run, --yes)", name)
		default:
			if o.Target != "" {
				return o, cli.Fail("server backup-prune: unexpected argument '%s' (USER@HOST is given once)", a)
			}
			o.Target = strings.TrimSuffix(a, "\r")
		}
		if err != nil {
			return o, err
		}
	}
	if o.Target == "" {
		return o, cli.Fail("server backup-prune: USER@HOST is required (it is what says which repositories this server has)")
	}
	return o, nil
}

// PruneSession is what backup-prune needs from the server: its marker and
// its repositories' passwords — never the storage credential.
type PruneSession interface {
	Marker() (*marker.Marker, string, error)
	Repos(apps string) ([]byte, int)
	Close()
}

// SSHPrune is the real PruneSession.
type SSHPrune struct {
	Conn  *ssh.Conn
	Self  remote.Info
	Local func(arch string) (string, error)
	bin   string
}

// DialPrune connects.
func DialPrune(self remote.Info, local func(arch string) (string, error)) func(string) (PruneSession, error) {
	return func(target string) (PruneSession, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSHPrune{Conn: c, Self: self, Local: local}, nil
	}
}

func (s *SSHPrune) bounded(args ...string) []string {
	return append([]string{"timeout", "-k", "5", strconv.Itoa(serverbin.RunTimeout), s.bin, "remote"}, args...)
}

func (s *SSHPrune) Marker() (*marker.Marker, string, error) {
	target := s.Conn.Target.String()
	res, err := serverbin.Ensure(s.Conn, s.Self, s.Local, serverbin.Options{})
	if err != nil {
		return nil, "", err
	}
	s.bin = serverbin.Path(res.Apps)
	path := marker.Path(res.Apps)
	body, err := s.Conn.Run(s.bounded("marker", res.Apps)...)
	if err != nil {
		return nil, "", cli.Fail("could not read the server marker %s on %s (the remote step exited %d, see above)", path, target, ssh.ExitCode(err))
	}
	init := "kasbah server init " + target
	if res.Apps != serverbin.DefaultApps {
		init += " --apps-path=" + res.Apps
	}
	m, err := marker.Validate(body, path, target, init)
	return m, path, err
}

func (s *SSHPrune) Repos(apps string) ([]byte, int) {
	out, err := s.Conn.Run(s.bounded("backup-init", "repos", apps)...)
	return out, ssh.ExitCode(err)
}

func (s *SSHPrune) Close() { s.Conn.Close() }

// PruneCtx is what a run needs from its process.
type PruneCtx struct {
	Out      *cli.Output
	Prompter *prompt.Prompter
	Dial     func(target string) (PruneSession, error)
	// Restic runs restic here against one staged repository: its combined
	// output and exit status. Nil is DockerRestic.
	Restic func(dir, network, repo string, args ...string) (string, int)
}

// DockerRestic is restic in a container on this machine, its repository and
// password staged in dir, so neither is ever in argv.
func DockerRestic(dir, network, repo string, args ...string) (string, int) {
	words := []string{"run", "--rm"}
	if network != "" {
		words = append(words, "--network", network)
	}
	words = append(words, "--env-file", dir+"/env/"+repo+".env", "-v", dir+"/pw:/pw:ro", ResticImage, "--no-cache")
	var out bytes.Buffer
	cmd := exec.Command("docker", append(words, args...)...)
	cmd.Stdout, cmd.Stderr = &out, &out
	err := cmd.Run()
	if err != nil && cmd.ProcessState == nil {
		return err.Error(), 127
	}
	return strings.TrimRight(out.String(), "\n"), exitCode(err)
}

func field(m *jv.Map, path ...any) string {
	v, _ := jv.Get(m, path...)
	return strings.TrimRight(jv.ToString(jv.Alt(v, "")), "\n")
}

// Prune applies the retention with the full-access credential, from this
// machine: a plan per repository, one confirmation, then the act on the
// planned ones only. The whole report is on stdout.
func Prune(c PruneCtx, o PruneOptions) error {
	out := c.Out
	say := func(format string, a ...any) { fmt.Fprintf(out.Stdout, format+"\n", a...) }
	restic := c.Restic
	if restic == nil {
		if _, err := exec.LookPath("docker"); err != nil {
			return cli.Fail("docker is required: kasbah installs no packages, so restic runs as a container here exactly as it does on the VPS (docs/phases/08-keep.md D1)")
		}
		restic = DockerRestic
	}

	s, err := c.Dial(o.Target)
	if err != nil {
		return err
	}
	closed := false
	defer func() {
		if !closed {
			s.Close()
		}
	}()
	m, path, err := s.Marker()
	if err != nil {
		return err
	}
	apps := m.AppsPath
	if en, _ := jv.Get(m.JSON, "backup", "enabled"); jv.ToString(jv.Alt(en, false)) != "true" {
		return cli.Fail("%s has no backups: %s says backup.enabled is %s", o.Target, path, jv.ToString(jv.Alt(en, false))).Cont(
			"there is nothing to prune. Install them with:",
			"  kasbah server init "+o.Target+" --with-backup")
	}
	base := o.RepoBase
	if base == "" {
		if base = field(m.JSON, "backup", "repo_base"); base == "" {
			return cli.Fail("%s on %s records no backup.repo_base — pass --repo-base= to say which storage to prune", path, o.Target)
		}
		out.Warn("using the repository base the server records: %s", Redact(base))
		out.Warn("that is the base the VPS writes with. Where the credential is in the URL, the")
		out.Warn("full-access spelling is a different one — pass it with --repo-base=.")
	}
	if err := CheckRepoBase(pruneCmd, "the backup.repo_base recorded on "+o.Target+", ", base); err != nil {
		return err
	}
	keep := map[string]string{"daily": o.Daily, "weekly": o.Weekly, "monthly": o.Monthly}
	def := map[string]int{"daily": DefaultDaily, "weekly": DefaultWeekly, "monthly": DefaultMonthly}
	for _, k := range []string{"daily", "weekly", "monthly"} {
		if keep[k] == "" {
			keep[k] = field(m.JSON, "backup", "retention", k)
		}
		if keep[k] == "" {
			keep[k] = strconv.Itoa(def[k])
		}
		if _, err := CheckKeep(pruneCmd, "--keep-"+k+"=", keep[k]); err != nil {
			return err
		}
	}

	env := o.Env
	if len(env) == 0 && !o.NoEnv {
		yes, err := c.Prompter.Choice(prompt.Pair{Yes: "env=KEY=VALUE", No: "no-env"},
			fmt.Sprintf("Does restic need environment variables to reach %s with full access (an S3 key pair, for example)?", Redact(base)), prompt.Unset)
		if err != nil {
			return err
		}
		for yes {
			name, err := c.Prompter.Value("env", "Variable name, or 'done' to finish", "", "done")
			if err != nil {
				return err
			}
			if name == "done" {
				break
			}
			val, err := c.Prompter.Secret("env", "Value for "+name+" (not echoed)", "")
			if err != nil {
				return err
			}
			if err := CheckEnvEntry(pruneCmd, "--env=", name+"="+val); err != nil {
				return err
			}
			env = append(env, name+"="+val)
		}
	}

	raw, rc := s.Repos(apps)
	if rc != 0 {
		return cli.Fail("could not read %s/.kasbah/backup/repos on %s (the remote step exited %d, see above)", apps, o.Target, rc)
	}
	var rep ReposReport
	if json.Unmarshal(bytes.TrimSpace(raw), &rep) != nil || rep.Repos == nil {
		// Not quoted back: the report carries the passwords.
		return cli.Fail("the backup repository read on %s reported no repos", o.Target).Cont(
			"the step was truncated, or the server's kasbah rejected it")
	}
	repos := append(append([]string{}, rep.Repos...), ProbeRepo)
	if len(o.Only) > 0 {
		var kept []string
		for _, want := range o.Only {
			found := false
			for _, r := range repos {
				found = found || r == want
			}
			if !found {
				return cli.Fail("server backup-prune: %s has no '%s' repository (it has: %s)", o.Target, want, strings.Join(repos, " "))
			}
			kept = append(kept, want)
		}
		repos = kept
	}

	dir, err := os.MkdirTemp("", "kasbah-backup-prune.*")
	if err != nil {
		return cli.Fail("could not create a temp directory for the prune credentials")
	}
	cleanup := func() { os.RemoveAll(dir) }
	pop := atexit.Push(cleanup)
	defer func() { pop(); cleanup() }()
	if err := stage(dir, o.Target, base, env, repos, rep.Pass); err != nil {
		return err
	}
	s.Close()
	closed = true

	flags := []string{"--keep-daily", keep["daily"], "--keep-weekly", keep["weekly"], "--keep-monthly", keep["monthly"]}
	lines := func(text string) {
		for _, l := range strings.Split(text, "\n") {
			say("    %s", l)
		}
	}
	say("Retention on %s: keep %s daily, %s weekly, %s monthly", o.Target, keep["daily"], keep["weekly"], keep["monthly"])
	net := ""
	if o.Network != "" {
		net = ", on the " + o.Network + " network"
	}
	say("  base: %s   restic: %s, run here and not on the VPS%s", Redact(base), ResticImage, net)
	// Only a repository whose plan was shown is pruned below.
	var planned []string
	for _, r := range repos {
		say("  %s — what would be removed:", r)
		text, rc := restic(dir, o.Network, r, append([]string{"forget", "--dry-run"}, flags...)...)
		lines(text)
		if rc != 0 {
			out.Warn("  %s — restic exited %d above; this repository is skipped", r, rc)
			continue
		}
		planned = append(planned, r)
	}
	if len(planned) == 0 {
		return cli.Fail("server backup-prune: no repository could be read with these credentials — nothing was changed")
	}
	if o.DryRun {
		say("--dry-run: nothing was removed")
		return nil
	}
	ok, err := c.Prompter.Confirm("yes", fmt.Sprintf("Apply this retention to %s's repositories? Snapshots outside it are removed permanently.", o.Target), o.Yes)
	if err != nil {
		return err
	}
	if !ok {
		return cli.Fail("server backup-prune: declined — nothing was removed")
	}
	failed, pruned := 0, 0
	for _, r := range planned {
		say("  %s — forgetting and pruning:", r)
		text, rc := restic(dir, o.Network, r, append([]string{"forget", "--prune"}, flags...)...)
		lines(text)
		if rc != 0 {
			out.Err("  %s — restic exited %d", r, rc)
			failed++
			continue
		}
		pruned++
	}
	if failed > 0 {
		return cli.Fail("server backup-prune: %d of %d repositories were not pruned (see above)", failed, len(planned))
	}
	say("Pruned %d repositories on %s", pruned, o.Target)
	say("  the repositories themselves stay: there is no way to remove one over the wire")
	return nil
}

// stage writes one password file and one env file per repository, 600 in
// 700 directories; the operator's entries first, kasbah's two keys last
// (`docker --env-file` is last-wins).
func stage(dir, target, base string, env, repos []string, pass map[string]string) error {
	for _, d := range []string{dir, dir + "/pw", dir + "/env"} {
		if err := os.MkdirAll(d, 0o700); err != nil || os.Chmod(d, 0o700) != nil {
			return cli.Fail("could not create %s", d)
		}
	}
	for _, r := range repos {
		p := ProbePassword
		if r != ProbeRepo {
			b, err := base64.StdEncoding.DecodeString(pass[r])
			if pass[r] == "" || err != nil {
				return cli.Fail("internal: %s listed the '%s' repository and sent no password for it", target, r)
			}
			p = strings.TrimSuffix(string(b), "\n")
		}
		if err := os.WriteFile(dir+"/pw/"+r+".pass", []byte(p+"\n"), 0o600); err != nil {
			return cli.Fail("could not stage the password for %s", r)
		}
		var b strings.Builder
		for _, e := range env {
			b.WriteString(e + "\n")
		}
		fmt.Fprintf(&b, "RESTIC_REPOSITORY=%s%s\nRESTIC_PASSWORD_FILE=/pw/%s.pass\n", base, r, r)
		if err := os.WriteFile(dir+"/env/"+r+".env", []byte(b.String()), 0o600); err != nil {
			return cli.Fail("could not stage the environment for %s", r)
		}
	}
	return nil
}
