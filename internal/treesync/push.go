package treesync

import (
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/adigourdi/kasbah/internal/ssh"
)

// Push sends src to dest through bin's `remote sync`, over c's master, in one
// ssh session; rsync's skip and read messages, and the server's errors, go to
// stderr. A source with nothing to send (a skipped fifo) contacts no one.
func Push(c *ssh.Conn, bin string, src *Source, dest string) error {
	if len(src.Ents) == 0 {
		if src.Errs > 0 {
			return errors.New("nothing could be read to send")
		}
		return nil
	}
	mode := "file"
	if src.Tree {
		mode = "dir"
	}
	cmd := c.Command(bin, "remote", "sync", mode, dest)
	in, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	out, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("cannot run ssh: %v", err)
	}
	rep, serr := src.Send(in, out, os.Stderr)
	io.Copy(io.Discard, out)
	werr := cmd.Wait()
	switch {
	case serr != nil:
		return serr
	case rep.Failed > 0:
		return fmt.Errorf("%d of the %d entries could not be synced (see above)", rep.Failed, len(src.Ents))
	case werr != nil:
		return fmt.Errorf("the server's sync exited %d", ssh.ExitCode(werr))
	}
	return nil
}
