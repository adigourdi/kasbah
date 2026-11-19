package mail

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/trace"
	"github.com/adigourdi/kasbah/internal/traefiknet"
)

// Remote is `kasbah remote mail <step> …`, run by the server binary: read
// answers in one JSON object, the others in key=value lines; failures are
// `remote: …` on stderr, exit 1. templates are the build's own, which dkim
// renders the signing override from.
func Remote(templates fs.FS, args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	usage := func() int {
		return fail("usage: kasbah remote mail read APPS DATA | write APPS DATA SIZE SHA256 | layout APPS DATA SIZE SHA256 | dkim APPS DATA [--replace=STAMP] [DOMAIN...] | start APPS TIMEOUT")
	}
	if len(args) == 0 {
		return usage()
	}
	if args[0] != "read" {
		w, done := remote.Outlive(stderr)
		defer done()
		stderr = w
	}
	var err error
	switch {
	case args[0] == "read" && len(args) == 3:
		err = json.NewEncoder(stdout).Encode(read(args[1], args[2]))
	case args[0] == "write" && len(args) == 5:
		err = remoteWrite(args[1], args[2], args[3], args[4], stdin, stdout)
	case args[0] == "layout" && len(args) == 5:
		err = remoteLayout(args[1], args[2], args[3], args[4], stdin, stdout)
	case args[0] == "dkim" && len(args) >= 3:
		err = remoteDKIM(templates, args[1], args[2], args[3:], stdout, stderr)
	case args[0] == "start" && len(args) == 3:
		t, perr := strconv.Atoi(args[2])
		if perr != nil {
			return usage()
		}
		err = remoteStart(args[1], time.Duration(t)*time.Second, stdout, stderr)
	default:
		return usage()
	}
	if err == errSaid {
		return 1
	}
	if err != nil {
		return fail("%s", cli.Full(err))
	}
	return 0
}

// errSaid is a failure already explained on stderr.
var errSaid = errors.New("")

// ReadReport is everything any mail command reads off a server, in one round
// trip, with nothing written. File bodies are base64, "" for a file that is
// absent, not regular or not readable.
type ReadReport struct {
	// Dir is <apps>/mail: absent, dir or notdir.
	Dir string `json:"dir"`
	// Env is whether <apps>/mail/.env is a regular file; EnvOwner its owner
	// when that is not this user.
	Env      bool   `json:"env"`
	EnvOwner string `json:"env_owner"`
	// Accounts is postfix-accounts.cf: absent, empty (readable, no account
	// line) or present — unreadable counts as present, since layout keeps it.
	Accounts string `json:"accounts"`
	Compose  string `json:"compose_b64"`
	Registry string `json:"registry_b64"`
	Fragment string `json:"fragment_b64"`
	Aliases  string `json:"aliases_b64"`
	Nginx    string `json:"nginx_b64"`
	Jail     string `json:"jail_b64"`
	// DKIMFiles are which of the registry domains' key files are there, and
	// DKIMTXT the TXT values their .public.dns.txt files hold, by record name.
	DKIMFiles []string          `json:"dkim_files"`
	DKIMTXT   map[string]string `json:"dkim_txt"`
	// HostAddr is the local end of this ssh connection, "" when unknown.
	HostAddr string `json:"host_addr"`
}

func b64(path string) string { return base64.StdEncoding.EncodeToString(regular(path)) }

// regular is a regular file's bytes, nil for anything else or a failed read.
func regular(path string) []byte {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return b
}

// isFile is `[ -f ]`, symlinks followed.
func isFile(p string) (exists, regular bool) {
	fi, err := os.Stat(p)
	if err != nil {
		_, lerr := os.Lstat(p)
		return lerr == nil, false
	}
	return true, fi.Mode().IsRegular()
}

// hasAccount is whether an account file holds a line that is neither blank
// nor a comment; ok is false when it cannot be read.
func hasAccount(path string) (has, ok bool) {
	b, err := os.ReadFile(path)
	if err != nil {
		return false, false
	}
	for _, l := range strings.Split(string(b), "\n") {
		l = strings.TrimSuffix(l, "\r")
		if l != "" && !strings.HasPrefix(l, "#") {
			return true, true
		}
	}
	return false, true
}

func accountsPath(data string) string { return data + "/mail/dms/config/postfix-accounts.cf" }

