package deploy

import (
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/tree"
)

// RestoreOptions is `kasbah restore`'s command line.
type RestoreOptions struct {
	Target, Snapshot, Backup, From string
	List                           bool
	Env, Data                      prompt.Given
}

const restoreUsage = `Usage: kasbah restore [USER@HOST] [--snapshot=ID] [--backup=NAME] [--from-path=PATH]
                      [--list] [--with-env|--no-env] [--with-data|--no-data]

Brings a project's .env and data back from its off-box backups onto the
version live on the server. Run from the project root. USER@HOST defaults to
the last server this project deployed to (.kasbah/state.json). The server
needs off-box backups (` + "`kasbah server init --with-backup`" + `) and a live
version: after a lost server, init it, deploy, then restore.

What it does:
  * lists, through the kasbah-backup container (which alone holds the
    credentials), the snapshots of the restic repository this project files
    into that hold its backups/, and the backup tarballs in the chosen one
  * copies the chosen tarball out of the snapshot into backups/ on the server,
    verified by size and sha256 and read through as a gzip'd tar; one already
    there under that name is used as it is
  * lists the names of the keys its .env and the server's disagree on (never
    a value), and asks whether to restore that .env, keep the server's, or
    decide per key; and, when the live version has a restore hook, whether to
    load the data with it — which replaces everything written since that
    backup was taken
  * ` + "`kasbah remote deploy restore`" + ` on the server, under the project's deploy
    lock: the chosen .env written, the backup extracted ($KASBAH_BACKUP_DIR)
    and the live version's restore hook run on it, and, when .env changed,
    docker compose -p <name> up -d --remove-orphans and the health wait. A
    failure after the .env write, or a SIGINT or SIGTERM, puts the previous
    .env back (and the stack up on it, once recreated) and says what became
    of the data; what a failed restore hook did to it is left as it is. No
    backup is taken and versions.log is not written

Flags:
  --snapshot=ID         the snapshot to restore from (an id or a prefix of
                        one); default the newest holding this project's backups
  --backup=NAME         the tarball to restore, <version>-<stamp>.tar.gz;
                        default the newest of the live version in the snapshot.
                        Another version's is allowed, with a warning: its data
                        may not fit the live version's schema
  --from-path=PATH      the path in the snapshots that holds the backups,
                        when it is neither backups/ here nor where it
                        resolves (another apps path, or a backups/ that was
                        a symlink): the refusal lists the candidates
  --list                print the snapshots and the backups in the chosen one,
                        and change nothing

  --with-env            restore the backup's .env whole
  --no-env              keep the server's .env
Unset, differing keys ask: restore, keep, or one question per key.
  --with-data           run the live version's restore hook on the backup —
                        refused, changing nothing, when it has none
  --no-data             leave the data as it is
Unset, a restore hook asks. With no terminal to ask on, an unanswered question
fails, naming its flags.

Without off-box backups, a backup already on the server is restored by
` + "`kasbah rollback`" + ` (an earlier version's) or by hand (docs/backup.md → Restore).

See docs/backup.md.
`

// RestoreUsage is `kasbah restore --help`.
func RestoreUsage() string { return restoreUsage }

