package buildpush

import (
	"bufio"
	"compress/gzip"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/ssh"
)

// Load is `kasbah remote load IMAGE...` on the server: a gzipped `docker save`
// on stdin into `docker load`, then `loaded=<n>` on stdout once every image is
// there; docker load's narration goes to stderr. `docker save` writes every
// blob before index.json and manifest.json, and docker refuses short input, so
// a cut stream never leaves a partial image tagged; a cut in the gzip trailer
// alone can at worst report failure for images that did load.
const loadUsage = "usage: kasbah remote load IMAGE... (a gzipped docker save of those images on stdin)"

func Load(images []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fail := func(format string, args ...any) int {
		fmt.Fprintf(stderr, "remote: "+format+"\n", args...)
		return 1
	}
	for _, a := range images {
		if a == "-h" || a == "--help" {
			fmt.Fprintln(stdout, loadUsage)
			return 0
		}
		if strings.HasPrefix(a, "-") {
			return fail("load: unknown flag '%s' — %s", a, loadUsage)
		}
	}
	if len(images) == 0 {
		return fail("load: no images named — %s", loadUsage)
	}
	zr, err := gzip.NewReader(bufio.NewReaderSize(stdin, 1<<20))
	if errors.Is(err, io.EOF) {
		return fail("no image stream arrived — nothing was loaded")
	}
	if err != nil {
		return fail("the image stream is not gzip (%v) — nothing was loaded", err)
	}

	dl := exec.Command("docker", "load")
	dl.Env = append(os.Environ(), "LC_ALL=C")
	dl.Stdout, dl.Stderr = stderr, stderr
	w, err := dl.StdinPipe()
	if err != nil {
		return fail("cannot run docker load: %v", err)
	}
	if err := dl.Start(); err != nil {
		return fail("cannot run docker load: %v", err)
	}
	pop := atexit.Push(func() { kill(dl) })
	defer pop()

	sink := &errWriter{w: w}
	_, cerr := io.Copy(sink, zr)
	if cerr != nil && sink.err == nil {
		// Killed before its stdin closes, so docker never sees a clean end.
		kill(dl)
		w.Close()
		dl.Wait()
		return fail("the image stream was cut short or corrupted (%v) — the load was abandoned", cerr)
	}
	w.Close()
	if err := dl.Wait(); err != nil {
		return fail("docker load exited %d", ssh.ExitCode(err))
	}
	if cerr != nil {
		return fail("docker load stopped reading its input (%v)", cerr)
	}

	// Asked of the daemon: what the next deploy retags is the tag.
	for _, img := range images {
		if exec.Command("docker", "image", "inspect", img).Run() != nil {
			return fail("%s is not on this server after docker load", img)
		}
	}
	fmt.Fprintf(stdout, "loaded=%d\n", len(images))
	return 0
}