func read(apps, data string) ReadReport {
	dir := apps + "/mail"
	r := ReadReport{Dir: "absent", Accounts: "absent"}
	if exists, _ := isFile(dir); exists {
		r.Dir = "notdir"
		if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
			r.Dir = "dir"
		}
	}
	_, r.Env = isFile(dir + "/.env")
	r.EnvOwner = serverlock.Foreign(dir + "/.env")
	if _, regular := isFile(accountsPath(data)); regular {
		r.Accounts = "empty"
		if has, ok := hasAccount(accountsPath(data)); has || !ok {
			r.Accounts = "present"
		}
	}
	r.Compose = b64(dir + "/compose.yml")
	reg := regular(dir + "/kasbah.yml")
	r.Registry = base64.StdEncoding.EncodeToString(reg)
	r.Fragment = b64(apps + "/traefik/dynamic/_mail.yml")
	r.Aliases = b64(data + "/mail/dms/config/postfix-virtual.cf")
	r.Nginx = b64(dir + "/cypht-nginx.conf")
	r.Jail = b64(data + "/mail/dms/config/fail2ban-jail.cf")
	if parsed, err := mailreg.Parse(reg, dir+"/kasbah.yml"); err == nil {
		r.DKIMFiles, r.DKIMTXT = dkimRead(parsed.Domains, DKIMDir(data))
	}
	if f := strings.Fields(os.Getenv("SSH_CONNECTION")); len(f) >= 3 {
		r.HostAddr = f[2]
	}
	return r
}

// WriteBody is add-mail-domain's payload: the whole re-rendered registry,
// and the alias line to append ("" for none).
type WriteBody struct {
	Registry string `json:"registry"`
	Alias    string `json:"alias"`
}

// remoteWrite replaces the registry whole and appends the alias to
// docker-mailserver's postfix-virtual.cf — only ever appended, and the
// failure to is reported rather than elevated past.
func remoteWrite(apps, data, size, sum string, stdin io.Reader, stdout io.Writer) error {
	reg := apps + "/mail/kasbah.yml"
	raw, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", reg, err)
	}
	var b WriteBody
	if err := json.Unmarshal(raw, &b); err != nil || b.Registry == "" {
		return fmt.Errorf("%s: the payload is not a mail write", reg)
	}
	if err := remote.Install(reg, []byte(b.Registry), 0o644); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "registry=written")

	cfg := data + "/mail/dms/config"
	aliases := cfg + "/postfix-virtual.cf"
	state, cause := "skipped", ""
	if b.Alias != "" {
		state = "failed"
		exists, regular := isFile(aliases)
		if fi, err := os.Stat(cfg); err != nil || !fi.IsDir() {
			state = "noconfig"
		} else if exists && !regular {
			state = "notfile"
		} else if err := appendLine(aliases, b.Alias); err != nil {
			cause = strings.ReplaceAll(err.Error(), "\n", " ")
		} else {
			state = "added"
		}
	}
	fmt.Fprintf(stdout, "alias=%s\n", state)
	if cause != "" {
		fmt.Fprintf(stdout, "alias_error=%s\n", cause)
	}
	return nil
}

// appendLine adds line, first ending a last line that has no newline.
func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o664)
	if errors.Is(err, os.ErrPermission) {
		if fi, serr := os.Stat(path); serr == nil {
			return fmt.Errorf("it belongs to %s and is mode %o, not group-writable: only its owner or root can append to it", serverlock.OwnerName(fi), fi.Mode().Perm())
		}
	}
	if err != nil {
		return cli.OSCause(err)
	}
	defer f.Close()
	lead := ""
	if fi, err := f.Stat(); err == nil && fi.Size() > 0 {
		last := make([]byte, 1)
		if _, err := f.ReadAt(last, fi.Size()-1); err != nil {
			return cli.OSCause(err)
		}
		if last[0] != '\n' {
			lead = "\n"
		}
	}
	_, err = f.WriteString(lead + line + "\n")
	return cli.OSCause(err)
}

// notFile is the layout step's refusal of something other than a regular
// file where init writes one.
func notFile(path string) *cli.Error {
	return cli.Fail("%s exists and is not a regular file", path).Next(
		fmt.Sprintf("Look at it (`ls -ld %s`) and move it aside: init writes it again.", path))
}

// LayoutBody is init's payload to the layout step: the rendered .env and the
// postmaster account line ("" when the server already has one). The account
// is a hash, and travels here rather than argv.
type LayoutBody struct {
	Env     string `json:"env"`
	Account string `json:"account"`
}

// envKeys are the .env keys kasbah owns; every other line is the operator's.
var envKeys = []string{"MAIL_HOSTNAME", "DOMAIN", "DATA_PATH"}

func ownedKey(line string) string {
	for _, k := range envKeys {
		if strings.HasPrefix(line, k+"=") {
			return k
		}
	}
	return ""
}

