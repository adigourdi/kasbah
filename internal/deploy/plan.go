package deploy

import (
	"os"
	"regexp"
	"strconv"
	"strings"
	"unicode"

	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/manifest"
)

// Entry is one sync: line: src copied to dst under the project directory,
// recursively when either side ends in a slash.
type Entry struct {
	Src, Dst string
	Recurse  bool
}

// Plan is everything a deploy decides from the checkout before it reaches a
// server.
type Plan struct {
	Sync   []Entry
	Client string
	// ClientNote is why a tag's unusable client: was replaced by the name.
	ClientNote string
	MailDomain string
	MailSnappy string
	// Hooks holds all four lists; the engine is sent its mode's pair.
	Hooks  map[string][]string
	Images []string
	Health Health
	Backup *Backup
}

func trim(s string) string { return strings.TrimFunc(s, unicode.IsSpace) }

// str is `yq -r '<path> // ""'`, CR and surrounding blanks dropped.
func str(m *manifest.Manifest, path ...any) string {
	v, _ := m.Get(path...)
	s := strings.TrimSuffix(jv.Raw(jv.Alt(v, "")), "\r")
	if s == "null" {
		s = ""
	}
	return trim(s)
}

func checkSyncPath(p, side, entry string) error {
	switch {
	case p == "":
		return cli.Fail("kasbah.yml: sync entry '%s' has no %s", entry, side)
	case strings.HasPrefix(p, "/"):
		return cli.Fail("kasbah.yml: sync entry '%s' names an absolute %s ('%s') — entries are relative to the project root", entry, side, p)
	case strings.HasPrefix(p, "-"):
		return cli.Fail("kasbah.yml: sync entry '%s' has a %s starting with '-' ('%s'), which rsync would read as an option", entry, side, p)
	case strings.Contains(p, ":"):
		return cli.Fail("kasbah.yml: sync entry '%s' has a ':' in its %s ('%s') — rsync splits host from path on it", entry, side, p)
	case strings.IndexFunc(p, unicode.IsControl) >= 0:
		return cli.Fail("kasbah.yml: sync entry '%s' has a control character in its %s", entry, side)
	}
	w := "/" + p + "/"
	if strings.Contains(w, "//") || strings.Contains(w, "/./") || strings.Contains(w, "/../") {
		return cli.Fail("kasbah.yml: sync entry '%s' has a '.', '..' or empty segment in its %s ('%s')", entry, side, p)
	}
	return nil
}

// ParseSync reads the manifest's sync: lines, `src` or `src -> dst`.
func ParseSync(lines []string) ([]Entry, error) {
	var out []Entry
	for _, l := range lines {
		entry := trim(strings.TrimSuffix(l, "\r"))
		if entry == "" || entry == "null" {
			continue
		}
		src, dst := entry, entry
		if a, b, ok := strings.Cut(entry, "->"); ok {
			src, dst = trim(a), trim(b)
		}
		rec := strings.HasSuffix(src, "/") || strings.HasSuffix(dst, "/")
		src, dst = strings.TrimRight(src, "/"), strings.TrimRight(dst, "/")
		if err := checkSyncPath(src, "source", entry); err != nil {
			return nil, err
		}
		if err := checkSyncPath(dst, "destination", entry); err != nil {
			return nil, err
		}
		out = append(out, Entry{Src: src, Dst: dst, Recurse: rec})
	}
	if len(out) == 0 {
		return nil, cli.Fail("kasbah.yml: the sync: list is empty — a deploy would ship no compose file and nothing to run")
	}
	return out, nil
}

func syncLines(m *manifest.Manifest) ([]string, error) {
	v, _ := m.Get("sync")
	var lines []string
	add := func(x jv.Value) {
		// jq's tostring, then `yq -r`'s lines.
		lines = append(lines, strings.Split(jv.ToString(x), "\n")...)
	}
	switch s := jv.Alt(v, []jv.Value{}).(type) {
	case []jv.Value:
		for _, x := range s {
			add(x)
		}
	case *jv.Map:
		for _, k := range s.Keys() {
			x, _ := s.Get(k)
			add(x)
		}
	default:
		return nil, cli.Fail("kasbah.yml: sync: is not a list")
	}
	return lines, nil
}

// checkSources reports every sync: source this tree does not have, at once.
func checkSources(entries []Entry) error {
	var rows []string
	for _, e := range entries {
		fi, err := os.Stat(e.Src)
		switch {
		case err != nil:
			rows = append(rows, e.Src+" — no such file or directory")
		case e.Recurse && !fi.IsDir():
			rows = append(rows, e.Src+"/ — listed with a trailing slash, which means a directory, but it is a file")
		case !e.Recurse && fi.IsDir():
			rows = append(rows, e.Src+" — is a directory; add a trailing slash ('"+e.Src+"/') to sync it recursively")
		}
	}
	if len(rows) == 0 {
		return nil
	}
	return cli.Fail("kasbah.yml lists paths in sync: that this working tree does not have:").Cont(rows...).Cont(
		"every sync: entry is shipped on every deploy — fix the list or the tree")
}

