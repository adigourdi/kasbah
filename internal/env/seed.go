package env

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/remote"
)

// SeedName prefixes an interactive run's staged --env-seed in a project's
// server directory, `SeedName.<token>`: written by `setup-env seed`, removed
// by the setup that reads it and, with every other, by each `setup-env drift`.
const SeedName = ".kasbah-env-seed"

// MaxSeed bounds a seed file; each value is held to maxValue, as `env set`'s.
const MaxSeed = 256 << 10

var reToken = regexp.MustCompile(`^[0-9a-f]{16}$`)

// newToken names one run's staged seed: random, not secret.
func newToken() string {
	b := make([]byte, 8)
	rand.Read(b)
	return hex.EncodeToString(b)
}

// seedPath is the staged seed of token in dir.
func seedPath(dir, token string) string {
	return filepath.Join(dir, SeedName+"."+token)
}

// removeSeeds removes every staged seed in dir, and their staging files.
func removeSeeds(dir string) {
	es, _ := os.ReadDir(dir)
	for _, e := range es {
		if strings.HasPrefix(e.Name(), SeedName+".") {
			os.Remove(filepath.Join(dir, e.Name()))
		}
	}
}

// Seed is an --env-seed file, read and judged on the workstation.
type Seed struct {
	Data []byte
	Keys map[string]bool
}

// ParseSeed reads KEY=value lines as the setup reads a .env: CR stripped,
// blank and `#` lines skipped, an `export ` prefix allowed, the last
// assignment winning. A value is compose syntax, written to .env as it stands.
func ParseSeed(data []byte) (map[string]string, error) {
	if len(data) > MaxSeed {
		return nil, fmt.Errorf("it is over %d KiB", MaxSeed>>10)
	}
	vals := map[string]string{}
	for i, l := range envtpl.Lines(data) {
		if envtpl.Blank(l) || envtpl.Comment(l) {
			continue
		}
		k, v, ok := envtpl.Assign(l)
		if !ok {
			return nil, fmt.Errorf("line %d is not KEY=value (blank lines and # comments aside)", i+1)
		}
		if reserved(k) {
			return nil, fmt.Errorf("line %d sets %s — the %s* keys are kasbah's own, injected at deploy", i+1, k, envtpl.ReservedPrefix)
		}
		if len(v) > maxValue {
			return nil, fmt.Errorf("%s's value is over %d KiB", k, maxValue>>10)
		}
		vals[k] = v
	}
	if len(vals) == 0 {
		return nil, fmt.Errorf("it sets no key (blank lines and # comments only)")
	}
	return vals, nil
}

// bareDollars names, by key and line, each value holding a `$` that is not
// `$$` outside single quotes: compose blanks a variable it cannot resolve.
func bareDollars(data []byte) []string {
	var out []string
	for i, l := range envtpl.Lines(data) {
		if envtpl.Blank(l) || envtpl.Comment(l) {
			continue
		}
		k, v, ok := envtpl.Assign(l)
		if !ok || len(v) >= 2 && v[0] == '\'' && strings.IndexByte(v[1:], '\'') >= 0 {
			continue
		}
		for j := 0; j < len(v); j++ {
			if v[j] != '$' {
				continue
			}
			if j+1 < len(v) && v[j+1] == '$' {
				j++
				continue
			}
			out = append(out, fmt.Sprintf("line %d (%s)", i+1, k))
			break
		}
	}
	return out
}

// ReadSeed is --env-seed=path, refused before anything connects; nil when
// the flag is unset. Its values never reach any output.
func ReadSeed(o *cli.Output, cmd, path string) (*Seed, error) {
	if path == "" {
		return nil, nil
	}
	fail := func(format string, a ...any) error {
		return cli.Fail("%s: --env-seed=%s: "+format, append([]any{cmd, path}, a...)...)
	}
	fi, err := os.Stat(path)
	switch {
	case err != nil:
		return nil, fail("no such file")
	case !fi.Mode().IsRegular():
		return nil, fail("not a regular file")
	case fi.Mode().Perm()&0o077 != 0:
		return nil, cli.Fail("%s: --env-seed=%s is open to others (mode %04o) — it holds secrets", cmd, path, fi.Mode().Perm()).Cont(
			"chmod 600 " + path + ", then re-run.")
	case fi.Size() > MaxSeed:
		return nil, fail("it is over %d KiB — a seed holds .env lines, not files", MaxSeed>>10)
	case fi.Size() == 0:
		return nil, fail("the file is empty")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fail("could not read it")
	}
	vals, err := ParseSeed(data)
	if err != nil {
		return nil, fail("%v", err)
	}
	for _, w := range bareDollars(data) {
		o.Warn("%s: --env-seed=%s: %s has a bare $ — compose reads it as a variable and blanks one it cannot resolve; write $$ for a literal $", cmd, path, w)
	}
	s := &Seed{Data: data, Keys: map[string]bool{}}
	for k := range vals {
		s.Keys[k] = true
	}
	return s, nil
}

// unseeded is the keys of a space-separated list the seed does not answer.
func (s *Seed) unseeded(keys string) []string {
	var out []string
	for _, k := range strings.Fields(keys) {
		if s == nil || !s.Keys[k] {
			out = append(out, k)
		}
	}
	return out
}

// readSeed is SetHeader then a seed on stdin, judged as the workstation did.
func readSeed(stdin io.Reader) ([]byte, map[string]string, error) {
	in := bufio.NewReader(io.LimitReader(stdin, MaxSeed+200))
	header, err := in.ReadString('\n')
	size, sum, ok := strings.Cut(strings.TrimSuffix(header, "\n"), " ")
	if err != nil || !ok {
		return nil, nil, fmt.Errorf("no size and sha256 line ahead of the seed on stdin")
	}
	body, err := remote.Payload(in, size, sum)
	if err != nil {
		return nil, nil, err
	}
	vals, err := ParseSeed(body)
	if err != nil {
		return nil, nil, err
	}
	return body, vals, nil
}

// stageSeed is `setup-env seed DIR TOKEN`, SetHeader then the seed on stdin,
// renamed into place at mode 600 for an interactive setup's --seed=TOKEN.
func stageSeed(dir, token string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: env seed: "+format+"\n", a...)
		return 1
	}
	if !reToken.MatchString(token) {
		return fail("'%s' is not a seed token — nothing staged", token)
	}
	path := seedPath(dir, token)
	body, _, err := readSeed(stdin)
	if err != nil {
		return fail("%v — nothing staged", err)
	}
	lock, err := lockEnv(dir)
	if err != nil {
		return fail("%v", err)
	}
	defer lock.Close()
	tmp := path + "." + strconv.Itoa(os.Getpid())
	os.Remove(tmp)
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return fail("could not create %s", tmp)
	}
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	_, err = f.Write(body)
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err == nil {
		err = os.Rename(tmp, path)
	}
	if err != nil {
		os.Remove(tmp)
		return fail("could not write %s", path)
	}
	fmt.Fprintln(stdout, "staged=yes")
	return 0
}

// takeSeed reads token's staged seed and removes it before anything else can
// fail, a signal included.
func takeSeed(dir, token string) (map[string]string, error) {
	if !reToken.MatchString(token) {
		return nil, fmt.Errorf("'%s' is not a seed token", token)
	}
	path := seedPath(dir, token)
	pop := atexit.Push(func() { os.Remove(path) })
	defer pop()
	defer os.Remove(path)
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("no staged seed at %s — another kasbah run in %s removed it; re-run", path, dir)
	}
	if err != nil {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	data, err := io.ReadAll(f)
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v", path, err)
	}
	return ParseSeed(data)
}
