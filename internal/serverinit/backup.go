package serverinit

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io/fs"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/backuprec"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/tmpl"
	"github.com/adigourdi/kasbah/internal/tree"
)

const bkCmd = "server init"

// FlagsUnused warns about backup flags on a run that installs no backups —
// a fleet script sets the base once and meets servers without them.
func FlagsUnused(out *cli.Output, o Options) {
	var named []string
	for _, f := range []struct {
		set  bool
		name string
	}{
		{o.Bk.RepoBase != "", "--backup-repo-base="}, {o.Bk.At != "", "--backup-at="},
		{o.Bk.Jitter != "", "--backup-jitter="}, {o.Bk.Daily != "", "--backup-keep-daily="},
		{o.Bk.Weekly != "", "--backup-keep-weekly="}, {o.Bk.Monthly != "", "--backup-keep-monthly="},
		{len(o.Bk.Env) > 0, "--backup-env="}, {len(o.Bk.Pass) > 0, "--backup-password="},
		{o.Bk.NoEnv, "--no-backup-env"},
	} {
		if f.set {
			named = append(named, f.name)
		}
	}
	if len(named) > 0 {
		out.Warn("%s had no effect: this run is not installing backups", strings.Join(named, " "))
	}
}

// BackupValues is what --with-backup settled, and where each came from.
type BackupValues struct {
	RepoBase, BaseOrigin   string
	At                     string
	Jitter, Timeout        int
	Daily, Weekly, Monthly int
	EnvOrigin              string
	Env                    []string
	Repos, Fallbacks       []string
	Pass                   map[string]string
	New                    []string
	HasPass                []string
}

// Marker is the marker's `backup` object for these values.
func (v *BackupValues) Marker() *marker.Backup {
	return &marker.Backup{RepoBase: v.RepoBase, At: v.At, Jitter: v.Jitter, Timeout: v.Timeout,
		Retention: marker.Retention{Daily: v.Daily, Weekly: v.Weekly, Monthly: v.Monthly}}
}

// recorded is an existing marker's backup.<path> as text, "" for none or null.
func recorded(m *tree.Map, path ...any) string {
	if m == nil {
		return ""
	}
	return tree.TextAt(m, append([]any{"backup"}, path...)...)
}

func in(ss []string, s string) bool {
	for _, x := range ss {
		if x == s {
			return true
		}
	}
	return false
}

