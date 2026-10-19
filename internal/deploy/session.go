package deploy

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// SSH is the Server a real run uses: env's session, one master, and the
// server's own kasbah answering `kasbah remote deploy`.
type SSH struct{ *env.SSH }

// DialSSH connects; the binary is ensured by Marker.
func DialSSH(self remote.Info, local func(arch string) (string, error)) func(string) (Server, error) {
	return func(target string) (Server, error) {
		if _, err := exec.LookPath("rsync"); err != nil {
			return nil, cli.Fail("rsync is required (install rsync and retry)")
		}
		c, err := ssh.Connect(target)
		if err != nil {
			return nil, err
		}
		return &SSH{&env.SSH{Conn: c, Self: self, Local: local}}, nil
	}
}

func (s *SSH) target() string { return s.Conn.Target.String() }

func lines(out []byte) map[string]string {
	kv := map[string]string{}
	for _, l := range strings.Split(strings.ReplaceAll(string(out), "\r", ""), "\n") {
		if k, v, ok := strings.Cut(l, "="); ok {
			kv[k] = v
		}
	}
	return kv
}

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
		return "", cli.Fail("could not prepare %s/%s on %s (the remote step exited %d, see above)", apps, name, s.target(), ssh.ExitCode(err))
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

// Sync is one sync: entry; -s so the far side never re-splits a path.
func (s *SSH) Sync(e Entry, base string) error {
	var cmd *exec.Cmd
	if e.Recurse {
		cmd = s.Conn.Rsync("-rlpt", "-s", e.Src+"/", s.target()+":"+base+"/"+e.Dst+"/")
	} else {
		cmd = s.Conn.Rsync("-lpt", "-s", e.Src, s.target()+":"+base+"/"+e.Dst)
	}
	cmd.Stdout, cmd.Stderr = io.Discard, os.Stderr
	if cmd.Run() != nil {
		if e.Recurse {
			return cli.Fail("could not sync %s/ to %s:%s/%s/", e.Src, s.target(), base, e.Dst)
		}
		return cli.Fail("could not sync %s to %s:%s/%s", e.Src, s.target(), base, e.Dst)
	}
	return nil
}

func (s *SSH) Mail(apps string) (*MailFacts, error) {
	dir := apps + "/mail"
	out, err := s.Conn.Run(s.Bounded("deploy", "mail", apps)...)
	if err != nil {
		return nil, cli.Fail("could not look for the mail stack at %s on %s (the remote step exited %d, see above)", dir, s.target(), ssh.ExitCode(err))
	}
	return parseMailFacts(out, s.target())
}

// parseMailFacts requires every key: a missing one must not read as "no".
func parseMailFacts(out []byte, target string) (*MailFacts, error) {
	var f MailFacts
	var m map[string]json.RawMessage
	bad := json.Unmarshal(bytes.TrimSpace(out), &m) != nil
	for _, k := range []string{"stack", "env", "registry", "registry_b64", "dms", "snappymail"} {
		bad = bad || m[k] == nil
	}
	if bad || json.Unmarshal(bytes.TrimSpace(out), &f) != nil {
		return nil, rawOutput(cli.Fail("the mail claim step on %s reported no mail facts", target).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:"), out)
	}
	return &f, nil
}

func (s *SSH) Seed(target string, data []byte) (string, error) {
	size, sum := remote.Digest(data)
	cmd := s.Conn.Command(s.Bounded("deploy", "seed", "mail-snappymail", target, size, sum)...)
	cmd.Stdin = bytes.NewReader(data)
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return "", err
	}
	return lines(out.Bytes())["mail_seed"], nil
}

// Run is the engine, unbounded by the 30 s limit: the health wait is bounded
// by health.timeout on the server, a dead link by ssh's keepalives, and hooks,
// backups and `compose up` by nothing kasbah sets.
func (s *SSH) Run(dir string, sp Spec) (string, int) {
	spec, _ := json.Marshal(sp)
	cmd := s.Conn.Command(s.Bin(), "remote", "deploy", "run", dir)
	cmd.Stdin = bytes.NewReader(spec)
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	return out.String(), ssh.ExitCode(err)
}

// Fragment is rsync's temp-then-rename, never --inplace: Traefik's watcher
// must see one atomic replace.
func (s *SSH) Fragment(local, dest string) error {
	cmd := s.Conn.Rsync("-pt", "--chmod=F644", "-s", local, s.target()+":"+dest)
	cmd.Stdout, cmd.Stderr = io.Discard, os.Stderr
	return cmd.Run()
}

func (s *SSH) Images(version string, images []string) (int, []string, error) {
	out, err := s.Conn.Run(s.Bounded(append([]string{"deploy", "images", version}, images...)...)...)
	if err != nil {
		return 0, nil, cli.Fail("could not look for the %s images on %s (the remote step exited %d, see above)", version, s.target(), ssh.ExitCode(err))
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
		return nil, cli.Fail("could not read %s on %s (the remote step exited %d, see above)", path, s.Conn.Target.String(), ssh.ExitCode(err))
	}
	return vlog.ReadProbe(out, s.Conn.Target.String(), path)
}
