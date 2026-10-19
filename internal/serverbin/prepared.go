package serverbin

import (
	"strconv"

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