// BackupResolve reproduces what the marker records, asks for what nothing
// says, and asks for a password only for a repository without one: a
// password on the server is never rewritten.
func BackupResolve(out *cli.Output, p *prompt.Prompter, o Options, r *backup.ReadReport, existing *tree.Map) (*BackupValues, error) {
	b := o.Bk
	v := &BackupValues{RepoBase: b.RepoBase, BaseOrigin: "flag", Pass: map[string]string{}, HasPass: r.HasPass}
	switch r.Dir {
	case "absent", "dir":
	case "notdir":
		return nil, cli.Fail("%s/.kasbah/backup on %s exists and is not a directory", o.Apps, o.Target).Cont(
			"that is where the backup stack lives — its compose file, its runner, the",
			"repository base and the per-repository passwords. Look at it, remove it,",
			"and re-run. Nothing has been changed.")
	default:
		return nil, cli.Fail("the backup stack read on %s reported backup_dir='%s', which this kasbah does not know", o.Target, r.Dir)
	}
	or := func(given string, path ...any) string {
		if given != "" {
			return given
		}
		return recorded(existing, path...)
	}
	if v.RepoBase == "" {
		if v.RepoBase = recorded(existing, "repo_base"); v.RepoBase != "" {
			v.BaseOrigin = "marker"
		}
	}
	at, jitter, timeout := or(b.At, "at"), or(b.Jitter, "jitter"), or(b.Timeout, "timeout")
	keeps := []string{or(b.Daily, "retention", "daily"), or(b.Weekly, "retention", "weekly"), or(b.Monthly, "retention", "monthly")}

	var err error
	if v.RepoBase == "" {
		if v.RepoBase, err = p.Value("backup-repo-base",
			fmt.Sprintf("Restic repository base for %s — snapshots go to <base><client>, with a trailing '/'", o.Target), "", ""); err != nil {
			return nil, err
		}
		v.BaseOrigin = "prompt"
	}
	if err := backup.CheckRepoBase(bkCmd, "--backup-repo-base=", v.RepoBase); err != nil {
		return nil, err
	}
	// Said, not refused: a rest: target has nowhere else for its credential.
	if shown := backup.Redact(v.RepoBase); shown != v.RepoBase {
		out.Warn("the repository base carries a credential: %s", shown)
		out.Warn("it is recorded in %s's server marker, which is mode 644 by contract, and", o.Target)
		out.Warn("printed (redacted) by every command that names it. Where the backend allows it,")
		out.Warn("put the credential in the environment block instead — --backup-env=KEY=VALUE.")
	}
	if at == "" {
		at = backup.DefaultAt
	}
	if err := backup.CheckAt(bkCmd, at); err != nil {
		return nil, err
	}
	v.At = at
	if jitter == "" {
		jitter = strconv.Itoa(backup.JitterFor(o.Target))
	}
	if v.Jitter, err = backup.CheckJitter(bkCmd, jitter); err != nil {
		return nil, err
	}
	if timeout == "" {
		timeout = strconv.Itoa(backup.DefaultTimeout)
	}
	if v.Timeout, err = backup.CheckTimeout(bkCmd, timeout); err != nil {
		return nil, err
	}
	defs := []int{backup.DefaultDaily, backup.DefaultWeekly, backup.DefaultMonthly}
	dest := []*int{&v.Daily, &v.Weekly, &v.Monthly}
	for i, name := range []string{"daily", "weekly", "monthly"} {
		if keeps[i] == "" {
			keeps[i] = strconv.Itoa(defs[i])
		}
		if *dest[i], err = backup.CheckKeep(bkCmd, "--backup-keep-"+name+"=", keeps[i]); err != nil {
			return nil, err
		}
	}

	// Asked once, on the run that creates the env file: after that it is the
	// operator's, and kasbah only rewrites what it is told to.
	v.EnvOrigin, v.Env = "file", b.Env
	switch {
	case len(b.Env) > 0:
		v.EnvOrigin = "flag"
	case b.NoEnv:
		v.EnvOrigin = "none"
	case r.Env != "present":
		yes, err := p.Choice(prompt.Pair{Yes: "backup-env=KEY=VALUE", No: "no-backup-env"},
			fmt.Sprintf("Does restic need environment variables to reach %s (an S3 key pair, for example)?", backup.Redact(v.RepoBase)), prompt.Unset)
		if err != nil {
			return nil, err
		}
		v.EnvOrigin = "none"
		if yes {
			v.EnvOrigin = "prompt"
		}
		for yes {
			name, err := p.Value("backup-env", "Variable name, or 'done' to finish", "", "done")
			if err != nil {
				return nil, err
			}
			if name == "done" {
				break
			}
			val, err := p.Secret("backup-env", "Value for "+name+" (not echoed)", "")
			if err != nil {
				return nil, err
			}
			if err := backup.CheckEnvEntry(bkCmd, "--backup-env=", name+"="+val); err != nil {
				return nil, err
			}
			v.Env = append(v.Env, name+"="+val)
		}
	}

	for _, pr := range r.Projects {
		if pr.Client == "" || pr.Client == "?" {
			v.Fallbacks = append(v.Fallbacks, pr.Name)
		}
	}
	v.Repos = backuprec.RepoSet(r.Projects, r.Mail)
	for _, given := range b.Pass {
		repo, pass, err := backup.SplitPassword(bkCmd, given)
		if err != nil {
			return nil, err
		}
		if in(r.HasPass, repo) {
			out.Warn("--backup-password=%s= had no effect: %s already has a password on %s,", repo, repo, o.Target)
			out.Warn("and init never rewrites one — that would leave the repository unreadable.")
			continue
		}
		v.Pass[repo] = pass
		// A client may be seeded before its first deploy.
		if !in(v.Repos, repo) {
			v.Repos = append(v.Repos, repo)
		}
	}
	for _, repo := range v.Repos {
		if _, ok := v.Pass[repo]; ok || in(r.HasPass, repo) {
			continue
		}
		pass, err := p.Secret("backup-password="+repo,
			fmt.Sprintf("Restic password for the '%s' repository (encrypts its snapshots; kasbah never generates one and cannot recover it)", repo), "")
		if err != nil {
			return nil, err
		}
		if err := backup.CheckPassword(bkCmd, repo, pass); err != nil {
			return nil, err
		}
		v.Pass[repo] = pass
	}
	for _, repo := range v.Repos {
		if _, ok := v.Pass[repo]; ok {
			v.New = append(v.New, repo)
		}
	}
	return v, nil
}

