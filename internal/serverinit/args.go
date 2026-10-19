// Package serverinit is `kasbah server init` (docs/server-setup.md): the
// Traefik core, the mail half and the backup half.
package serverinit

import (
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/backup"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

const (
	DefaultApps = "/apps"
	Pointer     = "/etc/kasbah/apps-path"
	// TraefikImage is the Traefik a fresh server init runs.
	TraefikImage = "traefik:v3.7.10"
	CAProduction = "https://acme-v02.api.letsencrypt.org/directory"
	CAStaging    = "https://acme-staging-v02.api.letsencrypt.org/directory"
)

// Options is the parsed command line.
type Options struct {
	Target     string
	Apps, Data string
	Mail       prompt.Given
	Backup     prompt.Given
	Domain     string
	Email      string
	Auth       string
	Staging    bool
	AcmeChoice prompt.Given
	Yes        bool
	// Postmaster is --postmaster-password=, \r stripped. A secret: never echoed.
	Postmaster string
	Bk         BackupFlags
	// Help is --help: the usage, and nothing else.
	Help bool
}

// BackupFlags are the --backup-* flags as given, each checked at parse.
type BackupFlags struct {
	RepoBase               string
	At, Jitter, Timeout    string
	Daily, Weekly, Monthly string
	Env                    []string
	NoEnv                  bool
	// Pass is each --backup-password=<repo>=<password>, whole. Secrets.
	Pass []string
}

const unknownFlags = "--apps-path=, --data-path=, --domain=, --email=, --traefik-auth=, --acme-staging, --reset-acme/--keep-acme, --with-mail/--no-mail, --postmaster-password=, --with-backup/--no-backup, --backup-repo-base=, --backup-env=/--no-backup-env, --backup-password=, --backup-at=, --backup-jitter=, --backup-keep-daily=/-weekly=/-monthly=, --backup-timeout=, --yes"

// Parse is the command line, every value checked before anything is opened.
func Parse(args []string) (Options, error) {
	var o Options
	var apps, data string
	appsGiven, dataGiven := false, false
	acme := prompt.Pair{Yes: "reset-acme", No: "keep-acme"}
	for _, a := range args {
		name, val, hasVal := strings.Cut(a, "=")
		var err error
		switch {
		case hasVal && name == "--apps-path":
			apps, appsGiven = val, true
		case hasVal && name == "--data-path":
			data, dataGiven = val, true
		case hasVal && name == "--domain":
			o.Domain = strings.TrimSuffix(val, "\r")
			err = CheckDomain(o.Domain)
		case hasVal && name == "--email":
			o.Email = strings.TrimSuffix(val, "\r")
			err = CheckEmail(o.Email)
		case hasVal && name == "--traefik-auth":
			// Validated, never echoed: the value carries a password.
			o.Auth = val
			_, _, err = SplitAuth(val)
		case a == "--acme-staging":
			o.Staging = true
		case a == "--reset-acme":
			err = o.AcmeChoice.Set(prompt.Yes, acme, "server init")
		case a == "--keep-acme":
			err = o.AcmeChoice.Set(prompt.No, acme, "server init")
		case a == "--yes":
			o.Yes = true
		case a == "--with-mail":
			err = o.Mail.Set(prompt.Yes, prompt.Feature("mail"), "server init")
		case hasVal && name == "--postmaster-password":
			o.Postmaster = strings.TrimSuffix(val, "\r")
			err = CheckPostmaster(o.Postmaster)
		case a == "--no-mail":
			err = o.Mail.Set(prompt.No, prompt.Feature("mail"), "server init")
		case a == "--with-backup":
			err = o.Backup.Set(prompt.Yes, prompt.Feature("backup"), "server init")
		case a == "--no-backup":
			err = o.Backup.Set(prompt.No, prompt.Feature("backup"), "server init")
		// The base is named in every report, redacted; the env and password
		// values are never echoed at all.
		case hasVal && name == "--backup-repo-base":
			o.Bk.RepoBase = strings.TrimSuffix(val, "\r")
			err = backup.CheckRepoBase("server init", "--backup-repo-base=", o.Bk.RepoBase)
		case hasVal && name == "--backup-env":
			if err = backup.CheckEnvEntry("server init", "--backup-env=", val); err == nil {
				o.Bk.Env = append(o.Bk.Env, val)
			}
		case a == "--no-backup-env":
			o.Bk.NoEnv = true
		case hasVal && name == "--backup-password":
			if _, _, err = backup.SplitPassword("server init", val); err == nil {
				o.Bk.Pass = append(o.Bk.Pass, val)
			}
		case hasVal && name == "--backup-at":
			o.Bk.At = strings.TrimSuffix(val, "\r")
			err = backup.CheckAt("server init", o.Bk.At)
		case hasVal && name == "--backup-jitter":
			o.Bk.Jitter = strings.TrimSuffix(val, "\r")
			_, err = backup.CheckJitter("server init", o.Bk.Jitter)
		case hasVal && name == "--backup-keep-daily":
			o.Bk.Daily = val
			_, err = backup.CheckKeep("server init", "--backup-keep-daily=", val)
		case hasVal && name == "--backup-keep-weekly":
			o.Bk.Weekly = val
			_, err = backup.CheckKeep("server init", "--backup-keep-weekly=", val)
		case hasVal && name == "--backup-keep-monthly":
			o.Bk.Monthly = val
			_, err = backup.CheckKeep("server init", "--backup-keep-monthly=", val)
		case hasVal && name == "--backup-timeout":
			o.Bk.Timeout = strings.TrimSuffix(val, "\r")
			_, err = backup.CheckTimeout("server init", o.Bk.Timeout)
		case a == "-h", a == "--help":
			o.Help = true
			return o, nil
		case strings.HasPrefix(a, "-"):
			// Only the name: a mistyped --traefik-auths=admin:pw must not
			// print the password.
			return o, cli.Fail("server init: unknown flag '%s' (expected %s)", name, unknownFlags)
		default:
			if o.Target != "" {
				return o, cli.Fail("server init: unexpected argument '%s' (USER@HOST is given once)", a)
			}
			o.Target = strings.TrimSuffix(a, "\r")
		}
		if err != nil {
			return o, err
		}
	}
	if o.Target == "" {
		return o, cli.Fail("server init: USER@HOST is required (the user kasbah deploys as is not optional)")
	}
	if !appsGiven {
		apps = DefaultApps
	}
	var err error
	if o.Apps, err = CheckPath("apps-path", apps); err != nil {
		return o, err
	}
	if !dataGiven {
		data = o.Apps + "/data"
	}
	if o.Data, err = CheckPath("data-path", data); err != nil {
		return o, err
	}
	// `drop --prune` removes <data>/<project>: a data path above the apps
	// path would put the apps tree under a project's name.
	if strings.HasPrefix(o.Apps, o.Data+"/") {
		return o, cli.Fail("server init: --data-path=%s must not be a directory above the apps path %s", o.Data, o.Apps)
	}
	return o, nil
}

// isCntrl is `[[:cntrl:]]` under C.UTF-8.
func isCntrl(r rune) bool {
	return r < 0x20 || (r >= 0x7f && r <= 0x9f) || r == 0x2028 || r == 0x2029
}

// isSpace is `[[:space:]]` under C.UTF-8.
func isSpace(r rune) bool {
	switch {
	case r == ' ', r >= '\t' && r <= '\r', r == 0x1680, r >= 0x2000 && r <= 0x2006,
		r >= 0x2008 && r <= 0x200A, r == 0x2028, r == 0x2029, r == 0x205F, r == 0x3000:
		return true
	}
	return false
}

func has(s string, f func(rune) bool) bool { return strings.IndexFunc(s, f) >= 0 }

// checkScalar: every value lands in a double-quoted YAML scalar, which `"`
// ends and `\` escapes out of.
func checkScalar(what, v string) error {
	switch {
	case strings.Contains(v, `"`):
		return cli.Fail("server init: %s must not contain a double quote — it is written into a quoted YAML value", what)
	case strings.Contains(v, `\`):
		return cli.Fail("server init: %s must not contain a backslash — it is written into a quoted YAML value", what)
	case has(v, isCntrl):
		return cli.Fail("server init: %s must not contain control characters", what)
	}
	return nil
}

// CheckPath normalises a path flag: absolute, no `.`/`..`/empty segment, no
// trailing slash. `$` and `:` are refused because compose interpolates and
// splits the bind mounts both paths are written into.
func CheckPath(flag, v string) (string, error) {
	v = strings.TrimSuffix(v, "\r")
	if v == "" {
		return "", cli.Fail("server init: --%s= must not be empty", flag)
	}
	if v[0] != '/' {
		return "", cli.Fail("server init: --%s=%s must be an absolute path", flag, v)
	}
	if strings.Contains(v, "\n") {
		return "", cli.Fail("server init: --%s= must not contain a newline", flag)
	}
	if err := checkScalar("--"+flag+"=", v); err != nil {
		return "", err
	}
	if strings.Contains(v, "$") {
		return "", cli.Fail("server init: --%s= must not contain '$' — the path is written into a compose bind mount, which compose expands on the server", flag)
	}
	if strings.Contains(v, ":") {
		return "", cli.Fail("server init: --%s= must not contain ':' — the path is written into a compose bind mount, where ':' separates source from target", flag)
	}
	if strings.Contains(v, "//") || strings.Contains(v, "/./") || strings.Contains(v, "/../") ||
		strings.HasSuffix(v, "/..") || strings.HasSuffix(v, "/.") {
		return "", cli.Fail("server init: --%s=%s must be a normalised path (no '.', '..' or empty segment)", flag, v)
	}
	v = strings.TrimRight(v, "/")
	if v == "" {
		return "", cli.Fail("server init: --%s=/ must not be the filesystem root", flag)
	}
	return v, nil
}

var reFQDN = regexp.MustCompile(`^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]+$`)

func CheckDomain(d string) error {
	if d == "" {
		return cli.Fail("server init: --domain= must not be empty")
	}
	if !reFQDN.MatchString(d) {
		return cli.Fail("server init: --domain=%s is not a domain name (expected an apex like example.com — the dashboard is served at traefik.<domain>)", d)
	}
	return nil
}

var reEmail = regexp.MustCompile(`^[^@]+@[^@]+$`)

// CheckEmail catches the typo, not RFC 5322: Let's Encrypt validates properly.
func CheckEmail(e string) error {
	if e == "" {
		return cli.Fail("server init: --email= must not be empty")
	}
	if has(e, isSpace) {
		return cli.Fail("server init: --email= must not contain whitespace")
	}
	if err := checkScalar("--email=", e); err != nil {
		return err
	}
	if !reEmail.MatchString(e) {
		return cli.Fail("server init: --email=%s is not an email address (expected one @, with something either side)", e)
	}
	return nil
}

func CheckAuthUser(u string) error {
	switch {
	case u == "":
		return cli.Fail("server init: the dashboard username must not be empty (--traefik-auth=user:pass)")
	case strings.Contains(u, ":"):
		return cli.Fail("server init: the dashboard username must not contain a colon (--traefik-auth=user:pass splits on the first one)")
	case has(u, isSpace):
		return cli.Fail("server init: the dashboard username must not contain whitespace")
	}
	return checkScalar("the dashboard username", u)
}

func CheckAuthPass(p string) error {
	switch {
	case p == "":
		return cli.Fail("server init: the dashboard password must not be empty (--traefik-auth=user:pass)")
	case strings.Contains(p, "\n"):
		return cli.Fail("server init: the dashboard password must not contain a newline")
	}
	return nil
}

// SplitAuth checks user:pass and splits it at the first colon.
func SplitAuth(v string) (user, pass string, err error) {
	user, pass, ok := strings.Cut(v, ":")
	if !ok {
		return "", "", cli.Fail("server init: --traefik-auth= must be user:pass")
	}
	if err := CheckAuthUser(user); err != nil {
		return "", "", err
	}
	if err := CheckAuthPass(pass); err != nil {
		return "", "", err
	}
	return user, pass, nil
}
