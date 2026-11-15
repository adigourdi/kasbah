package serverbin

import (
	"bytes"
	"path"
	"strconv"

	"github.com/adigourdi/kasbah/internal/remote"
	"github.com/adigourdi/kasbah/internal/ssh"
	"github.com/adigourdi/kasbah/internal/trace"
)

// Inspection is what the bootstrap probe learns of a server, nothing changed.
type Inspection struct {
	Probe *Probe
	// Bin is the server binary's own answer; nil when it has none that runs.
	// BinErr is why a binary that is there could not be accounted for.
	Bin    *remote.Info
	BinErr error
}

// Inspect runs Ensure's probe and judges the binary found, shipping nothing:
// no marker or binary is a fact, not a refusal. It fails only where
// readLayout refuses: a failed or unparsable probe, the pointer's refusals.
func Inspect(c *ssh.Conn) (*Inspection, error) {
	target := c.Target.String()
	cmd := c.Script(probeScript, probeDefault, probePointer, "", strconv.Itoa(RunTimeout))
	var out bytes.Buffer
	cmd.Stdout = &out
	p, err := readLayout(target, ssh.ExitCode(trace.Run(cmd)), out.Bytes())
	if err != nil {
		return nil, err
	}
	bin := Path(p.Apps)
	arch, _ := Arch(p.Machine)
	srv, err := Classify(p.Bin, bin, arch, func() error { return noexec(target, path.Dir(bin), bin, p.Mount) })
	return &Inspection{Probe: p, Bin: srv, BinErr: err}, nil
}