// BackupRender renders the compose file and the env file's first-run
// default, refusing an env file that already sets a key kasbah owns.
func BackupRender(fsys fs.FS, o Options, v *BackupValues, r *backup.ReadReport) (compose, envDefault string, err error) {
	read := func(name string) (string, error) {
		b, err := fs.ReadFile(fsys, "backup/"+name)
		if err != nil {
			return "", cli.Fail("internal: this kasbah build carries no backup/%s template", name)
		}
		return string(b), nil
	}
	// A data path equal to the apps path would be a duplicate mount point.
	dataMount := ""
	if o.Data != o.Apps {
		dataMount = fmt.Sprintf(`      - "%s:%s:ro"`, o.Data, o.Data)
	}
	tpl, err := read("compose.yml")
	if err != nil {
		return "", "", err
	}
	if compose, err = tmpl.Render(tpl, "backup compose.yml", map[string]string{
		"APPS_PATH": o.Apps, "DATA_PATH": o.Data, "RESTIC_IMAGE": backup.ResticImage,
		"BACKUP_AT": v.At, "BACKUP_JITTER": strconv.Itoa(v.Jitter), "BACKUP_TIMEOUT": strconv.Itoa(v.Timeout),
		"BACKUP_DATA_MOUNT": dataMount,
	}); err != nil {
		return "", "", err
	}
	if perr := tmpl.CheckYAML(compose); perr != nil {
		return "", "", cli.Fail("the rendered backup compose.yml is not valid YAML — refusing to ship it").Cont(
			perr.Error(), fmt.Sprintf("rendered with apps %s, data %s, at %s, jitter %d", o.Apps, o.Data, v.At, v.Jitter))
	}
	if tpl, err = read("env"); err != nil {
		return "", "", err
	}
	if envDefault, err = tmpl.Render(tpl, "backup env", map[string]string{"BACKUP_REPO_BASE": v.RepoBase}); err != nil {
		return "", "", err
	}
	if r.EnvOwned != "" {
		return "", "", backup.OwnedEnvError(o.Apps, r.EnvOwned)
	}
	return compose, envDefault, nil
}

// backupRead is the stack as the server's binary sees it.
func (s *session) backupRead(o Options) (*backup.ReadReport, error) {
	body, rc := s.remote(nil, true, "backup-init", "read", o.Apps, o.Data)
	if rc != 0 {
		return nil, cli.Fail("could not read the backup stack on %s (the remote step exited %d, see above)", s.target, rc)
	}
	var r backup.ReadReport
	if json.Unmarshal([]byte(body), &r) != nil || r.Dir == "" || r.Env == "" {
		return nil, cli.Fail("the backup stack read on %s reported nothing kasbah can use", s.target).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:", "| "+strings.TrimSpace(body))
	}
	if r.Owner != "" {
		return nil, serverlock.PrivateRefusal("--with-backup", r.Owner, o.Apps+"/.kasbah/backup")
	}
	return &r, nil
}

// backupStackNote is what a probe refusal says about the stack: the
// credentials land before the probe, so a stack already there now holds them.
func backupStackNote(e *cli.Error, apps string, hadStack bool) {
	if !hadStack {
		e.Cont("No backup stack was started.")
		return
	}
	e.Cont("The backup stack already on this server is still running, and now holds the",
		"credentials this run refused: it will keep failing until they are fixed. Take",
		fmt.Sprintf("it down with `docker compose -p %s down` in %s/.kasbah/backup", backup.Project, apps),
		"if it must not run at all meanwhile.")
}