// ParseRestore reads restore's arguments.
func ParseRestore(args []string) (RestoreOptions, error) {
	var o RestoreOptions
	for _, a := range args {
		a = strings.TrimSuffix(a, "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "--snapshot="):
			o.Snapshot = strings.TrimPrefix(a, "--snapshot=")
			if !backup.ReSnapshotID.MatchString(o.Snapshot) {
				return o, cli.Fail("restore: --snapshot='%s' is not a snapshot id (4 to 64 lowercase hex digits, as `kasbah restore --list` prints)", o.Snapshot)
			}
		case strings.HasPrefix(a, "--backup="):
			o.Backup = strings.TrimPrefix(a, "--backup=")
			if !reBackup.MatchString(o.Backup) {
				return o, cli.Fail("restore: --backup='%s' is not a backup's name (<version>-<YYYYMMDD-HHMMSS>.tar.gz, as `kasbah restore --list` prints)", o.Backup)
			}
		case strings.HasPrefix(a, "--from-path="):
			o.From = strings.TrimPrefix(a, "--from-path=")
			if !backup.FromPath(o.From) {
				return o, cli.Fail("restore: --from-path='%s' is not a path in a snapshot (absolute, clean, printable ASCII, as the refusal lists them)", o.From)
			}
		case a == "--snapshot" || a == "--backup" || a == "--from-path":
			return o, cli.Fail("restore: %s takes its value with '=' — %s=<%s>", a, a, strings.TrimPrefix(a, "--"))
		case a == "--list":
			o.List = true
		case a == "--with-env" || a == "--no-env" || a == "--with-data" || a == "--no-data":
			g, v, p := &o.Env, prompt.Yes, prompt.Feature("env")
			if strings.HasSuffix(a, "-data") {
				g, p = &o.Data, prompt.Feature("data")
			}
			if strings.HasPrefix(a, "--no-") {
				v = prompt.No
			}
			if err := g.Set(v, p, "restore"); err != nil {
				return o, err
			}
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("restore: unknown flag '%s' (restore takes USER@HOST, --snapshot=, --backup=, --from-path=, --list, --with-env/--no-env and --with-data/--no-data)", name)
		case !strings.Contains(a, "@"):
			return o, cli.Fail("restore: '%s' is not a server — restore takes USER@HOST and flags", a)
		case o.Target != "":
			return o, cli.Fail("restore: two servers given ('%s' and '%s') — one run goes to one server", o.Target, a)
		default:
			o.Target = a
		}
	}
	if o.List && (o.Env != prompt.Unset || o.Data != prompt.Unset || o.Backup != "") {
		return o, cli.Fail("restore: --list changes nothing, so it takes only USER@HOST, --snapshot= and --from-path=")
	}
	return o, nil
}

// RestoreServer is one server as `kasbah restore` needs it.
type RestoreServer interface {
	// Marker ships this build's binary when the server's is absent or older.
	Marker() (*marker.Marker, error)
	HoldServer(apps, what string) (release func(), err error)
	// RestoreList is `kasbah remote deploy restore-list`.
	RestoreList(apps, name, snapshot, from string) (*RestoreFacts, error)
	// FetchBackup is `kasbah remote deploy fetch`: fetched or present.
	FetchBackup(dir, snapshot, name, from string) (string, error)
	// ProbeNamed is `kasbah remote deploy backup-probe DIR --backup NAME`.
	ProbeNamed(dir, name string) (*BackupFacts, error)
	// Restore is `kasbah remote deploy restore`: its report, also on failure.
	Restore(dir, name, live string, envRestore bool, keys []string, data bool) (map[string]string, error)
	Close()
}

// RestoreCtx is what a restore needs from its process.
type RestoreCtx struct {
	Out      *cli.Output
	Prompter *prompt.Prompter
	Version  string
	Dial     func(target string) (RestoreServer, error)
}

// DialRestore is DialSSH as a RestoreServer.
func DialRestore(self remote.Info, local func(arch string) (string, error)) func(string) (RestoreServer, error) {
	dial := DialSSH(self, local)
	return func(target string) (RestoreServer, error) {
		s, err := dial(target)
		if err != nil {
			return nil, err
		}
		return s.(*SSH), nil
	}
}

