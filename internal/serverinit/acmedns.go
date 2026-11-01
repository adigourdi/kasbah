package serverinit

import (
	"bytes"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/user"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/adigourdi/kasbah/internal/acme"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/serverlock"
	"github.com/adigourdi/kasbah/internal/tree"
)

// DNSDir holds one provider's credentials per file, <provider>.env, under
// <apps>/traefik; DNSMode keeps them the operators' group's and nobody else's.
const (
	DNSDir  = "acme-dns"
	DNSMode = 0o640
	maxDNS  = 64 << 10
)

// DNSResolverAddrs are where a DNS resolver checks propagation: public
// resolvers, not the host's, which may answer from a split-horizon zone.
var DNSResolverAddrs = []string{"1.1.1.1:53", "8.8.8.8:53"}

// A provider name opens with a letter, so YAML never reads it as a number.
var reProvider = regexp.MustCompile(`^[a-z][a-z0-9]*$`)

// yamlWords are the names YAML 1.1 or 1.2 reads as a boolean or a null.
var yamlWords = map[string]bool{"null": true, "true": true, "false": true, "yes": true, "no": true, "on": true, "off": true, "y": true, "n": true}

// isProvider is a name kasbah renders a DNS resolver under.
func isProvider(p string) bool {
	return reProvider.MatchString(p) && !yamlWords[p] && p != acme.Resolver && p != "letsencrypt"
}

// DNSEnvRel is a provider's env file relative to <apps>/traefik.
func DNSEnvRel(provider string) string { return DNSDir + "/" + provider + ".env" }

// AcmeDNS is one --acme-dns=<provider>:<env file>, the file read and judged.
type AcmeDNS struct {
	Provider, Path string
	// Body is the file's lines, CR stripped: credentials, never shown.
	Body []byte
}

// CheckProvider is a resolver name kasbah renders for a DNS provider.
func CheckProvider(flag, p string) error {
	switch {
	case p == "":
		return cli.Fail("server init: %s names no provider (%s<provider>…)", flag, flag)
	case p == acme.Resolver:
		return cli.Fail("server init: %s%s — '%s' is the HTTP-01 resolver's name; a DNS provider's resolver is named after the provider", flag, p, acme.Resolver)
	case p == "letsencrypt":
		return cli.Fail("server init: %s%s — 'letsencrypt' is the HTTP-01 resolver's former name; a DNS provider's resolver is named after the provider", flag, p)
	case yamlWords[p]:
		return cli.Fail("server init: %s%s is not a provider name — YAML reads '%s' as a boolean or a null, not a name", flag, p, p)
	case !reProvider.MatchString(p):
		return cli.Fail("server init: %s%s is not a provider name (lowercase letters and digits, opening with a letter, as lego names them: cloudflare, ovh, route53, gandiv5)", flag, p)
	}
	return nil
}

var reEnvKey = regexp.MustCompile(`^[A-Z_][A-Z0-9_]*$`)

// envValueFault is why compose's env_file might not read v as written, or
// quote it back in an error; "" for a value it reads as is.
func envValueFault(v string) string {
	if v == "" {
		return "the value is empty"
	}
	if v[0] == ' ' || v[len(v)-1] == ' ' {
		return "the value opens or ends with a space"
	}
	for i := 0; i < len(v); i++ {
		switch c := v[i]; {
		case c == '"' || c == '\'' || c == '`':
			return "the value holds a quote"
		case c == '$':
			return "the value holds a $, which compose interpolates"
		case c == '\\':
			return "the value holds a backslash"
		case c == '#':
			return "the value holds a #, which compose may read as a comment"
		case c < 0x20 || c > 0x7e:
			return "the value holds a character that is not printable ASCII"
		}
	}
	return ""
}

