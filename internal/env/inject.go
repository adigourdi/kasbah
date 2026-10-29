package env

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// The managed block's sentinels. Frozen: an older kasbah's block has to be
// recognised, and every one of them collapses into one rewritten block.
const (
	ManagedBegin = "# >>> kasbah managed block - do not edit, rewritten on every deploy >>>"
	ManagedEnd   = "# <<< kasbah managed block <<<"
)

// Mode is a new .env's: the secrets are the kasbah group's, every operator's.
const Mode = 0o660

// GroupMode is an existing .env's mode with the group given the owner's read
// and write, so a 600 file converges to 660 on its next write.
func GroupMode(m os.FileMode) os.FileMode { return m | (m&0o600)>>3 }

var rePair = regexp.MustCompile(`^` + envtpl.ReservedPrefix + `[A-Za-z0-9_]*=`)

// rawLines splits a file keeping each line's bytes, CR included, NULs
// dropped; a last line without a newline is data.
func rawLines(data []byte) []string {
	s := strings.ReplaceAll(string(data), "\x00", "")
	if s == "" {
		return nil
	}
	lines := strings.Split(s, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

func setsReserved(line string) bool {
	k, _, ok := envtpl.Assign(strings.TrimSuffix(line, "\r"))
	return ok && reserved(k)
}

// resolve is `readlink -f` for a path whose last component may be missing.
func resolve(p string) (string, error) {
	for range 40 {
		fi, err := os.Lstat(p)
		if err != nil || fi.Mode()&os.ModeSymlink == 0 {
			dir, err := filepath.EvalSymlinks(filepath.Dir(p))
			if err != nil {
				return "", err
			}
			return filepath.Join(dir, filepath.Base(p)), nil
		}
		to, err := os.Readlink(p)
		if err != nil {
			return "", err
		}
		if !filepath.IsAbs(to) {
			to = filepath.Join(filepath.Dir(p), to)
		}
		p = to
	}
	return "", fmt.Errorf("too many levels of symbolic links")
}

// managedBlock marks the lines of every managed block, sentinels included.
func managedBlock(lines []string) []bool {
	n := len(lines)
	inBlock := make([]bool, n)
	for i := 0; i < n; i++ {
		if strings.TrimSuffix(lines[i], "\r") != ManagedBegin {
			continue
		}
		j := i + 1
		for ; j < n; j++ {
			if strings.TrimSuffix(lines[j], "\r") == ManagedEnd {
				break
			}
		}
		// A begin with no end is only a position, never a block to EOF.
		if j == n {
			j = i
		}
		for k := i; k <= j; k++ {
			inBlock[k] = true
		}
		i = j
	}
	return inBlock
}

// lockEnv takes dir's .deploy.lock for one read-modify-rename of its .env, so
// no two writers lose each other's change; held, it names the holder.
func lockEnv(dir string) (*os.File, error) {
	f, holder, err := serverlock.Project(dir)
	if err != nil {
		return nil, fmt.Errorf("could not open the lock file %s/.deploy.lock — .env left untouched", dir)
	}
	if f == nil {
		return nil, fmt.Errorf("%s is running in %s — it holds %s/.deploy.lock. .env left untouched; re-run once it has finished.", holder, dir, dir)
	}
	return f, nil
}

// Inject rewrites the managed block where the first one began, drops reserved
// strays and keeps every other line byte for byte (docs/env-template.md);
// renamed over the symlink-resolved target, whose mode it keeps (new: 600).
func Inject(envfile string, pairs []string, errw io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(errw, "ERROR: env inject: "+format+"\n", a...)
		return 1
	}
	if len(pairs) == 0 {
		return fail("no %sNAME=value pairs given", envtpl.ReservedPrefix)
	}
	for _, p := range pairs {
		if !rePair.MatchString(p) {
			return fail("'%s' is not a %sNAME=value pair", p, envtpl.ReservedPrefix)
		}
	}
	lock, err := lockEnv(filepath.Dir(envfile))
	if err != nil {
		return fail("%v", err)
	}
	defer lock.Close()
	target := envfile
	if fi, err := os.Lstat(envfile); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		t, err := resolve(envfile)
		if err != nil {
			return fail("cannot resolve '%s'", envfile)
		}
		target = t
	}

	var lines []string
	fi, statErr := os.Stat(target)
	exists := statErr == nil
	if exists && !fi.Mode().IsRegular() {
		return fail("'%s' is not a regular file", target)
	}
	if exists {
		data, err := os.ReadFile(target)
		if err != nil {
			return fail("cannot read '%s'", target)
		}
		lines = rawLines(data)
	}

	inBlock := managedBlock(lines)
	var kept []string
	at := -1
	for i, l := range lines {
		if inBlock[i] {
			if at < 0 {
				at = len(kept)
			}
			continue
		}
		if setsReserved(l) {
			continue
		}
		kept = append(kept, l)
	}
	if at < 0 {
		at = len(kept)
	}

	var b strings.Builder
	for _, l := range kept[:at] {
		b.WriteString(l + "\n")
	}
	b.WriteString(ManagedBegin + "\n")
	for _, p := range pairs {
		b.WriteString(p + "\n")
	}
	b.WriteString(ManagedEnd + "\n")
	for _, l := range kept[at:] {
		b.WriteString(l + "\n")
	}

	tmp := target + ".kasbah-inject." + strconv.Itoa(os.Getpid())
	os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fail("cannot write beside '%s'", target)
	}
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	mode := os.FileMode(Mode)
	if exists {
		mode = GroupMode(fi.Mode().Perm())
	}
	_, werr := io.WriteString(f, b.String())
	if cerr := f.Close(); werr == nil {
		werr = cerr
	}
	if werr == nil {
		werr = os.Chmod(tmp, mode)
	}
	if werr != nil {
		os.Remove(tmp)
		return fail("could not write '%s'", target)
	}
	if err := os.Rename(tmp, target); err != nil {
		os.Remove(tmp)
		return fail("could not replace '%s'", target)
	}
	return 0
}
