package serverinit

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/jv"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/tmpl"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// Files are the three Traefik files kasbah owns, in shipping order,
// relative to <apps>/traefik.
var Files = []string{"compose.yml", "traefik.yml", "dynamic/_shared.yml"}

// errUnparsed is yaml_get's exit 2: the document does not parse, or the
// query raises where jq would.
type errUnparsed struct{}

func (errUnparsed) Error() string { return "unparsed" }

// yamlGet is lib/common.sh's yaml_get: `$(yq -r …)` of a query over content —
// trailing newlines off, "" for empty content or a null answer, one CR off.
func yamlGet(content string, q func(jv.Value) (jv.Value, bool)) (string, error) {
	if content == "" {
		return "", nil
	}
	docs, err := yamlx.Load([]byte(content))
	if err != nil {
		return "", errUnparsed{}
	}
	var outs []string
	for _, d := range docs {
		v, ok := q(d)
		if !ok {
			return "", errUnparsed{}
		}
		outs = append(outs, jv.Raw(v))
	}
	s := strings.TrimRight(strings.Join(outs, "\n"), "\n")
	if s == "null" {
		s = ""
	}
	return strings.TrimSuffix(s, "\r"), nil
}

// field is `.a.b.c // ""`.
func field(path ...any) func(jv.Value) (jv.Value, bool) {
	return func(d jv.Value) (jv.Value, bool) {
		v, ok := jv.Get(d, path...)
		return jv.Alt(v, ""), ok
	}
}

var reDashboard = regexp.MustCompile("^Host\\(`traefik\\.([^`]+)`\\)$")

// DashboardApex is traefik_dashboard_apex: the apex the dashboard router hangs
// off, "" when the rule is not the shape kasbah renders.
func DashboardApex(shared string) (string, error) {
	rule, err := yamlGet(shared, field("http", "routers", "traefik-dashboard", "rule"))
	if err != nil {
		return "", err
	}
	if m := reDashboard.FindStringSubmatch(rule); m != nil {
		return m[1], nil
	}
	return "", nil
}

// users is `(.http.middlewares["traefik-dashboard-auth"].basicAuth.users // [])`.
func users(d jv.Value) (jv.Value, bool) {
	v, ok := jv.Get(d, "http", "middlewares", "traefik-dashboard-auth", "basicAuth", "users")
	return jv.Alt(v, []jv.Value{}), ok
}

// length is jq's.
func length(v jv.Value) (jv.Value, bool) {
	switch v := v.(type) {
	case nil:
		return jv.Number("0"), true
	case bool:
		return nil, false
	case string:
		return jv.Number(fmt.Sprint(len([]rune(v)))), true
	case []jv.Value:
		return jv.Number(fmt.Sprint(len(v))), true
	case *jv.Map:
		return jv.Number(fmt.Sprint(v.Len())), true
	case jv.Number:
		s := string(v)
		return jv.Number(strings.TrimPrefix(s, "-")), true
	}
	return nil, false
}

// ExtractAuth is _si_extract_auth: the dashboard's own htpasswd entry, keyed to
// its middleware so an operator's basicAuth elsewhere is never adopted.
func ExtractAuth(shared string) (string, error) {
	count, err := yamlGet(shared, func(d jv.Value) (jv.Value, bool) {
		u, ok := users(d)
		if !ok {
			return nil, false
		}
		return length(u)
	})
	if err != nil {
		return "", err
	}
	entry, err := yamlGet(shared, func(d jv.Value) (jv.Value, bool) {
		u, ok := users(d)
		if !ok {
			return nil, false
		}
		v, ok := jv.Get(u, 0)
		return jv.Alt(v, ""), ok
	})
	if err != nil {
		return "", err
	}
	if count == "" || count == "0" {
		return "", nil
	}
	if entry != "" && !strings.Contains(entry, "\n") && strings.Contains(entry, ":") {
		return entry, nil
	}
	shown := entry
	if strings.Contains(entry, "\n") || entry == "" {
		shown = "<not a string>"
	}
	return "", cli.Fail("the dashboard credentials in dynamic/_shared.yml are not an htpasswd entry").Cont(
		fmt.Sprintf("traefik-dashboard-auth.basicAuth.users[0] holds '%s', and kasbah", shown),
		"reuses that entry verbatim rather than regenerating it — it cannot reuse this one.",
		"Fix it, or pass --traefik-auth=user:pass to set the credentials outright.")
}

var reImage = regexp.MustCompile(`^traefik:[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$`)

// ExtractImage is the official traefik image with a tag, or "": anything else
// falls back to this kasbah's pin.
func ExtractImage(compose string) (string, error) {
	ref, err := yamlGet(compose, field("services", "traefik", "image"))
	if err != nil || !reImage.MatchString(ref) {
		return "", err
	}
	return ref, nil
}

