package deploy

import (
	"archive/tar"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/release"
	"github.com/adigourdi/kasbah/internal/serverbin"
	"github.com/adigourdi/kasbah/internal/state"
	"github.com/adigourdi/kasbah/internal/version"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// The tagged path ships everything from the v<target> ref, never HEAD, through
// a deploy's own sync: `git archive | tar -x` cannot honour sync renames.

const rollbackUsage = `Usage: kasbah rollback [USER@HOST] [VERSION] [--on-drift=setup|continue|abort]
                       [--env-seed=FILE] [--on-hook-failure=continue|stop]
                       [--with-env|--no-env] [--with-data|--no-data] [--skip-hooks]
                       [--no-health-wait]

Puts a server back on a version it has already run. Run from the project root.
An argument containing '@' is the server, anything else is the version.

VERSION defaults to the clean deploy before the running one in the server's
versions.log (the archive included); a deploy-failed entry can be the running
one, never the target. USER@HOST defaults to the last server this project
deployed to (.kasbah/state.json).

Everything shipped comes from the v<VERSION> git tag, never from the working
tree, which is neither read nor touched:
  * <VERSION>'s own manifest decides what is synced, and its compose file which
    images are retagged — a service HEAD builds and <VERSION> did not is not
    part of this rollback
  * each of those images must still be on the server as :<VERSION>; kasbah
    never re-ships one (docs/build-deploy.md → Retention)
  * <VERSION>'s newest backup on the server, backups/<VERSION>-<stamp>.tar.gz,
    when there is one: the names of the keys its .env and the server's
    disagree on are listed (never a value), and the rollback asks whether to
    restore that .env, keep the server's, or decide per key; and, when
    <VERSION>'s kasbah.yml has a restore hook, whether to restore the data
    with it — which replaces everything written since that backup
  * the chosen .env written on the server, then the env drift check
  * ` + "`kasbah remote deploy`" + ` on the server: the backup extracted for the hooks
    ($KASBAH_BACKUP_DIR), pre-rollback hooks, the restore hook when the
    answer was yes, retag <image>:current, docker compose -p <name> up -d
    --remove-orphans, health wait, post-rollback hooks, one versions.log
    entry — a failed pre-rollback or restore hook asks whether to carry on,
    and a failed up or health wait is put back, as a deploy's are (kasbah
    deploy --help); .env goes back with the files, the data does not. Once
    <VERSION> is up, the copies of what the run overwrote become the
    outgoing version's backup, backups/<outgoing version>-<stamp>.tar.gz
  * <VERSION>'s traefik-dynamic.yml, last, once the stack is up

Without a backup of <VERSION>, .env and data are left as they are (drift is
prompted for as usual); anything provisioned outside this project never is.

Flags:
  --on-drift=setup      re-run the interactive setup when .env has drifted
  --on-drift=continue   roll back against the .env as it stands
  --on-drift=abort      stop, changing nothing
Unset, a drifting .env asks; with no terminal to ask on, the run stops (exit 5).

  --env-seed=FILE       answer the keys .env lacks from FILE's KEY=value lines
                        (mode 600 or tighter), as deploy does (kasbah deploy --help)

  --with-env            restore the backup's .env whole
  --no-env              keep the server's .env
Unset, differing keys ask: restore, keep, or one question per key.
  --with-data           run <VERSION>'s restore hook on the backup — refused,
                        changing nothing, when there is no backup or no hook
  --no-data             leave the data as it is
Unset, a backup and a restore hook ask. With no terminal to ask on, an
unanswered question fails before anything changes, naming its flags.

For the server's side of the run:
  --on-hook-failure=continue
                        when the extraction, a pre-rollback or the restore
                        hook fails, carry on as if it had passed
  --on-hook-failure=stop
                        when one fails, put back the files and .env, and stop;
                        what the hooks already did to the data stays
Unset, such a failure asks; with no terminal to ask on, the run stops, and
fails naming the flag.

  --skip-hooks          skip the pre- and post-rollback hooks; the restore
                        hook still runs
  --no-health-wait      bring the stack up without blocking on its health

See docs/build-deploy.md.
`

// RollbackUsage is `kasbah rollback --help`.
func RollbackUsage() string { return rollbackUsage }

// tagged is the extraction and what was read out of it.
type tagged struct {
	extract  string
	hasFrag  bool
	fragName string
	pop      func()
}

// cleanup removes the extraction; a signal reaches it through atexit.
func (t *tagged) cleanup() {
	if t.pop != nil {
		t.pop()
	}
	if t.extract != "" {
		os.RemoveAll(t.extract)
	}
}

// RunTagged is a rollback (mode "rollback", Version optional) or a deploy of
// a named version (mode "deploy").
func RunTagged(c Ctx, o Options, mode string) error {
	if _, err := exec.LookPath("git"); err != nil {
		return cli.Fail("git is required — every file a %s of a tagged version ships comes out of the tag", mode)
	}
	m, err := manifest.Require(manifest.File, c.Version)
	if err != nil {
		return err
	}
	if exec.Command("git", "rev-parse", "--git-dir").Run() != nil {
		return cli.Fail("%s is not a git repository — the version to %s comes from a git tag", c.PWD, mode)
	}
	r := &run{c: c, o: o, m: m, target: o.Target, version: o.Version, mode: mode, tagged: true}
	if r.target, _, err = state.Server(o.Target, mode, "kasbah "+mode+" user@vps"); err != nil {
		return err
	}
	if r.seed, err = env.ReadSeed(c.Out, mode, o.EnvSeed); err != nil {
		return err
	}
	t := &tagged{}
	defer t.cleanup()

	// A named deploy is judged against this checkout before any connection; a
	// rollback asks the record first — "never deployed here" is the more
	// useful answer when the tag is missing too.
	if mode == "deploy" {
		if err := r.readRef(t); err != nil {
			return err
		}
	}
	if r.s, err = c.Dial(r.target); err != nil {
		return err
	}
	closeSession := sync.OnceFunc(r.s.Close)
	defer closeSession()
	if r.mk, err = r.s.Marker(); err != nil {
		return err
	}
	hold, err := r.s.HoldServer(r.mk.AppsPath, mode)
	if err != nil {
		return err
	}
	unlock := sync.OnceFunc(hold)
	defer unlock()
	r.dir = r.mk.AppsPath + "/" + m.Name

	var rec *vlog.Record
	if mode == "rollback" {
		if rec, err = r.s.Record(r.mk.AppsPath, m.Name); err != nil {
			return err
		}
		for _, w := range rec.Warnings {
			c.Out.Warn("%s", w)
		}
		if r.version == "" {
			if err := r.implicitTarget(rec); err != nil {
				return err
			}
		}
		if err := r.requireDeployed(rec); err != nil {
			return err
		}
	}
	if t.extract == "" {
		if err := r.readRef(t); err != nil {
			return err
		}
	}
	if err := r.checkImages(); err != nil {
		return err
	}
	if mode == "rollback" {
		if err := r.restoreChoices(); err != nil {
			return err
		}
	}

	if r.lim, err = env.Resolve(c.Out, r.s, r.target, r.p.Resources, r.mk, mode == "rollback"); err != nil {
		return err
	}

	claim, err := r.readClaim()
	if err != nil {
		return err
	}
	clientState, err := r.ship()
	if err != nil {
		return err
	}
	if err := r.restoreEnv(); err != nil {
		return err
	}
	st := &env.Step{Out: c.Out, Prompter: c.Prompter, S: r.s, Target: r.target, TTYIn: c.TTYIn, TTYOut: c.TTYOut, Color: c.Color, Seed: r.seed}
	if err := st.Run(r.dir, r.lim.CPU, r.lim.Mem, o.OnDrift, false); err != nil {
		return r.envBack(err)
	}
	if claim != nil {
		r.mailClaim(claim)
	}
	// From here the engine's revert puts .env back; an engine that stops
	// without a failure record leaves it to engineFailed.
	r.envHeld()
	r.route = func() (bool, error) {
		if t.hasFrag {
			return r.fragment()
		}
		dest := r.mk.AppsPath + "/traefik/dynamic/" + m.Name + ".yml"
		c.Out.Warn("v%s carries no %s — nothing was written to %s", r.version, t.fragName, dest)
		c.Out.Warn("whatever is there now is left as it is: removing a route is `kasbah drop`'s decision")
		return false, nil
	}
	rep, err := r.remote()
	if err != nil {
		return err
	}
	shipped, err := r.route()
	if err != nil {
		return err
	}
	if err := state.Record(state.File, c.Version,
		"last_server", r.target,
		"last_deploy", c.Now().UTC().Format("2006-01-02T15:04:05Z"),
		"last_version", r.version); err != nil {
		return err
	}
	// Origin is asked with the server let go: a slow origin must not hold the
	// server lock.
	unlock()
	closeSession()
	unpublished := release.Unpublished(c.Out, r.version)
	if mode == "rollback" {
		r.banner("Rolled "+m.Name+" back to "+r.version+" on "+r.target, rep, clientState, shipped)
	} else {
		r.banner("Deployed "+m.Name+" "+r.version+" to "+r.target, rep, clientState, shipped)
	}
	if unpublished != "" {
		c.Out.Info("  git:     %s", unpublished)
	}
	if mode == "rollback" {
		r.gaveUp(rep)
	} else {
		r.changelog(rep)
	}
	return nil
}

// implicitTarget is the second-latest deploy entry over both files.
func (r *run) implicitTarget(rec *vlog.Record) error {
	o, name := r.c.Out, r.m.Name
	idx, damaged := rec.PrevDeploy()
	if idx >= 0 {
		it := rec.Items[idx]
		r.version = it.Version
		o.Info("rolling back to %s — the latest clean `deploy` entry before the running one in %s's record (%s)", r.version, r.target, it.Time)
		if n := dirtyDeploys(rec.Items[idx+1 : latestDeploy(rec)]); n > 0 {
			o.Info("  stepped over %d --dirty deploy(s) after it — never a rollback target", n)
		}
		// A line a killed append left is still a deploy that ran: stepped
		// over, it makes the target one version too far back.
		if damaged > 0 {
			o.Warn("%s's record on %s has %d line(s) no version can be read", name, r.target, damaged)
			o.Warn("  out of — counted across %s and %s — and they were", rec.ActivePath, rec.ArchivePath)
			o.Warn("  stepped over to reach %s. A truncated write leaves exactly that, and the", r.version)
			o.Warn("  deploy it recorded is still a deploy that ran, so")
			o.Warn("  this target may be one version further back than it should be")
			o.Warn("  read both files before letting this rollback stand")
		}
		// Found in a half-read archive, a nearer deploy may be in what the
		// truncated member swallowed — the newest archived entries.
		if it.Archived {
			if n := rec.Note(); n != "" {
				o.Warn("%s", n)
				o.Warn("  and %s was read out of it, so a nearer deploy may be among the", r.version)
				o.Warn("  entries that could not be decoded")
			}
		}
		return nil
	}
	var e *cli.Error
	if damaged == 0 && rec.Whole() {
		e = cli.Fail("there is no earlier deploy of %s on %s to roll back to", name, r.target)
	} else {
		e = cli.Fail("there is no earlier deploy of %s on %s in what kasbah could read of its record", name, r.target)
	}
	if damaged > 0 {
		e.Cont(fmt.Sprintf("%d line(s) of that record could not be read, and any of them may be one", damaged))
	}
	if dirtyDeploys(rec.Items) > 0 {
		e.Cont("(--dirty builds in it are never a rollback target, and are not counted)")
	}
	arch, act := rec.Count()
	switch {
	case arch+act > 0 && arch > 0:
		e.Cont(rec.ActivePath+" and its archive hold entries, but not two `deploy` ones —",
			"a rollback needs a version this server ran before the one it runs now")
	case arch+act > 0:
		e.Cont(rec.ActivePath+" holds entries, but not two `deploy` ones —",
			"a rollback needs a version this server ran before the one it runs now")
	case rec.Whole():
		e.Cont(rec.ActivePath+" holds no entry for this project at all, so nothing was ever",
			"deployed here to go back to")
	default:
		// "Never deployed here" is a claim about both files, and one was
		// never read.
		e.Cont(rec.ActivePath+" holds no entry for this project, and",
			"whether its archive holds one cannot be told — this is not evidence that",
			r.target+" has never deployed it")
	}
	if n := rec.Note(); n != "" {
		e.Cont(n)
	}
	return e.Cont("name a version if you know one:  kasbah rollback " + r.target + " <X.Y.Z>")
}

// dirtyDeploys counts the readable --dirty deploy entries in items.
func dirtyDeploys(items []vlog.Item) int {
	n := 0
	for _, it := range items {
		if it.OK && it.Action == "deploy" && version.IsDirty(it.Version) {
			n++
		}
	}
	return n
}

// latestDeploy is the index of the record's latest deploy-like entry, the
// one PrevDeploy counts as running.
func latestDeploy(rec *vlog.Record) int {
	for i := len(rec.Items) - 1; i >= 0; i-- {
		if it := rec.Items[i]; it.DeployLike() {
			return i
		}
	}
	return len(rec.Items)
}

// requireDeployed: any entry naming the version counts, whatever its action.
// Absence is asserted only on a record read whole.
func (r *run) requireDeployed(rec *vlog.Record) error {
	idx, damaged := rec.FindVersion(r.version)
	if idx >= 0 {
		return nil
	}
	v, t := r.version, r.target
	if damaged > 0 || !rec.Whole() {
		e := cli.Fail("Version %s is not in what kasbah could read of this VPS's deploy record,", v).Cont(
			"and part of that record could not be read.")
		if damaged > 0 {
			e.Cont(fmt.Sprintf("%d line(s) of it could not be read: a truncated write leaves a line no version", damaged),
				"can be read out of, and any of them may be the one naming "+v+".")
		}
		if !rec.Whole() {
			e.Cont(rec.ArchivePath+" did not come back whole, and rotation moves the oldest entries",
				"into it — which is where an entry naming "+v+" would be by now.")
		}
		e.Cont("So this is not the same thing as never having deployed it here.",
			"Look at "+rec.ActivePath+" and "+rec.ArchivePath+" on "+t+". If "+v,
			"really has never run there, `kasbah deploy "+t+" "+v+"` is a",
			"first-time deploy.")
		if n := rec.Note(); n != "" {
			e.Cont(n)
		}
		return e
	}
	return cli.Fail("Version %s was never deployed to this VPS.", v).Cont(
		"Use `kasbah deploy "+t+" "+v+"` for a first-time deploy.",
		"(read from "+rec.ActivePath+" and its rotation archive on "+t+")")
}

// requireTag spends one announced `git fetch --tags` before giving up.
func (r *run) requireTag() error {
	ref := "v" + r.version
	have := func() bool {
		return exec.Command("git", "rev-parse", "-q", "--verify", "refs/tags/"+ref+"^{commit}").Run() == nil
	}
	if have() {
		return nil
	}
	r.c.Out.Warn("this checkout has no tag %s — fetching tags from the remote", ref)
	f := exec.Command("git", "fetch", "--tags")
	f.Stdout, f.Stderr = os.Stderr, os.Stderr
	if f.Run() == nil && have() {
		return nil
	}
	return cli.Fail("%s is not a tag in this repository, and `git fetch --tags` did not bring it", ref).Cont(
		r.target+" ran "+r.version+", so the tag exists somewhere — every file this",
		"run would ship comes out of it, and there is nothing to ship without it.",
		"fetch it from wherever that version was tagged, then retry.")
}

// refType is blob, tree or "" for a path at ref: `git ls-tree` exits 0 with
// no output for a path it does not have.
func refType(ref, path string) (string, error) {
	cmd := exec.Command("git", "ls-tree", ref, "--", path)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		return "", cli.Fail("could not read %s at %s (see git's error above)", path, ref)
	}
	f := strings.Fields(string(out))
	if len(f) < 2 {
		return "", nil
	}
	return f[1], nil
}