// envBody is an env file held to a shape compose cannot misread: KEY=value
// lines, blank lines and full-line # comments, CR stripped. A refusal names
// the line and the key, never the value.
func envBody(data []byte) (body []byte, keys int, fault string) {
	s := string(data)
	s = strings.TrimSuffix(s, "\n")
	if s == "" {
		return nil, 0, ""
	}
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		l = strings.TrimSuffix(l, "\r")
		lines[i] = l
		t := strings.TrimLeft(l, " \t")
		if strings.ContainsFunc(l, func(r rune) bool { return r < 0x20 && r != '\t' || r == 0x7f }) {
			return nil, 0, fmt.Sprintf("line %d holds a control character", i+1)
		}
		if t == "" || t[0] == '#' {
			continue
		}
		k, v, ok := strings.Cut(l, "=")
		switch {
		case !ok:
			return nil, 0, fmt.Sprintf("line %d is not KEY=value (blank lines and full-line # comments aside)", i+1)
		case !reEnvKey.MatchString(k):
			return nil, 0, fmt.Sprintf("line %d: the name before = is not uppercase letters, digits and _ (not opening with a digit, no space around =)", i+1)
		}
		if f := envValueFault(v); f != "" {
			return nil, 0, fmt.Sprintf("line %d (%s): %s", i+1, k, f)
		}
		keys++
	}
	return []byte(strings.Join(lines, "\n") + "\n"), keys, ""
}

// parseAcmeDNS is --acme-dns='s value: the provider checked, the env file
// read here and refused before anything connects. Its values never reach output.
func parseAcmeDNS(val string) (AcmeDNS, error) {
	p, path, ok := strings.Cut(strings.TrimSuffix(val, "\r"), ":")
	if !ok {
		return AcmeDNS{}, cli.Fail("server init: --acme-dns= must be <provider>:<env file>, e.g. --acme-dns=cloudflare:./cloudflare.env")
	}
	if err := CheckProvider("--acme-dns=", p); err != nil {
		return AcmeDNS{}, err
	}
	fail := func(format string, a ...any) *cli.Error {
		return cli.Fail("server init: --acme-dns=%s:%s: "+format, append([]any{p, path}, a...)...)
	}
	if path == "" {
		return AcmeDNS{}, cli.Fail("server init: --acme-dns=%s: names no env file (--acme-dns=%s:<env file>)", p, p)
	}
	fi, err := os.Stat(path)
	switch {
	case err != nil:
		return AcmeDNS{}, fail("no such file")
	case !fi.Mode().IsRegular():
		return AcmeDNS{}, fail("not a regular file")
	case fi.Mode().Perm()&0o077 != 0:
		return AcmeDNS{}, cli.Fail("server init: --acme-dns=%s:%s is open to its group or others (mode %04o) — it holds the provider's credentials", p, path, fi.Mode().Perm()).Cont(
			"chmod 600 " + path + ", then re-run.")
	case fi.Size() > maxDNS:
		return AcmeDNS{}, fail("it is over %d KiB — it holds KEY=value lines", maxDNS>>10)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return AcmeDNS{}, fail("could not read it")
	}
	body, keys, fault := envBody(data)
	switch {
	case fault != "":
		return AcmeDNS{}, fail("%s", fault).Cont(
			"Values are unquoted printable ASCII without \" ' ` $ \\ or #, and no space at either end — compose reads them as written.")
	case keys == 0:
		return AcmeDNS{}, fail("it sets no key — the provider's credentials go in it as KEY=value lines (lego's names, e.g. CF_DNS_API_TOKEN)")
	}
	return AcmeDNS{Provider: p, Path: path, Body: body}, nil
}

// checkDNSFlags refuses a provider given twice, or both added and removed.
func checkDNSFlags(o Options) error {
	seen := map[string]string{}
	for _, a := range o.AcmeDNS {
		if seen[a.Provider] != "" {
			return cli.Fail("server init: --acme-dns=%s: is given twice — one env file per provider", a.Provider)
		}
		seen[a.Provider] = "add"
	}
	for _, p := range o.NoAcmeDNS {
		switch seen[p] {
		case "add":
			return cli.Fail("server init: --acme-dns=%s: and --no-acme-dns=%s contradict each other", p, p)
		case "rm":
			return cli.Fail("server init: --no-acme-dns=%s is given twice", p)
		}
		seen[p] = "rm"
	}
	return nil
}

// StaticResolvers is every resolver a traefik.yml declares, true for one
// that answers DNS-01 (an acme.dnsChallenge).
func StaticResolvers(static string) (map[string]bool, error) {
	d, err := yamlDoc(static)
	if err != nil {
		return nil, err
	}
	rs, err := at(d, "certificatesResolvers")
	if err != nil {
		return nil, err
	}
	out := map[string]bool{}
	m, _ := rs.(*tree.Map)
	if m == nil {
		return out, nil
	}
	for _, k := range m.Keys() {
		v, _ := m.Get(k)
		dc, _ := tree.Lookup(v, "acme", "dnsChallenge")
		out[k] = dc != nil
	}
	return out, nil
}