// RemoteParents are the directories above each destination that rsync will
// not create, deduplicated, never the project root.
func RemoteParents(base string, entries []Entry) []string {
	var out []string
	seen := map[string]bool{}
	for _, e := range entries {
		dir := e.Dst
		if !e.Recurse {
			i := strings.LastIndex(e.Dst, "/")
			if i < 0 {
				continue
			}
			dir = e.Dst[:i]
		}
		if !seen[dir] {
			seen[dir] = true
			out = append(out, base+"/"+dir)
		}
	}
	return out
}

func readMail(m *manifest.Manifest, p *Plan) error {
	v, _ := m.Get("mail")
	if v == nil || v == false {
		return nil
	}
	if _, ok := v.(*jv.Map); !ok {
		return cli.Fail("kasbah.yml: mail: has type '%s' — it has to be a block with a domain: under it (docs/project-manifest.md → mail)", jv.Type(v))
	}
	p.MailDomain = str(m, "mail", "domain")
	if p.MailDomain == "" {
		return cli.Fail("kasbah.yml: mail: has no domain: — the claim is that the VPS mail stack handles that domain, and there is nothing else in the block for kasbah to check (docs/project-manifest.md)")
	}
	p.MailSnappy = str(m, "mail", "snappymail_domain")
	return nil
}

func readClient(m *manifest.Manifest, p *Plan, historical bool) error {
	v, _ := m.Get("client")
	raw := strings.TrimSuffix(jv.ToString(jv.Alt(v, "")), "\r")
	if raw == "null" {
		raw = ""
	}
	if raw == "" {
		p.Client = m.Name
		return nil
	}
	if why, ok := manifest.ClientCheck(raw); !ok {
		// A tag's bytes cannot be edited: a version cut before the check
		// existed still has to roll back, on client:'s documented default.
		if historical {
			p.Client, p.ClientNote = m.Name, why
			return nil
		}
		return cli.Fail("kasbah.yml: %s", why)
	}
	p.Client = raw
	return nil
}

var hookNames = []string{"pre-deploy", "post-deploy", "pre-rollback", "post-rollback"}

// readHooks validates every hook here: a hook with no command found on the
// server would be found after the backup and the retag.
func readHooks(m *manifest.Manifest, p *Plan) error {
	p.Hooks = map[string][]string{}
	for _, which := range hookNames {
		v, _ := m.Get("hooks", which)
		var list []jv.Value
		switch l := jv.Alt(v, []jv.Value{}).(type) {
		case []jv.Value:
			list = l
		default:
			return cli.Fail("kasbah.yml: hooks.%s is not a list of strings", which)
		}
		for _, x := range list {
			line := jv.ToString(x)
			line = strings.TrimRight(line, "\n")
			if first, _, ok := strings.Cut(line, "\n"); ok {
				return cli.Fail("kasbah.yml: the %s hook '%s…' spans more than one line — a hook is one line whose first word is the container name, and a multi-line value would be run as several hooks (docs/project-manifest.md)", which, first)
			}
			line = trim(strings.TrimSuffix(line, "\r"))
			if line == "" || line == "null" {
				continue
			}
			c := hookContainer(line)
			if trim(strings.TrimPrefix(line, c)) == "" {
				return cli.Fail("kasbah.yml: the %s hook '%s' names a container and no command — each entry is \"<container> <command…>\" (docs/project-manifest.md)", which, line)
			}
			p.Hooks[which] = append(p.Hooks[which], line)
		}
	}
	return nil
}

var reDuration = regexp.MustCompile(`^([0-9]+)([smh]?)$`)

// Seconds is health.timeout: 120s, 5m, 2h or a bare number of seconds.
func Seconds(raw string) (int, error) {
	g := reDuration.FindStringSubmatch(raw)
	if g == nil {
		return 0, cli.Fail("kasbah.yml: health.timeout '%s' is not a duration kasbah can use — write it as 120s, 5m or 2h", raw)
	}
	n, err := strconv.Atoi(g[1])
	if err != nil || n > 1<<30 {
		return 0, cli.Fail("kasbah.yml: health.timeout '%s' is not a duration kasbah can use — write it as 120s, 5m or 2h", raw)
	}
	if n == 0 {
		return 0, cli.Fail("kasbah.yml: health.timeout '%s' is zero — a wait of no time at all cannot gate the deploy on health", raw)
	}
	switch g[2] {
	case "m":
		n *= 60
	case "h":
		n *= 3600
	}
	return n, nil
}

