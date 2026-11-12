package mail

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"slices"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/mailreg"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/tmpl"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// DKIMKey is one of dual signing's two keys, named as DMS's `setup config
// dkim` names it: <prefix><domain>.private.txt, .public.txt, .public.dns.txt.
type DKIMKey struct {
	Selector string
	Prefix   string
	// Kind is the key's type, which says how its public key is derived.
	Kind string
	// Args are rspamadm dkim_keygen's key type arguments.
	Args []string
}

// DKIMKeys are RSA then Ed25519, DKIMKeyNames' order.
var DKIMKeys = [2]DKIMKey{
	{Selector: "mail", Prefix: "rsa-2048-mail-", Kind: "rsa", Args: []string{"-b", "2048"}},
	{Selector: "ed", Prefix: "ed25519-ed-", Kind: "ed25519", Args: []string{"-t", "ed25519"}},
}

// Files are the key's private, public and DNS-record file names for domain.
func (k DKIMKey) Files(domain string) [3]string {
	b := k.Prefix + domain
	return [3]string{b + ".private.txt", b + ".public.txt", b + ".public.dns.txt"}
}

// DKIMPrev is where a render keeps the override it replaced.
func DKIMPrev(data string) string { return DKIMConf(data) + ".kasbah-prev" }

// The override as DMS mounts it, and the copy Rspamd reads, which DMS makes
// at start and on a change it detects.
const (
	DKIMConfMounted = "/tmp/docker-mailserver/rspamd/override.d/dkim_signing.conf"
	DKIMConfLive    = "/etc/rspamd/override.d/dkim_signing.conf"
)

// DNSRecord is a .public.dns.txt's body from rspamadm's zone-format public
// key, as DMS makes it: every line's first-to-last-quote span, quotes and
// line breaks dropped, one newline.
func DNSRecord(zone string) string {
	var b strings.Builder
	for _, l := range strings.Split(zone, "\n") {
		i, j := strings.Index(l, `"`), strings.LastIndex(l, `"`)
		if i >= 0 && j > i {
			b.WriteString(strings.ReplaceAll(l[i:j+1], `"`, ""))
		}
	}
	return b.String() + "\n"
}

// renderMark opens the override's first line, the sha256 of the rest: a file
// whose line still matches its body is kasbah's own render, unedited.
const renderMark = "# kasbah-render sha256:"

func stamped(body string) string {
	sum := sha256.Sum256([]byte(body))
	return renderMark + hex.EncodeToString(sum[:]) + "\n" + body
}

func ownRender(conf string) bool {
	_, rest, ok := strings.Cut(conf, "\n")
	return ok && stamped(rest) == conf
}

// RenderDKIM is the signing override for domains, in order, under its digest
// line: a block per domain with at least one selector in signed, which holds
// each domain's selectors whose private key is present.
func RenderDKIM(templates fs.FS, domains []string, signed map[string][]DKIMKey) (string, error) {
	b, err := fs.ReadFile(templates, "mail/rspamd-dkim-signing.conf")
	if err != nil {
		return "", cli.Fail("internal: this kasbah build carries no mail/rspamd-dkim-signing.conf template")
	}
	var blocks strings.Builder
	for _, d := range domains {
		keys := signed[d]
		if len(keys) == 0 {
			continue
		}
		fmt.Fprintf(&blocks, "    %s {\n        selectors [\n", d)
		for i, k := range keys {
			sep := ","
			if i == len(keys)-1 {
				sep = ""
			}
			fmt.Fprintf(&blocks, "            {\n                path = \"%s/%s\";\n                selector = \"%s\";\n            }%s\n",
				DKIMContainerDir, k.Files(d)[0], k.Selector, sep)
		}
		blocks.WriteString("        ]\n    }\n")
	}
	body, err := tmpl.Render(string(b), "mail rspamd-dkim-signing.conf", map[string]string{"MAIL_DKIM_DOMAINS": blocks.String()})
	if err != nil {
		return "", err
	}
	return stamped(body), nil
}

// dockerTimeout bounds every docker command but a pull.
var dockerTimeout = 2 * time.Minute

var errTimeout = errors.New("timed out")

// docker is one bounded docker command, its stderr the failure's text.
func docker(what string, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), dockerTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "docker", args...)
	cmd.WaitDelay = 5 * time.Second
	var o, e bytes.Buffer
	cmd.Stdout, cmd.Stderr = &o, &e
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("%s did not finish within %s (%w)", what, dockerTimeout, errTimeout)
		}
		msg := strings.TrimSpace(e.String())
		if msg == "" {
			msg = err.Error()
		}
		return nil, fmt.Errorf("%s failed: %s", what, msg)
	}
	return o.Bytes(), nil
}

