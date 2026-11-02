package deploy

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/treesync"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// SSH is the Server a real run uses: env's session, one master, and the
// server's own kasbah answering `kasbah remote deploy`.
type SSH struct{ *env.SSH }

// DialSSH connects; the binary is ensured by Marker.
func DialSSH(self remote.Info, local func(arch string) (string, error)) func(string) (Server, error) {
	return func(target string) (Server, error) {
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

func (s *SSH) target() string { return s.Conn.Target.String() }

func lines(out []byte) map[string]string { return remote.KV(out) }

func rawOutput(e *cli.Error, out []byte) *cli.Error {
	for _, l := range strings.Split(strings.TrimRight(strings.ReplaceAll(string(out), "\r", ""), "\n"), "\n") {
		e.Cont("| " + l)
	}
	return e
}

func (s *SSH) PrepareProject(apps, data, name, client string, parents []string) (string, error) {
	args := append([]string{"deploy", "prepare", apps, data, name, client}, parents...)
	out, err := s.Conn.Run(s.Bounded(args...)...)
	if err != nil {
		return "", cli.Fail("could not prepare %s/%s on %s (%s, see above)", apps, name, s.target(), serverbin.ExitText(ssh.ExitCode(err), serverbin.RunTimeout))
	}
	return parsePrepare(out, s.target())
}

// parsePrepare reads prepare's report as a protocol: a key that never
// arrived is a failed step, never an empty value.
func parsePrepare(out []byte, target string) (string, error) {
	kv := lines(out)
	if kv["prepared"] != "yes" || kv["client"] == "" {
		return "", rawOutput(cli.Fail("the prepare step on %s reported no prepared or client", target).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return kv["client"], nil
}

// Sync is one sync: entry, as `rsync -rlpt src/ dst/` or `rsync -lpt src dst`
// shipped it (internal/treesync).
func (s *SSH) Sync(e Entry, base string) error {
	src, from, to := (*treesync.Source)(nil), e.Src, base+"/"+e.Dst
	var err error
	if e.Recurse {
		from, to = from+"/", to+"/"
		src, err = treesync.Dir(e.Src, os.Stderr)
	} else {
		src, err = treesync.File(e.Src, os.Stderr)
	}
	if err == nil {
		err = treesync.Push(s.Conn, s.Bin(), src, base+"/"+e.Dst)
	}
	if err != nil {
		return cli.Fail("could not sync %s to %s:%s", from, s.target(), to).Cont(err.Error())
	}
	return nil
}

// Snapshot is unbounded, as the engine is: it copies the sync targets, and
// those have no size limit.
func (s *SSH) Snapshot(dir, token string, targets []string) error {
	out, err := s.Conn.Run(append([]string{s.Bin(), "remote", "deploy", "snapshot", dir, token}, targets...)...)
	if err != nil {
		return cli.Fail("could not copy aside the files this run replaces in %s on %s (%s, see above) — nothing was changed", dir, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	return parseSnapshot(out, s.target())
}

func parseSnapshot(out []byte, target string) error {
	if v := lines(out)["snapshot"]; v != "written" && v != "none" {
		return rawOutput(cli.Fail("the snapshot step on %s reported no snapshot", target).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return nil
}

func (s *SSH) Mail(apps string) (*MailFacts, error) {
	dir := apps + "/mail"
	out, err := s.Conn.Run(s.Bounded("deploy", "mail", apps)...)
	if err != nil {
		return nil, cli.Fail("could not look for the mail stack at %s on %s (%s, see above)", dir, s.target(), serverbin.ExitText(ssh.ExitCode(err), serverbin.RunTimeout))
	}
	return parseMailFacts(out, s.target())
}

// parseMailFacts requires every key: a missing one must not read as "no".
func parseMailFacts(out []byte, target string) (*MailFacts, error) {
	var f MailFacts
	if err := remote.Decode(out, &f, []string{"stack", "env", "registry", "registry_b64", "dms"},
		"the mail claim step", target); err != nil {
		return nil, err
	}
	return &f, nil
}

// Run is the engine, free of the 30 s limit: hooks, backups and `compose up`
// have no bound kasbah sets. Stdin stays open after the Spec line for the
// answer to the engine's question, unless --on-hook-failure= gave it.
func (s *SSH) Run(dir string, sp Spec, ask func(Question) string) (string, int) {
	spec, _ := json.Marshal(sp)
	cmd := s.Conn.Command(s.Bin(), "remote", "deploy", "run", dir)
	in, err := cmd.StdinPipe()
	if err != nil {
		return "", -1
	}
	outp, err := cmd.StdoutPipe()
	if err != nil {
		return "", -1
	}
	if err := cmd.Start(); err != nil {
		return "", -1
	}
	in.Write(append(spec, '\n'))
	if sp.OnHookFailure != "" {
		in.Close()
	}
	out := Converse(outp, in, ask)
	return out, ssh.ExitCode(cmd.Wait())
}

// Fragment is a temp file renamed over dest, never written in place: Traefik's
// watcher must see one atomic replace. Mode 644 whatever the source's.
func (s *SSH) Fragment(local, dest string) error {
	src, err := treesync.Fixed(local, 0o644)
	if err != nil {
		return err
	}
	return treesync.Push(s.Conn, s.Bin(), src, dest)
}

func (s *SSH) Images(version string, images []string) (int, []string, error) {
	out, err := s.Conn.Run(s.Bounded(append([]string{"deploy", "images", version}, images...)...)...)
	if err != nil {
		return 0, nil, cli.Fail("could not look for the %s images on %s (%s, see above)", version, s.target(), serverbin.ExitText(ssh.ExitCode(err), serverbin.RunTimeout))
	}
	kv := lines(out)
	c, ok := kv["checked"]
	if _, has := kv["missing"]; !ok || !has {
		return 0, nil, rawOutput(cli.Fail("the image check on %s reported no checked or missing", s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	n, err := strconv.Atoi(c)
	if err != nil {
		n = -1
	}
	var missing []string
	if kv["missing"] != "" {
		missing = strings.Split(kv["missing"], ",")
	}
	return n, missing, nil
}

func (s *SSH) Record(apps, name string) (*vlog.Record, error) { return FetchRecord(s.SSH, apps, name) }

// FetchRecord is `kasbah remote vlog`: both halves of the deploy record in
// one round trip, judged by vlog.ReadProbe.
func FetchRecord(s *env.SSH, apps, name string) (*vlog.Record, error) {
	path := apps + "/" + name + "/" + vlog.Log
	out, err := s.Conn.Run(s.Bounded("vlog", apps, name)...)
	if err != nil {
		return nil, cli.Fail("could not read %s on %s (%s, see above)", path, s.Conn.Target.String(), serverbin.ExitText(ssh.ExitCode(err), serverbin.RunTimeout))
	}
	return vlog.ReadProbe(out, s.Conn.Target.String(), path)
}

// BackupProbe is unbounded, as the snapshot is: it reads through a backup
// tarball whose size kasbah does not set. Only key names come back.
func (s *SSH) BackupProbe(dir, version string) (*BackupFacts, error) {
	out, err := s.Conn.Run(s.Bin(), "remote", "deploy", "backup-probe", dir, version)
	if err != nil {
		return nil, cli.Fail("could not look for a backup of %s in %s/%s on %s (%s, see above) — nothing was changed", version, dir, Backups, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	var f BackupFacts
	if err := remote.Decode(out, &f, []string{"backup", "env", "changed", "only_backup", "only_live"}, "the backup probe", s.target()); err != nil {
		return nil, err
	}
	return &f, nil
}

// RestoreEnv names keys on argv, never a value: the server reads the values
// out of the backup itself.
func (s *SSH) RestoreEnv(dir, backup string, keys []string) error {
	args := []string{s.Bin(), "remote", "deploy", "restore-env", dir, backup}
	if keys == nil {
		args = append(args, "--all")
	}
	out, err := s.Conn.Run(append(args, keys...)...)
	if err != nil {
		return cli.Fail("could not write %s/.env on %s from the backup %s (%s, see above)", dir, s.target(), backup, serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	if lines(out)["env"] != "restored" {
		return rawOutput(cli.Fail("the .env restore on %s reported no env", s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return nil
}

// UndoEnv puts the server's .env back from the snapshot of token's run; saved
// is where the .env it replaced is kept, "" when it was the snapshot's.
func (s *SSH) UndoEnv(dir, token string) (string, error) {
	out, err := s.Conn.Run(s.Bin(), "remote", "deploy", "restore-env", dir, "--undo", token)
	if err != nil {
		return "", cli.Fail("could not put %s/.env back on %s (%s, see above)", dir, s.target(), serverbin.ExitText(ssh.ExitCode(err), 0))
	}
	l := lines(out)
	if l["env"] != "put-back" {
		return "", rawOutput(cli.Fail("putting %s/.env back on %s reported nothing", dir, s.target()).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return l["saved"], nil
}
