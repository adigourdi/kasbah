package env

import (
	"fmt"
	"os"
	"slices"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
)

// lastValues is each non-reserved key's last assignment: its value and its
// line, CR stripped, a quoted span folded to one line.
func lastValues(data []byte) (vals, lines map[string]string) {
	vals, lines = map[string]string{}, map[string]string{}
	raw := envtpl.RawLines(data)
	for _, e := range envtpl.Entries(raw) {
		if e.Key != "" && !reserved(e.Key) {
			vals[e.Key], lines[e.Key] = e.Value, e.OneLine(raw)
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

// MergeEnv is cur's lines with each of keys' assignments (a span whole)
// replaced by old's last one, where the first stood (appended if none), or
// dropped when old sets none; every other line byte for byte.
func MergeEnv(cur, old []byte, keys []string) []string {
	_, oldLines := lastValues(old)
	lines := envtpl.RawLines(cur)
	var out []string
	placed := map[string]bool{}
	for _, e := range envtpl.Entries(lines) {
		k := e.Key
		if k == "" || reserved(k) || !slices.Contains(keys, k) {
			out = append(out, lines[e.Line:e.End]...)
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
		lines = envtpl.RawLines(old)
	} else {
		cur, err := os.ReadFile(path)
		if err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("cannot read %s: %v — .env left untouched", path, cli.OSCause(err))
		}
		for _, f := range []struct {
			name string
			data []byte
		}{{path, cur}, {"the backup's .env", old}} {
			if err := envtpl.Refused(envtpl.RawLines(f.data)); err != nil {
				return fmt.Errorf("%s %v, which kasbah does not merge — .env left untouched", f.name, err)
			}
		}
		lines = MergeEnv(cur, old, keys)
	}
	if err := writeEnvFile(path, lines, cleanup); err != nil {
		return fmt.Errorf("could not write %s: %v", path, err)
	}
	return nil
}