// DNSResolvers is the DNS-01 resolvers a traefik.yml declares under a
// provider name, sorted: the ones kasbah renders and a re-run keeps.
func DNSResolvers(static string) ([]string, error) {
	all, err := StaticResolvers(static)
	if err != nil {
		return nil, err
	}
	var out []string
	for k, dns := range all {
		if dns && isProvider(k) {
			out = append(out, k)
		}
	}
	sort.Strings(out)
	return out, nil
}

// DNSPlan is the settled DNS resolvers: List renders, Install ships, Remove
// is swept once Traefik no longer reads them.
type DNSPlan struct {
	List    []string
	Install []AcmeDNS
	Remove  []string
	Kept    []string
}

// SettleDNS keeps the server's DNS resolvers unless a flag says otherwise:
// present has an env file, named is DNSNamed's read of dynamic/. An absent or
// unreadable traefik.yml keeps every provider whose env file is there.
func SettleDNS(out *cli.Output, o Options, static string, present []string, named map[string][]string) (DNSPlan, error) {
	var pl DNSPlan
	declared, err := DNSResolvers(static)
	if err != nil || static == "" {
		declared = append([]string(nil), present...)
	}
	given := map[string]bool{}
	for _, a := range o.AcmeDNS {
		given[a.Provider] = true
	}
	removed := map[string]bool{}
	for _, p := range o.NoAcmeDNS {
		removed[p] = true
		if !contains(declared, p) && !contains(present, p) {
			out.Warn("--no-acme-dns=%s had no effect: %s has no '%s' resolver", p, o.Target, p)
			continue
		}
		var files []string
		for _, f := range sortedKeys(named) {
			if contains(named[f], p) {
				files = append(files, "dynamic/"+strings.Map(printable, f))
			}
		}
		if len(files) > 0 {
			return pl, cli.Fail("server init: --no-acme-dns=%s refused — files Traefik's file provider reads may still name '%s':", p, p).Cont(
				fmt.Sprintf("  %s (under %s/traefik)", strings.Join(files, " "), o.Apps),
				"A router naming that resolver would stop getting certificates. A file counts when it holds",
				"the name as a whole word in any case (comments included), and also when kasbah cannot read",
				"it as Traefik would: a backslash, a '!', a '{{', a control character or a byte that is not",
				"UTF-8 anywhere in it (traefik.md → DNS-01). Only _shared.yml is skipped.",
				fmt.Sprintf("point those routers at another certResolver and remove the word or those characters, deploy, then re-run with --no-acme-dns=%s.", p))
		}
	}
	for _, p := range declared {
		switch {
		case removed[p], given[p]:
		case !contains(present, p):
			return pl, cli.Fail("%s/traefik/traefik.yml on %s declares the DNS resolver '%s', and its credentials are not there", o.Apps, o.Target, p).Cont(
				fmt.Sprintf("%s/traefik/%s is missing, and Traefik's compose stack reads it.", o.Apps, DNSEnvRel(p)),
				fmt.Sprintf("pass --acme-dns=%s:<env file> to install them, or --no-acme-dns=%s to remove the resolver.", p, p))
		default:
			pl.List = append(pl.List, p)
			pl.Kept = append(pl.Kept, p)
		}
	}
	for _, a := range o.AcmeDNS {
		pl.List = append(pl.List, a.Provider)
		pl.Install = append(pl.Install, a)
	}
	sort.Strings(pl.List)
	sort.Slice(pl.Install, func(i, j int) bool { return pl.Install[i].Provider < pl.Install[j].Provider })
	for _, p := range present {
		if !contains(pl.List, p) {
			pl.Remove = append(pl.Remove, p)
		}
	}
	return pl, nil
}

func contains(l []string, s string) bool {
	for _, v := range l {
		if v == s {
			return true
		}
	}
	return false
}