// RunRestore is `kasbah restore`.
func RunRestore(c RestoreCtx, o RestoreOptions) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	target, _, err := state.Server(o.Target, "restore", "kasbah restore user@vps")
	if err != nil {
		return err
	}
	s, err := c.Dial(target)
	if err != nil {
		return err
	}
	defer s.Close()
	mk, err := s.Marker()
	if err != nil {
		return err
	}
	dir := mk.AppsPath + "/" + m.Name
	local := "A backup already on the server, in " + dir + "/" + Backups + "/, is restored by `kasbah rollback " + target +
		" <version>` when it is an earlier version's, or by hand when it is the live version's (docs/backup.md → Restore)."
	if en, _ := tree.Lookup(mk.JSON, "backup", "enabled"); en != true {
		return cli.Fail("restore: %s has no off-box backups, and kasbah restore pulls its backup from them — nothing was changed", target).Cont(
			"`kasbah server init "+target+" --with-backup` sets them up.", local)
	}
	release, err := s.HoldServer(mk.AppsPath, "restore")
	if err != nil {
		return err
	}
	defer release()
	f, err := s.RestoreList(mk.AppsPath, m.Name, o.Snapshot, o.From)
	if err != nil {
		return err
	}
	if f.State != "running" || f.List == nil {
		return cli.Fail("restore: %s records off-box backups, and the %s container is %s there — it alone reads the repository. Nothing was changed", target, backup.Container, f.State).Cont(
			"`kasbah server status "+target+"` shows the stack; `kasbah server init "+target+" --with-backup` reinstalls it.", local)
	}
	l := f.List
	if o.List {
		printList(c.Out, target, m.Name, f)
		return nil
	}
	if f.Live == "" {
		return cli.Fail("restore: %s has no live version on %s — %s/versions.log records no run that went live. Deploy first, then restore. Nothing was changed", m.Name, target, dir)
	}
	if !f.Hooks {
		return cli.Fail("restore: %s/%s is missing on %s — every deploy that goes live writes it, recording the live version's restore hook. Deploy once, then restore. Nothing was changed", dir, HooksFile, target)
	}
	if l.Snapshot == "" {
		return noSnapshot(l, m.Name, target)
	}
	var names []string
	for _, b := range l.Backups {
		names = append(names, b.Name)
	}
	chosen := o.Backup
	switch {
	case chosen != "" && !slices.Contains(names, chosen):
		return cli.Fail("restore: snapshot %s holds no backup %s of %s — nothing was changed", l.Snapshot, chosen, m.Name).Cont(
			"it holds: "+orNone(names, "no backup"), "`kasbah restore "+target+" --list` lists them; --snapshot= chooses another snapshot.")
	case chosen == "":
		if chosen = newestBackup(names, f.Live); chosen == "" {
			return cli.Fail("restore: snapshot %s holds no backup of %s, the version live on %s — nothing was changed", l.Snapshot, f.Live, target).Cont(
				"it holds: "+orNone(names, "no backup"), "choose one with --backup=NAME (another version's data may not fit "+f.Live+"'s schema), or another snapshot with --snapshot=ID.")
		}
	}
	if g := reBackup.FindStringSubmatch(chosen); g[1] != f.Live {
		c.Out.Warn("%s is a backup of %s, and %s is live: its data may not fit %s's schema, and %s's restore hook loads it", chosen, g[1], f.Live, f.Live, f.Live)
	}
	if o.Data == prompt.Yes && !f.RestoreHook {
		return cli.Fail("restore: --with-data, and %s %s has no restore hook in %s on %s — kasbah loads no data itself", m.Name, f.Live, HooksFile, target).Cont(
			"Nothing was changed. To restore .env alone, pass --no-data.")
	}
	// The data question is known before the fetch; the .env one may follow it.
	if f.RestoreHook && o.Data == prompt.Unset {
		if err := needTTY(c.Prompter, chosen, o.Env == prompt.Unset, true); err != nil {
			return err
		}
	}
	c.Out.Info("restoring %s on %s from snapshot %s (%s) of repository %s: %s", m.Name, target, l.Snapshot, snapTime(l), l.Repo, chosen)

	at := dir + "/" + Backups + "/" + chosen
	how, err := s.FetchBackup(dir, l.Snapshot, chosen, o.From)
	if err != nil {
		return err
	}
	// What changed so far: the fetched tarball alone.
	nothing, kept := "Nothing was changed.", ""
	if how == "present" {
		c.Out.Info("  %s is already on the server — used as it is", at)
	} else {
		c.Out.Info("  fetched into %s, size and sha256 checked", at)
		nothing = "The fetched tarball was added to " + dir + "/" + Backups + "/; nothing else was changed."
		kept = "the fetched backup stays in " + dir + "/" + Backups + "/."
	}
	cont := func(err error, line string) error {
		if e, ok := err.(*cli.Error); ok && line != "" {
			return e.Cont(line)
		}
		return err
	}
	pf, err := s.ProbeNamed(dir, chosen)
	if err != nil {
		return err
	}
	if pf.Backup != chosen {
		return cli.Fail("restore: %s is not in %s/%s on %s after the fetch — nothing was changed", chosen, dir, Backups, target)
	}
	differ := showEnvDiff(c.Out, dir, chosen, o.Env, pf)
	if err := askable(c.Prompter, at, differ && o.Env == prompt.Unset, f.RestoreHook && o.Data == prompt.Unset, nothing); err != nil {
		return err
	}
	var envRestore bool
	var keys []string
	if differ {
		if envRestore, keys, err = envAnswer(c.Out, c.Prompter, o.Env, "restore", chosen, pf); err != nil {
			return cont(err, nothing)
		}
	}
	data := false
	switch {
	case !f.RestoreHook:
		c.Out.Info("  %s %s has no restore hook — data is left as it is", m.Name, f.Live)
	case o.Data == prompt.Yes:
		data = true
	case o.Data == prompt.Unset:
		if data, err = c.Prompter.Bool("data", "load the data from "+chosen+" with "+f.Live+"'s restore hook? It replaces everything written since that backup was taken", prompt.Unset); err != nil {
			return cont(err, nothing)
		}
	}
	if f.RestoreHook {
		if data {
			c.Out.Info("  data: loaded by %s's restore hook — everything written since %s is replaced", f.Live, chosen)
		} else {
			c.Out.Info("  data: left as it is")
		}
	}
	record := func() error { return state.Record(state.File, c.Version, "last_server", target) }
	if !envRestore && !data {
		c.Out.Info("Nothing to restore: %s's .env and data on %s are left as they are", m.Name, target)
		return record()
	}
	kv, err := s.Restore(dir, chosen, f.Live, envRestore, keys, data)
	if err != nil {
		return err
	}
	switch kv["restore"] {
	case "done":
	case "refused":
		return cli.Fail("the restore on %s refused (see above)", target).Cont(nothing)
	case "failed":
		return cont(restoreFailed(kv, target, dir, chosen, f.Live, data), kept)
	default:
		return cli.Fail("the restore step on %s reported no outcome", target)
	}
	c.Out.Info("Restored %s on %s from %s", m.Name, target, chosen)
	switch {
	case kv["env"] == "restored" && keys != nil:
		c.Out.Info("  .env:   the backup's values for %s", strings.Join(keys, " "))
	case kv["env"] == "restored":
		c.Out.Info("  .env:   the backup's")
	case kv["env"] == "unchanged":
		c.Out.Info("  .env:   already held what the backup restores")
	default:
		c.Out.Info("  .env:   the server's, kept")
	}
	if kv["data"] == "restored" {
		c.Out.Info("  data:   loaded by %s's restore hook", f.Live)
	} else {
		c.Out.Info("  data:   left as it is")
	}
	if kv["recreated"] == "yes" {
		c.Out.Info("  stack:  recreated on the restored .env (docker compose up -d), health waited on")
	} else {
		c.Out.Info("  stack:  left running — .env did not change")
	}
	return record()
}

