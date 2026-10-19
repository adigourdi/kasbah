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
