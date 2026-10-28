// Package vlog is the deploy record — versions.log, its rotation into
// versions.log.gz, and the one entry predicate (docs/build-deploy.md). The
// server writes and rotates; the workstation reads.
package vlog

import (
	"bytes"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unicode"
)

const (
	Log     = "versions.log"
	Archive = "versions.log.gz"
	// Mode is both files': every operator in the kasbah group appends.
	Mode = 0o664
)

// owned is whether this process's user owns the file: only the owner may
// chmod it, whatever its group bits allow.
func owned(fi os.FileInfo) bool {
	st, ok := fi.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid()
}

// fixMode puts a file this user owns back to Mode; another operator's is
// left as it is.
func fixMode(path string) {
	if fi, err := os.Stat(path); err == nil && fi.Mode().Perm() != Mode && owned(fi) {
		os.Chmod(path, Mode)
	}
}

// Entry is one non-blank line. OK is the frozen-format predicate: four
// non-empty positional fields, the first beginning YYYY-MM-DDT. A line that
// fails it is still history; it only yields no fields.
type Entry struct {
	Raw                           string
	OK                            bool
	Time, Action, Version, Backup string
	Kasbah, Digest, By            string
}

var reStamp = regexp.MustCompile(`^[0-9]{4}-[0-9]{2}-[0-9]{2}T`)

// fields splits as bash's `read` does under the default IFS.
func fields(s string) []string {
	return strings.FieldsFunc(s, func(r rune) bool { return r == ' ' || r == '\t' || r == '\n' })
}

// Parse reads one line. Pairs after the four fields that this version does
// not know are ignored, never rejected: a newer kasbah appends its own.
func Parse(line string) Entry {
	e := Entry{Raw: line}
	f := fields(strings.TrimSuffix(line, "\r"))
	if len(f) < 4 || !reStamp.MatchString(f[0]) {
		return e
	}
	e.OK = true
	e.Time, e.Action, e.Version, e.Backup = f[0], f[1], f[2], f[3]
	for _, p := range f[4:] {
		if v, ok := strings.CutPrefix(p, "kasbah="); ok {
			e.Kasbah = v
		} else if v, ok := strings.CutPrefix(p, "digest="); ok {
			e.Digest = v
		} else if v, ok := strings.CutPrefix(p, "by="); ok {
			e.By = v
		}
	}
	return e
}

// Entries is every non-blank line of a decoded log, in order.
func Entries(text string) []Entry {
	var out []Entry
	for _, l := range strings.Split(text, "\n") {
		if strings.TrimSpace(l) == "" {
			continue
		}
		out = append(out, Parse(l))
	}
	return out
}

// Stamp is versions.log's timestamp: `date -u -Iseconds`.
func Stamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05-07:00") }

// Line renders an entry. Every value is refused when empty or holding
// whitespace: either would shift every field after it, in a file every later
// kasbah must parse.
func Line(ts, action, version, backup, kasbah, digest, by string) (string, error) {
	for _, p := range [][2]string{{"timestamp", ts}, {"action", action}, {"version", version},
		{"backup path", backup}, {"kasbah version", kasbah}, {"digest", digest}, {"user", by}} {
		if p[1] == "" {
			return "", fmt.Errorf("refusing to write versions.log: the %s is empty, which would shift every field after it", p[0])
		}
		if strings.IndexFunc(p[1], func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) >= 0 {
			return "", fmt.Errorf("refusing to write versions.log: the %s ('%s') contains whitespace or a control character, which would shift every field after it", p[0], p[1])
		}
	}
	return fmt.Sprintf("%s %s %s %s kasbah=%s digest=%s by=%s", ts, action, version, backup, kasbah, digest, by), nil
}

// Append adds one line to dir's log. A last line with no newline — an append
// killed partway — is terminated first rather than written into, and
// repaired is true.
func Append(dir, line string) (repaired bool, err error) {
	path := filepath.Join(dir, Log)
	f, err := os.OpenFile(path, os.O_RDWR|os.O_APPEND|os.O_CREATE, Mode)
	if err != nil {
		return false, fmt.Errorf("could not append to %s", path)
	}
	defer f.Close()
	fixMode(path)
	if fi, err := f.Stat(); err == nil && fi.Size() > 0 {
		b := make([]byte, 1)
		if _, err := f.ReadAt(b, fi.Size()-1); err != nil {
			return false, fmt.Errorf("could not read the end of %s", path)
		}
		if b[0] != '\n' {
			if _, err := f.Write([]byte{'\n'}); err != nil {
				return false, fmt.Errorf("could not terminate the last line of %s", path)
			}
			repaired = true
		}
	}
	if _, err := f.Write([]byte(line + "\n")); err != nil {
		return repaired, fmt.Errorf("could not append to %s", path)
	}
	if err := f.Close(); err != nil {
		return repaired, fmt.Errorf("could not append to %s", path)
	}
	return repaired, nil
}

// LastLine is Last of the log under dir; "" when the file is absent.
func LastLine(dir string) (string, error) {
	data, err := os.ReadFile(filepath.Join(dir, Log))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return Last(data), nil
}

// Last is a log's last line that is not blank, CR stripped; "" when it holds none.
func Last(data []byte) string {
	last := ""
	for _, l := range strings.Split(string(data), "\n") {
		if l = strings.TrimSuffix(l, "\r"); strings.Trim(l, " \t\n\v\f\r") != "" {
			last = l
		}
	}
	return last
}