// ProbeVerdict judges the probe's report: reach, write and list failures
// and a credential that deleted are four refusals with four remedies.
func ProbeVerdict(f Facts, target, apps string, v *BackupValues, hadStack bool) error {
	probed := backup.Redact(f["probe_repo"])
	if want := v.RepoBase + backup.ProbeRepo; f["probe_repo"] != want {
		return cli.Fail("internal: the credential probe on %s opened %s, and this run configured %s — what was tested and what will be written are not the same repository", target, probed, backup.Redact(want))
	}
	logb, _ := base64.StdEncoding.DecodeString(f["probe_log_b64"])
	detail := func(e *cli.Error) *cli.Error {
		backupStackNote(e, apps, hadStack)
		for _, l := range strings.Split(strings.TrimSuffix(string(logb), "\n"), "\n") {
			e.Cont("| " + l)
		}
		return e
	}
	switch f["probe_stage"] {
	case "reach":
		return detail(cli.Fail("the backup credentials on %s cannot reach %s", target, probed).Cont(
			"restic could neither open nor create the probe repository, so nothing about",
			"this credential has been established.",
			"The repository base is --backup-repo-base=; anything restic needs besides",
			"it — an S3 key pair, for instance — is --backup-env=KEY=VALUE, and lands in",
			apps+"/.kasbah/backup/env, which you can also edit there directly.",
			"An address that accepts a connection and then answers nothing looks the same",
			fmt.Sprintf("from here as a wrong one: each restic call was given %ds (--backup-timeout=).", v.Timeout)))
	case "write":
		return detail(cli.Fail("the backup credentials on %s cannot write to %s", target, probed).Cont(
			"the repository opened and the snapshot did not go in, so this credential",
			"cannot take a backup at all."))
	case "unlisted":
		return detail(cli.Fail("the backup credentials on %s could not list %s", target, probed).Cont(
			"restic reached the repository and then failed to read its snapshots back",
			fmt.Sprintf("(%s the delete attempt), so whether this credential can delete its own", f["probe_when"]),
			"history is unknown — and unknown is not a state a backup stack may start in.",
			"A timeout is the likeliest cause: the bound on one restic call is",
			fmt.Sprintf("--backup-timeout=, currently %ds.", v.Timeout)))
	case "deleted":
	default:
		return cli.Fail("the backup credential probe on %s reported probe_stage='%s', which this kasbah does not know", target, f["probe_stage"])
	}
	mid, err1 := strconv.Atoi(f["probe_mid"])
	after, err2 := strconv.Atoi(f["probe_after"])
	if err1 != nil || err2 != nil {
		return cli.Fail("the backup credential probe on %s reported counts kasbah cannot read", target)
	}
	if mid < 2 {
		return cli.Fail("internal: the credential probe wrote two snapshots and counted %d — forgetting the only snapshot in a repository is the case restic refuses on its own argument check, so the delete it then attempted would have proved nothing", mid)
	}
	if after < mid {
		return detail(cli.Fail("the backup credentials on %s can DELETE snapshots — refusing to install backups", target).Cont(
			fmt.Sprintf("the probe wrote %d snapshots to %s, asked restic to forget", mid, probed),
			fmt.Sprintf("one of them by name, and %d were left. A VPS that can delete its own history is", after),
			"a VPS whose history a compromise destroys, which is the whole point of the",
			"credential split (docs/backup.md → Credentials).",
			"Give this server an append-only key — write and list, no delete, no overwrite —",
			"and keep the full-access one on your own machine, where",
			"`kasbah server backup-prune` uses it.",
			"The credentials are already at "+apps+"/.kasbah/backup/env; edit them there, or",
			"re-run with --backup-repo-base= / --backup-env=."))
	}
	return nil
}