func sortedKeys(m map[string][]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// dnsResolverBlock is traefik.yml's resolvers after `http`, one per provider,
// with the http resolver's address, endpoint and store tokens.
func dnsResolverBlock(list []string) string {
	if len(list) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("  # DNS-01, one resolver per provider, named after it. Its credentials are the\n")
	b.WriteString("  # container's environment (compose.yml's env_file); a router opts in by name.\n")
	for _, p := range list {
		fmt.Fprintf(&b, "  %s:\n    acme:\n      email: \"__ACME_EMAIL__\"\n      caServer: \"__ACME_CA__\"\n", p)
		fmt.Fprintf(&b, "      storage: /letsencrypt/acme.json\n      dnsChallenge:\n        provider: %s\n        resolvers:\n", p)
		for _, r := range DNSResolverAddrs {
			fmt.Fprintf(&b, "          - %q\n", r)
		}
	}
	return b.String()
}

// dnsEnvBlock is the traefik service's env_file list, relative to compose.yml.
func dnsEnvBlock(list []string) string {
	if len(list) == 0 {
		return ""
	}
	var b strings.Builder
	b.WriteString("    # Each DNS provider's credentials, installed by `kasbah server init --acme-dns=`.\n    env_file:\n")
	for _, p := range list {
		fmt.Fprintf(&b, "      - %s\n", DNSEnvRel(p))
	}
	return b.String()
}

// expandLine replaces the template's line holding token alone with block,
// which may be empty: no trace is left of a token with nothing to say.
func expandLine(tpl, label, token, block string) (string, error) {
	line := "__" + token + "__\n"
	if strings.Count(tpl, line) != 1 {
		return "", cli.Fail("internal: the %s template does not hold %s once, on a line of its own", label, strings.TrimSuffix(line, "\n"))
	}
	return strings.Replace(tpl, line, block, 1), nil
}

// PresentDNS is every provider with a regular env file under dir.
func PresentDNS(dir string) []string {
	out := []string{}
	ents, _ := os.ReadDir(dir)
	for _, e := range ents {
		p, ok := strings.CutSuffix(e.Name(), ".env")
		if ok && isProvider(p) && e.Type().IsRegular() {
			out = append(out, p)
		}
	}
	return out
}

// DNSNamed is, by path under dir, which of names each file holds as a whole
// word in any case: every file but kasbah's _shared.yml (certResolver http).
// One kasbah cannot read as Traefik would (readDynamic) holds them all.
func DNSNamed(dir string, names []string) map[string][]string {
	out := map[string][]string{}
	if len(names) == 0 {
		return out
	}
	filepath.WalkDir(dir, func(path string, d fs.DirEntry, err error) error {
		rel, _ := filepath.Rel(dir, path)
		var low []byte
		switch {
		case err != nil && os.IsNotExist(err):
			return nil
		case err != nil:
			rel += "/"
		case d.IsDir() || path == filepath.Join(dir, "_shared.yml"):
			return nil
		default:
			low, err = readDynamic(path, d)
		}
		for _, n := range names {
			if err != nil || wholeWord(low, n) {
				out[rel] = append(out[rel], n)
			}
		}
		return nil
	})
	return out
}

// maxDynamic bounds the read of one file under dynamic/.
const maxDynamic = 4 << 20

// plain is whether b reads the same as raw bytes as Traefik reads it: UTF-8
// with no control character but tab and line ends, no YAML-only line break or
// BOM, no Go template, escape or YAML tag.
func plain(b []byte) bool {
	if !utf8.Valid(b) || bytes.Contains(b, []byte("{{")) {
		return false
	}
	s := string(b)
	for i, r := range s {
		switch {
		case r == '\r' && !strings.HasPrefix(s[i:], "\r\n"):
			return false
		case r == '\t', r == '\n', r == '\r':
		case r < 0x20, r == 0x7f, r == '\\', r == '!', r >= 0x80 && r <= 0x9f,
			r == 0x2028, r == 0x2029, r == 0xfeff:
			return false
		}
	}
	return true
}

// readDynamic is path's bytes lowercased, or an error when kasbah cannot read
// it as Traefik would: not a regular file (a link, a FIFO), too large, or not
// plain.
func readDynamic(path string, d fs.DirEntry) ([]byte, error) {
	if !d.Type().IsRegular() {
		return nil, fmt.Errorf("%s is not a regular file", path)
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() || fi.Size() > maxDynamic {
		return nil, fmt.Errorf("%s is not a regular file kasbah reads", path)
	}
	b, err := io.ReadAll(io.LimitReader(f, maxDynamic+1))
	if err != nil || len(b) > maxDynamic {
		return nil, fmt.Errorf("cannot read %s", path)
	}
	if !plain(b) {
		return nil, fmt.Errorf("%s may name a resolver kasbah cannot read", path)
	}
	return bytes.ToLower(b), nil
}

// wholeWord is whether low holds w between two bytes that are not [a-z0-9].
func wholeWord(low []byte, w string) bool {
	word := func(c byte) bool { return c >= 'a' && c <= 'z' || c >= '0' && c <= '9' }
	for i := 0; ; {
		j := bytes.Index(low[i:], []byte(w))
		if j < 0 {
			return false
		}
		j += i
		if (j == 0 || !word(low[j-1])) && (j+len(w) == len(low) || !word(low[j+len(w)])) {
			return true
		}
		i = j + 1
	}
}

// dnsCandidates is every provider a server's DNSNamed read looks for: those
// with an env file, and those its traefik.yml declares.
func dnsCandidates(traefikDir string) []string {
	names := PresentDNS(traefikDir + "/" + DNSDir)
	if b, err := os.ReadFile(traefikDir + "/traefik.yml"); err == nil {
		declared, _ := DNSResolvers(string(b))
		for _, p := range declared {
			if !contains(names, p) {
				names = append(names, p)
			}
		}
	}
	sort.Strings(names)
	return names
}

// remoteAcmeDNS is `init acme-dns APPS PROVIDER SIZE SHA256`: the env file
// renamed into place at DNSMode, in the operators' group when this user can
// give it one; the same bytes at the same mode are left alone.
func remoteAcmeDNS(apps, provider, size, sum string, stdin io.Reader, stdout io.Writer) error {
	if !isProvider(provider) {
		return fmt.Errorf("'%s' is not a DNS provider name", provider)
	}
	dir := apps + "/traefik/" + DNSDir
	path := dir + "/" + provider + ".env"
	body, err := remote.Payload(stdin, size, sum)
	if err != nil {
		return fmt.Errorf("%s: %v", path, err)
	}
	if err := os.MkdirAll(dir, 0o777); err != nil {
		return fmt.Errorf("could not create %s", dir)
	}
	if fi, err := os.Lstat(path); err == nil && fi.Mode().IsRegular() && fi.Mode().Perm() == DNSMode {
		if cur, err := os.ReadFile(path); err == nil && string(cur) == string(body) {
			fmt.Fprintln(stdout, "acme_dns=unchanged")
			return nil
		}
	}
	gid := -1
	if g, err := user.LookupGroup(serverlock.Group); err == nil {
		fmt.Sscan(g.Gid, &gid)
	}
	if err := remote.Install(path, body, DNSMode, gid); err != nil {
		return err
	}
	fmt.Fprintln(stdout, "acme_dns=written")
	return nil
}

// remoteAcmeDNSRemove is `init acme-dns-rm APPS PROVIDER…`, run once Traefik
// no longer reads them. One a file under dynamic/ names is kept, reported as
// acme_dns_kept_<provider>=<files>.
func remoteAcmeDNSRemove(apps string, providers []string, stdout io.Writer) error {
	for _, p := range providers {
		if !isProvider(p) {
			return fmt.Errorf("'%s' is not a DNS provider name", p)
		}
		path := apps + "/traefik/" + DNSEnvRel(p)
		if named := DNSNamed(apps+"/traefik/dynamic", []string{p}); len(named) > 0 {
			var files []string
			for _, f := range sortedKeys(named) {
				files = append(files, "dynamic/"+strings.Map(printable, f))
			}
			fmt.Fprintf(stdout, "acme_dns_kept_%s=%s\n", p, strings.Join(files, " "))
			continue
		}
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			return fmt.Errorf("could not remove %s", path)
		}
	}
	fmt.Fprintln(stdout, "acme_dns_removed=yes")
	return nil
}

func printable(r rune) rune {
	if r < 0x20 || r > 0x7e {
		return '?'
	}
	return r
}