func caLabel(url string) string {
	switch url {
	case CAProduction:
		return "production"
	case CAStaging:
		return "staging"
	}
	return ""
}

// Acme is the settled ACME decision. One value, read by every later step:
// Reset is the only thing that archives a store.
type Acme struct {
	CA, Stored string
	Reset      bool
	// KeptUnknown is a store kept although nothing records its CA.
	KeptUnknown bool
}

// SettleAcme is _si_settle_acme_ca. store is the probe's acme_store; stored
// the caServer read off traefik.yml (staticErr when it does not parse,
// static the file's content). When it asks, nothing has been restarted and
// nothing created — except, on an existing apps path, the server binary
// shipped into <apps>/.kasbah/bin to read it.
func SettleAcme(out *cli.Output, p *prompt.Prompter, o Options, store, static, stored string, staticErr error) (Acme, error) {
	a := Acme{CA: CAProduction}
	if o.Staging {
		a.CA = CAStaging
	}
	origin := "nofield"
	switch {
	case staticErr != nil:
		origin = "unreadable"
	case stored != "":
		origin = "known"
		a.Stored = stored
	case static == "":
		origin = "nocontent"
	}

	unused := func(why string) {
		if o.AcmeChoice == prompt.Unset {
			return
		}
		flag := "--reset-acme"
		if o.AcmeChoice == prompt.No {
			flag = "--keep-acme"
		}
		out.Warn("%s had no effect: it answers what to do with a certificate store", flag)
		out.Warn("whose CA nothing on %s records, and %s", o.Target, why)
	}

	if store == "nonempty" && origin != "known" {
		return chooseUnknown(out, p, o, a, origin)
	}
	if store == "nonempty" && a.Stored != a.CA {
		if o.AcmeChoice == prompt.No {
			return a, cli.Fail("server init: --keep-acme cannot be honoured on %s", o.Target).Cont(
				"the server states one ACME endpoint and this run renders another, and every",
				"certificate in acme.json was issued by the one being left behind — keeping the",
				"store and switching CA cannot both happen:",
				fmt.Sprintf("  %s -> %s", a.Stored, a.CA),
				"re-run without --keep-acme to be asked, or with --yes to switch and reset.",
				"nothing was created or restarted — on a re-run the kasbah binary may already",
				"have been brought up to date.")
		}
		unused("this run is switching away from the endpoint that server states")
		return confirmSwitch(out, p, o, a)
	}
	if store == "nonempty" {
		unused("traefik.yml there records the CA that filled acme.json")
	} else {
		unused("acme.json there holds nothing to decide about")
	}
	return a, nil
}

func confirmSwitch(out *cli.Output, p *prompt.Prompter, o Options, a Acme) (Acme, error) {
	from, to := caLabel(a.Stored), caLabel(a.CA)
	var stay string
	switch from {
	case "staging":
		out.Warn("%s is configured for the Let's Encrypt staging CA and this run renders %s", o.Target, to)
		out.Warn("  %s -> %s", a.Stored, a.CA)
		stay = "re-run with --acme-staging"
	case "production":
		out.Warn("%s is configured for the Let's Encrypt production CA and this run renders %s", o.Target, to)
		out.Warn("  %s -> %s", a.Stored, a.CA)
		stay = "re-run without --acme-staging"
	default:
		// No flag reproduces this URL, so none is offered.
		out.Warn("%s is configured for an ACME endpoint kasbah does not render:", o.Target)
		out.Warn("  %s -> %s", a.Stored, a.CA)
		out.Warn("it was set outside kasbah. kasbah renders Let's Encrypt production or")
		out.Warn("staging and nothing else, so this run would replace it with %s.", to)
		stay = "leave the endpoint as it is — no kasbah flag reproduces it"
	}
	out.Warn("no certificate in acme.json survives the switch: the store is archived beside")
	out.Warn("itself, re-created empty, and re-issued from scratch on the next request.")
	ok, err := p.Confirm("yes", fmt.Sprintf("Switch %s to the Let's Encrypt %s CA and reset acme.json?", o.Target, to), o.Yes)
	if err != nil {
		return a, err
	}
	if !ok {
		return a, cli.Fail("server init: declined — %s is unchanged", o.Target).Cont(
			"nothing was created or restarted — on a re-run the kasbah binary may already",
			fmt.Sprintf("have been brought up to date. To keep what is there, %s.", stay))
	}
	a.Reset = true
	return a, nil
}

