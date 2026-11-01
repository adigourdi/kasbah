package deploy

import (
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"

	"github.com/adigourdi/kasbah/internal/buildpush"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/resources"
	"github.com/adigourdi/kasbah/internal/tree"
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
	// HookNotes name the keys under a tag's hooks: that are not hooks, ignored.
	HookNotes  []string
	MailDomain string
	// Hooks holds all four lists; the engine is sent its mode's pair.
	Hooks  map[string][]string
	Images []string
	Health Health
	Backup *Backup
	// Resources is resources: as written; ResourcesNote why a tag's was
	// unusable.
	Resources     resources.Spec
	ResourcesNote string
}

func trim(s string) string { return strings.TrimFunc(s, unicode.IsSpace) }

// Field is the string or number at path, "" for none, null or the string
// "null"; CR and surrounding blanks dropped. Anything else is refused as not
// being what (`a string`, `a whole number`, `a duration like …`).
func Field(m *manifest.Manifest, what string, path ...any) (string, error) {
	v, _ := m.Get(path...)
	switch v.(type) {
	case nil, string, tree.Number:
	default:
		names := make([]string, len(path))
		for i, p := range path {
			names[i] = fmt.Sprint(p)
		}
		return "", cli.Fail("kasbah.yml: %s must be %s, not %s", strings.Join(names, "."), what, tree.Compact(v))
	}
	s := strings.TrimSuffix(tree.TextAt(m.Doc, path...), "\r")
	if s == "null" {
		s = ""
	}
	return trim(s), nil
}