func showBlob(ref, path, dest string) error {
	if err := os.MkdirAll(filepath.Dir(dest), 0o777); err != nil {
		return cli.Fail("could not create %s", filepath.Dir(dest))
	}
	cmd := exec.Command("git", "show", ref+":"+path)
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil || os.WriteFile(dest, out, 0o666) != nil {
		return cli.Fail("could not read %s out of %s (see git's error above)", path, ref)
	}
	return nil
}

func extractBlob(ref, path, dest, what string) error {
	t, err := refType(ref, path)
	if err != nil {
		return err
	}
	switch t {
	case "blob":
	case "":
		return cli.Fail("%s has no %s — %s", ref, path, what)
	default:
		return cli.Fail("%s is a %s at %s, not a file", path, t, ref)
	}
	return showBlob(ref, path, dest)
}

// readRef is everything this run reads out of the checkout: the tag, then
// v<target>'s manifest, compose file, sync list, fragment and mail seed.
func (r *run) readRef(t *tagged) error {
	if err := r.requireTag(); err != nil {
		return err
	}
	ref := "v" + r.version
	tmp, err := os.MkdirTemp("", "kasbah-"+r.mode+".")
	if err != nil {
		return cli.Fail("could not create a temporary directory to extract %s into", ref)
	}
	t.extract = tmp
	t.pop = atexit.Push(func() { os.RemoveAll(tmp) })
	if err := extractBlob(ref, manifest.File, filepath.Join(tmp, manifest.File),
		"that version predates this project's kasbah metadata, so there is no sync: list to ship. Roll forward instead."); err != nil {
		return err
	}
	if err := extractBlob(ref, buildpush.Compose, filepath.Join(tmp, buildpush.Compose),
		"the images to retag are read from it (docs/build-deploy.md → the invariant)"); err != nil {
		return err
	}
	m, err := manifest.Require(filepath.Join(tmp, manifest.File), r.c.Version)
	if err != nil {
		return err
	}
	if m.Name != r.m.Name {
		return cli.Fail("this project is called %s today and was called %s at %s — the server's directory is <apps>/<name>, so kasbah cannot tell which of the two this run is about", r.m.Name, m.Name, ref)
	}
	sync, err := readSync(m)
	if err != nil {
		return err
	}
	var paths []string
	seen := map[string]bool{}
	for _, e := range sync {
		if !seen[e.Src] {
			seen[e.Src] = true
			paths = append(paths, e.Src)
		}
	}
	if err := checkRefPaths(ref, r.version, sync); err != nil {
		return err
	}
	if err := archive(ref, paths, tmp); err != nil {
		return err
	}
	if err := checkExtraction(ref, r.version, r.mode, paths, tmp); err != nil {
		return err
	}
	t.fragName = Fragment
	if ty, err := refType(ref, Fragment); err != nil {
		return err
	} else if ty == "blob" {
		if err := showBlob(ref, Fragment, filepath.Join(tmp, Fragment)); err != nil {
			return err
		}
		t.hasFrag = true
		r.frag = filepath.Join(tmp, Fragment)
	}

	// The checkout's own cwd-relative readers, pointed at the extraction.
	root, err := os.Getwd()
	if err != nil {
		return cli.Fail("cannot read the current directory: %v", err)
	}
	if err := os.Chdir(tmp); err != nil {
		return cli.Fail("could not enter %s", tmp)
	}
	p, perr := readPlan(m, tmp, r.version, true)
	if err := os.Chdir(root); err != nil {
		return cli.Fail("could not return to %s", root)
	}
	if perr != nil {
		return perr
	}
	for i := range p.Sync {
		p.Sync[i].Src = filepath.Join(tmp, p.Sync[i].Src)
	}
	if p.ClientNote != "" {
		r.c.Out.Warn("the manifest in this version says %s", p.ClientNote)
		r.c.Out.Warn("falling back to '%s', which is client:'s documented default — a", m.Name)
		r.c.Out.Warn("version tagged before kasbah checked this field still has to roll back")
	}
	switch {
	case p.ResourcesNote != "" && r.mode != "rollback":
		return cli.Fail("kasbah.yml in v%s: %s", r.version, p.ResourcesNote).Cont(
			"a version deployed by name is held to the same rules as a deploy of the working tree; only `kasbah rollback` takes the server's ceilings instead.")
	case p.ResourcesNote != "":
		r.c.Out.Warn("the manifest in this version says %s — the server's ceilings stand instead", p.ResourcesNote)
	}
	for _, k := range p.HookNotes {
		r.c.Out.Warn("the manifest in this version has hooks.%s, which is not a hook kasbah runs — ignored", k)
	}
	r.p = p
	return nil
}

