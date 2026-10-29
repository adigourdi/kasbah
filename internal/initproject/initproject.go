// Package initproject is `kasbah init-project`: kasbah.yml,
// .env.prod.example, .kasbah/state.json and the .gitignore entries, scaffolded
// into the current directory, all or nothing.
package initproject

import (
	"bytes"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/manifest"
	"github.com/adigourdi/kasbah/internal/state"
)

// Usage is `init-project --help`.
const Usage = `Usage: kasbah init-project [--name=<name>] [--domain=<fqdn>]

Scaffolds kasbah metadata in the current directory:
  - kasbah.yml           (manifest)
  - .env.prod.example     (env template skeleton)
  - .kasbah/state.json   (project state)
  - .gitignore entries for .env and .kasbah/

Does not create compose.prod.yml — that is user-authored.
`

// ErrHelp is the --help request, which the caller answers.
var ErrHelp = errors.New("help requested")

// Template is the .env.prod.example scaffold: comments only, which E01, E04
// and E05 all pass — declaring nothing is a first-class state.
const Template = "# =============================================================================\n" +
	"# Production Configuration\n" +
	"# =============================================================================\n" +
	"#\n" +
	"# One KEY=value per line; the first deploy prompts for each and writes the\n" +
	"# answers to .env on the server (docs/env-template.md in the kasbah repository\n" +
	"# for hints, defaults and ! generators). Leave this file as it is if the\n" +
	"# project configures nothing — the file is required, the keys are not. KASBAH_* names belong to kasbah.\n"

var (
	reName = regexp.MustCompile(`^[a-z][a-z0-9-]*$`)
	reFQDN = regexp.MustCompile(`^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]+$`)
)

// IsFQDN is a hostname a certificate could be issued for: at least one dot,
// labels of 1-63 [A-Za-z0-9-] not opening or closing with a hyphen, an
// alphabetic final label.
func IsFQDN(d string) bool { return reFQDN.MatchString(d) }

// Options are the parsed flags.
type Options struct {
	Name, Domain           string
	NameGiven, DomainGiven bool
}

// Parse reads the flags in order: the first unknown one
// is refused, and --help wins over anything after it.
func Parse(args []string) (Options, error) {
	var o Options
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--name="):
			o.Name, o.NameGiven = strings.TrimPrefix(a, "--name="), true
		case strings.HasPrefix(a, "--domain="):
			o.Domain, o.DomainGiven = strings.TrimPrefix(a, "--domain="), true
		case a == "-h" || a == "--help":
			return o, ErrHelp
		default:
			return o, cli.Fail("init-project: unknown argument '%s' (expected --name=X or --domain=X)", a)
		}
	}
	return o, nil
}

// Run scaffolds the project in the current directory, named after pwd unless
// --name says otherwise. version is what the manifest and state record.
func Run(out *cli.Output, o Options, pwd, version string) error {
	if o.NameGiven && o.Name == "" {
		return cli.Fail("--name=<name> must not be empty")
	}
	name := o.Name
	if name == "" {
		name = filepath.Base(pwd)
	}
	if !reName.MatchString(name) {
		return cli.Fail("invalid project name '%s' (must match ^[a-z][a-z0-9-]*$)", name)
	}
	if manifest.NameReserved(name) {
		return cli.Fail("project name '%s' is reserved — kasbah owns <apps>/%s on every server (reserved: %s). Pass --name=<other>.", name, name, strings.Join(manifest.Reserved, " "))
	}
	if o.DomainGiven && !IsFQDN(o.Domain) {
		return cli.Fail("invalid domain '%s' (expected FQDN like app.example.com)", o.Domain)
	}
	for _, t := range []string{manifest.File, ".env.prod.example", state.File} {
		if _, err := os.Stat(t); err == nil {
			return cli.Fail("%s already exists — refusing to overwrite", t)
		}
	}

	if err := scaffold(name, o.Domain, version); err != nil {
		return cli.Fail("init-project: %v", err)
	}

	out.Info("Initialized kasbah project '%s'", name)
	if o.Domain != "" {
		out.Info("  domain: %s", o.Domain)
	} else {
		out.Warn("domain is empty — edit kasbah.yml before deploying")
	}
	fmt.Fprintln(out.Stdout)
	fmt.Fprint(out.Stdout, Snippet(name, o.Domain))
	return nil
}