// chooseUnknown is a choice, never answered by --yes: answering it takes
// knowing which CA filled the store. Keeping proceeds.
func chooseUnknown(out *cli.Output, p *prompt.Prompter, o Options, a Acme, origin string) (Acme, error) {
	to := caLabel(a.CA)
	switch origin {
	case "unreadable":
		out.Warn("%s/traefik/traefik.yml on %s does not parse, so the endpoint it configures cannot be read", o.Apps, o.Target)
	case "nocontent":
		out.Warn("%s/traefik/traefik.yml on %s is missing, empty or unreadable, so nothing states which endpoint this server uses", o.Apps, o.Target)
	default:
		out.Warn("%s/traefik/traefik.yml on %s parses but names no caServer under certificatesResolvers.letsencrypt.acme", o.Apps, o.Target)
	}
	out.Warn("acme.json is not empty, and nothing here says which CA issued what is in it.")
	out.Warn("this run configures the Let's Encrypt %s CA. If the certificates in the store", to)
	out.Warn("came from the other one, Traefik keeps serving them until they renew and then")
	out.Warn("replaces them with %s ones — resetting the store now is what avoids that.", to)
	reset, err := p.Choice(prompt.Pair{Yes: "reset-acme", No: "keep-acme"},
		fmt.Sprintf("Reset acme.json on %s (archives it, forces re-issue from the %s CA)?", o.Target, to), o.AcmeChoice)
	if err != nil {
		return a, err
	}
	if reset {
		a.Reset = true
		return a, nil
	}
	out.Warn("keeping acme.json. %s is being configured for the %s CA with a", o.Target, to)
	out.Warn("certificate store of unknown provenance — if it holds certificates from the")
	out.Warn("other endpoint, they stay in service until they renew.")
	out.Warn("this run records the endpoint in traefik.yml, so you are asked this once.")
	a.KeptUnknown = true
	return a, nil
}

// Values are what the Traefik stack is rendered with.
type Values struct {
	Image, Domain, Email, AuthEntry, AuthOrigin string
	Acme                                        Acme
}

func unreadableStack(o Options, file, flag string) error {
	return cli.Fail("%s/traefik/%s on %s could not be read as YAML", o.Apps, file, o.Target).Cont(
		"kasbah reuses what is already on the server instead of regenerating it, so it",
		"will not guess past a file it cannot parse — that would overwrite whatever is",
		fmt.Sprintf("in there. Fix the file, or delete it, or pass %s to settle the value.", flag))
}

// Hasher bcrypts user:pass into an htpasswd line.
type Hasher func(user, pass string) (string, error)

// Resolve is _server_init_traefik_values: flag, else what the server has,
// else ask. The ACME question goes first — it alone can end the run.
func Resolve(out *cli.Output, p *prompt.Prompter, o Options, cur map[string]string, store string, hash Hasher) (Values, error) {
	shared, static, compose := cur["dynamic/_shared.yml"], cur["traefik.yml"], cur["compose.yml"]
	var v Values

	storedDomain, sharedErr := DashboardApex(shared)
	// Read only when it would be reused: a broken entry is no reason to
	// refuse a run that sets the credentials outright.
	var storedAuth string
	if sharedErr == nil && o.Auth == "" {
		var err error
		if storedAuth, err = ExtractAuth(shared); err != nil {
			if _, bad := err.(errUnparsed); !bad {
				return v, err
			}
			sharedErr = err
		}
	}
	storedEmail, staticErr := yamlGet(static, field("certificatesResolvers", "letsencrypt", "acme", "email"))
	storedCA, caErr := yamlGet(static, field("certificatesResolvers", "letsencrypt", "acme", "caServer"))
	storedImage, composeErr := ExtractImage(compose)

	if storedImage != "" && composeErr == nil {
		v.Image = storedImage
	} else {
		v.Image = TraefikImage
		if compose != "" {
			out.Warn("the traefik image in compose.yml on %s is not one kasbah reproduces — rendering %s (a managed bump is `kasbah server upgrade-traefik --version=`)", o.Target, TraefikImage)
		}
	}

	var err error
	if v.Acme, err = SettleAcme(out, p, o, store, static, storedCA, caErr); err != nil {
		return v, err
	}

	switch {
	case o.Domain != "":
		v.Domain = o.Domain
	case sharedErr != nil:
		return v, unreadableStack(o, "dynamic/_shared.yml", "--domain=")
	case storedDomain != "":
		v.Domain = storedDomain
	default:
		if v.Domain, err = p.Value("domain", fmt.Sprintf("Apex domain for %s (the dashboard is served at traefik.<domain>)", o.Target), "", ""); err != nil {
			return v, err
		}
		if err = CheckDomain(v.Domain); err != nil {
			return v, err
		}
	}

	switch {
	case o.Email != "":
		v.Email = o.Email
	case staticErr != nil:
		return v, unreadableStack(o, "traefik.yml", "--email=")
	case storedEmail != "":
		v.Email = storedEmail
	default:
		if v.Email, err = p.Value("email", "Email address to register with Let's Encrypt", "", ""); err != nil {
			return v, err
		}
		if err = CheckEmail(v.Email); err != nil {
			return v, err
		}
	}

	switch {
	case o.Auth != "":
		user, pass, err := SplitAuth(o.Auth)
		if err != nil {
			return v, err
		}
		if v.AuthEntry, err = hash(user, pass); err != nil {
			return v, err
		}
		v.AuthOrigin = "flag"
	case sharedErr != nil:
		return v, unreadableStack(o, "dynamic/_shared.yml", "--traefik-auth=")
	case storedAuth != "":
		v.AuthEntry, v.AuthOrigin = storedAuth, "reused"
	default:
		user, err := p.Value("traefik-auth", "Username for the dashboard at traefik."+v.Domain, "", "")
		if err != nil {
			return v, err
		}
		pass, err := p.Secret("traefik-auth", "Password for "+user, "")
		if err != nil {
			return v, err
		}
		if err = CheckAuthUser(user); err != nil {
			return v, err
		}
		if err = CheckAuthPass(pass); err != nil {
			return v, err
		}
		if v.AuthEntry, err = hash(user, pass); err != nil {
			return v, err
		}
		v.AuthOrigin = "prompt"
	}
	return v, nil
}