// dmsImage is the image the server's mail compose file pins for mail-dms.
func dmsImage(apps string) (string, error) {
	f := apps + "/mail/compose.yml"
	docs, err := yamlx.LoadFile(f)
	if err != nil || len(docs) != 1 {
		return "", fmt.Errorf("could not read %s, which names the docker-mailserver image the keys are made with", f)
	}
	img := tree.TextAt(docs[0], "services", "mail-dms", "image")
	if img == "" {
		return "", fmt.Errorf("%s has no services.mail-dms.image, the docker-mailserver image the keys are made with", f)
	}
	return img, nil
}

// keyScript makes one key's three files under temp names in a DMS-image
// container as _rspamd (rspamadm, or derived from the private key), then
// hard-links each into place: a link never replaces a file. Args in Go below.
const keyScript = `set -euo pipefail
d=$1 b=$2 mode=$3 sel=$4 kind=$5
shift 5
t=$d/.kasbah-new-$b
tmp=("$t.private.txt" "$t.public.txt" "$t.public.dns.txt")
rm -f "${tmp[@]}"
trap 'rm -f "${tmp[@]}"' EXIT
there() { [ -e "$1" ] || [ -L "$1" ]; }
place() { ln -T "$1" "$2" 2>/dev/null && [ "$1" -ef "$2" ]; }
if [ "$mode" = generated ]; then
	rspamadm "$@" -k "$t.private.txt" >"$t.public.txt"
else
	k=$d/$b.private.txt
	case $kind in
	rsa)
		p=$(openssl pkey -in "$k" -pubout -outform DER | base64 -w0)
		{ printf '%s._domainkey IN TXT ( "v=DKIM1; k=rsa; "\n' "$sel"
		  { printf 'p=%s' "$p" | fold -w 255; echo; } | sed 's/.*/\t"&"/'
		  printf ') ; \n'; } >"$t.public.txt" ;;
	ed25519)
		[ "$(base64 -d "$k" | wc -c)" = 64 ] || { echo "$k is not an Ed25519 key rspamadm wrote" >&2; exit 1; }
		p=$(base64 -d "$k" | tail -c 32 | base64 -w0)
		printf '%s._domainkey IN TXT ( "v=DKIM1; k=ed25519;" \n\t"p=%s" ) ;\n' "$sel" "$p" >"$t.public.txt" ;;
	*) echo "unknown key type $kind" >&2; exit 1 ;;
	esac
fi
{ grep -o '".*"' "$t.public.txt" | tr -d '"\n' || true; echo; } >"$t.public.dns.txt"
grep -q 'p=.' "$t.public.dns.txt" || { echo "no public key in $(cat "$t.public.txt")" >&2; exit 1; }
if [ "$mode" = generated ]; then
	if there "$d/$b.public.txt" || there "$d/$b.public.dns.txt"; then echo dkim_key=partial; exit 0; fi
	if ! place "$t.private.txt" "$d/$b.private.txt"; then
		there "$d/$b.private.txt" || { echo "could not link $b.private.txt into $d" >&2; exit 1; }
		echo dkim_key=kept; exit 0
	fi
fi
for x in public.txt public.dns.txt; do
	place "$t.$x" "$d/$b.$x" || there "$d/$b.$x" || { echo "could not link $b.$x into $d" >&2; exit 1; }
done
echo "dkim_key=$mode"
`