// scaffold writes every file. On any failure it removes what this run created
// — a scaffold file, .kasbah, .gitignore — and cuts a .gitignore it appended
// to back to its old length; nothing that was there before is removed.
func scaffold(name, domain, version string) (err error) {
	// Removed in reverse: state.json before the .kasbah holding it.
	targets := []string{".kasbah", state.File, manifest.File, ".env.prod.example", ".gitignore"}
	absent := map[string]bool{}
	for _, t := range targets {
		if _, lerr := os.Lstat(t); errors.Is(lerr, fs.ErrNotExist) {
			absent[t] = true
		}
	}
	appendedAt := int64(-1)
	defer func() {
		if err == nil {
			return
		}
		for i := len(targets) - 1; i >= 0; i-- {
			if absent[targets[i]] {
				os.Remove(targets[i])
			}
		}
		if appendedAt >= 0 {
			os.Truncate(".gitignore", appendedAt)
		}
	}()

	if err := manifest.Write(manifest.File, name, domain, version); err != nil {
		return err
	}
	if err := os.WriteFile(".env.prod.example", []byte(Template), 0o666); err != nil {
		return err
	}
	if fi, serr := os.Stat(".kasbah"); serr != nil || !fi.IsDir() {
		if err := os.Mkdir(".kasbah", 0o777); err != nil {
			return err
		}
	}
	if err := state.Init(state.File, version); err != nil {
		return err
	}
	return updateGitignore(&appendedAt)
}

// updateGitignore appends `.env` and `.kasbah/` unless a line already is
// exactly that (a NUL ends a line, as for GNU grep), first ending an
// unterminated last line. *at is set to the length it appended at.
func updateGitignore(at *int64) error {
	data, err := os.ReadFile(".gitignore")
	if err != nil && !errors.Is(err, fs.ErrNotExist) {
		return err
	}
	var add bytes.Buffer
	if len(data) > 0 && data[len(data)-1] != '\n' {
		add.WriteByte('\n')
	}
	have := map[string]bool{}
	for _, l := range strings.FieldsFunc(string(data), func(r rune) bool { return r == '\n' || r == 0 }) {
		have[l] = true
	}
	for _, l := range []string{".env", ".kasbah/"} {
		if !have[l] {
			add.WriteString(l + "\n")
		}
	}
	if add.Len() == 0 {
		return nil
	}
	f, err := os.OpenFile(".gitignore", os.O_WRONLY|os.O_APPEND|os.O_CREATE, 0o666)
	if err != nil {
		return err
	}
	*at = int64(len(data))
	if _, err := f.Write(add.Bytes()); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

// Snippet is the starter compose and routing printed after a scaffold.
func Snippet(name, domain string) string {
	if domain == "" {
		domain = "<your-domain>"
	}
	return strings.NewReplacer("{name}", name, "{domain}", domain).Replace(snippet)
}

const snippet = "Next step: author compose.prod.yml. Starter snippet:\n" +
	"\n" +
	"  services:\n" +
	"    {name}-web:\n" +
	"      image: nginx:alpine\n" +
	"      restart: unless-stopped\n" +
	"      cpus: ${KASBAH_CPU_LIMIT}\n" +
	"      mem_limit: ${KASBAH_MEM_LIMIT}\n" +
	"      logging:\n" +
	"        driver: json-file\n" +
	"        options:\n" +
	"          max-size: \"10m\"\n" +
	"          max-file: \"3\"\n" +
	"      networks: [kasbah]\n" +
	"\n" +
	"  networks:\n" +
	"    kasbah: {}\n" +
	"\n" +
	"  Only Traefik-routed containers join the kasbah network — the project's own,\n" +
	"  which compose creates as {name}_kasbah and deploy connects Traefik to; it is\n" +
	"  not external, so the file runs under plain `docker compose up` too. Add a\n" +
	"  second, project-internal network the moment there is a service nothing\n" +
	"  routes to, and keep that service off kasbah (see docs/traefik.md in the\n" +
	"  kasbah repository). The KASBAH_* limits are injected into .env at deploy.\n" +
	"\n" +
	"Routing is declared in traefik-dynamic.yml at the project root (see\n" +
	"docs/traefik.md in the kasbah repository). Starter:\n" +
	"\n" +
	"  http:\n" +
	"    routers:\n" +
	"      {name}-http:\n" +
	"        rule: \"Host(`{domain}`)\"\n" +
	"        entryPoints: [web]\n" +
	"        middlewares: [\"http-to-https@file\"]\n" +
	"        service: noop@internal\n" +
	"      {name}:\n" +
	"        rule: \"Host(`{domain}`)\"\n" +
	"        entryPoints: [websecure]\n" +
	"        tls:\n" +
	"          certResolver: letsencrypt\n" +
	"        middlewares: [\"security-headers@file\", \"gzip-compression@file\"]\n" +
	"        service: {name}\n" +
	"    services:\n" +
	"      {name}:\n" +
	"        loadBalancer:\n" +
	"          servers:\n" +
	"            - url: \"http://{name}-web:80\"\n" +
	"\n" +
	"Then run `kasbah check` to validate structure.\n"
