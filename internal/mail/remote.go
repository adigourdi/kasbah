package mail

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"slices"
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/traefiknet"
)

// Remote is `kasbah remote mail <step> …`, run by the server binary: read
// answers in one JSON object, the others in key=value lines; failures are
// `remote: …` on stderr, exit 1.
func Remote(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, a ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", a...)
		return 1
	}
	usage := func() int {
		return fail("usage: kasbah remote mail read APPS DATA | write APPS DATA SIZE SHA256 | layout APPS DATA SIZE SHA256 | start APPS TIMEOUT")
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
		return fail("%v", err)
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
	// HostAddr is the local end of this ssh connection, "" when unknown.
	HostAddr string `json:"host_addr"`
}

func b64(path string) string {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return ""
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(b)
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
	r.Registry = b64(dir + "/kasbah.yml")
	r.Fragment = b64(apps + "/traefik/dynamic/_mail.yml")
	r.Aliases = b64(data + "/mail/dms/config/postfix-virtual.cf")
	r.Nginx = b64(dir + "/cypht-nginx.conf")
	r.Jail = b64(data + "/mail/dms/config/fail2ban-jail.cf")
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
	state := "skipped"
	if b.Alias != "" {
		state = "failed"
		exists, regular := isFile(aliases)
		if fi, err := os.Stat(cfg); err != nil || !fi.IsDir() {
			state = "noconfig"
		} else if exists && !regular {
			state = "notfile"
		} else if appendLine(aliases, b.Alias) == nil {
			state = "added"
		}
	}
	fmt.Fprintf(stdout, "alias=%s\n", state)
	return nil
}

// appendLine adds line, first ending a last line that has no newline.
func appendLine(path, line string) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_APPEND, 0o664)
	if errors.Is(err, os.ErrPermission) {
		if fi, serr := os.Stat(path); serr == nil {
			return fmt.Errorf("%s belongs to %s and is mode %o, not group-writable: only its owner or root can append to it", path, serverlock.OwnerName(fi), fi.Mode().Perm())
		}
	}
	if err != nil {
		return err
	}
	defer f.Close()
	lead := ""
	if fi, err := f.Stat(); err == nil && fi.Size() > 0 {
		last := make([]byte, 1)
		if _, err := f.ReadAt(last, fi.Size()-1); err != nil {
			return err
		}
		if last[0] != '\n' {
			lead = "\n"
		}
	}
	_, err = f.WriteString(lead + line + "\n")
	return err
}

// LayoutBody is init's payload to the layout step: the rendered .env and
// Rspamd override, and the postmaster account line ("" when the server
// already has one). The account is a hash, and travels here rather than argv.
type LayoutBody struct {
	Env     string `json:"env"`
	DKIM    string `json:"dkim"`
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
// rendered default, copies every other line through untouched, and appends
// an owned key current lacks.
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
	for _, l := range lines {
		if k := ownedKey(strings.TrimSuffix(l, "\r")); k != "" {
			l = k + "=" + want[k]
			seen[k] = true
		}
		b.WriteString(l + "\n")
	}
	for _, k := range envKeys {
		if !seen[k] {
			b.WriteString(k + "=" + want[k] + "\n")
		}
	}
	return b.String()
}

// remoteLayout is the mail tree, the .env, and the two seeds, before DMS can
// ever have run: .env merged by key, the DKIM override written only where
// absent, the account seed replacing only a file with no account line.
func remoteLayout(apps, data, size, sum string, stdin io.Reader, stdout io.Writer) error {
	dir := apps + "/mail"
	raw, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", dir, err)
	}
	var b LayoutBody
	if err := json.Unmarshal(raw, &b); err != nil || b.Env == "" || b.DKIM == "" {
		return fmt.Errorf("%s: the payload is not a mail layout", dir)
	}
	mdata := data + "/mail"
	// Bind-mount sources, which Docker would make root's. Cypht's entrypoint
	// hands cypht/ and everything in it to www-data (uid 33).
	for _, d := range []string{dir, mdata + "/dms/mail-data", mdata + "/dms/mail-state", mdata + "/dms/mail-logs",
		mdata + "/dms/config/rspamd/override.d", mdata + "/cypht"} {
		if err := os.MkdirAll(d, 0o777); err != nil {
			return fmt.Errorf("could not create %s", d)
		}
	}
	// Set before Cypht's first start, which makes the directory www-data's and
	// any later chmod by the deploy user a failure: at 700 the healthcheck
	// still passes and every settings save fails silently.
	if fi, err := os.Stat(mdata + "/cypht"); err != nil || fi.Mode().Perm() != 0o755 {
		if err := os.Chmod(mdata+"/cypht", 0o755); err != nil {
			return fmt.Errorf("could not set the mode of %s/cypht to 755 (Cypht makes it www-data's); on the server: sudo chmod 755 %s/cypht", mdata, mdata)
		}
	}

	env := dir + "/.env"
	exists, regular := isFile(env)
	switch {
	case exists && !regular:
		return fmt.Errorf("%s exists and is not a regular file", env)
	case !exists:
		if err := remote.Install(env, []byte(b.Env), 0o600); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "mail_env=created")
	default:
		cur, err := os.ReadFile(env)
		if err != nil {
			return fmt.Errorf("could not read %s", env)
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
		return fmt.Errorf("%s exists and is not a regular file", accounts)
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

	dkim := DKIMConf(data)
	exists, regular = isFile(dkim)
	switch {
	case exists && !regular:
		return fmt.Errorf("%s exists and is not a regular file", dkim)
	case regular:
		fmt.Fprintln(stdout, "mail_dkim_seed=kept")
	default:
		if err := remote.Install(dkim, []byte(b.DKIM), 0o644); err != nil {
			return err
		}
		fmt.Fprintln(stdout, "mail_dkim_seed=seeded")
	}
	fmt.Fprintln(stdout, "mail_layout=done")
	return nil
}