// MergeEnv rewrites kasbah's three keys in current by name, from the
// rendered default (an owned key's quoted span whole), copies every other
// line through untouched, and appends an owned key current lacks.
func MergeEnv(current, rendered string) string {
	want := map[string]string{}
	for _, l := range strings.Split(rendered, "\n") {
		l = strings.TrimSuffix(l, "\r")
		if k := ownedKey(l); k != "" {
			want[k] = l[len(k)+1:]
		}
	}
	var b strings.Builder
	seen := map[string]bool{}
	lines := strings.Split(current, "\n")
	if strings.HasSuffix(current, "\n") || current == "" {
		lines = lines[:len(lines)-1]
	}
	// A quoted span is one entry: its lines past the first are never a key,
	// and go with an owned key's first line.
	for _, e := range envtpl.Entries(lines) {
		l := lines[e.Line]
		k := ownedKey(strings.TrimSuffix(l, "\r"))
		if k == "" {
			for _, l := range lines[e.Line:e.End] {
				b.WriteString(l + "\n")
			}
			continue
		}
		b.WriteString(k + "=" + want[k] + "\n")
		seen[k] = true
	}
	for _, k := range envKeys {
		if !seen[k] {
			b.WriteString(k + "=" + want[k] + "\n")
		}
	}
	return b.String()
}

// remoteLayout is the mail tree, the .env and the account seed, before DMS
// can ever have run: .env merged by key, the account seed replacing only a
// file with no account line.
func remoteLayout(apps, data, size, sum string, stdin io.Reader, stdout io.Writer) error {
	dir := apps + "/mail"
	raw, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", dir, err)
	}
	var b LayoutBody
	if err := json.Unmarshal(raw, &b); err != nil || b.Env == "" {
		return fmt.Errorf("%s: the payload is not a mail layout", dir)
	}
	mdata := data + "/mail"
	// Bind-mount sources, which Docker would make root's. Cypht's entrypoint
	// hands cypht/ and everything in it to www-data (uid 33).
	for _, d := range []string{dir, mdata + "/dms/mail-data", mdata + "/dms/mail-state", mdata + "/dms/mail-logs",
		mdata + "/dms/config/rspamd/override.d", mdata + "/cypht"} {
		if err := os.MkdirAll(d, 0o777); err != nil {
			return fmt.Errorf("could not create %s: %v", d, cli.OSCause(err))
		}
	}
	// Set before Cypht's first start, which makes the directory www-data's and
	// any later chmod by the deploy user a failure: at 700 the healthcheck
	// still passes and every settings save fails silently.
	if fi, err := os.Stat(mdata + "/cypht"); err != nil || fi.Mode().Perm() != 0o755 {
		if err := os.Chmod(mdata+"/cypht", 0o755); err != nil {
			return fmt.Errorf("could not set the mode of %s/cypht to 755: %v (Cypht makes it www-data's); on the server: sudo chmod 755 %s/cypht", mdata, cli.OSCause(err), mdata)
		}
	}

	env := dir + "/.env"
	exists, regular := isFile(env)
	switch {
	case exists && !regular:
		return notFile(env)
	case !exists:
		if err := remote.Install(env, []byte(b.Env), 0o600); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "mail_env=created")
	default:
		cur, err := os.ReadFile(env)
		if err != nil {
			return fmt.Errorf("could not read %s: %v", env, cli.OSCause(err))
		}
		if err := envtpl.Refused(envtpl.RawLines(cur)); err != nil {
			return fmt.Errorf("%s %v, which kasbah does not rewrite — fix it by hand", env, err)
		}
		merged := MergeEnv(string(cur), b.Env)
		if merged == string(cur) {
			fmt.Fprintln(stdout, "mail_env=unchanged")
		} else {
			if err := remote.Install(env, []byte(merged), 0o600); err != nil {
				return err
			}
			fmt.Fprintln(stdout, "mail_env=rewritten")
		}
	}
	// Every run: the mode is a fact about the file, not about this run.
	if err := serverlock.EnsureMode(env, 0o600); err != nil {
		return err
	}

	accounts := accountsPath(data)
	exists, regular = isFile(accounts)
	if exists && !regular {
		return notFile(accounts)
	}
	has, readable := hasAccount(accounts)
	if b.Account == "" || (exists && (has || !readable)) {
		fmt.Fprintln(stdout, "mail_account=kept")
	} else {
		if err := remote.Install(accounts, []byte(b.Account+"\n"), 0o600); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "mail_account=seeded")
	}

	fmt.Fprintln(stdout, "mail_layout=done")
	return nil
}

// inspect is `docker inspect -f`, bounded by dockerTimeout.
func inspect(id, format string) (string, error) {
	out, err := docker("docker inspect "+id, "inspect", "-f", format, id)
	return strings.TrimRight(string(out), "\n"), err
}