var reBcrypt = regexp.MustCompile(`:\$2[aby]\$[0-9]{2}\$`)

// Bcrypt is docs/cli.md's hashing: htpasswd from PATH, else from the
// httpd:2-alpine image, the password on stdin (-i), never in argv.
func Bcrypt(user, pass string) (string, error) {
	var cmd *exec.Cmd
	if _, err := exec.LookPath("htpasswd"); err == nil {
		cmd = exec.Command("htpasswd", "-niB", user)
	} else if _, err := exec.LookPath("docker"); err == nil {
		cmd = exec.Command("docker", "run", "--rm", "-i", "httpd:2-alpine", "htpasswd", "-niB", user)
	} else {
		return "", cli.Fail("cannot hash the dashboard password: no htpasswd on PATH, and no docker to borrow one from").Cont(
			"install apache2-utils (Debian/Ubuntu) or httpd-tools (RHEL), or make",
			"`docker run --rm httpd:2-alpine` work here")
	}
	cmd.Stdin = strings.NewReader(pass + "\n")
	var stdout bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, os.Stderr
	rc := 0
	if err := cmd.Run(); err != nil {
		rc = 1
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		}
	}
	line := strings.TrimSuffix(strings.TrimRight(stdout.String(), "\n"), "\r")
	u, _, _ := strings.Cut(line, ":")
	if rc != 0 || !reBcrypt.MatchString(line) || u != user || strings.Contains(line, "\n") {
		return "", cli.Fail("could not produce a bcrypt hash for the dashboard password (htpasswd exited %d)", rc).Cont(
			fmt.Sprintf("expected one line of '%s:$2y$..' — see htpasswd's own error above", user))
	}
	return line, nil
}

// Render renders the three templates under dir/traefik and parses each one:
// nothing unparseable reaches the server.
func Render(dir string, o Options, v Values) (map[string]string, error) {
	tdir := filepath.Join(dir, "traefik")
	if fi, err := os.Stat(tdir); err != nil || !fi.IsDir() {
		return nil, cli.Fail("the Traefik templates are missing (looked in %s) — this kasbah installation is incomplete", tdir)
	}
	subst := map[string]string{
		"APPS_PATH":        o.Apps,
		"DATA_PATH":        o.Data,
		"ACME_EMAIL":       v.Email,
		"ACME_CA":          v.Acme.CA,
		"DASHBOARD_DOMAIN": v.Domain,
		"DASHBOARD_AUTH":   v.AuthEntry,
		"TRAEFIK_IMAGE":    v.Image,
	}
	out := map[string]string{}
	for _, rel := range Files {
		src := filepath.Join(tdir, rel)
		tpl, err := os.ReadFile(src)
		if err != nil {
			if os.IsNotExist(err) {
				return nil, cli.Fail("the %s template %s is missing", rel, src)
			}
			return nil, cli.Fail("could not read %s", src)
		}
		s, err := tmpl.Render(string(tpl), rel, subst)
		if err != nil {
			return nil, err
		}
		if perr := tmpl.CheckYAML(s); perr != nil {
			user, _, _ := strings.Cut(v.AuthEntry, ":")
			return nil, cli.Fail("the rendered Traefik %s is not valid YAML — refusing to ship it", rel).Cont(
				perr.Error(),
				"a substituted value is the likely cause; this run rendered it with:",
				"  domain          "+v.Domain,
				"  acme email      "+v.Email,
				"  dashboard user  "+user,
				fmt.Sprintf("  apps / data     %s, %s", o.Apps, o.Data))
		}
		out[rel] = s
	}
	return out, nil
}