func inspect(id, format string) (string, error) {
	out, err := exec.Command("docker", "inspect", "-f", format, id).Output()
	return strings.TrimRight(string(out), "\n"), err
}

// remoteStart is `compose up -d` and a wait for Cypht alone. DMS is
// reported, never waited for: without its certificate it crashloops, forever
// where mail.<primary> does not resolve publicly.
func remoteStart(apps string, timeout time.Duration, stdout, stderr io.Writer) error {
	dir := apps + "/mail"
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return fmt.Errorf("could not enter %s", dir)
	}
	dc := func(args ...string) error {
		cmd := exec.Command("docker", append([]string{"compose", "-p", Project}, args...)...)
		cmd.Dir = dir
		cmd.Stdout, cmd.Stderr = stderr, stderr
		return cmd.Run()
	}
	cid := func(svc string) string {
		cmd := exec.Command("docker", "compose", "-p", Project, "ps", "-a", "-q", svc)
		cmd.Dir = dir
		out, _ := cmd.Output()
		return strings.TrimSpace(string(out))
	}
	dmsBefore := cid("mail-dms")
	// A stack still on kasbah-net leaves it with this up: say so, apps lose it.
	moved := "no"
	if dmsBefore != "" {
		if on, err := inspect(dmsBefore, "{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}"); err == nil && slices.Contains(strings.Fields(on), "kasbah-net") {
			moved = "yes"
		}
	}
	// --remove-orphans: a service the template no longer names is removed.
	if err := dc("up", "-d", "--remove-orphans"); err != nil {
		return fmt.Errorf("docker compose -p %s up -d --remove-orphans failed in %s", Project, dir)
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
	got, gerr := exec.Command("docker", "exec", web, "cat", "/etc/nginx/nginx.conf").Output()
	if rerr == nil && gerr == nil {
		nginx = "mounted"
		if !bytes.Equal(got, want) {
			if err := dc("up", "-d", "--no-deps", "--force-recreate", "mail-cypht"); err != nil {
				return fmt.Errorf("docker compose -p %s up -d --force-recreate mail-cypht failed in %s", Project, dir)
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
	fmt.Fprintf(&out, "mail_cypht_health=%s\nmail_cypht_nginx=%s\nmail_dms_state=%s\nmail_dms_health=%s\nmail_dms_restarts=%s\nmail_dms_image=%s\nmail_jail=%s\nmail_cypht_unbanned=%s\nmail_cypht_addr=%s\nmail_networks=%s\nmail_moved=%s\n",
		h, nginx, state, health(dms), restarts, image, jail, unbanned, addr, strings.Join(nets, " "), moved)
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
		return exec.Command("docker", args...).CombinedOutput()
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
	if exec.Command("docker", "exec", dms, "fail2ban-client", "ping").Run() != nil {
		return "skipped", ""
	}
	// Every address, resolved inside DMS as Fail2ban resolves ignoreip: on a
	// dual-stack network `getent hosts` gives only the IPv6 one.
	out, err := exec.Command("docker", "exec", dms, "getent", "ahosts", "mail-cypht").Output()
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
	out, err = exec.Command("docker", append([]string{"exec", dms, "fail2ban-client", "unban"}, addrs...)...).CombinedOutput()
	n := strings.TrimSpace(string(out))
	if _, cerr := strconv.Atoi(n); err != nil || cerr != nil {
		fmt.Fprintf(stderr, "remote: fail2ban-client unban %s on mail-dms failed: %s\n", addr, n)
		return "failed", addr
	}
	return n, addr
}
