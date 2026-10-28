package serverinit

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/rootsteps"
	"github.com/adigourdi/kasbah/internal/serverlock"
)

// groupScript reads how far the server is from the multi-operator model, on
// the resolved apps and data paths, over entries the ssh user or a group
// member owns (by uid), with root's eyes when it can. Read-only.
const groupScript = `set -u
export LC_ALL=C
apps=$1
data=$2
user=$3
group=$4
s=""
sudo_ok=no
if [ "$(id -u)" = 0 ]; then
    sudo_ok=yes
elif sudo -n true >/dev/null 2>&1; then
    sudo_ok=yes
    s="sudo -n"
fi
printf 'group_sudo=%s\n' "$sudo_ok"
A=$(cd -P "$apps" 2>/dev/null && pwd -P) || A=$apps
D=$(cd -P "$data" 2>/dev/null && pwd -P) || D=$data
printf 'group_apps=%s\ngroup_datadir=%s\n' "$A" "$D"
if command -v getent >/dev/null 2>&1; then
    line=$(getent group "$group" 2>/dev/null) || line=""
else
    line=$(grep "^$group:" /etc/group 2>/dev/null) || line=""
fi
uids=$(id -u)
gid=$(printf '%s' "$line" | cut -d: -f3)
if command -v getent >/dev/null 2>&1; then pw=$(getent passwd 2>/dev/null) || pw=""; else pw=$(cat /etc/passwd 2>/dev/null) || pw=""; fi
primary=$(printf '%s\n' "$pw" | awk -F: -v g="$gid" 'g != "" && $4 == g { print $1 }' | tr '\n' ' ')
for u in $(printf '%s' "${line##*:}" | tr ',' ' ') $primary; do
    case $u in ''|*[!A-Za-z0-9._-]*) continue ;; esac
    n=$(id -u "$u" 2>/dev/null) || continue
    case ",$uids," in *",$n,"*) ;; *) uids="$uids,$n" ;; esac
done
own="-user $(printf '%s' "$uids" | sed 's/,/ -o -user /g')"
printf 'group_uids=%s\n' "$uids"
any() { r=$(eval "$s find $1 -print -quit" 2>/dev/null); if [ -n "$r" ]; then echo yes; else echo no; fi; }
# shellcheck disable=SC2016 # expanded by any()'s eval, not here
tree='"$A" \( -path "$D" -o -path "$A/data" \) -prune -o'
# shellcheck disable=SC2016
files='\( \( -name .env -o -name versions.log -o -name versions.log.gz -o -name .deploy.lock \) ! -path "$A/*/*/*" -o -path "$A/.kasbah/server.json" -o -path "$A/.kasbah/server.lock" -o -path "$A/.kasbah/migrate.lock" -o -path "$A/.kasbah/bin/.lock" -o -path "$A/.kasbah/bin/kasbah" \) ! -path "$A/mail/.env"'
if [ -n "$line" ]; then
    printf 'group_exists=yes\n'
    case " $(id -nG "$user" 2>/dev/null) " in
        *" $group "*) printf 'group_member=yes\n' ;;
        *) printf 'group_member=no\n' ;;
    esac
    printf 'group_tree=%s\n' "$(any "$tree \( $own \) ! -group \"\$group\"")"
    printf 'group_dirs=%s\n' "$(any "$tree -type d \( $own \) -perm /070 ! -perm -2070")"
    printf 'group_data=%s\n' "$(any "\"\$D\" -maxdepth 0 -type d \( $own \) \( ! -group \"\$group\" -o ! -perm -2070 \)")"
    printf 'group_files=%s\n' "$(any "\"\$A\" -mindepth 2 -maxdepth 3 -type f \( $own \) $files ! -perm -060")"
else
    printf 'group_exists=no\ngroup_member=no\ngroup_tree=yes\ngroup_dirs=yes\ngroup_data=yes\ngroup_files=yes\n'
fi
exit 0
`

var groupKeys = []string{"group_sudo", "group_apps", "group_datadir", "group_uids", "group_exists", "group_member", "group_tree", "group_dirs", "group_data", "group_files"}

var reUID = regexp.MustCompile(`^[0-9]+$`)