// noSnapshot is the refusal when no snapshot holds the project's backups at
// a path looked at, naming the paths in the repository that hold some.
func noSnapshot(l *backup.RestoreList, name, target string) error {
	e := cli.Fail("restore: repository %s holds no snapshot of %s's backups at %s — nothing was changed", l.Repo, name, orNone(l.Looked, "no path"))
	if len(l.Elsewhere) == 0 {
		return e.Cont("a snapshot is taken nightly, and by `kasbah backup " + target + "`.")
	}
	e.Cont("its snapshots hold backup tarballs at: " + strings.Join(l.Elsewhere, " "))
	return e.Cont("if one is " + name + "'s (another apps path, or a backups/ that was a symlink), `kasbah restore " + target +
		" --from-path=PATH` restores from it; keeping the apps path and re-creating the backups/ link avoids it (docs/backup.md → Restore).")
}

// restoreFailed is the failed restore's error: where it stopped, and what
// became of the data, .env and the stack.
func restoreFailed(kv map[string]string, target, dir, name, live string, data bool) error {
	var e *cli.Error
	switch {
	case kv["signal"] == "yes":
		e = cli.Fail("a signal stopped the restore on %s at its %s step (see above)", target, kv["step"])
	case kv["step"] == stepHook:
		e = cli.Fail("the restore hook failed on %s (see above)", target)
	case kv["step"] == stepExtract:
		e = cli.Fail("could not extract %s on %s (see above) — the restore hook did not run", name, target)
	case kv["step"] == stepUp || kv["step"] == stepHealth:
		e = cli.Fail("the stack did not come back up on the restored .env on %s (see above)", target)
	default:
		e = cli.Fail("the restore on %s failed at '%s' (see above)", target, kv["step"])
	}
	putBack := kv["env"] == "put-back"
	switch {
	case kv["data"] == "restored" && putBack && kv["stack"] != "down":
		e.Cont("the data is " + name + "'s: " + live + "'s restore hook replaced it, and it now runs under the server's previous .env.")
	case kv["data"] == "restored":
		e.Cont("the data is " + name + "'s: " + live + "'s restore hook replaced it.")
	case kv["data"] == "partial":
		e.Cont("what the restore hook did to the data is left as it is.")
	case data:
		e.Cont("the data was not touched.")
	}
	switch kv["env"] {
	case "put-back":
		e.Cont(dir + "/.env on " + target + " was put back as it was before this restore; the values from " + name + " are not live.")
	case "put-back-failed":
		e.Cont(dir+"/.env on "+target+" still holds the values restored from "+name+" — putting it back failed (see above).",
			"Fix it before the next deploy: `kasbah env set KEY` changes one key, or edit it on the server.")
	default:
		e.Cont(dir + "/.env on " + target + " was not changed.")
	}
	project := filepath.Base(dir)
	switch kv["stack"] {
	case "up":
		e.Cont("the stack was brought up on it again (see above).")
	case "down":
		e.Cont("bringing the stack up on it again failed too, so it may be down: once the cause is fixed, `docker compose -p " + project + " up -d` in " + dir + " on " + target + " brings it up.")
	case "as-left":
		e.Cont("the stack is as the failed recreate left it: once .env is fixed, `docker compose -p " + project + " up -d` in " + dir + " on " + target + " brings it up on it.")
	}
	return e
}

