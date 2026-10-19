package vlog

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/adigourdi/kasbah/internal/cli"
)

// Probe is `kasbah remote vlog APPS NAME`: both files' states and bytes,
// read-only. A state is one of ok missing empty notfile unreadable noaccess
// notdir — the words `kasbah server status` reports a log in.
type Probe struct {
	ActiveState  string `json:"active_state"`
	ActiveB64    string `json:"active_b64"`
	ArchiveState string `json:"archive_state"`
	ArchiveB64   string `json:"archive_b64"`
}

const probeUsage = "usage: kasbah remote vlog APPS NAME"

// Remote is the server's half of every record reader.
func Remote(args []string, stdout, stderr io.Writer) int {
	if len(args) != 2 {
		fmt.Fprintln(stderr, probeUsage)
		return 1
	}
	apps, dir := args[0], filepath.Join(args[0], args[1])
	var p Probe
	p.ActiveState, p.ActiveB64 = readFile(apps, dir, filepath.Join(dir, Log))
	p.ArchiveState, p.ArchiveB64 = readFile(apps, dir, filepath.Join(dir, Archive))
	b, _ := json.Marshal(p)
	fmt.Fprintf(stdout, "%s\n", b)
	return 0
}

// access is access(2) with R_OK|X_OK (5) or R_OK (4): the answer `[ -r ]` gives.
func access(path string, mode uint32) bool { return syscall.Access(path, mode) == nil }

// stateOf asks the apps path and the project directory first: a path through
// a file or an unenterable directory must not read as "never deployed here".
func stateOf(apps, dir, path string) string {
	for _, d := range []string{apps, dir} {
		fi, err := os.Stat(d)
		switch {
		case err == nil && !fi.IsDir():
			return "notdir"
		case err == nil && !access(d, 5):
			return "noaccess"
		}
	}
	fi, err := os.Stat(path)
	switch {
	case err == nil && !fi.Mode().IsRegular():
		return "notfile"
	case err != nil:
		return "missing"
	case !access(path, 4):
		return "unreadable"
	case fi.Size() == 0:
		return "empty"
	}
	return "ok"
}

// ReadFile is a file under a project directory, judged as the record's
// files are: its state, and its bytes in base64 when the state is ok.
func ReadFile(apps, dir, path string) (state, b64 string) { return readFile(apps, dir, path) }

func readFile(apps, dir, path string) (string, string) {
	st := stateOf(apps, dir, path)
	if st != "ok" {
		return st, ""
	}
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 {
		return "unreadable", ""
	}
	return "ok", base64.StdEncoding.EncodeToString(b)
}

// Item is one entry of the record and which file it came from.
type Item struct {
	Entry
	Archived bool
}

// Record is both files as the workstation read them: archive first (older),
// then active, nothing deduplicated — a rotation that duplicated entries is
// a state to show, not to fold away.
type Record struct {
	Target, ActivePath, ArchivePath string
	ActiveState, ArchiveState       string
	// Damaged: the archive did not read whole; Reason is the clause a report
	// puts after its path.
	Damaged  bool
	Reason   string
	Items    []Item
	Warnings []string
}

// Usable is whether an active log in that state may be read for contents.
func Usable(state string) bool {
	switch strings.TrimSuffix(state, "\r") {
	case "ok", "missing", "empty":
		return true
	}
	return false
}

// ReadProbe judges the probe's answer in opposite directions: an active log
// kasbah cannot read stops the run (an empty answer there is "never deployed
// here"), while everything about the archive is a warning.
func ReadProbe(out []byte, target, activePath string) (*Record, error) {
	r := &Record{Target: target, ActivePath: activePath, ArchivePath: activePath + ".gz"}
	out = bytes.ReplaceAll(out, []byte("\r"), nil)
	var m map[string]json.RawMessage
	var p Probe
	bad := json.Unmarshal(bytes.TrimSpace(out), &m) != nil
	var missing []string
	for _, k := range []string{"active_state", "active_b64", "archive_state", "archive_b64"} {
		if m[k] == nil {
			missing = append(missing, k)
		}
	}
	if bad || len(missing) > 0 || json.Unmarshal(bytes.TrimSpace(out), &p) != nil {
		what := strings.Join(missing, " ")
		if what == "" {
			what = "active_state active_b64 archive_state archive_b64"
		}
		e := cli.Fail("reading the deploy record on %s reported no %s", target, what).Cont(
			"the step was truncated, or the server's kasbah rejected it — raw output:")
		for _, l := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
			e.Cont("| " + l)
		}
		return nil, e
	}
	r.ActiveState, r.ArchiveState = p.ActiveState, p.ArchiveState
	if !Usable(r.ActiveState) {
		e := cli.Fail("%s on %s cannot be read — the probe called it '%s'", r.ActivePath, target, r.ActiveState)
		switch r.ActiveState {
		case "notfile":
			e.Cont("something that is not a regular file is where the deploy record should be")
		case "unreadable":
			e.Cont("the file is there and this ssh user cannot read it — a deploy that ran under sudo leaves that")
		case "noaccess":
			e.Cont("the directory holding it cannot be entered by this ssh user — a deploy that ran under sudo leaves that")
		case "notdir":
			e.Cont("a path above it is occupied by something that is not a directory")
		default:
			e.Cont("which is a state this kasbah does not know")
		}
		return nil, e.Cont(
			"kasbah will not read this as an empty record: 'the record cannot be read' and 'this",
			"project has never been deployed here' are different answers, and rollback acts on",
			"the difference.")
	}
	active := ""
	if r.ActiveState == "ok" {
		b, err := base64.StdEncoding.DecodeString(p.ActiveB64)
		if err != nil {
			return nil, cli.Fail("the deploy record read on %s sent %s back as something that is not base64", target, r.ActivePath)
		}
		active = string(b)
		if strings.TrimSpace(active) == "" {
			r.ActiveState, active = "empty", ""
		}
	}
	archive := ""
	switch r.ArchiveState {
	case "ok":
		archive = r.decodeArchive(p.ArchiveB64)
	case "missing", "empty":
	default:
		r.warn("%s on %s cannot be read — the probe called it '%s'", r.ArchivePath, target, r.ArchiveState)
		r.warn("  the rotated history is not in the record below; the active log is")
	}
	for _, e := range Entries(archive) {
		r.Items = append(r.Items, Item{e, true})
	}
	for _, e := range Entries(active) {
		r.Items = append(r.Items, Item{e, false})
	}
	return r, nil
}

