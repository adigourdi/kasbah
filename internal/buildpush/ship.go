package buildpush

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/serverbin"
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

// countWriter counts what reaches the wire.
type countWriter struct {
	w io.Writer
	n int64
}

func (c *countWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += int64(n)
	return n, err
}

// shipped is what a ship sent: gzip bytes on the wire, and the distinct
// layers the images carry and how many of those the server already had.
type shipped struct {
	sent         int64
	layers       int
	skipped      int
	skippedBytes int64
	// abandoned is what a skipping stream sent before the server failed to
	// load it and the images went again whole.
	abandoned int64
	// compressed: the server held some layers, but the save named none of
	// them by a name the run knew (a containerd-store workstation whose
	// layer names could not be learned).
	compressed bool
	// loadFailed: the stream arrived whole and the server's load failed.
	loadFailed bool
}

// errIncomplete is a load the server could not unpack: under the containerd
// store docker load exits 0 even then, so `remote load` reports it.
var errIncomplete = errors.New("incomplete")

// ship sends every image in one stream, minus the layers the server says it
// holds; a server that cannot load the images on those gets them whole.
func ship(out *cli.Output, conn *ssh.Conn, apps string, images []Image) (shipped, error) {
	refs := make([]string, len(images))
	for i, im := range images {
		refs[i] = im.Ref
	}
	skip, diffs := serverLayers(out, conn, apps, refs)
	drop, known := dropSet(out, refs, skip, diffs)
	st, err := stream(conn, apps, refs, drop, known)
	if err != nil && st.loadFailed && st.skipped > 0 {
		out.Warn("%s could not load the images on the layers it reported — sending them whole", conn.Target)
		first := st.sent
		st, err = stream(conn, apps, refs, nil, nil)
		st.abandoned = first
	}
	st.layers = len(diffs)
	if errors.Is(err, errIncomplete) {
		err = cli.Fail("%s could not unpack the images it loaded (see docker's error above)", conn.Target)
	}
	return st, err
}

// serverHeld is what the server holds of the images: the diffIDs that can stay
// home, and the blob names it knows each one by.
type serverHeld struct {
	ids   map[string]bool
	names map[string][]string
}

// serverLayers is what the server already holds — skippable diffIDs and their
// names — asked in one bounded round trip, and every diffID the images carry.
// Any answer that cannot be trusted means nothing is skipped.
func serverLayers(out *cli.Output, conn *ssh.Conn, apps string, refs []string) (skip serverHeld, known map[string]bool) {
	diffs, err := rootFS(refs)
	if err != nil {
		out.Warn("could not read the built images' layers (%v) — sending them whole", err)
		return serverHeld{}, nil
	}
	var chains []string
	known, asked := map[string]bool{}, map[string]bool{}
	for _, d := range diffs {
		for i, c := range chainIDs(d) {
			known[d[i]] = true
			if !asked[c] {
				asked[c] = true
				chains = append(chains, c)
			}
		}
	}
	if len(chains) == 0 {
		return serverHeld{}, known
	}
	bin := serverbin.Path(apps)
	raw, err := conn.Run(serverbin.Bounded(bin, serverbin.RunTimeout, append([]string{"layers", apps}, chains...)...)...)
	if err != nil {
		out.Warn("could not ask %s which layers it holds (the remote step exited %d) — sending the images whole", conn.Target, ssh.ExitCode(err))
		return serverHeld{}, known
	}
	a, err := parseHave(raw, chains, known)
	if err != nil {
		out.Warn("%s's layer list was not usable (%v) — sending the images whole", conn.Target, err)
		return serverHeld{}, known
	}
	return serverHeld{ids: skippable(diffs, a.have), names: a.names}, known
}

// dropSet is the blob names the filter leaves out, and every name known for a
// layer of the images. A skippable layer with no known name on a
// containerd-store workstation costs one local export to learn the names.
func dropSet(out *cli.Output, refs []string, skip serverHeld, diffs map[string]bool) (drop, known map[string]bool) {
	if len(skip.ids) == 0 {
		return nil, nil
	}
	drop, known = map[string]bool{}, map[string]bool{}
	for d := range diffs {
		known[d] = true
		for _, b := range skip.names[d] {
			known[b] = true
		}
	}
	unnamed := false
	for d := range skip.ids {
		drop[d] = true
		for _, b := range skip.names[d] {
			drop[b] = true
		}
		unnamed = unnamed || len(skip.names[d]) == 0
	}
	if !unnamed || !containerdStore() {
		return drop, known
	}
	out.Info("learning this workstation's layer names: one extra local export, nothing sent")
	local, err := learnLocal(refs)
	if err != nil {
		out.Warn("could not learn this workstation's layer names (%v)", err)
		return drop, known
	}
	for b, d := range local {
		if diffs[d] {
			known[b] = true
		}
		if skip.ids[d] {
			drop[b] = true
		}
	}
	return drop, known
}