// checkRefPaths reports every sync: source the tag's tree lacks, before
// `git archive` dies at 128 on the first one; a type mismatch counts.
func checkRefPaths(ref, version string, sync []Entry) error {
	var rows []string
	seen := map[string]bool{}
	for _, e := range sync {
		if seen[e.Src] {
			continue
		}
		seen[e.Src] = true
		t, err := refType(ref, e.Src)
		if err != nil {
			return err
		}
		switch {
		case t == "":
			rows = append(rows, e.Src+" — no such path at "+ref)
		case e.Recurse && t != "tree":
			rows = append(rows, e.Src+"/ — listed with a trailing slash, which means a directory, and at "+ref+" it is a file")
		case !e.Recurse && t == "tree":
			rows = append(rows, e.Src+" — is a directory at "+ref+"; the entry needs a trailing slash to sync one")
		}
	}
	if len(rows) == 0 {
		return nil
	}
	return cli.Fail("%s's own kasbah.yml lists paths in sync: that are not in %s:", ref, ref).Cont(rows...).Cont(
		"that tag is internally inconsistent — its manifest names files it does not carry,",
		"so there is no complete copy of "+version+" to ship. Roll forward instead.")
}

// archive unpacks `git archive ref -- paths` into dir.
func archive(ref string, paths []string, dir string) error {
	fail := cli.Fail("could not extract %s's sync: list into %s (see the error above)", ref, dir)
	cmd := exec.Command("git", append([]string{"archive", "--format=tar", ref, "--"}, paths...)...)
	cmd.Stderr = os.Stderr
	pipe, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return fail
	}
	terr := untar(pipe, dir)
	io.Copy(io.Discard, pipe)
	if cmd.Wait() != nil || terr != nil {
		if terr != nil {
			fmt.Fprintf(os.Stderr, "%v\n", terr)
		}
		return fail
	}
	return nil
}

