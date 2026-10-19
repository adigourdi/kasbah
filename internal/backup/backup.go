// Package backup is kasbah's off-VPS backup (docs/backup.md): init's checks
// and server steps, the kasbah-backup container's runner (`kasbah remote
// backup`), and `server backup-prune`.
package backup

import (
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
)

const (
	// Project and Container are templates/backup/compose.yml's names, which
	// `server destroy` removes by.
	Project   = "kasbah-backup"
	Container = "kasbah-backup"
	// ResticImage is the one restic kasbah runs, here and on every server.
	ResticImage = "restic/restic:0.18.0"
	// ProbeRepo is the credential probe's repository; the dot keeps every
	// project and client name off it.
	ProbeRepo = "kasbah.probe"
	// ProbePassword is not a secret: the probe repository holds one probe file.
	ProbePassword = "kasbah-probe"

	DefaultAt      = "02:00"
	DefaultTimeout = 900
	DefaultDaily   = 7
	DefaultWeekly  = 4
	DefaultMonthly = 3
)

// Owned are the restic variables kasbah sets per repository: an operator
// value would decide which repository opens, or with what key.
var Owned = []string{"RESTIC_REPOSITORY", "RESTIC_REPOSITORY_FILE",
	"RESTIC_PASSWORD", "RESTIC_PASSWORD_FILE", "RESTIC_PASSWORD_COMMAND"}

// IsOwned is whether kasbah sets key itself.
func IsOwned(key string) bool {
	if strings.HasPrefix(key, "KASBAH_BACKUP_") {
		return true
	}
	for _, o := range Owned {
		if key == o {
			return true
		}
	}
	return false
}

// Redact replaces a URL's password with `***`, for display only. Nothing
// branches on the scheme: a string without `://` comes back as it went in.
func Redact(in string) string {
	i := strings.Index(in, "://")
	if i < 0 {
		return in
	}
	scheme, host, tail := in[:i+3], in[i+3:], ""
	if j := strings.IndexByte(host, '/'); j >= 0 {
		host, tail = host[:j], host[j:]
	}
	if k := strings.LastIndexByte(host, '@'); k >= 0 {
		if auth := host[:k]; strings.Contains(auth, ":") {
			host = auth[:strings.IndexByte(auth, ':')] + ":***@" + host[k+1:]
		}
	}
	return scheme + host + tail
}

// isCntrl and isSpace are `[[:cntrl:]]` and `[[:space:]]` under C.UTF-8.
func isCntrl(r rune) bool {
	return r < 0x20 || (r >= 0x7f && r <= 0x9f) || r == 0x2028 || r == 0x2029
}

func isSpace(r rune) bool {
	switch {
	case r == ' ', r >= '\t' && r <= '\r', r == 0x1680, r >= 0x2000 && r <= 0x2006,
		r >= 0x2008 && r <= 0x200A, r == 0x2028, r == 0x2029, r == 0x205F, r == 0x3000:
		return true
	}
	return false
}

var (
	reAt     = regexp.MustCompile(`^([01][0-9]|2[0-3]):[0-5][0-9]$`)
	reDigits = regexp.MustCompile(`^[0-9]+$`)
	reRepo   = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	reKey    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
)

// CheckRepoBase: the base is appended to and never parsed, so only what
// would break its env line is refused, and its trailing `/` is required.
func CheckRepoBase(cmd, flag, v string) error {
	switch {
	case v == "":
		return cli.Fail("%s: %s must not be empty (it is where the snapshots go, and kasbah never invents one)", cmd, flag)
	case strings.IndexFunc(v, isCntrl) >= 0:
		return cli.Fail("%s: %s must not contain control characters — it is one line of <apps>/.kasbah/backup/env", cmd, flag)
	case strings.IndexFunc(v, isSpace) >= 0:
		return cli.Fail("%s: %s must not contain whitespace", cmd, flag)
	case !strings.HasSuffix(v, "/"):
		return cli.Fail("%s: %s%s must end in '/' — kasbah appends the repository name to it and never edits the URL, so the separator has to be in the value", cmd, flag, Redact(v))
	}
	return nil
}