// backupInstall lays out the stack and its secrets, proves the credential,
// ships the compose file and starts the stack — in that order, so only a
// credential that could write and could not delete gets a scheduler.
func (s *session) backupInstall(o Options, v *BackupValues, r *backup.ReadReport, compose, envDefault string, restart bool) (bkReport, error) {
	var rep bkReport
	body := backup.LayoutBody{Default: envDefault, RepoBase: v.RepoBase, Env: v.Env, Passwords: []backup.Password{}}
	for _, repo := range v.New {
		body.Passwords = append(body.Passwords, backup.Password{Repo: repo, Pass: v.Pass[repo]})
	}
	raw, _ := json.Marshal(body)
	size, sum := remote.Digest(raw)
	res, rc := s.remote(raw, true, "backup-init", "layout", o.Apps, size, sum)
	if rc != 0 {
		return rep, stepFailed("lay out "+o.Apps+"/.kasbah/backup", s.target, rc)
	}
	lay, err := checked("the backup layout step", s.target, res, "backup_layout", "env_state")
	if err != nil {
		return rep, err
	}
	rep.Env = lay["env_state"]

	// Unbounded here: each of its restic calls is bounded on the server.
	res, rc = s.remote(nil, false, "backup-init", "probe", o.Apps, backup.ResticImage, strconv.Itoa(v.Timeout))
	if rc != 0 {
		return rep, cli.Fail("could not run the backup credential probe on %s (the remote step exited %d, see above)", s.target, rc)
	}
	pf, err := checked("the backup credential probe", s.target, res,
		"probe_repo", "probe_stage", "probe_mid", "probe_after", "probe_rc", "probe_when", "probe_log_b64")
	if err != nil {
		return rep, err
	}
	cur, _ := base64.StdEncoding.DecodeString(r.Compose)
	if err := ProbeVerdict(pf, s.target, o.Apps, v, len(cur) > 0); err != nil {
		return rep, err
	}
	rep.Probed = pf["probe_repo"]

	if compose != string(cur) {
		dest := o.Apps + "/.kasbah/backup/compose.yml"
		if _, rc := s.send([]byte(compose), "write", dest); rc != 0 {
			return rep, cli.Fail("could not ship the backup compose.yml to %s:%s", s.target, dest)
		}
		rep.Changed = append(rep.Changed, "compose.yml")
	}
	yn := "no"
	if restart {
		yn = "yes"
	}
	res, rc = s.remote(nil, false, "backup-init", "start", o.Apps, yn)
	if rc != 0 {
		return rep, cli.Fail("could not start the backup stack on %s (the remote step exited %d, see above)", s.target, rc)
	}
	if rep.Start, err = checked("the backup start", s.target, res,
		"backup_state", "backup_restarts", "backup_image", "backup_container", "backup_legacy"); err != nil {
		return rep, err
	}
	return rep, nil
}

type bkReport struct {
	Env, Probed string
	Changed     []string
	Start       Facts
}

// reportBackup says what the stack became, which repositories still have
// no password, and which projects file under their own name.
func reportBackup(out *cli.Output, o Options, v *BackupValues, rep bkReport) {
	shipped := "nothing re-rendered"
	if len(rep.Changed) > 0 {
		shipped = "shipped " + strings.Join(rep.Changed, " ")
	}
	if rep.Start["backup_legacy"] == "removed" {
		shipped += ", removed the old backup.sh"
	}
	ind := "          "
	out.Info("  backup: %s/.kasbah/backup (%s, env %s)", o.Apps, shipped, rep.Env)
	out.Info(ind+"repo base %s (%s), daily at %s plus %ds jitter, %ds per restic call", backup.Redact(v.RepoBase), v.BaseOrigin, v.At, v.Jitter, v.Timeout)
	switch v.EnvOrigin {
	case "none":
		out.Info("%srestic environment: none, as stated", ind)
	case "flag":
		out.Info(ind+"restic environment: the keys named on this command line, merged into %s/.kasbah/backup/env", o.Apps)
	default:
		out.Info(ind+"restic environment: whatever %s/.kasbah/backup/env holds — kasbah copies it through untouched", o.Apps)
	}
	out.Info(ind+"retention %d daily / %d weekly / %d monthly, applied by `kasbah server backup-prune %s`", v.Daily, v.Weekly, v.Monthly, o.Target)
	out.Info(ind+"credentials: append-only (probed against %s)", backup.Redact(rep.Probed))
	st := rep.Start
	out.Info(ind+"%s %s (%s restarts, %s)", st["backup_container"], st["backup_state"], st["backup_restarts"], st["backup_image"])
	out.Info(ind+"back up now: ssh %s 'docker exec %s %s/.kasbah/bin/kasbah remote backup once'", o.Target, backup.Container, o.Apps)
	out.Info(ind+"last run:     %s/.kasbah/backup/state/status (what the healthcheck reads)", o.Apps)
	var missing []string
	for _, repo := range v.Repos {
		if _, ok := v.Pass[repo]; !ok && !in(v.HasPass, repo) {
			missing = append(missing, repo)
		}
	}
	if len(missing) > 0 {
		out.Warn("no restic password for: %s — those repositories are NOT backed up", strings.Join(missing, " "))
		out.Warn("re-run init with --with-backup to be asked, or --backup-password=<repo>=<password>")
	}
	if len(v.Fallbacks) > 0 {
		out.Warn("no client record for: %s — each is filed under its own name", strings.Join(v.Fallbacks, " "))
		out.Warn("that is what `client:` defaults to, and `kasbah deploy` writes the record — so a")
		out.Warn("project deployed by an older kasbah, or one whose manifest names a different")
		out.Warn("client, is in the wrong repository until it is deployed again")
	}
}