// MonthIndex is year*12+month for a timestamp beginning YYYY-MM-. Rotation's
// deliberate exception to the entry predicate: a datable truncated line
// still ages out.
func MonthIndex(ts string) (int, bool) {
	if len(ts) < 8 || ts[4] != '-' || ts[7] != '-' {
		return 0, false
	}
	for _, i := range []int{0, 1, 2, 3, 5, 6} {
		if ts[i] < '0' || ts[i] > '9' {
			return 0, false
		}
	}
	y, _ := strconv.Atoi(ts[0:4])
	m, _ := strconv.Atoi(ts[5:7])
	return y*12 + m, true
}

// MonthName is YYYY-MM for a month index.
func MonthName(idx int) string {
	y := (idx - 1) / 12
	return fmt.Sprintf("%04d-%02d", y, idx-y*12)
}

// RotateError is a rotation that did not complete, in one of three shapes.
type RotateError int

const (
	// Untouched: nothing reached either file.
	Untouched RotateError = 1
	// Duplicated: the archive took the entries, the log was not rewritten.
	Duplicated RotateError = 2
	// Partial: the append to the archive stopped partway.
	Partial RotateError = 3
)

func (e RotateError) Error() string {
	switch e {
	case Duplicated:
		return "versions.log was rotated into versions.log.gz but could not then be rewritten, so the entries older than three months are now in BOTH files — and every later run will append them to versions.log.gz again until versions.log is trimmed by hand. The run itself is unaffected; nothing was lost."
	case Partial:
		return "versions.log could not be rotated: the append to versions.log.gz stopped partway, so the archive may end in an incomplete gzip member. versions.log is untouched and still holds every entry, so nothing was lost — repair or truncate versions.log.gz before reading it."
	}
	return "versions.log could not be rotated — the entry is written and both files are exactly as they were, only its 3-month compaction into versions.log.gz did not run"
}

// Rotate moves entries older than (now's month − 3) into the archive, archive
// first, so a crash duplicates rather than loses. Kept lines travel byte for
// byte; both files end at Mode wherever this user owns them.
func Rotate(dir string, now time.Time) (moved, cut int, err error) {
	log := filepath.Join(dir, Log)
	gz := filepath.Join(dir, Archive)
	keep := filepath.Join(dir, ".versions.log.keep")
	drop := filepath.Join(dir, ".versions.log.drop")
	part := filepath.Join(dir, ".versions.log.part")

	fi, serr := os.Stat(log)
	if serr != nil || fi.Size() == 0 {
		return 0, 0, nil
	}
	n := now.UTC()
	cut = n.Year()*12 + int(n.Month()) - 3
	defer func() {
		os.Remove(keep)
		os.Remove(drop)
		os.Remove(part)
	}()

	data, rerr := os.ReadFile(log)
	if rerr != nil {
		return 0, cut, Untouched
	}
	var kept, dropped bytes.Buffer
	text := string(data)
	text = strings.TrimSuffix(text, "\n")
	for _, l := range strings.Split(text, "\n") {
		ts := l
		if i := strings.IndexAny(l, " \t\n\v\f\r"); i >= 0 {
			ts = l[:i]
		}
		if idx, ok := MonthIndex(ts); ok && idx < cut {
			dropped.WriteString(l + "\n")
			moved++
		} else {
			kept.WriteString(l + "\n")
		}
	}
	if os.WriteFile(keep, kept.Bytes(), 0o666) != nil || os.WriteFile(drop, dropped.Bytes(), 0o666) != nil {
		return 0, cut, Untouched
	}
	if moved == 0 {
		return 0, cut, nil
	}

	var z bytes.Buffer
	zw := gzip.NewWriter(&z)
	zw.Write(dropped.Bytes())
	if zw.Close() != nil || os.WriteFile(part, z.Bytes(), 0o666) != nil {
		return 0, cut, Untouched
	}
	af, err := os.OpenFile(gz, os.O_WRONLY|os.O_APPEND|os.O_CREATE, Mode)
	appended := err == nil
	if appended {
		if _, err := af.Write(z.Bytes()); err != nil {
			appended = false
		}
		if af.Close() != nil {
			appended = false
		}
	}
	// Applied after a short append too: those bytes are in a file someone has
	// to open to repair it.
	fixMode(gz)
	if !appended {
		return 0, cut, Partial
	}
	if os.Rename(keep, log) != nil {
		return 0, cut, Duplicated
	}
	os.Chmod(log, Mode)
	return moved, cut, nil
}

// Decode reads an archive as zcat does — every decoded byte, a cut member's
// partial line included, trailing zero padding ignored; why names what
// stopped the read ("" when whole). Nothing decoded is "is not gzip".
func Decode(data []byte) (text, why string) {
	if len(data) == 0 {
		return "", ""
	}
	br := bytes.NewReader(data)
	zr, err := gzip.NewReader(br)
	if err != nil {
		return "", "is not gzip"
	}
	var out bytes.Buffer
	for {
		zr.Multistream(false)
		if _, err = io.Copy(&out, zr); err != nil {
			break
		}
		rest := data[len(data)-br.Len():]
		if len(bytes.Trim(rest, "\x00")) == 0 {
			return out.String(), ""
		}
		if err = zr.Reset(br); err != nil {
			break
		}
	}
	if out.Len() == 0 {
		return "", "is not gzip"
	}
	return out.String(), "ends in a truncated gzip member"
}