func CheckAt(cmd, v string) error {
	if !reAt.MatchString(v) {
		return cli.Fail("%s: --backup-at=%s is not a time of day (expected HH:MM in 24-hour form, e.g. 02:00)", cmd, v)
	}
	return nil
}

// CheckJitter: under a day, the slot being a time of day.
func CheckJitter(cmd, v string) (int, error) {
	if !reDigits.MatchString(v) {
		return 0, cli.Fail("%s: --backup-jitter=%s is not a whole number of seconds", cmd, v)
	}
	n, err := strconv.Atoi(v)
	if err != nil || n >= 86400 {
		return 0, cli.Fail("%s: --backup-jitter=%s is a day or more — the slot is a time of day, so anything from 86400 wraps", cmd, v)
	}
	return n, nil
}

func CheckKeep(cmd, flag, v string) (int, error) {
	n, err := strconv.Atoi(v)
	if !reDigits.MatchString(v) || err != nil {
		return 0, cli.Fail("%s: %s%s is not a whole number of snapshots to keep", cmd, flag, v)
	}
	return n, nil
}

// CheckTimeout: a floor, since timeout(1) reads 0 as "kill it now".
func CheckTimeout(cmd, v string) (int, error) {
	if !reDigits.MatchString(v) {
		return 0, cli.Fail("%s: --backup-timeout=%s is not a whole number of seconds", cmd, v)
	}
	n, err := strconv.Atoi(v)
	if err != nil || n < 30 {
		return 0, cli.Fail(`%s: --backup-timeout=%s is under 30 seconds — that is a bound restic could not finish an empty repository inside, and timeout(1) reads 0 as "kill it now"`, cmd, v)
	}
	return n, nil
}

// CheckRepoName: a project name's charset; the names kasbah owns under
// <apps> are refused except `mail`, which is kasbah's own repository.
func CheckRepoName(cmd, flag, v string) error {
	if !reRepo.MatchString(v) {
		return cli.Fail("%s: %s%s is not a repository name (expected ^[a-z][a-z0-9-]*$, the same charset as a project name)", cmd, flag, v)
	}
	for _, r := range manifest.Reserved {
		if r != "mail" && v == r {
			return cli.Fail("%s: %s%s is a directory kasbah owns under <apps>, and no repository of that name exists (kasbah's own is 'mail')", cmd, flag, v)
		}
	}
	return nil
}

// CheckRepoRef is a repository a server has: a name, or the probe's.
func CheckRepoRef(cmd, flag, v string) error {
	if v == ProbeRepo {
		return nil
	}
	return CheckRepoName(cmd, flag, v)
}

// CheckEnvEntry checks a KEY=VALUE for the restic environment; only the key
// is ever quoted back.
func CheckEnvEntry(cmd, flag, entry string) error {
	key, val, ok := strings.Cut(entry, "=")
	if !ok {
		return cli.Fail("%s: %s must be KEY=VALUE (only the name is quoted back — the value is a credential)", cmd, flag)
	}
	if !reKey.MatchString(key) {
		return cli.Fail("%s: the key of %s is '%s', which is not a variable name", cmd, flag, key)
	}
	if strings.HasPrefix(key, "KASBAH_BACKUP_") {
		return cli.Fail("%s: %s%s= is a key kasbah owns and rewrites on every run (the repository base is --backup-repo-base=)", cmd, flag, key)
	}
	if IsOwned(key) {
		return cli.Fail("%s: %s%s= is a key kasbah owns — it is what says which repository restic opens and what key opens it, and an entry naming one would point the credential probe somewhere other than where the backups go. The repository is --backup-repo-base=; the password is --backup-password=<repo>=<password>.", cmd, flag, key)
	}
	if strings.ContainsAny(val, "\n\r") {
		return cli.Fail("%s: the value of %s%s= must not contain a newline — it is one line of <apps>/.kasbah/backup/env", cmd, flag, key)
	}
	return nil
}

func CheckPassword(cmd, repo, pass string) error {
	switch {
	case pass == "":
		return cli.Fail("%s: the restic password for '%s' must not be empty — it is what encrypts that client's snapshots, and kasbah never generates one", cmd, repo)
	case strings.ContainsAny(pass, "\n\r"):
		return cli.Fail("%s: the restic password for '%s' must not contain a newline — restic reads the password file's first line, so only the part before it would be used", cmd, repo)
	}
	return nil
}