// remoteDKIM makes the keys domains lack and renders the registry's override:
// a private key is never written over, missing public files are derived from
// it, and public files without their private key leave the key unmade.
func remoteDKIM(templates fs.FS, apps, data string, args []string, stdout, stderr io.Writer) error {
	regPath := mailreg.Path(apps)
	body, err := os.ReadFile(regPath)
	if err != nil {
		return fmt.Errorf("could not read %s", regPath)
	}
	reg, err := mailreg.Parse(body, regPath)
	if err != nil {
		return err
	}
	var domains []string
	for _, d := range args {
		if !reg.Serves(d) {
			return fmt.Errorf("%s does not list %s, so it has no DKIM keys to make", regPath, d)
		}
		if !slices.Contains(domains, d) {
			domains = append(domains, d)
		}
	}
	dir := DKIMDir(data)
	// A key file kasbah cannot see is one it could replace: any answer but
	// "absent" refuses the step before anything is made.
	there := map[string]bool{}
	for _, d := range slices.Concat(reg.Domains, domains) {
		for _, k := range DKIMKeys {
			for _, f := range k.Files(d) {
				_, err := os.Lstat(dir + "/" + f)
				switch {
				case err == nil:
					there[f] = true
				case !errors.Is(err, fs.ErrNotExist):
					var pe *fs.PathError
					if errors.As(err, &pe) {
						err = pe.Err
					}
					return fmt.Errorf("could not look for %s/%s (%v), so no DKIM key was made: a key kasbah cannot see is one it could replace", dir, f, err)
				}
			}
		}
	}
	type job struct {
		d    string
		i    int
		mode string
	}
	state := map[string][2]string{}
	var todo []job
	for _, d := range domains {
		var st [2]string
		for i, k := range DKIMKeys {
			f := k.Files(d)
			switch {
			case there[f[0]] && there[f[1]] && there[f[2]]:
				st[i] = "kept"
			case there[f[0]]:
				st[i] = "failed"
				todo = append(todo, job{d, i, "repaired"})
			case there[f[1]] || there[f[2]]:
				st[i] = "partial"
			default:
				st[i] = "failed"
				todo = append(todo, job{d, i, "generated"})
			}
		}
		state[d] = st
	}

	var failed error
	if len(todo) > 0 {
		img, err := dmsImage(apps)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return fmt.Errorf("could not create %s", dir)
		}
		if _, err := docker("docker image inspect "+img, "image", "inspect", img); err != nil {
			if errors.Is(err, errTimeout) {
				return err
			}
			pull := exec.Command("docker", "pull", "-q", img)
			pull.Stdout, pull.Stderr = stderr, stderr
			if pull.Run() != nil {
				return fmt.Errorf("could not pull %s, whose rspamadm makes the DKIM keys", img)
			}
		}
		// A named one-off container of that image, the key directory mounted
		// where DMS mounts it; a timed-out one is removed, so it cannot finish
		// writing after the step gave up.
		seq := 0
		run := func(what string, opts []string, args ...string) ([]byte, error) {
			seq++
			name := fmt.Sprintf("kasbah-dkim-%d-%d", os.Getpid(), seq)
			base := []string{"run", "--rm", "--name", name, "--network", "none", "-v", dir + ":" + DKIMContainerDir}
			out, err := docker(what, slices.Concat(base, opts, []string{img}, args)...)
			if errors.Is(err, errTimeout) {
				if _, rerr := docker("docker rm -f "+name, "rm", "-f", name); rerr != nil {
					err = fmt.Errorf("%v; %v, so it may still be running", err, rerr)
				}
			}
			return out, err
		}
		// DMS's own preflight: the key directory is _rspamd's.
		if _, err := run("chown _rspamd:_rspamd "+dir, []string{"--entrypoint", "chown"}, "_rspamd:_rspamd", DKIMContainerDir); err != nil {
			return err
		}
		for _, j := range todo {
			k := DKIMKeys[j.i]
			what := fmt.Sprintf("making the %s key of %s", k.Selector, j.d)
			if j.mode == "repaired" {
				what = fmt.Sprintf("deriving the public files of %s/%s from it", dir, k.Files(j.d)[0])
			}
			out, err := run(what, []string{"--user", "_rspamd", "--entrypoint", "bash"},
				slices.Concat([]string{"-c", keyScript, "bash", DKIMContainerDir, k.Prefix + j.d, j.mode, k.Selector, k.Kind,
					"dkim_keygen", "-s", k.Selector, "-d", j.d}, k.Args)...)
			got := remote.KV(out)["dkim_key"]
			if err == nil && got != j.mode && got != "kept" && got != "partial" {
				err = fmt.Errorf("%s reported dkim_key='%s'", what, got)
			}
			if err != nil {
				if j.mode == "repaired" {
					err = fmt.Errorf("%v — the private key is kept as it is, and its public files need the operator's hand", err)
				}
				failed = err
				break
			}
			st := state[j.d]
			st[j.i] = got
			state[j.d] = st
		}
	}
	for _, d := range domains {
		st := state[d]
		fmt.Fprintf(stdout, "mail_dkim_%s=%s %s\n", d, st[0], st[1])
	}
	if failed != nil {
		return failed
	}

	signed := map[string][]DKIMKey{}
	var unsigned []string
	for _, d := range reg.Domains {
		for _, k := range DKIMKeys {
			if _, regular := isFile(dir + "/" + k.Files(d)[0]); regular {
				signed[d] = append(signed[d], k)
			}
		}
		if len(signed[d]) == 0 {
			unsigned = append(unsigned, d)
		}
	}
	conf, err := RenderDKIM(templates, reg.Domains, signed)
	if err != nil {
		return err
	}
	path := DKIMConf(data)
	exists, regular := isFile(path)
	cstate := "written"
	switch {
	case exists && !regular:
		return fmt.Errorf("%s exists and is not a regular file", path)
	case regular:
		cur, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("could not read %s", path)
		}
		switch {
		case string(cur) == conf:
			cstate = "unchanged"
		case ownRender(string(cur)):
			cstate = "updated"
		default:
			if err := remote.Install(DKIMPrev(data), cur, 0o644); err != nil {
				return err
			}
			cstate = "replaced"
			fmt.Fprintf(stdout, "mail_dkim_prev=%s\n", DKIMPrev(data))
		}
	}
	if cstate != "unchanged" {
		if err := os.MkdirAll(data+"/mail/dms/config/rspamd/override.d", 0o777); err != nil {
			return fmt.Errorf("could not create %s", data+"/mail/dms/config/rspamd/override.d")
		}
		if err := remote.Install(path, []byte(conf), 0o644); err != nil {
			return err
		}
	}
	fmt.Fprintf(stdout, "mail_dkim_conf=%s\nmail_dkim_unsigned=%s\n", cstate, strings.Join(unsigned, " "))

	rspamd := "unchanged"
	if cstate != "unchanged" || len(todo) > 0 {
		rspamd = reloadRspamd(stderr)
	}
	fmt.Fprintf(stdout, "mail_dkim_rspamd=%s\nmail_dkim=done\n", rspamd)
	return nil
}

