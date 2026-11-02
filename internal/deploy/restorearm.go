package deploy

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/env"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// The steps of `deploy restore` a failure names, after something changed.
const (
	stepExtract = "extract"
	stepHook    = "hook"
	stepUp      = "up"
	stepHealth  = "health"
)

// restoreArm is `deploy restore DIR BACKUP LIVE [--env=all|--env=KEY,…]
// [--data]`, under .deploy.lock (see restore). stdout: restore=done env= data=
// recreated=; restore=refused; restore=failed step= env= data= stack= signal=.
func restoreArm(dir, name, live string, flags []string, stdout, stderr, raw io.Writer) int {
	e := &engine{dir: strings.TrimSuffix(dir, "/"), stderr: stderr, raw: raw, now: time.Now, sleep: time.Sleep, forward: true}
	return e.restoreArm(name, live, flags, stdout)
}

func (e *engine) restoreArm(name, live string, flags []string, stdout io.Writer) int {
	stderr := e.stderr
	var keys []string
	envSet, data := false, false
	for _, f := range flags {
		switch {
		case f == "--env=all" && !envSet:
			envSet = true
		case strings.HasPrefix(f, "--env=") && !envSet:
			envSet, keys = true, []string{}
			for _, k := range strings.Split(strings.TrimPrefix(f, "--env="), ",") {
				if !reEnvKey.MatchString(k) || strings.HasPrefix(k, "KASBAH_") {
					fmt.Fprintf(stderr, "remote: '%s' is not a key a restore writes — nothing was changed\n", k)
					fmt.Fprintln(stdout, "restore=refused")
					return 1
				}
				keys = append(keys, k)
			}
		case f == "--data":
			data = true
		default:
			fmt.Fprintln(stderr, "remote: usage: restore DIR BACKUP LIVE [--env=all|--env=KEY,…] [--data] — nothing was changed")
			fmt.Fprintln(stdout, "restore=refused")
			return 1
		}
	}
	res, err := e.restore(name, live, envSet, keys, data)
	for _, f := range []*os.File{e.lockFile, e.serverLock} {
		if f != nil {
			f.Close()
		}
	}
	if e.broot != nil {
		e.broot.Close()
	}
	if err != nil {
		fmt.Fprintf(stderr, "remote: %v\n", err)
	}
	code := 1
	if sig := int(e.stop.Load()); sig != 0 {
		code = sig
	}
	if res == nil {
		fmt.Fprintln(stdout, "restore=refused")
		return code
	}
	if res.step != "" {
		signal := "no"
		if res.signal {
			signal = "yes"
		}
		fmt.Fprintf(stdout, "restore=failed\nstep=%s\nenv=%s\ndata=%s\nstack=%s\nsignal=%s\n", res.step, res.env, res.data, res.stack, signal)
		return code
	}
	fmt.Fprintf(stdout, "restore=done\nenv=%s\ndata=%s\nrecreated=%s\n", res.env, res.data, res.recreated)
	return 0
}

// restoreResult is what a restore did, as its report's keys say (cli.md →
// kasbah restore, step 6); step is "" unless one failed.
type restoreResult struct {
	env, data, recreated, step string
	// stack, after a failure: untouched, up, down or as-left.
	stack string
	// signal: a held SIGINT or SIGTERM stopped the run.
	signal bool
}