// SplitPassword is `--backup-password=<repo>=<password>`, checked.
func SplitPassword(cmd, given string) (repo, pass string, err error) {
	repo, pass, ok := strings.Cut(given, "=")
	if !ok {
		return "", "", cli.Fail("%s: --backup-password= must be <repo>=<password> — repositories are per client, so a password is too (only the repository name is ever quoted back)", cmd)
	}
	if err := CheckRepoName(cmd, "--backup-password=", repo); err != nil {
		return "", "", err
	}
	if err := CheckPassword(cmd, repo, pass); err != nil {
		return "", "", err
	}
	return repo, pass, nil
}

var crcTable = func() (t [256]uint32) {
	for i := range t {
		c := uint32(i) << 24
		for k := 0; k < 8; k++ {
			if c&0x80000000 != 0 {
				c = c<<1 ^ 0x04C11DB7
			} else {
				c <<= 1
			}
		}
		t[i] = c
	}
	return
}()

// Cksum is POSIX cksum(1)'s CRC.
func Cksum(b []byte) uint32 {
	var crc uint32
	for _, c := range b {
		crc = crc<<8 ^ crcTable[byte(crc>>24)^c]
	}
	for n := len(b); n > 0; n >>= 8 {
		crc = crc<<8 ^ crcTable[byte(crc>>24)^byte(n)]
	}
	return ^crc
}

// JitterFor is the per-server slot offset: derived from the target, so a
// re-run renders the same bytes and two servers do not share a slot.
func JitterFor(target string) int { return int(Cksum([]byte(target+"\n")) % 3600) }

// FirstOwned is the first line of an env file setting a key kasbah sets
// itself (KASBAH_BACKUP_* aside, which init rewrites), or "".
func FirstOwned(content string) string {
	for _, line := range strings.Split(content, "\n") {
		line = strings.TrimSuffix(line, "\r")
		if line == "" || line[0] == '#' {
			continue
		}
		key, _, ok := strings.Cut(line, "=")
		if !ok || strings.HasPrefix(key, "KASBAH_BACKUP_") {
			continue
		}
		if IsOwned(key) {
			return key
		}
	}
	return ""
}

// OwnedEnvError is the refusal of an env file that sets one of Owned.
func OwnedEnvError(apps, key string) *cli.Error {
	return cli.Fail("%s/.kasbah/backup/env sets %s, which kasbah sets itself", apps, key).Cont(
		"that variable decides which repository restic opens and what key opens it,",
		"so a value there would point the credential probe at one repository while the",
		"scheduled backup wrote to another — and the probe would report a URL it had",
		"never contacted. Remove the line from that file and re-run.",
		"The repository is --backup-repo-base=; the password is --backup-password=<repo>=<password>.")
}

// MergeEnv is the env file kasbah writes: the default plus the given entries
// on a first run; after that the current file with kasbah's key and each
// given key rewritten by name, missing ones appended, the rest copied.
func MergeEnv(def, current, base string, given []string) string {
	if current == "" {
		var b strings.Builder
		b.WriteString(def)
		for _, e := range given {
			b.WriteString(e + "\n")
		}
		return b.String()
	}
	want := map[string]string{"KASBAH_BACKUP_REPO_BASE": base}
	order := []string{"KASBAH_BACKUP_REPO_BASE"}
	for _, e := range given {
		k, v, _ := strings.Cut(e, "=")
		want[k] = v
		order = append(order, k)
	}
	seen := map[string]bool{}
	var b strings.Builder
	for _, line := range strings.Split(strings.TrimSuffix(current, "\n"), "\n") {
		if k, _, ok := strings.Cut(strings.TrimSuffix(line, "\r"), "="); ok {
			if v, w := want[k]; w {
				line = k + "=" + v
				seen[k] = true
			}
		}
		b.WriteString(line + "\n")
	}
	for _, k := range order {
		if !seen[k] {
			b.WriteString(k + "=" + want[k] + "\n")
			seen[k] = true
		}
	}
	return b.String()
}
