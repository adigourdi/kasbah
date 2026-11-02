package env

import (
	"fmt"
	"os"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/envtpl"
)

// lastValues is each non-reserved key's last assignment: its value and its
// line, CR stripped.
func lastValues(data []byte) (vals, lines map[string]string) {
	vals, lines = map[string]string{}, map[string]string{}
	for _, l := range envtpl.Lines(data) {
		if k, v, ok := envtpl.Assign(l); ok && !reserved(k) {
			vals[k], lines[k] = v, l
		}
	}
	return vals, lines
}

// EnvDiff is, by key and in byte order, what cur and old disagree on: keys
// both set to different values as written, then those only one sets.
// KASBAH_* keys never differ.
func EnvDiff(cur, old []byte) (changed, onlyOld, onlyCur []string) {
	c, _ := lastValues(cur)
	o, _ := lastValues(old)
	for k, v := range c {
		switch ov, ok := o[k]; {
		case !ok:
			onlyCur = append(onlyCur, k)
		case ov != v:
			changed = append(changed, k)
		}
	}
	for k := range o {
		if _, ok := c[k]; !ok {
			onlyOld = append(onlyOld, k)
		}
	}
	return envtpl.SortUniq(changed), envtpl.SortUniq(onlyOld), envtpl.SortUniq(onlyCur)
}

// MergeEnv is cur's lines with each of keys' assignments replaced by old's
// last line for it, where the first stood (appended if none), or dropped when
// old sets none; every other line is kept byte for byte.
func MergeEnv(cur, old []byte, keys []string) []string {
	_, oldLines := lastValues(old)
	lines := rawLines(cur)
	var out []string
	placed := map[string]bool{}
	for _, l := range lines {
		k, _, ok := envtpl.Assign(strings.TrimSuffix(l, "\r"))
		if !ok || reserved(k) || !slices.Contains(keys, k) {
			out = append(out, l)
			continue
		}
		if ol, has := oldLines[k]; has && !placed[k] {
			out = append(out, ol)
		}
		placed[k] = true
	}
	for _, k := range keys {
		if ol, has := oldLines[k]; has && !placed[k] {
			out = append(out, ol)
		}
	}
	return out
}

// RestoreEnv writes dir's .env from a backup's copy, old: whole when keys is
// nil, else MergeEnv's merge of keys into the .env there. It takes the
// project's .deploy.lock, and writes as every .env writer does (writeEnv).
func RestoreEnv(dir string, old []byte, keys []string) error {
	lock, err := lockEnv(dir)
	if err != nil {
		return err
	}
	defer lock.Close()
	return RestoreEnvLocked(dir, old, keys)
}

// RestoreEnvLocked is RestoreEnv for a caller already holding .deploy.lock.
func RestoreEnvLocked(dir string, old []byte, keys []string) error {
	return restoreEnvLocked(dir, old, keys, true)
}

// PutBackLocked writes prev as dir's whole .env, as RestoreEnvLocked does but
// registering no cleanup, so an atexit cleanup can run it.
func PutBackLocked(dir string, prev []byte) error {
	return restoreEnvLocked(dir, prev, nil, false)
}

func restoreEnvLocked(dir string, old []byte, keys []string, cleanup bool) error {
	path := dir + "/.env"
	if fi, err := os.Stat(path); err == nil && !fi.Mode().IsRegular() {
		return fmt.Errorf("%s is not a regular file — .env left untouched", path)
	}
	var lines []string
	if keys == nil {
		lines = rawLines(old)
	} else {
		cur, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("cannot read %s — .env left untouched", path)
		}
		lines = MergeEnv(cur, old, keys)
	}
	if err := writeEnvFile(path, lines, cleanup); err != nil {
		return fmt.Errorf("could not write %s: %v", path, err)
	}
	return nil
}
