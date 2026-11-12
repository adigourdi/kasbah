package mail

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/adigourdi/kasbah/internal/remote"
)

// keygenDocker is a docker on PATH that does what the DMS image would: its
// bash container runs keyScript for real against the -v mount's host side,
// with an rspamadm that writes a real key; the log is every call.
func keygenDocker(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	script := `#!/bin/sh
s=` + dir + `
printf '%s\n' "$*" >> "$s/log"
case "$1" in
image) [ ! -f "$s/no_image" ] ;;
pull) rm -f "$s/no_image" ;;
inspect) [ -f "$s/dms_state" ] && cat "$s/dms_state" || exit 1 ;;
exec) [ ! -f "$s/exec_fails" ] || { echo 'OCI runtime exec failed' >&2; exit 1; } ;;
rm) ;;
run)
	src= dst= ent= prev=
	shift
	while [ $# -gt 0 ]; do
		a=$1; shift
		case "$prev" in
		-v) src=${a%%:*}; dst=${a#*:} ;;
		--entrypoint) ent=$a ;;
		esac
		prev=$a
		case "$a" in dms:*) break ;; esac
	done
	case "$ent" in
	chown) ;;
	bash)
		[ ! -f "$s/keygen_fails" ] || { echo 'rspamadm: boom' >&2; exit 1; }
		[ ! -f "$s/hang" ] || sleep 2
		script=$2; shift 3
		d=$1; shift
		[ "$d" = "$dst" ] && d=$src
		PATH="$s/bin:$PATH" exec bash -c "$script" bash "$d" "$@" ;;
	*) exit 9 ;;
	esac ;;
*) exit 9 ;;
esac
`
	rspamadm := `#!/bin/sh
k= t=rsa sel=
while [ $# -gt 0 ]; do
	case $1 in -k) k=$2; shift ;; -t) t=$2; shift ;; -s) sel=$2; shift ;; esac
	shift
done
[ ! -f ` + dir + `/race ] || printf 'OTHER\n' > "${k%/.kasbah-new-*}/${k##*/.kasbah-new-}"
case $t in
ed25519)
	head -c 64 /dev/urandom | base64 -w0 > "$k"
	printf '%s._domainkey IN TXT ( "v=DKIM1; k=ed25519;" \n\t"p=%s" ) ;\n' "$sel" "$(base64 -d "$k" | tail -c 32 | base64 -w0)" ;;
*)
	openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out "$k" 2>/dev/null
	printf '%s._domainkey IN TXT ( "v=DKIM1; k=rsa; "\n\t"p=%s"\n) ; \n' "$sel" "$(openssl pkey -in "$k" -pubout -outform DER | base64 -w0)" ;;
esac
`
	os.MkdirAll(dir+"/bin", 0o755)
	if os.WriteFile(dir+"/docker", []byte(script), 0o755) != nil || os.WriteFile(dir+"/bin/rspamadm", []byte(rspamadm), 0o755) != nil {
		t.Fatal("stubs")
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	return dir
}

func TestDNSRecord(t *testing.T) {
	rsa := "mail._domainkey IN TXT ( \"v=DKIM1; k=rsa; \"\n\t\"p=MIIB\"\n\t\"AQAB\"\n) ; \n"
	ed := "ed._domainkey IN TXT ( \"v=DKIM1; k=ed25519;\" \n\t\"p=qBa0=\" ) ;\n"
	if got := DNSRecord(rsa); got != "v=DKIM1; k=rsa; p=MIIBAQAB\n" {
		t.Errorf("rsa: %q", got)
	}
	if got := DNSRecord(ed); got != "v=DKIM1; k=ed25519;p=qBa0=\n" {
		t.Errorf("ed25519: %q", got)
	}
}

func TestRenderDKIM(t *testing.T) {
	conf, err := RenderDKIM(repoTemplates(t), []string{"a.com", "b.com", "c.com"},
		map[string][]DKIMKey{"a.com": DKIMKeys[:], "c.com": DKIMKeys[1:]})
	if err != nil {
		t.Fatal(err)
	}
	want := "domain {\n" +
		"    a.com {\n        selectors [\n" +
		"            {\n                path = \"/tmp/docker-mailserver/rspamd/dkim/rsa-2048-mail-a.com.private.txt\";\n                selector = \"mail\";\n            },\n" +
		"            {\n                path = \"/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-a.com.private.txt\";\n                selector = \"ed\";\n            }\n" +
		"        ]\n    }\n" +
		"    c.com {\n        selectors [\n" +
		"            {\n                path = \"/tmp/docker-mailserver/rspamd/dkim/ed25519-ed-c.com.private.txt\";\n                selector = \"ed\";\n            }\n" +
		"        ]\n    }\n}\n"
	if !strings.HasSuffix(conf, want) || strings.Contains(conf, "b.com") {
		t.Errorf("render:\n%s", conf)
	}
	// What M04 reads: both of a.com's keys listed, none of b.com's.
	if _, unlisted := DKIMGaps("a.com", nil, conf); len(unlisted) != 0 {
		t.Errorf("a.com unlisted %v", unlisted)
	}
	if _, unlisted := DKIMGaps("b.com", nil, conf); len(unlisted) != 2 {
		t.Errorf("b.com listed %v", unlisted)
	}
	if empty, _ := RenderDKIM(repoTemplates(t), []string{"a.com"}, nil); !strings.HasSuffix(empty, "domain {\n}\n") {
		t.Errorf("no keys:\n%s", empty)
	}
}

func TestRemoteDKIM(t *testing.T) {
	root := t.TempDir()
	apps, data := root+"/apps", root+"/apps/data"
	os.MkdirAll(apps+"/mail", 0o755)
	os.MkdirAll(data+"/mail/dms/config/rspamd/override.d", 0o755)
	registry := func(domains ...string) {
		os.WriteFile(apps+"/mail/kasbah.yml", []byte("name: mail\nprimary_domain: a.com\ndomains:\n  - "+strings.Join(domains, "\n  - ")+"\n"), 0o644)
	}
	registry("a.com", "b.com")
	os.WriteFile(apps+"/mail/compose.yml", []byte("services:\n  mail-dms:\n    image: dms:1.2.3\n"), 0o644)
	d := keygenDocker(t)
	os.WriteFile(d+"/no_image", nil, 0o644)
	dir, conf := DKIMDir(data), DKIMConf(data)
	read := func(f string) string { b, _ := os.ReadFile(f); return string(b) }
	step := func(what string, args ...string) (map[string]string, string, string) {
		t.Helper()
		os.Remove(d + "/log")
		o, e, rc := run(t, "", append([]string{"dkim", apps, data}, args...)...)
		if rc != 0 {
			t.Fatalf("%s: rc %d\n%s%s%s", what, rc, o, e, read(d+"/log"))
		}
		if m, _ := filepath.Glob(dir + "/.kasbah-new-*"); len(m) != 0 {
			t.Errorf("%s: temp files left %v", what, m)
		}
		return remote.KV([]byte(o)), e, read(d + "/log")
	}

	// The primary's keys: pulled, made, the override names a.com alone.
	kv, _, log := step("primary", "a.com")
	if kv["mail_dkim_a.com"] != "generated generated" || kv["mail_dkim_conf"] != "written" || kv["mail_dkim_unsigned"] != "b.com" ||
		kv["mail_dkim_rspamd"] != "atstart" || kv["mail_dkim"] != "done" || kv["mail_dkim_prev"] != "" {
		t.Errorf("primary: %v", kv)
	}
	for _, w := range []string{"image inspect dms:1.2.3\npull -q dms:1.2.3\n",
		" --network none -v " + dir + ":" + DKIMContainerDir + " --entrypoint chown dms:1.2.3 _rspamd:_rspamd " + DKIMContainerDir + "\n",
		"run --rm --name kasbah-dkim-",
		" " + DKIMContainerDir + " rsa-2048-mail-a.com generated mail rsa dkim_keygen -s mail -d a.com -b 2048\n",
		" " + DKIMContainerDir + " ed25519-ed-a.com generated ed ed25519 dkim_keygen -s ed -d a.com -t ed25519\n"} {
		if !strings.Contains(log, w) {
			t.Errorf("no %q in\n%s", w, log)
		}
	}
	if !strings.Contains(log, "--user _rspamd --entrypoint bash dms:1.2.3 -c set -euo pipefail") {
		t.Errorf("keys not made by keyScript as _rspamd:\n%s", log)
	}
	for _, k := range DKIMKeys {
		f := k.Files("a.com")
		if pub, dns := read(dir+"/"+f[1]), read(dir+"/"+f[2]); dns != DNSRecord(pub) || !strings.HasPrefix(dns, "v=DKIM1; k="+k.Kind+";") || read(dir+"/"+f[0]) == "" {
			t.Errorf("%s: public %q dns %q", k.Selector, pub, dns)
		}
	}
	c := read(conf)
	if !strings.Contains(c, "rsa-2048-mail-a.com.private.txt") || strings.Contains(c, "b.com {") || mode(t, conf) != 0o644 ||
		!strings.HasPrefix(c, renderMark) || !ownRender(c) {
		t.Errorf("override:\n%s", c)
	}
	rsaKey, edPub := read(dir+"/rsa-2048-mail-a.com.private.txt"), read(dir+"/ed25519-ed-a.com.public.txt")

	// A second domain, DMS healthy: its block joins, Rspamd restarts, and the
	// override kasbah rendered last is replaced with no copy kept.
	os.WriteFile(d+"/dms_state", []byte("running healthy\n"), 0o644)
	kv, _, log = step("second", "b.com")
	if kv["mail_dkim_b.com"] != "generated generated" || kv["mail_dkim_conf"] != "updated" || kv["mail_dkim_unsigned"] != "" ||
		kv["mail_dkim_rspamd"] != "restarted" || kv["mail_dkim_prev"] != "" || strings.Contains(log, "pull") {
		t.Errorf("second: %v\n%s", kv, log)
	}
	if !strings.Contains(log, "exec mail-dms cp "+DKIMConfMounted+" "+DKIMConfLive+"\nexec mail-dms supervisorctl restart rspamd\n") {
		t.Errorf("no reload in\n%s", log)
	}
	if _, err := os.Lstat(DKIMPrev(data)); err == nil {
		t.Error("a routine render saved a -prev copy")
	}
	c = read(conf)
	if !strings.Contains(c, "    a.com {") || !strings.Contains(c, "    b.com {") || strings.Index(c, "a.com {") > strings.Index(c, "b.com {") {
		t.Errorf("override:\n%s", c)
	}

	// A re-run, a domain named twice: no container, no restart, the keys untouched.
	kv, _, log = step("re-run", "a.com", "b.com", "a.com")
	if kv["mail_dkim_a.com"] != "kept kept" || kv["mail_dkim_b.com"] != "kept kept" || kv["mail_dkim_conf"] != "unchanged" ||
		kv["mail_dkim_rspamd"] != "unchanged" || log != "" {
		t.Errorf("re-run: %v\n%s", kv, log)
	}
	if read(dir+"/rsa-2048-mail-a.com.private.txt") != rsaKey {
		t.Error("a key was rewritten")
	}

	// A hand edit is replaced and kept; a failed restart is a warning, not a failure.
	os.WriteFile(conf, []byte("hand edit\n"), 0o644)
	os.WriteFile(d+"/exec_fails", nil, 0o644)
	kv, e, _ := step("hand edit", "a.com")
	if kv["mail_dkim_conf"] != "replaced" || kv["mail_dkim_prev"] != DKIMPrev(data) || kv["mail_dkim_rspamd"] != "failed" || !strings.Contains(e, "OCI runtime exec failed") {
		t.Errorf("hand edit: %v %q", kv, e)
	}
	if prev := read(DKIMPrev(data)); prev != "hand edit\n" {
		t.Errorf("prev %q", prev)
	}

	// Public files without their private key: never written over, no block.
	// DMS up but not healthy: its change detector is left to restart Rspamd.
	// The -prev copy of the hand edit outlives the next render.
	os.WriteFile(dir+"/rsa-2048-mail-c.com.public.txt", []byte("old\n"), 0o644)
	os.WriteFile(d+"/dms_state", []byte("running starting\n"), 0o644)
	registry("a.com", "b.com", "c.com")
	kv, _, log = step("partial", "c.com")
	if kv["mail_dkim_c.com"] != "partial generated" || kv["mail_dkim_conf"] != "updated" || kv["mail_dkim_rspamd"] != "detector" || strings.Contains(log, "exec") {
		t.Errorf("partial: %v\n%s", kv, log)
	}
	c = read(conf)
	if read(dir+"/rsa-2048-mail-c.com.public.txt") != "old\n" || strings.Contains(c, "rsa-2048-mail-c.com") || !strings.Contains(c, "ed25519-ed-c.com.private.txt") {
		t.Errorf("partial wrote over a key or signed with it:\n%s", c)
	}
	if read(DKIMPrev(data)) != "hand edit\n" {
		t.Error("a routine render overwrote the -prev copy")
	}

	// A private key without its public files: they are derived from it, the
	// key itself untouched.
	os.Remove(dir + "/ed25519-ed-a.com.public.txt")
	os.Remove(dir + "/ed25519-ed-a.com.public.dns.txt")
	edKey := read(dir + "/ed25519-ed-a.com.private.txt")
	kv, _, log = step("repair", "a.com")
	if kv["mail_dkim_a.com"] != "kept repaired" || !strings.Contains(log, " ed25519-ed-a.com repaired ed ed25519 ") ||
		read(dir+"/ed25519-ed-a.com.private.txt") != edKey || read(dir+"/ed25519-ed-a.com.public.txt") != edPub ||
		read(dir+"/ed25519-ed-a.com.public.dns.txt") != DNSRecord(edPub) {
		t.Errorf("repair: %v %q\n%s", kv, read(dir+"/ed25519-ed-a.com.public.txt"), log)
	}
	os.Remove(dir + "/rsa-2048-mail-a.com.public.dns.txt")
	if kv, _, _ = step("repair rsa", "a.com"); kv["mail_dkim_a.com"] != "repaired kept" || read(dir+"/rsa-2048-mail-a.com.private.txt") != rsaKey ||
		read(dir+"/rsa-2048-mail-a.com.public.dns.txt") != DNSRecord(read(dir+"/rsa-2048-mail-a.com.public.txt")) {
		t.Errorf("repair rsa: %v", kv)
	}

	// A private key that appears while its key is made is kept, the new one discarded.
	registry("a.com", "e.com")
	os.WriteFile(d+"/race", nil, 0o644)
	kv, _, _ = step("race", "e.com")
	os.Remove(d + "/race")
	if kv["mail_dkim_e.com"] != "kept kept" || read(dir+"/rsa-2048-mail-e.com.private.txt") != "OTHER\n" {
		t.Errorf("race: %v", kv)
	}

	// Refusals: a domain the registry lacks; a key directory kasbah cannot
	// look into, before any container; a keygen that hangs, its container
	// removed; a failed keygen (reported, then the failure).
	if _, e, rc := run(t, "", "dkim", apps, data, "z.com"); rc != 1 || !strings.Contains(e, "does not list z.com") {
		t.Errorf("unlisted: %q", e)
	}
	registry("a.com", "d.com")
	os.Rename(dir, dir+".real")
	os.WriteFile(dir, nil, 0o644)
	os.Remove(d + "/log")
	if _, e, rc := run(t, "", "dkim", apps, data, "d.com"); rc != 1 || !strings.Contains(e, "could not look for "+dir+"/rsa-2048-mail-a.com.private.txt (not a directory), so no DKIM key was made") || read(d+"/log") != "" {
		t.Errorf("unreadable key directory: %q\n%s", e, read(d+"/log"))
	}
	os.Remove(dir)
	os.Rename(dir+".real", dir)
	defer func(t time.Duration) { dockerTimeout = t }(dockerTimeout)
	dockerTimeout = 500 * time.Millisecond
	os.WriteFile(d+"/hang", nil, 0o644)
	if o, e, rc := run(t, "", "dkim", apps, data, "d.com"); rc != 1 || !strings.Contains(e, "making the mail key of d.com did not finish within 500ms") ||
		!strings.Contains(read(d+"/log"), "rm -f kasbah-dkim-") || !strings.Contains(o, "mail_dkim_d.com=failed failed") {
		t.Errorf("hung keygen: %q %q\n%s", o, e, read(d+"/log"))
	}
	os.Remove(d + "/hang")
	dockerTimeout = time.Minute
	os.WriteFile(d+"/keygen_fails", nil, 0o644)
	if o, e, rc := run(t, "", "dkim", apps, data, "d.com"); rc != 1 || !strings.Contains(e, "rspamadm: boom") || !strings.Contains(o, "mail_dkim_d.com=failed failed") {
		t.Errorf("keygen failure: %q %q", o, e)
	}
	if _, err := os.Lstat(dir + "/rsa-2048-mail-d.com.private.txt"); err == nil {
		t.Error("a failed keygen left a key")
	}
}