// containerdStore is whether this engine keeps images in containerd's store,
// whose save names layers by their compressed digest.
func containerdStore() bool {
	raw, err := exec.Command("docker", "info", "--format", "{{json .DriverStatus}}").Output()
	if err != nil {
		return false
	}
	var status [][]string
	if json.Unmarshal(bytes.TrimSpace(raw), &status) != nil {
		return false
	}
	for _, kv := range status {
		if len(kv) == 2 && kv[0] == "driver-type" && kv[1] == "io.containerd.snapshotter.v1" {
			return true
		}
	}
	return false
}

// learnLocal is a `docker save` of refs read to its end for its layer names
// alone; nothing of it is kept or sent.
func learnLocal(refs []string) (names, error) {
	save := exec.Command("docker", append([]string{"save"}, refs...)...)
	var errb bytes.Buffer
	save.Stderr = &tail{&errb, 4 << 10}
	src, err := save.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := save.Start(); err != nil {
		return nil, err
	}
	pop := atexit.Push(func() { kill(save) })
	defer pop()
	n, lerr := learn(src)
	if err := save.Wait(); err != nil {
		return nil, fmt.Errorf("docker save exited %d: %s", ssh.ExitCode(err), strings.TrimSpace(errb.String()))
	}
	return n, lerr
}

// stream is one `docker save` of every image — one stream writes each shared
// layer once — filtered of skip's layers and gzipped on the way into `kasbah
// remote load` on the server. Nothing lands on disk on either end. The tar's
// end marker and the gzip trailer are written only after save has exited 0,
// so a save that fails reaches the server as a truncated stream, which the
// far side refuses, and never as a short valid one.
func stream(conn *ssh.Conn, apps string, refs []string, skip, known map[string]bool) (shipped, error) {
	var st shipped
	target := conn.Target.String()
	load := conn.Command(append([]string{serverbin.Path(apps), "remote", "load", apps}, refs...)...)
	var report bytes.Buffer
	load.Stdout = &report
	sink, err := load.StdinPipe()
	if err != nil {
		return st, cli.Fail("could not open the stream to %s: %v", target, err)
	}
	save := exec.Command("docker", append([]string{"save"}, refs...)...)
	save.Stderr = os.Stderr
	src, err := save.StdoutPipe()
	if err != nil {
		return st, cli.Fail("could not run docker save: %v", err)
	}
	if err := load.Start(); err != nil {
		return st, cli.Fail("could not run ssh: %v", err)
	}
	pop := atexit.Push(func() { kill(save); kill(load) })
	defer pop()
	if err := save.Start(); err != nil {
		sink.Close()
		load.Wait()
		return st, cli.Fail("could not run docker save: %v", err)
	}

	out := &errWriter{w: sink}
	wire := &countWriter{w: out}
	bw := bufio.NewWriterSize(wire, 1<<20)
	gz := gzip.NewWriter(bw)
	var f *filter
	var copyErr error
	if len(skip) > 0 {
		f = newFilter(gz, skip, known)
		copyErr = f.run(src)
	} else {
		_, copyErr = io.Copy(gz, src)
	}
	if copyErr != nil {
		kill(save)
	}
	saveErr := save.Wait()
	var closeErr error
	if copyErr == nil && saveErr == nil {
		if f != nil {
			closeErr = f.close()
		}
		if closeErr == nil {
			closeErr = gz.Close()
		}
		if closeErr == nil {
			closeErr = bw.Flush()
		}
	}
	sink.Close()
	loadErr := load.Wait()
	st.sent = wire.n
	if f != nil {
		st.skipped, st.skippedBytes, st.compressed = f.skipped, f.skippedBytes, f.matched == 0
	}
	raw := strings.ReplaceAll(report.String(), "\r", "")
	lines := strings.Split(raw, "\n")

	loadFailed := cli.Fail("could not load the images onto %s (the remote step exited %d, see above)", target, ssh.ExitCode(loadErr))
	switch {
	case out.err != nil && loadErr != nil:
		return st, loadFailed
	case out.err != nil:
		return st, cli.Fail("could not send the images to %s (%v)", target, out.err)
	case copyErr != nil:
		return st, cli.Fail("could not read docker save's output: %v", copyErr)
	case saveErr != nil:
		return st, cli.Fail("docker save %s failed (see docker's error above) — the server was sent no complete stream", strings.Join(refs, " "))
	case loadErr != nil:
		st.loadFailed = true
		for _, l := range lines {
			if strings.HasPrefix(l, "incomplete=") {
				return st, errIncomplete
			}
		}
		return st, loadFailed
	case closeErr != nil:
		return st, cli.Fail("could not send the images to %s (%v)", target, closeErr)
	}

	// A protocol, not a courtesy: a report that never arrived must not read as
	// a successful load.
	want := "loaded=" + strconv.Itoa(len(refs))
	for _, l := range lines {
		if l == want {
			return st, nil
		}
	}
	e := cli.Fail("loading the images onto %s reported no %s", target, want).Cont(
		"the step was truncated, or the remote binary rejected it — raw output:")
	for _, l := range strings.Split(strings.TrimRight(raw, "\n"), "\n") {
		e.Cont("| " + l)
	}
	return st, e
}
