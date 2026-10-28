package check

import (
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/serverlock"
)

// Group is serverlock.Group, the operators' Unix group.
const Group = serverlock.Group

// permsMax bounds the offenders a report carries; the count is exact.
const permsMax = 20

// groupBits is what an entry needs for every operator: setgid and g+rwx on a
// directory with any group bit (none: private, as the root step leaves it),
// g+rw on the files written in place or read by the next one, g+rwx on the binary.
func groupBits(rel string, have fs.FileMode, dir bool) fs.FileMode {
	if dir {
		if have&0o070 == 0 {
			return 0
		}
		return fs.ModeSetgid | 0o070
	}
	switch rel {
	case "mail/.env":
		return 0
	case ".kasbah/bin/kasbah":
		return 0o070
	case ".kasbah/server.json", ".kasbah/server.lock", ".kasbah/migrate.lock", ".kasbah/bin/.lock":
		return 0o060
	}
	switch filepath.Base(rel) {
	case ".env", "versions.log", "versions.log.gz", ".deploy.lock":
		if strings.Count(rel, "/") == 1 {
			return 0o060
		}
	}
	return 0
}

// Perms walks the resolved apps path, never below <data>, over what the ssh
// user or a group member owns, for entries off the group or short of
// groupBits; "absent" without the group, n every offender, list permsMax.
func Perms(apps, data, group string) (state string, n int, list []string) {
	g, err := user.LookupGroup(group)
	if err != nil {
		return "absent", 0, nil
	}
	gid, _ := strconv.Atoi(g.Gid)
	n, list = perms(apps, data, gid, owners(group, gid))
	return "present", n, list
}

// owners is this user's uid, every member's of group and every user's whose
// primary group it is — from getent when there is one, as the root step reads
// them, else /etc/group and /etc/passwd.
func owners(group string, gid int) map[int]bool {
	set := map[int]bool{os.Getuid(): true}
	// Keyed lookups reach directory services that refuse enumeration.
	db := func(name string, key ...string) string {
		if out, err := exec.Command("getent", append([]string{name}, key...)...).Output(); err == nil {
			return string(out)
		}
		b, _ := os.ReadFile("/etc/" + name)
		return string(b)
	}
	for _, l := range strings.Split(db("group", group), "\n") {
		f := strings.Split(strings.TrimSpace(l), ":")
		if len(f) != 4 || f[0] != group {
			continue
		}
		for _, m := range strings.Split(f[3], ",") {
			for _, pl := range strings.Split(db("passwd", m), "\n") {
				pf := strings.Split(pl, ":")
				if len(pf) < 3 || pf[0] != m {
					continue
				}
				if id, err := strconv.Atoi(pf[2]); err == nil {
					set[id] = true
				}
			}
		}
	}
	for _, l := range strings.Split(db("passwd"), "\n") {
		f := strings.Split(l, ":")
		if len(f) >= 4 && f[3] == strconv.Itoa(gid) {
			if id, err := strconv.Atoi(f[2]); err == nil {
				set[id] = true
			}
		}
	}
	return set
}

func resolved(p string) string {
	p = strings.TrimSuffix(p, "/")
	if r, err := filepath.EvalSymlinks(p); err == nil {
		return r
	}
	return p
}

func perms(apps, data string, gid int, own map[int]bool) (n int, list []string) {
	apps = resolved(apps)
	skip := map[string]bool{resolved(data): true, apps + "/data": true}
	filepath.WalkDir(apps, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		// <data> itself is the group's; what is in it, the containers'.
		next := error(nil)
		if skip[p] {
			next = fs.SkipDir
		}
		fi, err := d.Info()
		if err != nil {
			return next
		}
		st, ok := fi.Sys().(*syscall.Stat_t)
		if !ok || !own[int(st.Uid)] {
			return next
		}
		rel := strings.TrimPrefix(strings.TrimPrefix(p, apps), "/")
		have := fi.Mode() & (fs.ModeSetgid | fs.ModePerm)
		want := groupBits(rel, have, fi.IsDir())
		if int(st.Gid) == gid && have&want == want {
			return next
		}
		n++
		if len(list) < permsMax {
			gname := strconv.Itoa(int(st.Gid))
			if gg, err := user.LookupGroupId(gname); err == nil {
				gname = gg.Name
			}
			list = append(list, fmt.Sprintf("%s (group %s, mode %s)", p, gname, octal(have)))
		}
		return next
	})
	return n, list
}

// octal is a mode as stat -c %a prints it: 2775, 660.
func octal(m fs.FileMode) string {
	v := uint32(m.Perm())
	if m&fs.ModeSetgid != 0 {
		v |= 0o2000
	}
	return strconv.FormatUint(uint64(v), 8)
}