// restore writes the backup's .env, loads its data with the live restore
// hook, and recreates the stack when .env changed; nil is a refusal. A first
// SIGINT or SIGTERM leaves through the failure path, .env put back.
func (e *engine) restore(name, live string, envSet bool, keys []string, data bool) (*restoreResult, error) {
	if e.dir == "" || !filepath.IsAbs(e.dir) {
		return nil, failf("the project directory must be an absolute path (got '%s') — nothing was changed", e.dir)
	}
	if fi, err := os.Stat(e.dir); err != nil || !fi.IsDir() {
		return nil, failf("%s is not a project directory on this server — nothing was changed", e.dir)
	}
	if !reBackup.MatchString(name) {
		return nil, failf("'%s' is not a backup's name — nothing was changed", name)
	}
	e.project = filepath.Base(e.dir)
	if err := e.lock(); err != nil {
		return nil, failf("%v — nothing was changed", err)
	}
	release := atexit.Hold(e.interrupt)
	defer release()
	b, err := os.ReadFile(filepath.Join(e.dir, vlog.Log))
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, failf("could not read %s/%s: %v — nothing was changed", e.dir, vlog.Log, err)
	}
	entries := vlog.Entries(strings.ReplaceAll(string(b), "\r", ""))
	if err := e.inFlight(entries, "restore"); err != nil {
		return nil, err
	}
	switch now := liveVersion(entries); {
	case now == "":
		return nil, failf("%s has no live version: %s/%s records no run that went live — deploy first, then restore. Nothing was changed", e.project, e.dir, vlog.Log)
	case now != live:
		return nil, failf("%s's live version is now %s, not %s: a deploy or rollback ran since the restore was planned. Nothing was changed; run kasbah restore again", e.project, now, live)
	}
	h, err := loadHooks(e.dir)
	if err != nil {
		return nil, err
	}
	if data && len(h.Restore) == 0 {
		return nil, failf("%s %s has no restore hook in %s, so there is nothing to load the data with — nothing was changed", e.project, live, HooksFile)
	}
	if err := e.openBackups(); err != nil {
		return nil, failf("%v — nothing was changed", err)
	}
	src := filepath.Join(e.dir, Backups, name)
	if fi, err := e.broot.Lstat(name); err != nil || !fi.Mode().IsRegular() {
		return nil, failf("%s is not a backup on this server — nothing was changed", src)
	}
	var old []byte
	if envSet {
		if old, err = backupEnv(e.broot, name); err != nil {
			return nil, failf("could not read %s: %v — nothing was changed", src, err)
		}
		if old == nil {
			return nil, failf("%s holds no %s, so there is no .env to restore — nothing was changed", src, snapEnv)
		}
	}
	e.clearRestores()
	health := Health{Timeout: 120}
	if h.Health != nil {
		health = *h.Health
	}
	if health.Timeout <= 0 {
		health.Timeout = 120
	}
	e.sp = Spec{Mode: "restore", Version: live, Restore: h.Restore, RestoreFrom: name, RestoreData: data, Health: health}
	defer e.dropRestore()

	if e.stop.Load() != 0 {
		return nil, failf("a signal arrived before the restore changed anything — nothing was changed")
	}
	res := &restoreResult{env: "kept", data: "kept", recreated: "no", stack: "untouched"}
	path := filepath.Join(e.dir, ".env")
	prev, perr := os.ReadFile(path)
	had := perr == nil
	if perr != nil && !errors.Is(perr, fs.ErrNotExist) {
		return nil, failf("could not read %s: %v — nothing was changed", path, perr)
	}
	// Once: a second signal's cleanup and the failure path never both write.
	var once sync.Once
	ok := false
	putBack := func(say func(string, ...any)) bool {
		once.Do(func() { ok = e.putEnvBack(prev, had, say) })
		return ok
	}
	changed, pop := false, func() {}
	if envSet {
		// Whole is every key that differs: the server's KASBAH_* block stays.
		if keys == nil {
			c, o, l := env.EnvDiff(prev, old)
			keys = append(append(append([]string{}, c...), o...), l...)
		}
		if len(keys) > 0 {
			pop = atexit.Push(func() { putBack(e.noteRaw) })
			defer pop()
			if err := env.RestoreEnvLocked(e.dir, old, keys); err != nil {
				return nil, failf("%v — nothing was changed", err)
			}
		}
		cur, cerr := os.ReadFile(path)
		changed = (cerr == nil) != had || !bytes.Equal(prev, cur)
		res.env = "unchanged"
		if changed {
			res.env = "restored"
			e.note("%s written from %s", path, src)
		} else {
			pop()
			e.note("%s already held what %s restores", path, src)
		}
	}
	back := func() {}
	if changed {
		back = func() {
			res.env = "put-back-failed"
			if putBack(e.note) {
				res.env = "put-back"
			}
			pop()
		}
	}
	fail := func(step string, err error) (*restoreResult, error) {
		res.step, res.signal = step, e.stop.Load() != 0
		back()
		return res, err
	}
	stopped := func() error { return failf("a signal stopped the restore") }
	if data {
		if err := e.extract(); err != nil {
			return fail(stepExtract, err)
		}
		if e.stop.Load() != 0 {
			return fail(stepExtract, stopped())
		}
		if err := e.hooks("restore", h.Restore, nil); err != nil {
			res.data = "partial"
			return fail(stepHook, failf("%v — what it did to the data is left as it is", err))
		}
		res.data = "restored"
		e.dropRestore()
	}
	if !changed {
		return res, nil
	}
	if e.stop.Load() != 0 {
		return fail(stepUp, stopped())
	}
	if err := e.up(); err != nil {
		return e.recreateFailed(res, fail, stepUp, failf("docker compose -p %s up -d --remove-orphans failed", e.project))
	}
	if err := e.joinTraefik(); err != nil {
		return e.recreateFailed(res, fail, stepUp, err)
	}
	if e.stop.Load() != 0 {
		return e.recreateFailed(res, fail, stepUp, stopped())
	}
	if err := e.healthWaitFor(health.Container); err != nil {
		return e.recreateFailed(res, fail, stepHealth, err)
	}
	res.recreated = "yes"
	return res, nil
}

// recreateFailed puts .env back, then brings the stack up once more so its
// containers read that .env again.
func (e *engine) recreateFailed(res *restoreResult, fail func(string, error) (*restoreResult, error), step string, err error) (*restoreResult, error) {
	r, err := fail(step, err)
	if res.env != "put-back" {
		res.stack = "as-left"
		return r, err
	}
	if uerr := e.up(); uerr != nil {
		res.stack = "down"
		e.note("bringing %s up again on the .env put back failed too — `docker compose -p %s up -d` in %s once it is fixed", e.project, e.project, e.dir)
	} else {
		res.stack = "up"
		e.note("brought %s up again on the .env put back", e.project)
	}
	return r, err
}

// putEnvBack writes the .env the restore replaced, or removes the one it
// created, saying so with say; false when it cannot. It registers no cleanup.
func (e *engine) putEnvBack(prev []byte, had bool, say func(string, ...any)) bool {
	path := filepath.Join(e.dir, ".env")
	var err error
	if had {
		err = env.PutBackLocked(e.dir, prev)
	} else if err = os.Remove(path); errors.Is(err, fs.ErrNotExist) {
		err = nil
	}
	if err != nil {
		say("could not put %s back as it was before this restore: %v", path, err)
		return false
	}
	say("put %s back as it was before this restore", path)
	return true
}