// untar keeps each entry's mtime, as tar -x did: the sync carries it on.
// Directories are stamped last, after their contents stop changing them.
func untar(rd io.Reader, dir string) error {
	tr := tar.NewReader(rd)
	type stamp struct {
		path string
		t    time.Time
	}
	var dirs []stamp
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			for i := len(dirs) - 1; i >= 0; i-- {
				os.Chtimes(dirs[i].path, dirs[i].t, dirs[i].t)
			}
			return nil
		}
		if err != nil {
			return err
		}
		name := filepath.Clean(h.Name)
		if filepath.IsAbs(name) || name == ".." || strings.HasPrefix(name, "../") {
			return fmt.Errorf("refusing archive member %q", h.Name)
		}
		dest := filepath.Join(dir, name)
		switch h.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(dest, 0o777); err != nil {
				return err
			}
			dirs = append(dirs, stamp{dest, h.ModTime})
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(dest), 0o777); err != nil {
				return err
			}
			f, err := os.OpenFile(dest, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, os.FileMode(h.Mode)&0o777)
			if err != nil {
				return err
			}
			_, cerr := io.Copy(f, tr)
			if err := f.Close(); cerr != nil || err != nil {
				return errors.Join(cerr, err)
			}
			if err := os.Chtimes(dest, h.ModTime, h.ModTime); err != nil {
				return err
			}
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(dest), 0o777); err != nil {
				return err
			}
			os.Remove(dest)
			if err := os.Symlink(h.Linkname, dest); err != nil {
				return err
			}
		}
	}
}