func printList(o *cli.Output, target, name string, f *RestoreFacts) {
	l := f.List
	w := o.Stdout
	if len(l.Snapshots) == 0 {
		fmt.Fprintf(w, "Repository %s holds no snapshot of %s's backups at %s.\n", l.Repo, name, orNone(l.Looked, "no path"))
		if len(l.Elsewhere) > 0 {
			fmt.Fprintf(w, "Its snapshots hold backup tarballs at: %s (--from-path= chooses one).\n", strings.Join(l.Elsewhere, " "))
		}
		return
	}
	fmt.Fprintf(w, "Snapshots of %s's backups in repository %s, oldest first:\n", name, l.Repo)
	for _, sn := range l.Snapshots {
		mark := ""
		if sn.ID == l.Snapshot {
			mark = "  (listed below)"
		}
		fmt.Fprintf(w, "  %s  %s%s\n", sn.ID, sn.Time, mark)
	}
	var names []string
	for _, b := range l.Backups {
		names = append(names, b.Name)
	}
	newest := newestBackup(names, f.Live)
	fmt.Fprintf(w, "Backups in snapshot %s (%s):\n", l.Snapshot, l.Path)
	if len(l.Backups) == 0 {
		fmt.Fprintln(w, "  none")
	}
	for _, b := range l.Backups {
		var notes []string
		if b.Name == newest {
			notes = append(notes, "the default: newest of the live version "+f.Live)
		}
		if slices.Contains(f.Local, b.Name) {
			notes = append(notes, "already on "+target)
		}
		note := ""
		if len(notes) > 0 {
			note = "  (" + strings.Join(notes, "; ") + ")"
		}
		fmt.Fprintf(w, "  %s  %d bytes%s\n", b.Name, b.Size, note)
	}
	if f.Live == "" {
		fmt.Fprintf(w, "%s has no live version on %s: deploy first, then restore.\n", name, target)
	}
}