// GroupBlock is what root runs to bring the server to the model from what
// groupScript found; empty when there is nothing to do.
func GroupBlock(f Facts, target, apps, data, user string) *rootsteps.Block {
	b := &rootsteps.Block{Target: target, User: user}
	g := serverlock.Group
	A, D := f["group_apps"], f["group_datadir"]
	if A == "" {
		A = apps
	}
	if D == "" {
		D = data
	}
	var own []string
	for _, u := range strings.Split(f["group_uids"], ",") {
		if reUID.MatchString(u) {
			own = append(own, "-user "+u)
		}
	}
	if len(own) == 0 {
		own = []string{"-user " + rootsteps.Quote(user)}
	}
	owners := `\( ` + strings.Join(own, " -o ") + ` \)`
	qa, qd := rootsteps.Quote(A), rootsteps.Quote(D)
	tree := fmt.Sprintf(`sudo find %s \( -path %s -o -path %s \) -prune -o`, qa, qd, rootsteps.Quote(A+"/data"))
	if f["group_exists"] != "yes" {
		b.Add("sudo groupadd " + g)
	}
	if f["group_member"] != "yes" {
		b.Add("sudo usermod -aG " + g + " " + rootsteps.Quote(user))
	}
	if f["group_tree"] != "no" {
		b.Add(fmt.Sprintf("%s %s ! -group %s -exec chgrp -h %s {} +", tree, owners, g, g))
	}
	if f["group_dirs"] != "no" {
		b.Add(fmt.Sprintf("%s -type d %s -perm /070 ! -perm -2070 -exec chmod g+rwxs {} +", tree, owners))
	}
	// <data> itself, never what is in it: that is the containers'.
	if f["group_data"] != "no" {
		b.Add(fmt.Sprintf("sudo find %s -maxdepth 0 -type d %s -exec chgrp -h %s {} + -exec chmod g+rwxs {} +", qd, owners, g))
	}
	if f["group_files"] != "no" {
		p := func(s string) string { return rootsteps.Quote(A + s) }
		b.Add(fmt.Sprintf(`sudo find %s -mindepth 2 -maxdepth 3 -type f %s \( \( -name .env -o -name versions.log -o -name versions.log.gz -o -name .deploy.lock \) ! -path %s -o -path %s -o -path %s -o -path %s -o -path %s -o -path %s \) ! -path %s ! -perm -060 -exec chmod g+rwX {} +`,
			qa, owners, p("/*/*/*"), p("/.kasbah/server.json"), p("/.kasbah/server.lock"), p("/.kasbah/migrate.lock"),
			p("/.kasbah/bin/.lock"), p("/.kasbah/bin/kasbah"), p("/mail/.env")))
	}
	return b
}

// GroupWhy is why the group step needs root.
func GroupWhy(target, apps, user string) string {
	return fmt.Sprintf("%s on %s is not yet the '%s' group's: every operator deploys as their own Unix user in that group, and only root can create it, add %s to it and hand the tree over.", apps, target, serverlock.Group, user)
}

// GroupState is the group step's outcome in words, for init's summary.
func GroupState(f Facts) string {
	switch f["group_action"] {
	case "unchanged":
		return "already in place"
	case "converged with sudo":
		return "put in place with sudo"
	case "converged by hand":
		return "put in place by hand"
	}
	return "NOT in place — root's commands are printed above"
}

// group reads the facts and, with sudo -n, runs the block init would print.
// usermod reaches new sessions only; nothing later in this run needs it.
func (s *session) group(o Options, user string) (Facts, error) {
	read := func() (Facts, error) {
		res, rc := s.script(groupScript, o.Apps, o.Data, user, serverlock.Group)
		if rc != 0 {
			return nil, cli.Fail("could not read the group step on %s (the remote step exited %d, see above)", s.target, rc)
		}
		return checked("the group step", s.target, res, groupKeys...)
	}
	f, err := read()
	if err != nil {
		return nil, err
	}
	b := GroupBlock(f, s.target, o.Apps, o.Data, user)
	if b.Empty() {
		f["group_action"] = "unchanged"
		return f, nil
	}
	if f["group_sudo"] != "yes" {
		f["group_action"] = "nosudo"
		return f, nil
	}
	body := "set -eu\n"
	for _, c := range b.Commands {
		body += "sudo -n " + strings.TrimPrefix(c, "sudo ") + "\n"
	}
	if _, rc := s.script(body); rc != 0 {
		return nil, stepFailed("put "+o.Apps+" under the '"+serverlock.Group+"' group", s.target, rc)
	}
	if f, err = read(); err != nil {
		return nil, err
	}
	if left := GroupBlock(f, s.target, o.Apps, o.Data, user); !left.Empty() {
		return nil, cli.Fail("the group step on %s ran and the tree is still not the '%s' group's", s.target, serverlock.Group).Cont(left.Lines()...)
	}
	f["group_action"] = "converged with sudo"
	return f, nil
}