// remoteStart is `compose up -d` and a wait for Cypht alone. DMS is
// reported, never waited for: without its certificate it crashloops, forever
// where mail.<primary> does not resolve publicly.
func remoteStart(apps string, timeout time.Duration, stdout, stderr io.Writer) error {
	dir := apps + "/mail"
	if fi, err := os.Stat(dir); err != nil {
		return fmt.Errorf("could not enter %s: %v", dir, cli.OSCause(err))
	} else if !fi.IsDir() {
		return fmt.Errorf("could not enter %s: it is not a directory", dir)
	}
	dc := func(args ...string) error {
		cmd := exec.Command("docker", append([]string{"compose", "-p", Project}, args...)...)
		cmd.Dir = dir
		cmd.Stdout, cmd.Stderr = stderr, stderr
		return trace.Run(cmd)
	}
	cid := func(svc string) string {
		cmd := exec.Command("docker", "compose", "-p", Project, "ps", "-a", "-q", svc)
		cmd.Dir = dir
		out, _ := trace.Output(cmd)
		return strings.TrimSpace(string(out))
	}
	dmsBefore := cid("mail-dms")
	// --remove-orphans: a service the template no longer names is removed.
	if err := dc("up", "-d", "--remove-orphans"); err != nil {
		return fmt.Errorf("docker compose -p %s up -d --remove-orphans failed in %s: %v", Project, dir, err)
	}
	// Webmail routes through Traefik, which joins the stack's own network.
	d := traefiknet.Docker(traefiknet.Exec)
	nets, err := d.Networks(Project)
	if err == nil {
		_, err = d.Join(nets)
	}
	if err != nil {
		return fmt.Errorf("the mail stack is up and traefik could not join its network (%v) — webmail answers 502 until it does", err)
	}
	web := cid("mail-cypht")
	if web == "" {
		return errors.New("compose reported no mail-cypht container after up -d")
	}
	// A file bind mount keeps the inode it was made with, and init replaces the
	// file whole: a container showing other bytes is recreated onto the new one.
	nginx := "unchecked"
	want, rerr := os.ReadFile(dir + "/cypht-nginx.conf")
	got, gerr := trace.Output(exec.Command("docker", "exec", web, "cat", "/etc/nginx/nginx.conf"))
	if rerr == nil && gerr == nil {
		nginx = "mounted"
		if !bytes.Equal(got, want) {
			if err := dc("up", "-d", "--no-deps", "--force-recreate", "mail-cypht"); err != nil {
				return fmt.Errorf("docker compose -p %s up -d --force-recreate mail-cypht failed in %s: %v", Project, dir, err)
			}
			nginx = "remounted"
			if web = cid("mail-cypht"); web == "" {
				return errors.New("compose reported no mail-cypht container after recreating it")
			}
		}
	}
	dms := cid("mail-dms")
	if dms == "" {
		return errors.New("compose reported no mail-dms container after up -d")
	}
	health := func(id string) string {
		h, err := inspect(id, "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}")
		if err != nil {
			return "gone"
		}
		return h
	}
	diagnose := func(msg string, logs bool) error {
		fmt.Fprintf(stderr, "remote: %s\n", msg)
		dc("ps", "-a")
		if logs {
			dc("logs", "--no-color", "--tail", "60", "mail-cypht")
		}
		return errSaid
	}
	deadline := time.Now().Add(timeout)
	h := ""
	for {
		h = health(web)
		if h == "healthy" {
			break
		}
		if h == "none" {
			return diagnose("the mail-cypht container declares no healthcheck — compose.yml lost it", false)
		}
		if running, err := inspect(web, "{{.State.Running}}"); err != nil || running != "true" {
			return diagnose(fmt.Sprintf("mail-cypht is not running (health %s) — it exited instead of coming up", h), true)
		}
		if !time.Now().Before(deadline) {
			return diagnose(fmt.Sprintf("mail-cypht did not report healthy within %ds (last health: %s)", int(timeout/time.Second), h), true)
		}
		time.Sleep(2 * time.Second)
	}
	jail := applyJail(dmsBefore, dms, stderr)
	unbanned, addr := unbanCypht(dms, stderr)
	state, _ := inspect(dms, "{{.State.Status}}")
	restarts, _ := inspect(dms, "{{.RestartCount}}")
	image, _ := inspect(dms, "{{.Config.Image}}")
	var out bytes.Buffer
	fmt.Fprintf(&out, "mail_cypht_health=%s\nmail_cypht_nginx=%s\nmail_dms_state=%s\nmail_dms_health=%s\nmail_dms_restarts=%s\nmail_dms_image=%s\nmail_jail=%s\nmail_cypht_unbanned=%s\nmail_cypht_addr=%s\nmail_networks=%s\n",
		h, nginx, state, health(dms), restarts, image, jail, unbanned, addr, strings.Join(nets, " "))
	_, err = stdout.Write(out.Bytes())
	return err
}