// checkExtraction holds the extraction against every blob the tree has under
// the sync: list: `.gitattributes export-ignore` separates what is in the
// tree from what `git archive` exports, and the extraction is what ships.
func checkExtraction(ref, version, mode string, paths []string, dir string) error {
	var missing []string
	for _, src := range paths {
		cmd := exec.Command("git", "ls-tree", "-r", "-z", "--name-only", ref, "--", src)
		cmd.Stderr = os.Stderr
		out, err := cmd.Output()
		if err != nil {
			return cli.Fail("could not list %s at %s (see git's error above)", src, ref)
		}
		for _, p := range strings.Split(string(out), "\x00") {
			if p == "" {
				continue
			}
			if _, err := os.Lstat(filepath.Join(dir, p)); err != nil {
				missing = append(missing, p+" — in the tag's tree, not in the archive")
			}
		}
	}
	if len(missing) == 0 {
		return nil
	}
	return cli.Fail("%s's sync: list did not come out of `git archive` whole:", ref).Cont(missing...).Cont(
		"`git ls-tree` finds those paths at "+ref+", so they are committed — something told",
		"`git archive` to leave them out, and export-ignore in .gitattributes is what does",
		"that. A "+mode+" ships what the archive produced, so it would put an",
		"incomplete "+version+" on the server.")
}

