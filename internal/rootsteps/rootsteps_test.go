package rootsteps

import (
	"bytes"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
)

func TestQuote(t *testing.T) {
	for in, want := range map[string]string{"/srv/apps": "/srv/apps", "u:g": "u:g", "/my apps": "'/my apps'", "it's": `'it'\''s'`} {
		if got := Quote(in); got != want {
			t.Errorf("%q: %q, want %q", in, got, want)
		}
	}
}

func TestLines(t *testing.T) {
	b := &Block{Target: "d@h", User: "d"}
	b.Add("sudo mkdir /apps", "sudo chown d:d /apps")
	got := strings.Join(b.Lines(), "\n")
	want := "Run on d@h, as root or as d with your own sudo (`sudo -n` is not available to them):\n    sudo mkdir /apps\n    sudo chown d:d /apps"
	if got != want {
		t.Errorf("got\n%s\nwant\n%s", got, want)
	}
}

func await(tty bool, answers string, b *Block, left ...*Block) (bool, *Block, error, string, int) {
	var e bytes.Buffer
	p := &prompt.Prompter{In: strings.NewReader(answers), Out: &cli.Output{Stdout: &e, Stderr: &e}, TTY: tty}
	checks := 0
	rounds := 0
	done, last, err := Await(p, func() []string { rounds++; return []string{"why", string(rune('0' + rounds))} }, b, func() (*Block, error) {
		checks++
		next := left[0]
		left = left[1:]
		return next, nil
	})
	return done, last, err, e.String(), checks
}

func TestAwait(t *testing.T) {
	b := &Block{Target: "d@h", Commands: []string{"sudo mkdir /apps", "sudo chown d:d /apps"}}
	rest := &Block{Target: "d@h", Commands: []string{"sudo chown d:d /apps"}}
	if done, last, err, out, n := await(false, "", b); done || last != b || err != nil || out != "" || n != 0 {
		t.Errorf("no tty: %v %v %q %d", done, err, out, n)
	}
	// Enter, half done: only what is left is shown again, under a reason asked
	// afresh; Enter, done.
	done, last, err, out, n := await(true, "\n\n", b, rest, &Block{})
	if !done || !last.Empty() || err != nil || n != 2 || strings.Count(out, "sudo mkdir /apps") != 1 ||
		strings.Count(out, "sudo chown d:d /apps") != 2 || !strings.Contains(out, "why\n2\n") ||
		!strings.Contains(out, "warning: d@h still needs root") {
		t.Errorf("enter: %v %v %d\n%s", done, err, n, out)
	}
	// Half done, then q: the block handed back is what is left.
	if done, last, _, _, n := await(true, "\nq\n", b, rest); done || n != 1 || last != rest {
		t.Errorf("half done, then q: %v %d %v", done, n, last)
	}
	if done, last, _, _, n := await(true, "q\n", b); done || n != 0 || last != b {
		t.Errorf("q: %v %d", done, n)
	}
	if done, _, _, out, n := await(true, "yes\n", b); done || n != 0 || !strings.Contains(out, "press Enter, or type q") {
		t.Errorf("anything else, then end of input: %v %d %q", done, n, out)
	}
	if done, _, _, out, _ := await(true, "", &Block{}); !done || out != "" {
		t.Errorf("an empty block: %v %q", done, out)
	}
}