// reloadRspamd: a healthy DMS gets the override copied in and Rspamd restarted
// (as `setup config dkim` does); a running one is left to DMS's change
// detector; a stopped one reads override and keys when it starts.
func reloadRspamd(stderr io.Writer) string {
	h, err := inspect("mail-dms", "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{end}}")
	switch {
	case err != nil || !strings.HasPrefix(h, "running "):
		return "atstart"
	case h != "running healthy":
		return "detector"
	}
	for _, args := range [][]string{
		{"exec", "mail-dms", "cp", DKIMConfMounted, DKIMConfLive},
		{"exec", "mail-dms", "supervisorctl", "restart", "rspamd"},
	} {
		if _, err := docker("docker "+strings.Join(args, " "), args...); err != nil {
			fmt.Fprintf(stderr, "remote: %v\n", err)
			return "failed"
		}
	}
	return "restarted"
}

// DKIMFacts are the dkim step's report keys for the domains it was given.
func DKIMFacts(domains []string) []string {
	keys := []string{"mail_dkim", "mail_dkim_conf", "mail_dkim_unsigned", "mail_dkim_rspamd"}
	for _, d := range domains {
		keys = append(keys, "mail_dkim_"+d)
	}
	return keys
}

// DKIMSummary is the keys' and override's states, one line's worth: "keys
// generated, override written, rspamd restarted".
func DKIMSummary(f map[string]string, d string) string {
	st := strings.Fields(f["mail_dkim_"+d])
	keys := "keys " + strings.Join(st, "/")
	if len(st) == 2 && st[0] == st[1] {
		keys = "keys " + st[0]
	}
	words := map[string]string{"restarted": "rspamd restarted", "atstart": "rspamd reads it when docker-mailserver starts",
		"detector":  "docker-mailserver, up but not healthy yet, restarts rspamd onto it",
		"unchanged": "rspamd unchanged", "failed": "rspamd NOT restarted"}
	return fmt.Sprintf("%s, override %s, %s", keys, f["mail_dkim_conf"], words[f["mail_dkim_rspamd"]])
}

// DKIMWarn is what the dkim step's report leaves for the operator: an
// override that replaced one kasbah did not render, a key left unmade, a
// domain left unsigned, an Rspamd that did not restart.
func DKIMWarn(out *cli.Output, target, data string, domains []string, f map[string]string) {
	if p := f["mail_dkim_prev"]; p != "" {
		out.Warn("%s was not kasbah's last render (edited by hand, or an older kasbah's), and was replaced;", DKIMConf(data))
		out.Warn("the file it was is kept as %s (Rspamd never loads it)", p)
	}
	for _, d := range domains {
		for i, s := range strings.Fields(f["mail_dkim_"+d]) {
			if s == "partial" && i < len(DKIMKeys) {
				fl := DKIMKeys[i].Files(d)
				out.Warn("%s/%s is absent and %s or %s is there, so no %s key was made for %s", DKIMDir(data), fl[0], fl[1], fl[2], DKIMKeys[i].Selector, d)
				out.Warn("(kasbah never writes over a key file); move them aside and re-run")
			}
		}
	}
	if u := f["mail_dkim_unsigned"]; u != "" {
		out.Warn("no DKIM key for %s, so the signing override has no block for it: mail from it goes out unsigned", u)
	}
	if f["mail_dkim_rspamd"] == "failed" {
		out.Warn("Rspamd in mail-dms did not restart onto the new keys (see above); it reads them when docker-mailserver")
		out.Warn("next starts, or: ssh %s 'docker exec mail-dms supervisorctl restart rspamd'", target)
	}
}