func orNone(l []string, none string) string {
	if len(l) == 0 {
		return none
	}
	return strings.Join(l, " ")
}

func snapTime(l *backup.RestoreList) string {
	for _, s := range l.Snapshots {
		if s.ID == l.Snapshot {
			return s.Time
		}
	}
	return "?"
}

// RestoreList reads through the scheduler container; restic in it is bounded
// there.
func (s *SSH) RestoreList(apps, name, snapshot, from string) (*RestoreFacts, error) {
	args := []string{s.Bin(), "remote", "deploy", "restore-list", apps, name}
	if snapshot != "" {
		args = append(args, snapshot)
	}
	if from != "" {
		args = append(args, "--from-path="+from)
	}
	out, err := s.Conn.Run(args...)
	if err != nil {
		return nil, cli.Fail("could not list %s's off-box backups on %s (%s, see above) — nothing was changed", name, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	var f RestoreFacts
	if err := remote.Decode(out, &f, []string{"state", "live", "hooks", "restore_hook", "local"}, "the restore listing", s.target()); err != nil {
		return nil, err
	}
	return &f, nil
}

// FetchBackup is unbounded, as a tarball's size is.
func (s *SSH) FetchBackup(dir, snapshot, name, from string) (string, error) {
	args := []string{s.Bin(), "remote", "deploy", "fetch", dir, snapshot, name}
	if from != "" {
		args = append(args, "--from-path="+from)
	}
	out, err := s.Conn.Run(args...)
	if err != nil {
		return "", cli.Fail("could not fetch %s from snapshot %s into %s/%s on %s (%s, see above) — nothing was changed", name, snapshot, dir, Backups, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	kv := lines(out)
	if kv["fetch"] != "fetched" && kv["fetch"] != "present" {
		return "", rawOutput(cli.Fail("the fetch step on %s reported no fetch", s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return kv["fetch"], nil
}

// ProbeNamed is BackupProbe of one named backup.
func (s *SSH) ProbeNamed(dir, name string) (*BackupFacts, error) {
	out, err := s.Conn.Run(s.Bin(), "remote", "deploy", "backup-probe", dir, "--backup", name)
	if err != nil {
		return nil, cli.Fail("could not read %s/%s/%s on %s (%s, see above)", dir, Backups, name, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	var f BackupFacts
	if err := remote.Decode(out, &f, []string{"backup", "env", "changed", "only_backup", "only_live"}, "the backup probe", s.target()); err != nil {
		return nil, err
	}
	return &f, nil
}

// Restore is unbounded, as the restore hook is. Key names travel, never a
// value: the server reads the values out of the backup.
func (s *SSH) Restore(dir, name, live string, envRestore bool, keys []string, data bool) (map[string]string, error) {
	args := []string{s.Bin(), "remote", "deploy", "restore", dir, name, live}
	switch {
	case envRestore && keys == nil:
		args = append(args, "--env=all")
	case envRestore:
		args = append(args, "--env="+strings.Join(keys, ","))
	}
	if data {
		args = append(args, "--data")
	}
	out, err := s.Conn.Run(args...)
	kv := lines(out)
	if kv["restore"] == "" {
		if err != nil {
			return nil, cli.Fail("could not restore %s on %s (%s, see above)", dir, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
		}
		return nil, rawOutput(cli.Fail("the restore step on %s reported no outcome", s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return kv, nil
}