func readHealth(m *manifest.Manifest, p *Plan) error {
	p.Health = Health{Timeout: 120}
	if v, _ := m.Get("health"); !jv.Truthy(v) {
		return nil
	}
	p.Health.Container = str(m, "health", "container")
	raw := str(m, "health", "timeout")
	if raw == "" {
		raw = "120s"
	}
	n, err := Seconds(raw)
	if err != nil {
		return err
	}
	p.Health.Timeout = n
	return nil
}

func readBackup(m *manifest.Manifest, p *Plan) error {
	if v, _ := m.Get("backup"); !jv.Truthy(v) {
		return nil
	}
	b := &Backup{
		Check:     str(m, "backup", "check"),
		Container: str(m, "backup", "container"),
		Command:   str(m, "backup", "command"),
		Pipe:      str(m, "backup", "pipe"),
		Extension: str(m, "backup", "extension"),
	}
	switch {
	case b.Check == "":
		return cli.Fail("kasbah.yml: backup: has no check: — it is the command whose exit status decides whether a backup is taken (docs/project-manifest.md)")
	case b.Command == "":
		return cli.Fail("kasbah.yml: backup: has no command: — it is what writes the backup to stdout")
	case b.Extension == "":
		return cli.Fail("kasbah.yml: backup: has no extension: — it names the file backups/pre-deploy-<timestamp>.<extension>")
	case b.Container == "":
		return cli.Fail("kasbah.yml: backup: has no container: — backup.command runs inside it, as `docker exec <container> sh -c`")
	case strings.IndexFunc(b.Extension, func(r rune) bool { return r == '/' || unicode.IsSpace(r) || unicode.IsControl(r) }) >= 0:
		return cli.Fail("kasbah.yml: backup.extension '%s' must be a plain filename extension — it lands in backups/pre-deploy-<timestamp>.<extension>, and versions.log's fields are space-delimited", b.Extension)
	}
	raw := str(m, "backup", "retain")
	if raw == "" {
		raw = "10"
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 || strings.ContainsAny(raw, "+-") {
		return cli.Fail("kasbah.yml: backup.retain '%s' is not a whole number of backups to keep", raw)
	}
	if n == 0 {
		return cli.Fail("kasbah.yml: backup.retain is 0 — rotation would delete the backup it just took")
	}
	b.Retain = n
	p.Backup = b
	return nil
}

// readImages is what build-push tagged, untagged: the server appends the
// version.
func readImages(pwd, name, version string, p *Plan) error {
	doc, err := buildpush.ReadCompose(pwd, "deploy reads the images to retag from the same file `kasbah build-push` builds (docs/build-deploy.md)")
	if err != nil {
		return err
	}
	images, err := buildpush.Built(doc, name, version)
	if err != nil {
		return err
	}
	for _, im := range images {
		p.Images = append(p.Images, buildpush.Base(im.Source))
	}
	return nil
}

// ReadPlan reads and judges everything the deploy needs from the checkout.
func ReadPlan(m *manifest.Manifest, pwd, version string) (*Plan, error) {
	return readPlan(m, pwd, version, false)
}

// readSync is the sync: list, which must land a compose.yml.
func readSync(m *manifest.Manifest) ([]Entry, error) {
	lines, err := syncLines(m)
	if err != nil {
		return nil, err
	}
	sync, err := ParseSync(lines)
	if err != nil {
		return nil, err
	}
	hasCompose := false
	for _, e := range sync {
		hasCompose = hasCompose || e.Dst == "compose.yml"
	}
	if !hasCompose {
		return nil, cli.Fail("kasbah.yml: no sync: entry lands on compose.yml").Cont(
			"the server runs `docker compose` on "+m.Name+"/compose.yml, so the list has to",
			"put the project's compose file there:  compose.prod.yml -> compose.yml")
	}
	return sync, nil
}

// readPlan reads from the current directory; historical is a tag's manifest.
func readPlan(m *manifest.Manifest, pwd, version string, historical bool) (*Plan, error) {
	p := &Plan{}
	var err error
	if p.Sync, err = readSync(m); err != nil {
		return nil, err
	}
	// A tag's tree is checked against the ref instead (tagged.go), where a
	// symlink rsync -l ships — dangling or not — is a source like any other.
	if !historical {
		if err := checkSources(p.Sync); err != nil {
			return nil, err
		}
	}
	if err := readMail(m, p); err != nil {
		return nil, err
	}
	if err := readClient(m, p, historical); err != nil {
		return nil, err
	}
	for _, f := range []func(*manifest.Manifest, *Plan) error{readHooks, readHealth, readBackup} {
		if err := f(m, p); err != nil {
			return nil, err
		}
	}
	if err := readImages(pwd, m.Name, version, p); err != nil {
		return nil, err
	}
	return p, nil
}
