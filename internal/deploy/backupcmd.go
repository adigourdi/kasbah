package deploy

import (
	"strings"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/tree"
)

// BackupOptions is `kasbah backup`'s command line.
type BackupOptions struct{ Target string }

const backupUsage = `Usage: kasbah backup [USER@HOST]

Takes a backup of the version live on the server, outside any deploy, and
pushes it off the box when the server has off-box backups (` + "`kasbah server\ninit --with-backup`" + `). Run from the project root. USER@HOST defaults to the
last server this project deployed to (.kasbah/state.json).

What it does:
  * runs ` + "`kasbah remote deploy backup`" + ` on the server, under the project's
    deploy lock: copies the live .env and the files the live version's run
    synced into backups/<live version>-<stamp>/kasbah-snapshot/, runs the
    live version's backup hooks into that directory ($KASBAH_BACKUP_DIR),
    tars it into backups/<live version>-<stamp>.tar.gz and applies backup
    retention. A failed hook keeps nothing. versions.log is not written
  * with off-box backups on, backs up the restic repository this project
    files into now, through the kasbah-backup container; without them the
    backup stays on the server, and the run says so

See docs/backup.md and docs/build-deploy.md.
`

// BackupUsage is `kasbah backup --help`.
func BackupUsage() string { return backupUsage }

// ParseBackup reads backup's arguments.
func ParseBackup(args []string) (BackupOptions, error) {
	var o BackupOptions
	for _, a := range args {
		a = strings.TrimSuffix(a, "\r")
		switch {
		case a == "-h" || a == "--help":
			return o, ErrHelp
		case strings.HasPrefix(a, "-"):
			name, _, _ := strings.Cut(a, "=")
			return o, cli.Fail("backup: unknown flag '%s' (backup takes USER@HOST and nothing else)", name)
		case !strings.Contains(a, "@"):
			return o, cli.Fail("backup: '%s' is not a server — backup takes USER@HOST and nothing else", a)
		case o.Target != "":
			return o, cli.Fail("backup: two servers given ('%s' and '%s') — one run goes to one server", o.Target, a)
		default:
			o.Target = a
		}
	}
	return o, nil
}

// BackupServer is one server as `kasbah backup` needs it.
type BackupServer interface {
	// Marker ships this build's binary when the server's is absent or older.
	Marker() (*marker.Marker, error)
	HoldServer(apps, what string) (release func(), err error)
	// TakeBackup is `kasbah remote deploy backup`: the tarball's path under
	// the project directory, and the live version it holds.
	TakeBackup(dir string) (name, version string, err error)
	// Push is `kasbah remote backup push`: its report.
	Push(apps, name string) (map[string]string, error)
	Close()
}

// BackupCtx is what a backup needs from its process.
type BackupCtx struct {
	Out     *cli.Output
	Version string
	Dial    func(target string) (BackupServer, error)
}

// DialBackup is DialSSH as a BackupServer.
func DialBackup(self remote.Info, local func(arch string) (string, error)) func(string) (BackupServer, error) {
	dial := DialSSH(self, local)
	return func(target string) (BackupServer, error) {
		s, err := dial(target)
		if err != nil {
			return nil, err
		}
		return s.(*SSH), nil
	}
}

// RunBackup is `kasbah backup`.
func RunBackup(c BackupCtx, o BackupOptions) error {
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	target, _, err := state.Server(o.Target, "backup", "kasbah backup user@vps")
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
	release, err := s.HoldServer(mk.AppsPath, "backup")
	if err != nil {
		return err
	}
	defer release()
	dir := mk.AppsPath + "/" + m.Name
	name, live, err := s.TakeBackup(dir)
	if err != nil {
		return err
	}
	c.Out.Info("Backed up %s %s on %s", m.Name, live, target)
	c.Out.Info("  backup:  %s/%s", dir, name)
	record := func() error { return state.Record(state.File, c.Version, "last_server", target) }
	if en, _ := tree.Lookup(mk.JSON, "backup", "enabled"); en != true {
		c.Out.Info("  off-box: none — %s has no off-box backups, so this one stays on the server", target)
		c.Out.Info("           (kasbah server init %s --with-backup sets them up)", target)
		return record()
	}
	kv, err := s.Push(mk.AppsPath, m.Name)
	if err != nil {
		return err
	}
	kept := "the backup is kept on the server as " + dir + "/" + name
	switch kv["push"] {
	case "ok":
		c.Out.Info("  off-box: pushed through %s (its output above)", backup.Container)
	case "no-container":
		return cli.Fail("%s records off-box backups, and the %s container is %s there — nothing was pushed", target, backup.Container, kv["state"]).Cont(
			kept+".", "`kasbah server status "+target+"` shows the stack; `kasbah server init "+target+" --with-backup` reinstalls it")
	case "failed":
		return cli.Fail("the push through %s on %s failed (exit %s, its output above)", backup.Container, target, kv["rc"]).Cont(kept + ".")
	default:
		return cli.Fail("the push step on %s reported no push", target).Cont(kept + ".")
	}
	return record()
}

// TakeBackup is unbounded, as the engine is: the copies and the hooks have
// no bound kasbah sets.
func (s *SSH) TakeBackup(dir string) (string, string, error) {
	out, err := s.Conn.Run(s.Bin(), "remote", "deploy", "backup", dir)
	if err != nil {
		return "", "", cli.Fail("could not back up %s on %s (%s, see above)", dir, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	kv := lines(out)
	if kv["backup"] == "" || kv["version"] == "" {
		return "", "", rawOutput(cli.Fail("the backup step on %s reported no backup or version", s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return kv["backup"], kv["version"], nil
}

// Push is unbounded: each restic call in it is bounded by the scheduler.
func (s *SSH) Push(apps, name string) (map[string]string, error) {
	out, err := s.Conn.Run(s.Bin(), "remote", "backup", "push", apps, name)
	if err != nil {
		return nil, cli.Fail("could not push %s's backups from %s (%s, see above)", name, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	kv := lines(out)
	if kv["push"] == "" {
		return nil, rawOutput(cli.Fail("the push step on %s reported no push", s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return kv, nil
}
