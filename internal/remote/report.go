package remote

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
)

// Decode reads one JSON report into v, checking its keys as a protocol
// first: a truncated step must not be absorbed into a plan that ends in a
// deletion. step names it in the refusal ("the drop probe").
func Decode(out []byte, v any, keys []string, step, target string) error {
	return decode(out, v, keys, step, target, true)
}

// DecodeHidden is Decode for a report that may carry secrets: a bad one is
// described by its size, never shown.
func DecodeHidden(out []byte, v any, keys []string, step, target string) error {
	return decode(out, v, keys, step, target, false)
}

func decode(out []byte, v any, keys []string, step, target string, show bool) error {
	out = bytes.TrimSpace(bytes.ReplaceAll(out, []byte("\r"), nil))
	var m map[string]json.RawMessage
	bad := json.Unmarshal(out, &m) != nil
	var missing []string
	for _, k := range keys {
		if m[k] == nil {
			missing = append(missing, k)
		}
	}
	if !bad && len(missing) == 0 && json.Unmarshal(out, v) == nil {
		return nil
	}
	what := strings.Join(missing, " ")
	if what == "" {
		what = strings.Join(keys, " ")
	}
	e := cli.Fail("%s on %s reported no %s", step, target, what).Cont(
		"the step was truncated, or the server's kasbah rejected it — raw output:")
	if !show {
		return e.Cont(fmt.Sprintf("| <%d bytes, not shown>", len(out)))
	}
	for i, l := range strings.Split(string(out), "\n") {
		if i == 20 {
			e.Cont("| … and more, not shown")
			break
		}
		if len(l) > 120 {
			l = fmt.Sprintf("%s… (%d bytes in all)", l[:120], len(l))
		}
		e.Cont("| " + l)
	}
	return e
}

// KV reads a step's key=value lines, a trailing CR stripped; a line without
// `=` is not a fact, and a later key wins.
func KV(out []byte) map[string]string {
	m := map[string]string{}
	for _, l := range strings.Split(string(out), "\n") {
		if k, v, ok := strings.Cut(strings.TrimSuffix(l, "\r"), "="); ok {
			m[k] = v
		}
	}
	return m
}
