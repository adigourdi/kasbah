package buildpush

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// errWriter remembers a failed write, so a broken copy can say which end of
// the pipeline broke it.
type errWriter struct {
	w   io.Writer
	err error
}

func (e *errWriter) Write(p []byte) (int, error) {
	n, err := e.w.Write(p)
	if err != nil && e.err == nil {
		e.err = err
	}
	return n, err
}

func kill(cmd *exec.Cmd) {
	if cmd.Process != nil {
		cmd.Process.Kill()
	}
}

// ship is one `docker save` of every image — one stream writes each shared
// layer once — gzipped on the way into `kasbah remote load` on the server.
// Nothing lands on disk on either end. The gzip trailer is written only after
// save has exited 0, so a save that fails reaches the server as a truncated
// stream, which the far side refuses, and never as a short valid one.
func ship(conn *ssh.Conn, bin string, images []Image) error {
	target := conn.Target.String()
	refs := make([]string, len(images))
	for i, im := range images {
		refs[i] = im.Ref
	}

	load := conn.Command(append([]string{bin, "remote", "load"}, refs...)...)
	var report bytes.Buffer
	load.Stdout = &report
	sink, err := load.StdinPipe()
	if err != nil {
		return cli.Fail("could not open the stream to %s: %v", target, err)
	}
	save := exec.Command("docker", append([]string{"save"}, refs...)...)
	save.Stderr = os.Stderr
	src, err := save.StdoutPipe()
	if err != nil {
		return cli.Fail("could not run docker save: %v", err)
	}
	if err := load.Start(); err != nil {
		return cli.Fail("could not run ssh: %v", err)
	}
	pop := atexit.Push(func() { kill(save); kill(load) })
	defer pop()
	if err := save.Start(); err != nil {
		sink.Close()
		load.Wait()
		return cli.Fail("could not run docker save: %v", err)
	}

	out := &errWriter{w: sink}
	bw := bufio.NewWriterSize(out, 1<<20)
	gz := gzip.NewWriter(bw)
	_, copyErr := io.Copy(gz, src)
	if copyErr != nil {
		kill(save)
	}
	saveErr := save.Wait()
	var closeErr error
	if copyErr == nil && saveErr == nil {
		if closeErr = gz.Close(); closeErr == nil {
			closeErr = bw.Flush()
		}
	}
	sink.Close()
	loadErr := load.Wait()

	loadFailed := cli.Fail("could not load the images onto %s (the remote step exited %d, see above)", target, ssh.ExitCode(loadErr))
	switch {
	case out.err != nil && loadErr != nil:
		return loadFailed
	case out.err != nil:
		return cli.Fail("could not send the images to %s (%v)", target, out.err)
	case copyErr != nil:
		return cli.Fail("could not read docker save's output: %v", copyErr)
	case saveErr != nil:
		return cli.Fail("docker save %s failed (see docker's error above) — the server was sent no complete stream", strings.Join(refs, " "))
	case loadErr != nil:
		return loadFailed
	case closeErr != nil:
		return cli.Fail("could not send the images to %s (%v)", target, closeErr)
	}

	// A protocol, not a courtesy: a report that never arrived must not read as
	// a successful load.
	want := "loaded=" + strconv.Itoa(len(images))
	raw := strings.ReplaceAll(report.String(), "\r", "")
	for _, l := range strings.Split(raw, "\n") {
		if l == want {
			return nil
		}
	}
	e := cli.Fail("loading the images onto %s reported no %s", target, want).Cont(
		"the step was truncated, or the remote binary rejected it — raw output:")
	for _, l := range strings.Split(strings.TrimRight(raw, "\n"), "\n") {
		e.Cont("| " + l)
	}
	return e
}