func checkSyncPath(p, side, entry string) error {
	switch {
	case p == "":
		return cli.Fail("kasbah.yml: sync entry '%s' has no %s", entry, side)
	case strings.HasPrefix(p, "/"):
		return cli.Fail("kasbah.yml: sync entry '%s' names an absolute %s ('%s') — entries are relative to the project root", entry, side, p)
	case strings.HasPrefix(p, "-"):
		return cli.Fail("kasbah.yml: sync entry '%s' has a %s starting with '-' ('%s'), which kasbah 1.0.1 and older hand to rsync as an option", entry, side, p)
	case strings.Contains(p, ":"):
		return cli.Fail("kasbah.yml: sync entry '%s' has a ':' in its %s ('%s') — kasbah 1.0.1 and older hand it to rsync, which splits host from path on it", entry, side, p)
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
	add := func(x tree.Value) {
		// Each entry's text, one line per line of it.
		lines = append(lines, strings.Split(tree.Text(x), "\n")...)
	}
	switch s := v.(type) {
	case nil:
	case []tree.Value:
		for _, x := range s {
			add(x)
		}
	default:
		return nil, cli.Fail("kasbah.yml: sync: is not a list — it lists the files a deploy ships (docs/project-manifest.md)")
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

// RemoteParents are the directories above each destination that the sync will
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

// MailDomain is the manifest's claim on the server's mail stack, "" for
// none; a mail: block that is not one, or has no domain:, is refused.
func MailDomain(m *manifest.Manifest) (string, error) {
	v, _ := m.Get("mail")
	if v == nil || v == false {
		return "", nil
	}
	if _, ok := v.(*tree.Map); !ok {
		return "", cli.Fail("kasbah.yml: mail: is not a block — it has to be a block with a domain: under it (docs/project-manifest.md → mail)")
	}
	d, err := Field(m, "a string", "mail", "domain")
	if err != nil {
		return "", err
	}
	if d == "" {
		return "", cli.Fail("kasbah.yml: mail: has no domain: — the claim is that the VPS mail stack handles that domain, and there is nothing else in the block for kasbah to check (docs/project-manifest.md)")
	}
	return d, nil
}

func readMail(m *manifest.Manifest, p *Plan) error {
	d, err := MailDomain(m)
	if err != nil || d == "" {
		return err
	}
	p.MailDomain = d
	return nil
}

func readClient(m *manifest.Manifest, p *Plan, historical bool) error {
	raw, err := Field(m, "a string", "client")
	if err != nil {
		return err
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

// readResources judges resources:; a tag's unusable block is noted, for a
// rollback to take the ceilings instead and a named deploy to refuse.
func readResources(m *manifest.Manifest, p *Plan, historical bool) error {
	spec, err := resources.Read(m)
	switch {
	case err == nil:
		p.Resources = spec
	case historical:
		p.ResourcesNote = err.Error()
	default:
		return cli.Fail("kasbah.yml: %v", err)
	}
	return nil
}

var hookNames = []string{"pre-deploy", "post-deploy", "pre-rollback", "post-rollback"}

// ReadHooks is the manifest's four hook lists as a deploy reads them.
func ReadHooks(m *manifest.Manifest) (map[string][]string, error) {
	var p Plan
	err := readHooks(m, &p, false)
	return p.Hooks, err
}

// readHooks validates every hook here: a hook with no command found on the
// server would be found after the backup and the retag.
// historical is a tag's manifest, where a key that is not a hook is noted and
// ignored: a version a server has run stays rollable.
func readHooks(m *manifest.Manifest, p *Plan, historical bool) error {
	p.Hooks = map[string][]string{}
	if h, _ := m.Get("hooks"); h != nil {
		hm, ok := h.(*tree.Map)
		if !ok {
			return cli.Fail("kasbah.yml: hooks: is not a block — it holds the lists pre-deploy:, post-deploy:, pre-rollback: and post-rollback: (docs/project-manifest.md)")
		}
		for _, k := range hm.Keys() {
			if slices.Contains(hookNames, k) {
				continue
			}
			if historical {
				p.HookNotes = append(p.HookNotes, k)
				continue
			}
			return cli.Fail("kasbah.yml: hooks.%s is not a hook kasbah runs — hooks: holds the lists pre-deploy:, post-deploy:, pre-rollback: and post-rollback: (docs/project-manifest.md)", k)
		}
	}
	for _, which := range hookNames {
		v, _ := m.Get("hooks", which)
		var list []tree.Value
		switch l := v.(type) {
		case nil:
		case []tree.Value:
			list = l
		default:
			return cli.Fail("kasbah.yml: hooks.%s is not a list of strings", which)
		}
		for _, x := range list {
			switch x.(type) {
			case nil, string, tree.Number:
			default:
				return cli.Fail("kasbah.yml: hooks.%s holds %s — each entry must be a string, \"<container> <command…>\"", which, tree.Compact(x))
			}
			line := tree.Text(x)
			line = strings.TrimRight(line, "\n")
			if first, _, ok := strings.Cut(line, "\n"); ok {
				return cli.Fail("kasbah.yml: the %s hook '%s…' spans more than one line — a hook is one line whose first word is the container name, and a multi-line value would be run as several hooks (docs/project-manifest.md)", which, first)
			}
			line = trim(strings.TrimSuffix(line, "\r"))
			if line == "" || line == "null" {
				continue
			}
			c := HookContainer(line)
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

// ReadHealth is the manifest's health: block as a deploy reads it.
func ReadHealth(m *manifest.Manifest) (Health, error) {
	var p Plan
	err := readHealth(m, &p)
	return p.Health, err
}

func readHealth(m *manifest.Manifest, p *Plan) error {
	p.Health = Health{Timeout: 120}
	if v, _ := m.Get("health"); v == nil || v == false {
		return nil
	} else if _, ok := v.(*tree.Map); !ok {
		return cli.Fail("kasbah.yml: health: is not a block — it holds container: and timeout: (docs/project-manifest.md)")
	}
	var err error
	if p.Health.Container, err = Field(m, "a string", "health", "container"); err != nil {
		return err
	}
	raw, err := Field(m, "a duration like 120s, 5m or 2h", "health", "timeout")
	if err != nil {
		return err
	}
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

// ReadBackup is the manifest's backup: block as a deploy reads it, nil for
// none.
func ReadBackup(m *manifest.Manifest) (*Backup, error) {
	var p Plan
	err := readBackup(m, &p)
	return p.Backup, err
}

func readBackup(m *manifest.Manifest, p *Plan) error {
	if v, _ := m.Get("backup"); v == nil || v == false {
		return nil
	} else if _, ok := v.(*tree.Map); !ok {
		return cli.Fail("kasbah.yml: backup: is not a block — it holds check:, command:, extension: and container: (docs/project-manifest.md)")
	}
	b := &Backup{}
	// check is a command, and a boolean is the command of that name.
	if c, _ := m.Get("backup", "check"); c == true || c == false {
		b.Check = tree.Compact(c)
	}
	for _, f := range []struct {
		key string
		to  *string
	}{{"container", &b.Container}, {"command", &b.Command}, {"pipe", &b.Pipe}, {"extension", &b.Extension}} {
		var err error
		if *f.to, err = Field(m, "a string", "backup", f.key); err != nil {
			return err
		}
	}
	if b.Check == "" {
		var err error
		if b.Check, err = Field(m, "a string", "backup", "check"); err != nil {
			return err
		}
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
	raw, err := Field(m, "a whole number", "backup", "retain")
	if err != nil {
		return err
	}
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
	// symlink the sync ships as a link — dangling or not — is a source like any other.
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
	if err := readHooks(m, p, historical); err != nil {
		return nil, err
	}
	if err := readResources(m, p, historical); err != nil {
		return nil, err
	}
	for _, f := range []func(*manifest.Manifest, *Plan) error{readHealth, readBackup} {
		if err := f(m, p); err != nil {
			return nil, err
		}
	}
	if err := readImages(pwd, m.Name, version, p); err != nil {
		return nil, err
	}
	return p, nil
}