func (r *Record) warn(format string, a ...any) {
	r.Warnings = append(r.Warnings, fmt.Sprintf(format, a...))
}

// decodeArchive keeps whatever decoded before a failure, and names it.
func (r *Record) decodeArchive(b64 string) string {
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		r.Damaged, r.Reason = true, "did not arrive as base64 from "+r.Target
		r.warn("%s on %s did not come back as base64 — the transport was cut, not the file", r.ArchivePath, r.Target)
		r.warn("  the file on the server is untouched; this says nothing about whether it is whole")
		r.warn("  no archived entry is in the record below; the active log is")
		return ""
	}
	text, why := Decode(data)
	switch why {
	case "":
	case "is not gzip":
		r.Damaged, r.Reason = true, "is not gzip: no archived entry could be decoded"
		r.warn("%s on %s is not gzip — nothing could be decoded from it", r.ArchivePath, r.Target)
		r.warn("  no archived entry is in the record below; look at the file itself")
	default:
		r.Damaged, r.Reason = true, "ends in a truncated gzip member: whatever is inside it could not be decoded"
		r.warn("%s on %s ends in a truncated gzip member", r.ArchivePath, r.Target)
		r.warn("  every entry before it is read; anything inside it is not")
		r.warn("  the likely cause is a rotation that ran out of disk while appending")
	}
	return text
}

// Whole is whether the archived half is fully accounted for — not the same
// question as whether it holds entries.
func (r *Record) Whole() bool {
	return !r.Damaged && (r.ArchiveState == "ok" || r.ArchiveState == "missing" || r.ArchiveState == "empty")
}

// Note is the one line a report adds when the archive is not whole: the
// warnings went to stderr, and a redirected report must not read as complete.
func (r *Record) Note() string {
	if r.Whole() {
		return ""
	}
	if r.Reason != "" {
		return r.ArchivePath + " " + r.Reason + ", so this is not the whole record"
	}
	return fmt.Sprintf("%s could not be read (the probe called it '%s'), so this is not the whole record", r.ArchivePath, r.ArchiveState)
}

// Count is how many entries came from the archive and from the active log.
func (r *Record) Count() (archived, active int) {
	for _, it := range r.Items {
		if it.Archived {
			archived++
		} else {
			active++
		}
	}
	return
}

// LastActive is the active log's last entry, parsed or not; -1 when it holds
// none. The active log is what says what runs now.
func (r *Record) LastActive() int {
	for i := len(r.Items) - 1; i >= 0; i-- {
		if !r.Items[i].Archived {
			return i
		}
	}
	return -1
}

// PrevDeploy is the second-latest action=deploy entry over the whole record
// (-1 when there are not two), and how many unparsed lines it stepped over:
// a truncated latest deploy otherwise makes the one before it the target.
func (r *Record) PrevDeploy() (idx, skipped int) {
	seen := 0
	for i := len(r.Items) - 1; i >= 0; i-- {
		e := r.Items[i]
		if !e.OK {
			skipped++
			continue
		}
		if e.Action != "deploy" {
			continue
		}
		if seen++; seen == 2 {
			return i, skipped
		}
	}
	return -1, skipped
}

// FindVersion is the most recent entry naming v, whatever its action — a
// rollback entry proves a version ran exactly as a deploy entry does.
func (r *Record) FindVersion(v string) (idx, skipped int) {
	for i := len(r.Items) - 1; i >= 0; i-- {
		e := r.Items[i]
		if !e.OK {
			skipped++
			continue
		}
		if e.Version == v {
			return i, skipped
		}
	}
	return -1, skipped
}
