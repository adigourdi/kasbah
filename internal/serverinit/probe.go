package serverinit

import (
	"fmt"
	"regexp"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/rootsteps"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// probeScript is the bootstrap read: every fact the verdicts need, before
// the apps path — and so the server binary — may exist. POSIX sh, read-only,
// always exit 0; the verdicts are the workstation's.
const probeScript = `set -u
export LC_ALL=C
apps=$1
data=$2
pointer=$3
cr=$(printf '\r')
nl='
'
uid=$(id -u)

kv() {
    kv_v=$2
    while :; do
        case $kv_v in
            *' ') kv_v=${kv_v% } ;;
            *) break ;;
        esac
    done
    printf '%s=%s\n' "$1" "$kv_v"
}
flat() { tr -d '\r' | tr '\n' ' '; }

kv user "$(id -un)"
kv group "$(id -gn)"

if command -v docker >/dev/null 2>&1; then kv have_docker yes; else kv have_docker no; fi
docker_out=$(docker version --format '{{.Server.Version}}' 2>&1); docker_rc=$?
if [ "$docker_rc" -eq 0 ]; then
    kv docker_server "$(printf '%s' "$docker_out" | flat)"
    kv docker_error ""
else
    kv docker_server ""
    kv docker_error "$(printf '%s' "$docker_out" | flat)"
fi
kv compose_version "$(docker compose version --short 2>/dev/null | flat)"

if sudo -n true >/dev/null 2>&1; then sudo_ok=yes; else sudo_ok=no; fi
kv sudo_nopasswd "$sudo_ok"

# Always called in $(…): its variables, IFS and set -f end with the subshell.
norm_path() {
    p=${1%"$cr"}
    while :; do
        case $p in
            *' '|*'	') p=${p%?} ;;
            *) break ;;
        esac
    done
    case $p in
        /*) ;;
        *) printf '%s' "$p"; return 0 ;;
    esac
    out=""
    IFS=/
    set -f
    for seg in $p; do
        [ -n "$seg" ] && [ "$seg" != . ] || continue
        out="$out/$seg"
    done
    [ -n "$out" ] || out=/
    printf '%s' "$out"
}

# Root's eyes when this user's will not do: a pointer behind a directory this
# user cannot enter, or one only root can read, is not "no pointer".
pointer_dir=${pointer%/*}
pointer_state=absent
pointer_value=""
if [ -e "$pointer" ] && [ ! -f "$pointer" ]; then
    pointer_state=notfile
elif [ -f "$pointer" ]; then
    pointer_state=present
    if [ -r "$pointer" ]; then
        IFS= read -r pointer_value < "$pointer" || [ -n "$pointer_value" ] || pointer_value=""
    elif [ "$sudo_ok" = yes ]; then
        pointer_value=$(sudo -n cat "$pointer" 2>/dev/null) || pointer_value=""
        pointer_value=${pointer_value%%"$nl"*}
        [ -n "$pointer_value" ] || pointer_state=unreadable
    else
        pointer_state=unreadable
    fi
elif [ -d "$pointer_dir" ] && [ ! -x "$pointer_dir" ]; then
    if [ "$sudo_ok" = yes ] && sudo -n test -e "$pointer" 2>/dev/null; then
        if sudo -n test -f "$pointer" 2>/dev/null; then
            pointer_state=present
            pointer_value=$(sudo -n cat "$pointer" 2>/dev/null) || pointer_value=""
            pointer_value=${pointer_value%%"$nl"*}
            [ -n "$pointer_value" ] || pointer_state=unreadable
        else
            pointer_state=notfile
        fi
    elif [ "$sudo_ok" != yes ]; then
        pointer_state=unreachable
    fi
fi
pointer_value=$(norm_path "$pointer_value")
kv pointer_state "$pointer_state"
kv pointer_value "$pointer_value"

path_state() {
    if [ -L "$1" ] && [ ! -e "$1" ]; then printf dangling
    elif [ ! -e "$1" ];              then printf absent
    elif [ -d "$1" ];                then printf dir
    else                                  printf notdir
    fi
}

nearest_visible() {
    p=$1
    while [ ! -e "$p" ] && [ "$p" != / ]; do
        p=${p%/*}
        [ -n "$p" ] || p=/
    done
    printf '%s' "$p"
}

apps_state=$(path_state "$apps")
apps_base=$(nearest_visible "$apps")

# Absent to this user is asked again of root: a directory behind a wall this
# user cannot cross answers -e with no, and the chown that follows is root's.
apps_root_state=unknown
apps_root_owner=""
if [ "$apps_state" = absent ] && [ "$sudo_ok" = yes ]; then
    if sudo -n test -e "$apps" 2>/dev/null; then
        apps_root_state=exists
        apps_root_owner=$(sudo -n stat -c '%U:%G' "$apps" 2>/dev/null | flat)
    else
        apps_root_state=absent
    fi
fi
if [ "$apps_state" = absent ]; then
    if [ "$apps_root_state" = exists ]; then
        apps_state=unreachable
    elif [ "$apps_base" != "$apps" ] && [ ! -x "$apps_base" ]; then
        apps_state=unreachable
    fi
fi

kv apps_state "$apps_state"
kv apps_root_state "$apps_root_state"
kv apps_root_owner "$apps_root_owner"
kv apps_base "$apps_base"
kv apps_base_owner "$(stat -c '%U:%G' "$apps_base" 2>/dev/null | flat)"
kv apps_base_mode "$(stat -c '%a' "$apps_base" 2>/dev/null | flat)"

if [ "$(stat -L -c '%u' "$apps" 2>/dev/null)" = "$uid" ]; then kv apps_owned yes; else kv apps_owned no; fi
if [ -w "$apps" ] && [ -x "$apps" ]; then kv apps_writable yes; else kv apps_writable no; fi
kv apps_owner "$(stat -c '%U:%G' "$apps" 2>/dev/null | flat)"
kv apps_group "$(stat -L -c '%G' "$apps" 2>/dev/null | flat)"
if [ -f "$apps/.kasbah/server.json" ]; then kv apps_marker yes; else kv apps_marker no; fi
# The group database's answer, and this session's: usermod reaches new logins only.
case " $(id -nG "$(id -un)" 2>/dev/null) " in *" kasbah "*) kv kasbah_member yes ;; *) kv kasbah_member no ;; esac
case " $(id -nG 2>/dev/null) " in *" kasbah "*) kv kasbah_session yes ;; *) kv kasbah_session no ;; esac

# A read-only mount and a stripped mode are the same -w and want opposite
# advice; only the errno tells them apart.
apps_write_error=""
if [ "$apps_state" = dir ] && [ "$(stat -L -c '%u' "$apps" 2>/dev/null)" = "$uid" ] && [ ! -w "$apps" ]; then
    apps_write_error=$(touch "$apps/.kasbah-write-probe" 2>&1 | flat)
    rm -f "$apps/.kasbah-write-probe" 2>/dev/null
fi
kv apps_write_error "$apps_write_error"

kv data_state "$(path_state "$data")"
if [ -w "$data" ] && [ -x "$data" ]; then kv data_writable yes; else kv data_writable no; fi
kv data_owner "$(stat -c '%U:%G' "$data" 2>/dev/null | flat)"
case $data in
    "$apps"|"$apps"/*) kv data_scope inside ;;
    *)                 kv data_scope outside ;;
esac
base=$(nearest_visible "$data")
kv data_base "$base"
if [ -w "$base" ] && [ -x "$base" ]; then kv data_base_writable yes; else kv data_base_writable no; fi

# Whether there are certificates to lose: the one fact about the store every
# ACME decision turns on. Read here because a data path outside an absent apps
# path can hold one.
acme="$data/traefik/letsencrypt/acme.json"
if   [ ! -e "$acme" ]; then kv acme_store absent
elif [ ! -f "$acme" ]; then kv acme_store notfile
elif [ -s "$acme" ];  then kv acme_store nonempty
else                       kv acme_store empty
fi

kv nproc "$(nproc 2>/dev/null | flat)"
memtotal_kb=""
while read -r field value _; do
    if [ "$field" = "MemTotal:" ]; then memtotal_kb=$value; break; fi
done < /proc/meminfo
kv memtotal_kb "$memtotal_kb"

exit 0
`

var probeKeys = []string{"user", "group", "have_docker", "docker_server", "docker_error",
	"compose_version", "sudo_nopasswd",
	"pointer_state", "pointer_value",
	"apps_state", "apps_owned", "apps_writable", "apps_owner", "apps_group", "apps_marker", "kasbah_member", "kasbah_session", "apps_write_error",
	"apps_root_state", "apps_root_owner", "apps_base", "apps_base_owner", "apps_base_mode",
	"data_state", "data_writable", "data_owner", "data_scope", "data_base", "data_base_writable",
	"acme_store", "nproc", "memtotal_kb"}

// Facts is a remote step's key=value report.
type Facts map[string]string

// absorb reads key=value lines, CR stripped; lines without `=` are not facts.
func absorb(f Facts, out string) {
	for k, v := range remote.KV([]byte(out)) {
		f[k] = v
	}
}

// checked fails naming every key that never arrived, with the raw output: a
// missing fact must not read as an empty one.
func checked(what, target, out string, keys ...string) (Facts, error) {
	f := Facts{}
	absorb(f, out)
	var missing []string
	for _, k := range keys {
		if _, ok := f[k]; !ok {
			missing = append(missing, k)
		}
	}
	if len(missing) == 0 {
		return f, nil
	}
	e := cli.Fail("%s on %s reported no %s", what, target, strings.Join(missing, " ")).Cont(
		"the step was truncated, or the remote shell rejected it — raw output:")
	for _, l := range strings.Split(strings.TrimSuffix(out, "\n"), "\n") {
		e.Cont("| " + l)
	}
	return nil, e
}

// ParseProbe validates the probe's key set as a protocol.
func ParseProbe(target, out string) (Facts, error) {
	if out == "" {
		return nil, cli.Fail("the prerequisite probe on %s succeeded and reported nothing (its output was lost, or the login shell swallowed it)", target)
	}
	f, err := checked("the prerequisite probe", target, out, probeKeys...)
	if err != nil {
		err.(*cli.Error).Lines[1] = "the probe was truncated, or the remote shell rejected it — raw output:"
		return nil, err
	}
	switch f["acme_store"] {
	case "absent", "notfile", "empty", "nonempty":
	default:
		return nil, cli.Fail("the prerequisite probe on %s reported acme_store='%s', which this kasbah does not know", target, f["acme_store"])
	}
	return f, nil
}

var reInt = regexp.MustCompile(`^[1-9][0-9]*$`)

// major is a version's leading component, a `v` prefix dropped.
func major(v string) string {
	v = strings.TrimPrefix(v, "v")
	m, _, _ := strings.Cut(v, ".")
	return m
}

// below is `! [[ m =~ ^[0-9]+$ ]] || [ m -lt n ]`.
func below(m string, n int64) bool {
	if m == "" || strings.Trim(m, "0123456789") != "" {
		return true
	}
	v, err := strconv.ParseInt(m, 10, 64)
	return err == nil && v < n
}

// Preflight is every row of the prerequisites table judged at once: a server
// three rows short costs one round trip, not three. An apps path only root can
// create is a row only when nothing can wait for the operator to create it.
func Preflight(f Facts, target, apps, data string, wait bool) error {
	var rows []string
	user := f["user"]
	owner := user + ":" + f["group"]
	add := func(l ...string) { rows = append(rows, l...) }

	switch {
	case f["have_docker"] != "yes":
		add("Docker >= 24 — no docker command on the remote.",
			"  Install Docker Engine: https://docs.docker.com/engine/install/")
	case f["docker_server"] == "":
		add(fmt.Sprintf("the SSH user can run docker without sudo — `docker version` failed as %s.", user),
			"  "+f["docker_error"],
			fmt.Sprintf("  sudo usermod -aG docker %s   (then open a new session)", user))
	case below(major(f["docker_server"]), 24):
		add(fmt.Sprintf("Docker >= 24 — the daemon reports %s.", f["docker_server"]),
			"  Upgrade Docker Engine: https://docs.docker.com/engine/install/")
	}

	switch cv := f["compose_version"]; {
	case cv == "":
		add("Docker Compose v2 — `docker compose version` produced nothing.",
			"  The compose plugin is missing: install docker-compose-plugin.")
	case below(major(cv), 2):
		add(fmt.Sprintf("Docker Compose v2 — the plugin reports %s.", cv),
			"  kasbah's compose files need include: and v2 syntax.")
	}

	switch f["apps_state"] {
	case "absent":
		if f["sudo_nopasswd"] != "yes" && !wait {
			add(fmt.Sprintf("passwordless sudo — `sudo -n true` failed as %s.", user),
				fmt.Sprintf("  %s does not exist, and it lives outside the deploy user's home,", apps),
				"  so only root can create it. Run these once and re-run init — or run init",
				"  from a terminal, where it waits while you do:")
			for _, l := range AppsBlock(f, target, apps).Lines() {
				add("  " + l)
			}
		}
	case "dangling":
		add(apps+" is a symlink to nothing.",
			"  Point it somewhere or remove it — `mkdir -p` fails on it with",
			"  \"File exists\", which is not a diagnosis anybody enjoys.")
	case "unreachable":
		if f["apps_root_state"] == "exists" {
			add(fmt.Sprintf("%s exists and belongs to %s, and %s cannot see it.", apps, f["apps_root_owner"], user),
				"  Only root can, which is why this is a refusal: kasbah would have to take the",
				"  directory over to use it, and it never takes over one it did not create.")
		} else {
			add(fmt.Sprintf("%s cannot be reached by %s.", apps, user),
				fmt.Sprintf("  %s is not traversable by them (owner %s, mode %s),", f["apps_base"], f["apps_base_owner"], f["apps_base_mode"]),
				fmt.Sprintf("  so kasbah cannot even tell whether %s exists.", apps))
		}
		add(fmt.Sprintf("  Everything below the apps path is written as %s, so a path they cannot", user),
			"  enter is no use even once it exists. Pick one they can, with --apps-path=<dir>.")
	case "notdir":
		add(apps+" exists and is not a directory.",
			"  Remove it, or point init elsewhere with --apps-path=<dir>.")
	case "dir":
		switch {
		case f["apps_owned"] != "yes" && SharedApps(f):
			// Another operator's server, handed to the group: shared.
		case f["apps_owned"] != "yes" && f["apps_marker"] == "yes":
			add(operatorRows(f, target, apps)...)
		case f["apps_owned"] != "yes":
			add(fmt.Sprintf("%s already exists and belongs to %s, not %s.", apps, f["apps_owner"], user),
				"  kasbah only elevates to create the apps path; it never takes over one",
				"  it did not create, because everything below would end up in mixed",
				"  ownership. If this path really is meant for kasbah, hand it over:",
				fmt.Sprintf("  ssh %s 'sudo chown %s %s'", target, owner, apps))
		case f["apps_writable"] != "yes":
			if strings.Contains(f["apps_write_error"], "Read-only file system") {
				add(fmt.Sprintf("%s belongs to %s and is on a read-only filesystem.", apps, user),
					"  "+f["apps_write_error"],
					"  No mode change fixes that: remount it read-write, or pick another",
					"  path with --apps-path=<dir>.")
			} else {
				add(fmt.Sprintf("%s belongs to %s but is not writable by them.", apps, user),
					fmt.Sprintf("  ssh %s 'chmod u+rwx %s'", target, apps))
			}
		}
	}

	switch f["data_state"] {
	case "dangling":
		add(fmt.Sprintf("the data path %s is a symlink to nothing.", data),
			"  Point it somewhere or remove it.")
	case "notdir":
		add(fmt.Sprintf("the data path %s exists and is not a directory.", data),
			"  Remove it, or point init elsewhere with --data-path=<dir>.")
	case "dir":
		if f["data_writable"] != "yes" && f["apps_owned"] != "yes" && f["apps_marker"] == "yes" {
			if SharedApps(f) {
				add(fmt.Sprintf("the data path %s is %s's and not writable through the '%s' group.", data, f["data_owner"], serverlock.Group),
					fmt.Sprintf("  A run of `kasbah server init` by its owner hands %s to the group.", data))
			}
		} else if f["data_writable"] != "yes" {
			add(fmt.Sprintf("the data path %s exists and is not writable by %s (owner %s).", data, user, f["data_owner"]),
				fmt.Sprintf("  ssh %s 'sudo chown %s %s'", target, owner, data))
		}
	case "absent":
		if f["data_scope"] == "outside" && f["data_base_writable"] != "yes" {
			add(fmt.Sprintf("the data path %s cannot be created: %s is not writable by %s.", data, f["data_base"], user),
				fmt.Sprintf("  It sits outside %s, so kasbah cannot get there unelevated. Create it once:", apps),
				fmt.Sprintf("  ssh %s 'sudo mkdir -p %s && sudo chown %s %s'", target, data, owner, data))
		}
	}

	if !reInt.MatchString(f["nproc"]) {
		add(fmt.Sprintf("resource limits — the remote reported nproc='%s'.", f["nproc"]),
			"  The marker's cpu_limit is 90% of that and cannot be computed.")
	}
	if !reInt.MatchString(f["memtotal_kb"]) {
		add(fmt.Sprintf("resource limits — /proc/meminfo reported MemTotal='%s'.", f["memtotal_kb"]),
			"  The marker's mem_limit is 90% of that and cannot be computed.")
	}

	if len(rows) == 0 {
		return nil
	}
	e := cli.Fail("%s does not meet the prerequisites for kasbah server init:", target).Cont(rows...)
	return e.Cont("kasbah checks prerequisites and never installs them — see docs/server-setup.md")
}

// SharedApps is a kasbah server another operator prepared and handed to the
// group, writable by this user through it.
func SharedApps(f Facts) bool {
	return f["apps_marker"] == "yes" && f["apps_group"] == serverlock.Group && f["apps_writable"] == "yes"
}

// operatorRows is the refusal for another operator's server this user cannot
// write: join the group, never take the tree over.
func operatorRows(f Facts, target, apps string) []string {
	user, g := f["user"], serverlock.Group
	head := fmt.Sprintf("%s is the kasbah server %s prepared, and %s cannot write it.", apps, f["apps_owner"], user)
	switch {
	case f["apps_group"] != g:
		return []string{head,
			fmt.Sprintf("  It is not the '%s' group's yet: %s's own `kasbah server init %s`", g, strings.SplitN(f["apps_owner"], ":", 2)[0], target),
			"  hands it to the group. Then add yourself, and re-run:",
			fmt.Sprintf("  ssh %s 'sudo usermod -aG %s %s'", target, g, user)}
	case f["kasbah_member"] == "yes" && f["kasbah_session"] != "yes":
		return []string{head,
			fmt.Sprintf("  %s is in the '%s' group, but this ssh session began before that:", user, g),
			"  a re-run opens a new one, which has it. Re-run init."}
	}
	return []string{head,
		fmt.Sprintf("  Every operator works as their own user in the '%s' group — join it, then re-run", g),
		"  (a new ssh session picks the group up; kasbah never takes the tree over):",
		fmt.Sprintf("  ssh %s 'sudo usermod -aG %s %s'", target, g, user)}
}

// AppsBlock is what root runs to create the apps path and hand it to the SSH
// user, from the state the probe found it in: nothing when there is no such work.
func AppsBlock(f Facts, target, apps string) *rootsteps.Block {
	b := &rootsteps.Block{Target: target, User: f["user"]}
	owner := rootsteps.Quote(f["user"] + ":" + f["group"])
	q := rootsteps.Quote(apps)
	switch {
	case f["apps_state"] == "absent":
		parent := apps[:strings.LastIndex(apps, "/")]
		if parent == "" {
			parent = "/"
		}
		if f["apps_base"] != parent {
			b.Add("sudo mkdir -p " + rootsteps.Quote(parent))
		}
		b.Add("sudo mkdir "+q, "sudo chown "+owner+" "+q)
	case f["apps_state"] == "dir" && f["apps_owned"] != "yes" && f["apps_marker"] != "yes":
		b.Add("sudo chown " + owner + " " + q)
	}
	return b
}

// PointerDirBlock makes the pointer's directory traversable again.
func PointerDirBlock(f Facts, target string) *rootsteps.Block {
	b := &rootsteps.Block{Target: target, User: f["user"]}
	if f["pointer_state"] == "unreachable" {
		b.Add("sudo chmod 755 " + rootsteps.Quote(pointerPath[:strings.LastIndex(pointerPath, "/")]))
	}
	return b
}

// CheckPointer refuses a server whose pointer records another apps path, or
// one that cannot be told: one server runs one kasbah, because one Traefik
// holds :80 and :443.
func CheckPointer(f Facts, target, apps string) error {
	dir := Pointer[:strings.LastIndex(Pointer, "/")]
	value := f["pointer_value"]
	switch f["pointer_state"] {
	case "absent":
		return nil
	case "notfile":
		return cli.Fail("%s on %s exists and is not a regular file", Pointer, target).Cont(
			"that path is the server's record of where it was prepared, and kasbah",
			"writes one absolute path there. Look at it, remove it, and re-run.")
	case "unreachable":
		return cli.Fail("%s on %s cannot be entered by %s, and there is no sudo to look with", dir, target, f["user"]).Cont(
			"so whether this server already records an apps path cannot be told, and",
			fmt.Sprintf("this run would prepare %s. If the two differ that stands a second", apps),
			"Traefik beside the one already holding :80 and :443, so kasbah stops here.",
			"Make it traversable — it is mode 755 on a server kasbah prepared.").Cont(
			PointerDirBlock(f, target).Lines()...)
	case "unreadable":
		return cli.Fail("%s on %s cannot be read, by %s or by root", Pointer, target, f["user"]).Cont(
			"it records where this server was prepared, and this run would prepare",
			fmt.Sprintf("%s — which, if the two differ, stands a second Traefik beside the", apps),
			"one already holding :80 and :443. kasbah will not guess. Read the file",
			fmt.Sprintf("yourself and remove it if %s is the tree this server runs from.", apps))
	}
	if len(value) < 2 || value[0] != '/' {
		return cli.Fail("%s on %s holds '%s', which is not an absolute path", Pointer, target, value).Cont(
			"kasbah will not write over a pointer it cannot read: whatever apps path",
			"this server was prepared at, that file was meant to name it, and this run",
			fmt.Sprintf("would prepare %s instead. If %s is the tree this", apps, apps),
			fmt.Sprintf("server really runs from, remove %s and re-run — init", Pointer),
			"writes it again.")
	}
	if value == apps {
		return nil
	}
	return cli.Fail("%s is already prepared at %s, and this run would prepare it at %s", target, value, apps).Cont(
		fmt.Sprintf("%s records %s. One server runs one kasbah, because one", Pointer, value),
		"Traefik holds :80 and :443: preparing a second tree here would render a rival",
		"stack under the frozen 'traefik' compose project, recreate the running proxy",
		fmt.Sprintf("against it — off this tree's dynamic/ and acme.json rather than %s's —", value),
		"and take every site on the server down. Nothing has been changed.",
		"To manage the server that is there, re-run with --apps-path set to the directory",
		fmt.Sprintf("%s resolves to — for a plain path that is %s itself, and kasbah's flags", value, value),
		"take no '..' segment — or with no --apps-path if that is the default.",
		fmt.Sprintf("To move the server to %s, take the existing stack down first and", apps),
		fmt.Sprintf("remove %s.", Pointer))
}

// Limits is 90% of the host in integer arithmetic, so the marker's bytes
// never depend on a locale: tenths of a core, floored GiB, else floored MiB.
func Limits(nproc, memKB string) (cpu, mem string, err error) {
	if !reInt.MatchString(nproc) {
		return "", "", cli.Fail("internal: nproc '%s' is not a core count", nproc)
	}
	if !reInt.MatchString(memKB) {
		return "", "", cli.Fail("internal: MemTotal '%s' is not a size in kB", memKB)
	}
	cores, err1 := strconv.ParseInt(nproc, 10, 64)
	kb, err2 := strconv.ParseInt(memKB, 10, 64)
	if err1 != nil || err2 != nil {
		return "", "", cli.Fail("internal: nproc '%s' or MemTotal '%s' is out of range", nproc, memKB)
	}
	tenths := cores * 9
	cpu = fmt.Sprintf("%d.%d", tenths/10, tenths%10)
	if gib := kb * 9 / 10485760; gib >= 1 {
		return cpu, fmt.Sprintf("%dg", gib), nil
	}
	mib := kb * 9 / 10240
	if mib < 1 {
		mib = 1
	}
	return cpu, fmt.Sprintf("%dm", mib), nil
}