// checkImages: every image v<target> builds must still be on the server as
// :<target>; kasbah never re-ships one and calls it the original.
func (r *run) checkImages() error {
	imgs := r.p.Images
	if len(imgs) == 0 {
		return nil
	}
	checked, missing, err := r.s.Images(r.version, imgs)
	if err != nil {
		return err
	}
	if checked != len(imgs) {
		return cli.Fail("the image check on %s looked at %d of %s's %d built images, so its answer is about the wrong set", r.target, checked, r.m.Name, len(imgs))
	}
	if len(missing) == 0 {
		return nil
	}
	v, t := r.version, r.target
	// One error: line per image, the guidance under the last.
	var e *cli.Error
	add := func(first string, rest ...string) {
		if e != nil {
			r.c.Out.Err("%s", e.Lines[0])
			for _, l := range e.Lines[1:] {
				r.c.Out.ErrCont("%s", l)
			}
		}
		e = cli.Fail("%s", first).Cont(rest...)
	}
	// Only a rollback has proved the version is in the record, so only it
	// may call an absent image one retention let go.
	for _, img := range missing {
		if r.mode == "rollback" {
			add("Image "+img+":"+v+" is no longer on the VPS (outside the", "retention window).")
		} else {
			add("Image "+img+":"+v+" is not on "+t+" — either it was never built",
				"and shipped for this version, or it was and the retention window has let it go.",
				"A tagged deploy does not read the deploy record, so kasbah cannot tell which;",
				"`kasbah history "+t+" --all` is what answers it.")
		}
	}
	if r.mode == "rollback" {
		return e.Cont("Prefer deploying a fix forward. To force a rollback anyway, rebuild from the",
			"tag (NOT byte-identical to the original — compare versions.log digests):",
			"  git checkout v"+v+" && kasbah build-push "+t,
			"Then retry:",
			"  kasbah rollback "+t+" "+v)
	}
	return e.Cont("Nothing was deployed. Build that version and ship it first:",
		"  git checkout v"+v+" && kasbah build-push "+t,
		"Then retry:",
		"  kasbah deploy "+t+" "+v)
}

// gaveUp is a rollback's step 10: the range runs the other way, and the
// commits in it are what the rollback gave up.
func (r *run) gaveUp(rep *Report) {
	o, prev, v, t := r.c.Out, rep.PrevVersion, r.version, r.target
	if prev == "" {
		if rep.ArchiveOnly {
			o.Warn("%s has deployed %s before, but %s/versions.log held no entry — only", t, r.m.Name, r.dir)
			o.Warn("versions.log.gz does, so there is no record of the version this rollback")
			o.Warn("replaced and nothing to say what it gave up. The rollback itself is done.")
			return
		}
		if rep.DeployedBefore {
			o.Warn("%s has deployed %s before, but the last line of its", t, r.m.Name)
			o.Warn("versions.log is not one a version can be read out of — so there is nothing to")
			o.Warn("say what this rollback gave up. The rollback itself is done.")
			return
		}
		o.Warn("%s reports no history for %s, while %s was", t, r.m.Name, v)
		o.Warn("chosen because its record names it — the two disagree, and one of them was read")
		o.Warn("wrong. The rollback itself is done; look at %s/%s.", r.dir, vlog.Log)
		return
	}
	if prev == v {
		o.Info("  gave up: nothing — %s was already running %s", t, v)
		return
	}
	from, ok := asTag(o, prev)
	if !ok {
		return
	}
	rng := "v" + v + ".." + from
	if exec.Command("git", "rev-parse", "-q", "--verify", "refs/tags/"+from+"^{commit}").Run() != nil {
		o.Warn("%s was running %s, and this checkout has no tag %s — so there", t, prev, from)
		o.Warn("is no list of what the rollback gave up. `git fetch --tags`, then `git log %s`", rng)
		return
	}
	cmd := exec.Command("git", "log", "--no-color", "--format=%h %s", rng, "--")
	cmd.Stderr = os.Stderr
	out, err := cmd.Output()
	if err != nil {
		o.Warn("could not read `git log %s` (see git's error above) — no changelog", rng)
		return
	}
	log := strings.TrimRight(string(out), "\n")
	if log == "" {
		o.Info("  gave up: nothing — %s is empty, so %s carried no commit %s does not", rng, prev, v)
		return
	}
	o.Info("  gave up: %s — no longer deployed", rng)
	for _, l := range strings.Split(log, "\n") {
		if l != "" {
			fmt.Fprintf(o.Stderr, "    %s\n", l)
		}
	}
}

