// Package rootsteps is root-only work a run cannot do itself because
// `sudo -n` is not available: the commands are printed for the operator to
// run on the server, and on a terminal the run waits for them and checks again.
package rootsteps

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/prompt"
)

// Block is the commands, in order, that bring the server to the state a step
// needs — only the ones its current state calls for.
type Block struct {
	Target   string
	User     string
	Commands []string
}

// Add appends commands to the block.
func (b *Block) Add(cmd ...string) { b.Commands = append(b.Commands, cmd...) }

// Empty is a block with nothing left to run.
func (b *Block) Empty() bool { return b == nil || len(b.Commands) == 0 }

// Lines is the block as printed: one line naming where and as whom, then one
// copy-pasteable command per line.
func (b *Block) Lines() []string {
	who := "as root or with your own sudo"
	if b.User != "" {
		who = fmt.Sprintf("as root or as %s with your own sudo (`sudo -n` is not available to them)", b.User)
	}
	l := []string{fmt.Sprintf("Run on %s, %s:", b.Target, who)}
	for _, c := range b.Commands {
		l = append(l, "    "+c)
	}
	return l
}

var plain = regexp.MustCompile(`^[A-Za-z0-9_./:@%+=,-]+$`)

// Quote is s as one POSIX shell word.
func Quote(s string) string {
	if plain.MatchString(s) {
		return s
	}
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

// Await is for a terminal only; without one it prints nothing and is not
// done. On one it shows why() and the block, waits for Enter, and asks check
// what is left, until nothing is or the operator types q. The block it returns
// is the last one shown: what was still left when it stopped.
func Await(p *prompt.Prompter, why func() []string, b *Block, check func() (*Block, error)) (bool, *Block, error) {
	if b.Empty() {
		return true, b, nil
	}
	if !p.TTY {
		return false, b, nil
	}
	for {
		for _, l := range why() {
			fmt.Fprintln(p.Out.Stderr, l)
		}
		for _, l := range b.Lines() {
			fmt.Fprintln(p.Out.Stderr, l)
		}
		if !p.Wait("Press Enter once they have run, or type q to stop:") {
			return false, b, nil
		}
		next, err := check()
		if err != nil {
			return false, b, err
		}
		if next.Empty() {
			return true, next, nil
		}
		p.Out.Warn("%s still needs root — checked again just now", b.Target)
		b = next
	}
}
