package deploy

import (
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/vlog"
)

// HostPath is the job's PATH, whatever started it.
const HostPath = "/usr/local/bin:/usr/bin:/bin"

const hostUsage = "usage: kasbah remote backup host APPS SECONDS"

// HostBackup is `kasbah remote backup host APPS SECONDS`, the nightly job on
// the host: every project's live version backed up as `remote deploy backup`
// does it, one result line per project on stdout, all of it inside SECONDS.
func HostBackup(args []string, stdout, stderr io.Writer) int {
	secs := 0
	if len(args) == 2 {
		secs, _ = strconv.Atoi(args[1])
	}
	if secs <= 0 || !filepath.IsAbs(args[0]) {
		fmt.Fprintln(stderr, hostUsage)
		return 1
	}
	w, done := remote.Outlive(stderr)
	defer done()
	syscall.Umask(0o002)
	return hostBackup(args[0], time.Now().Add(time.Duration(secs)*time.Second), time.Now, HostEnv(os.Getenv), stdout, w)
}

// HostEnv is a hook's environment in the nightly job: the fixed PATH, the C
// locale, and who the job runs as — nothing else of what started it.
func HostEnv(getenv func(string) string) []string {
	env := []string{"PATH=" + HostPath, "LC_ALL=C"}
	for _, k := range []string{"HOME", "USER", "LOGNAME"} {
		if v := getenv(k); v != "" {
			env = append(env, k+"="+v)
		}
	}
	return env
}

// Results of the host job, the first word after the project's name.
const (
	HostOK      = "ok"
	HostFailed  = "failed"
	HostSkipped = "skipped"
)

// oneLine is s fit for a result line.
func oneLine(s string) string {
	return strings.Join(strings.Fields(strings.ReplaceAll(s, "\r", " ")), " ")
}

func hostBackup(apps string, deadline time.Time, now func() time.Time, env []string, stdout, stderr io.Writer) int {
	ents, err := os.ReadDir(apps)
	if err != nil {
		fmt.Fprintf(stderr, "remote: backup host: could not list %s: %v\n", apps, err)
		return 1
	}
	rc := 0
	result := func(name, what, detail string) {
		fmt.Fprintf(stdout, "project %s %s %s\n", name, what, oneLine(detail))
	}
	for _, en := range ents {
		name := en.Name()
		if !IsProject(apps, name) {
			continue
		}
		dir := apps + "/" + name
		if _, err := os.Lstat(filepath.Join(dir, HooksFile)); errors.Is(err, fs.ErrNotExist) {
			result(name, HostSkipped, "no "+HooksFile+": no deploy has recorded its hooks")
			continue
		}
		data, _ := os.ReadFile(filepath.Join(dir, vlog.Log))
		if liveVersion(vlog.Entries(strings.ReplaceAll(string(data), "\r", ""))) == "" {
			result(name, HostSkipped, "no live version")
			continue
		}
		if !time.Now().Before(deadline) {
			result(name, HostFailed, "not backed up: the job's deadline had passed before its turn")
			rc = 1
			continue
		}
		fmt.Fprintf(stderr, "%s: backing up the live version\n", name)
		file, version, err := backupOne(&engine{dir: dir, stderr: stderr, now: now, env: env, deadline: deadline})
		if err != nil {
			result(name, HostFailed, err.Error())
			rc = 1
			continue
		}
		result(name, HostOK, file+" "+version)
	}
	return rc
}