// restoreChoices settles what a rollback restores from its target's newest
// backup before anything on the server changes: a flag answers, else the
// terminal is asked, else the run fails naming the flags.
func (r *run) restoreChoices() error {
	f, err := r.s.BackupProbe(r.dir, r.version)
	if err != nil {
		return err
	}
	o, v, t := r.c.Out, r.version, r.target
	hook := len(r.p.Hooks["restore"]) > 0
	if r.o.Data == prompt.Yes && (f.Backup == "" || !hook) {
		var e *cli.Error
		switch {
		case f.Backup == "" && !hook:
			e = cli.Fail("rollback: --with-data, and there is nothing to restore it with: %s holds no backup of %s in %s/%s, and v%s's kasbah.yml has no restore hook", t, v, r.dir, Backups, v)
		case f.Backup == "":
			e = cli.Fail("rollback: --with-data, and %s holds no backup of %s in %s/%s to restore it from", t, v, r.dir, Backups)
		default:
			e = cli.Fail("rollback: --with-data, and v%s's kasbah.yml has no restore hook — kasbah restores no data itself", v)
		}
		return e.Cont("Nothing was changed. To roll back without restoring data, pass --no-data.")
	}
	if f.Backup == "" {
		o.Info("no backup of %s in %s/%s on %s — .env and data are left as they are", v, r.dir, Backups, t)
		if r.o.Env == prompt.Yes {
			o.Warn("--with-env: there is no backup of %s to restore .env from", v)
		}
		return nil
	}
	r.restoreFrom = f.Backup
	at := r.dir + "/" + Backups + "/" + f.Backup
	o.Info("the newest backup of %s on %s is %s", v, t, at)
	differ := len(f.Changed)+len(f.OnlyBackup)+len(f.OnlyLive) > 0
	switch {
	case f.Env == "unreadable":
		o.Warn("its .env could not be read (see above) — %s/.env is left as it is", r.dir)
	case f.Env != "yes" && r.o.Env == prompt.Yes:
		o.Warn("--with-env: %s holds no .env to restore — %s/.env is left as it is", f.Backup, r.dir)
	case f.Env != "yes":
		o.Info("  it holds no .env — %s/.env is left as it is", r.dir)
	case !differ:
		o.Info("  its .env and %s/.env agree on every key — nothing to restore", r.dir)
	default:
		o.Info("  its .env and %s/.env differ on these keys (names only):", r.dir)
		for _, l := range [][2]string{{"values differ:     ", strings.Join(f.Changed, " ")},
			{"only in the backup:", strings.Join(f.OnlyBackup, " ")}, {"only on the server:", strings.Join(f.OnlyLive, " ")}} {
			if l[1] != "" {
				o.Info("    %s %s", l[0], l[1])
			}
		}
	}
	envAsk := f.Env == "yes" && differ && r.o.Env == prompt.Unset
	dataAsk := hook && r.o.Data == prompt.Unset
	if (envAsk || dataAsk) && (r.c.Prompter == nil || !r.c.Prompter.TTY) {
		var flags []string
		if envAsk {
			flags = append(flags, "--with-env or --no-env")
		}
		if dataAsk {
			flags = append(flags, "--with-data or --no-data")
		}
		return cli.Fail("cannot ask what to restore from %s: stdin is not a terminal", at).Cont(
			"pass " + strings.Join(flags, ", and ") + ". Nothing was changed.")
	}
	if f.Env == "yes" && differ {
		if err := r.chooseEnv(f); err != nil {
			return err
		}
	}
	if !hook {
		o.Info("  v%s's kasbah.yml has no restore hook — data is left as it is", v)
		return nil
	}
	switch r.o.Data {
	case prompt.Yes:
		r.restoreData = true
	case prompt.Unset:
		yes, err := r.c.Prompter.Bool("data", "restore data from "+f.Backup+" with v"+v+"'s restore hook? It replaces everything written since that backup was taken", prompt.Unset)
		if err != nil {
			return err
		}
		r.restoreData = yes
	}
	if r.restoreData {
		o.Info("  data: restored by v%s's restore hook, before %s comes up — everything written since %s is replaced", v, v, f.Backup)
	} else {
		o.Info("  data: left as it is")
	}
	return nil
}

