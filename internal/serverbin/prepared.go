package serverbin

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/marker"
	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// Bounded is `timeout -k 5 LIMIT BIN remote ARGS…`: a non-interactive run of
// the server binary, bounded as every one is.
func Bounded(bin string, limit int, args ...string) []string {
	return append([]string{"timeout", "-k", "5", strconv.Itoa(limit), bin, "remote"}, args...)
}

// InitCmd is `server init` spelled for this server: the remedy every marker
// refusal names.
func InitCmd(target, apps string) string {
	init := "kasbah server init " + target
	if apps != DefaultApps {
		init += " --apps-path=" + apps
	}
	return init
}

// EnterApps is the next step for an apps path this user cannot enter:
// operators enter it as members of the kasbah group, init's group step makes
// the tree the group's, and a directory with no group bits stays private
// unless its operator opens it.
func EnterApps(target, apps string) []string {
	login, _, ok := strings.Cut(target, "@")
	if !ok || login == "" {
		login = "<user>"
	}
	return []string{
		fmt.Sprintf("`ssh %s ls -ld %s` shows its owner and mode. Operators enter it as members of the kasbah group:", target, apps),
		fmt.Sprintf("`ssh %s 'sudo usermod -aG kasbah %s'` adds %[2]s (a new login picks it up), and `%s` makes the tree the group's.", target, login, InitCmd(target, apps)),
		fmt.Sprintf("A directory with no group bits stays private to its owner: if %s is meant to be shared, `ssh %s 'sudo chmod g+rwxs %[1]s'` opens it. Then re-run.", apps, target),
	}
}

// EnsurePrepared is Ensure for every command that needs a prepared server: the
// probe's copy of the marker passes marker.Validate before anything ships, and
// comes back validated.
func EnsurePrepared(c *ssh.Conn, self remote.Info, local func(arch string) (string, error)) (*Result, *marker.Marker, error) {
	target := c.Target.String()
	var mk *marker.Marker
	res, err := Ensure(c, self, local, Options{Prepared: func(body []byte, apps string) (err error) {
		mk, err = marker.Validate(body, marker.Path(apps), target, InitCmd(target, apps))
		return err
	}})
	if err != nil {
		return nil, nil, err
	}
	return res, mk, nil
}