// Jail is the jail file in DMS's config mount, and Fail2ban's copy of it.
const (
	JailSource = "/tmp/docker-mailserver/fail2ban-jail.cf"
	JailLive   = "/etc/fail2ban/jail.d/user-jail.local"
)

// applyJail brings DMS's Fail2ban to the jail file. DMS copies it only in the
// setup of a new container, skipped when the same container starts again, so
// anything else gets the copy here. A failure is a warning: mail flows either way.
func applyJail(before, dms string, stderr io.Writer) string {
	if before != dms {
		return "atstart"
	}
	do := func(args ...string) ([]byte, error) {
		return trace.CombinedOutput(exec.Command("docker", args...))
	}
	failed := func(what string, out []byte) string {
		fmt.Fprintf(stderr, "remote: %s on mail-dms failed: %s\n", what, strings.TrimSpace(string(out)))
		return "failed"
	}
	if r, _ := inspect(dms, "{{.State.Running}}"); r != "true" {
		// Stopped or between restarts: Fail2ban reads the copy when it starts.
		src, _ := inspect(dms, `{{range .Mounts}}{{if eq .Destination "/tmp/docker-mailserver"}}{{.Source}}{{end}}{{end}}`)
		if src == "" {
			return failed("finding the config mount", []byte("no mount at /tmp/docker-mailserver"))
		}
		if out, err := do("cp", src+"/fail2ban-jail.cf", dms+":"+JailLive); err != nil {
			return failed("docker cp of the jail", out)
		}
		return "atstart"
	}
	copied := false
	if _, err := do("exec", dms, "cmp", "-s", JailSource, JailLive); err != nil {
		if out, err := do("exec", dms, "cp", JailSource, JailLive); err != nil {
			return failed("cp "+JailSource, out)
		}
		copied = true
	}
	if _, err := do("exec", dms, "fail2ban-client", "ping"); err != nil {
		return "atstart"
	}
	if !copied {
		if out, err := do("exec", dms, "fail2ban-client", "get", "dovecot", "ignoreip"); err == nil && ignoresCypht(string(out)) {
			return "unchanged"
		}
	}
	if out, err := do("exec", dms, "fail2ban-client", "reload"); err != nil {
		return failed("fail2ban-client reload", out)
	}
	return "reloaded"
}

// ignoresCypht reads `fail2ban-client get <jail> ignoreip`: a header line,
// then one entry per line after a `|- ` or "`- " branch.
func ignoresCypht(out string) bool {
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSuffix(l, "\r")
		if strings.HasSuffix(l, "- mail-cypht") {
			return true
		}
	}
	return false
}

// unbanCypht lifts any ban on mail-cypht's address in every jail: ignoreip
// stops new bans, not ones made before it. The count is "skipped" while
// Fail2ban is not answering; a starting jail drops restored bans it ignores.
func unbanCypht(dms string, stderr io.Writer) (count, addr string) {
	if trace.Run(exec.Command("docker", "exec", dms, "fail2ban-client", "ping")) != nil {
		return "skipped", ""
	}
	// Every address, resolved inside DMS as Fail2ban resolves ignoreip: on a
	// dual-stack network `getent hosts` gives only the IPv6 one.
	out, err := trace.Output(exec.Command("docker", "exec", dms, "getent", "ahosts", "mail-cypht"))
	var addrs []string
	for _, l := range strings.Split(string(out), "\n") {
		if f := strings.Fields(l); len(f) > 0 && !slices.Contains(addrs, f[0]) {
			addrs = append(addrs, f[0])
		}
	}
	if err != nil || len(addrs) == 0 {
		fmt.Fprintln(stderr, "remote: mail-dms cannot resolve mail-cypht, so no ban on it was looked for")
		return "failed", ""
	}
	addr = strings.Join(addrs, " ")
	out, err = trace.CombinedOutput(exec.Command("docker", append([]string{"exec", dms, "fail2ban-client", "unban"}, addrs...)...))
	n := strings.TrimSpace(string(out))
	if _, cerr := strconv.Atoi(n); err != nil || cerr != nil {
		fmt.Fprintf(stderr, "remote: fail2ban-client unban %s on mail-dms failed: %s\n", addr, n)
		return "failed", addr
	}
	return n, addr
}