// chooseEnv is the .env answer: the backup's whole, the server's, or — on a
// terminal only — one answer per differing key.
func (r *run) chooseEnv(f *BackupFacts) error {
	o, v := r.c.Out, r.version
	switch r.o.Env {
	case prompt.Yes:
		r.envRestore = true
		o.Info("  .env: the backup's (--with-env)")
		return nil
	case prompt.No:
		o.Info("  .env: the server's, kept (--no-env)")
		return nil
	}
	p := r.c.Prompter
	stopped := cli.Fail("rollback stopped at the .env question — nothing was changed")
	// Select's own refusal would name a flag that does not exist.
	unanswered := cli.Fail("no answer to the .env question — pass --with-env or --no-env. Nothing was changed.")
	choice, ok, err := p.Select("env", "restore .env from "+v+"'s backup, keep the server's, or decide per key?",
		[]string{"restore", "keep", "per-key"},
		[]string{"restore — the backup's .env replaces the server's whole",
			"keep — the server's .env stays as it is",
			"per-key — one question per key that differs"}, "")
	if err != nil {
		return unanswered
	}
	if !ok {
		return stopped
	}
	switch choice {
	case "restore":
		r.envRestore = true
	case "per-key":
		labels := map[string][]string{}
		for _, k := range f.Changed {
			labels[k] = []string{"backup — the value it had in " + v + "'s backup", "server — the value it has now"}
		}
		for _, k := range f.OnlyBackup {
			labels[k] = []string{"backup — set it, as the backup does", "server — leave it unset, as it is now"}
		}
		for _, k := range f.OnlyLive {
			labels[k] = []string{"backup — remove it, as the backup has none", "server — keep it"}
		}
		keys := []string{}
		for _, k := range envtpl.SortUniq(append(append(append([]string{}, f.Changed...), f.OnlyBackup...), f.OnlyLive...)) {
			c, ok, err := p.Select("env", k+": the backup's or the server's?", []string{"backup", "server"}, labels[k], "")
			if err != nil {
				return unanswered
			}
			if !ok {
				return stopped
			}
			if c == "backup" {
				keys = append(keys, k)
			}
		}
		if len(keys) > 0 {
			r.envRestore, r.envKeys = true, keys
		}
	}
	switch {
	case !r.envRestore:
		o.Info("  .env: the server's, kept")
	case r.envKeys == nil:
		o.Info("  .env: the backup's")
	default:
		o.Info("  .env: the backup's values for %s", strings.Join(r.envKeys, " "))
	}
	return nil
}

// restoreEnv writes the chosen .env, after the snapshot holds the server's
// and before the env step reads it.
func (r *run) restoreEnv() error {
	if !r.envRestore {
		return nil
	}
	if err := r.s.RestoreEnv(r.dir, r.restoreFrom, r.envKeys); err != nil {
		var e *cli.Error
		if errors.As(err, &e) {
			return e.Cont("nothing was started: "+r.version+"'s files are on the server beside the running stack,",
				"and its snapshot is kept for the next run. Re-running `"+r.rerun()+"` is safe.")
		}
		return err
	}
	what := "the whole of it"
	if r.envKeys != nil {
		what = strings.Join(r.envKeys, " ")
	}
	r.c.Out.Info("%s/.env on %s restored from %s: %s", r.dir, r.target, r.restoreFrom, what)
	r.envLive = true
	r.envPop = atexit.Push(func() {
		for _, l := range r.putEnvBack() {
			r.c.Out.Warn("%s", l)
		}
	})
	return nil
}

// envHeld drops the signal cleanup putEnvBack runs from.
func (r *run) envHeld() {
	if r.envPop != nil {
		r.envPop()
		r.envPop = nil
	}
}

// envBack is err, a failure between restore-env and the engine, with the
// server's .env put back first and what became of it said.
func (r *run) envBack(err error) error {
	if r.envPop == nil {
		return err
	}
	r.envHeld()
	l := r.putEnvBack()
	var e *cli.Error
	if errors.As(err, &e) {
		return e.Cont(l...)
	}
	for _, x := range l {
		r.c.Out.Warn("%s", x)
	}
	return err
}

// putEnvBack puts the server's .env back from this run's snapshot, and says
// so — or, when it cannot, that the backup's values are live and the fix.
func (r *run) putEnvBack() []string {
	at := r.dir + "/.env"
	saved, err := r.s.UndoEnv(r.dir, r.snap)
	if err == nil {
		l := []string{at + " on " + r.target + " was put back as it was before this rollback; the values from " + r.restoreFrom + " are not live."}
		if saved != "" {
			l = append(l, "the .env it replaced is kept as "+saved+".")
		}
		return l
	}
	why := err.Error()
	if i := strings.IndexByte(why, '\n'); i >= 0 {
		why = why[:i]
	}
	return []string{
		at + " on " + r.target + " still holds the values restored from " + r.restoreFrom + " — putting it back failed:",
		"  " + why,
		"A plain deploy would run on them. Before any other deploy or rollback of " + r.m.Name + ", put it back with",
		"  ssh " + r.target + " " + serverbin.Path(r.mk.AppsPath) + " remote deploy restore-env " + r.dir + " --undo " + r.snap,
	}
}
