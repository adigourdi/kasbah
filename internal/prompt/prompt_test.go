package prompt

import (
	"bytes"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
)

// closed is no terminal at all; tty is a terminal that will type input.
func closed() (*Prompter, *bytes.Buffer) {
	var errb bytes.Buffer
	return &Prompter{In: strings.NewReader(""), Out: &cli.Output{Stdout: &bytes.Buffer{}, Stderr: &errb}}, &errb
}

func tty(input string) (*Prompter, *bytes.Buffer) {
	p, errb := closed()
	p.In = strings.NewReader(input)
	p.TTY = true
	return p, errb
}

func failText(t *testing.T, err error) string {
	t.Helper()
	e, ok := err.(*cli.Error)
	if !ok {
		t.Fatalf("want a *cli.Error, got %T %v", err, err)
	}
	if e.Code != cli.ExitFailure {
		t.Errorf("exit %d, want 1", e.Code)
	}
	return e.Error()
}

// Case 1: an explicit flag answers, with no terminal in sight, silently.
func TestFlagAnswers(t *testing.T) {
	p, errb := closed()
	if a, err := p.Bool("mail", "Enable mail?", Yes); err != nil || !a {
		t.Errorf("--with-mail: %v %v", a, err)
	}
	if a, err := p.Bool("mail", "Enable mail?", No); err != nil || a {
		t.Errorf("--no-mail: %v %v", a, err)
	}
	if a, err := p.Value("domain", "Domain?", "app.example.com", ""); err != nil || a != "app.example.com" {
		t.Errorf("--domain=: %q %v", a, err)
	}
	if a, err := p.Value("domain", "Domain?", "crlf.example.com\r", ""); err != nil || a != "crlf.example.com" {
		t.Errorf("a given value loses one trailing CR: %q %v", a, err)
	}
	if a, err := p.Secret("traefik-auth", "Password?", "hunter2"); err != nil || a != "hunter2" {
		t.Errorf("a given secret: %q %v", a, err)
	}
	if a, err := p.Confirm("yes", "Reset acme.json?", true); err != nil || !a {
		t.Errorf("--yes: %v %v", a, err)
	}
	if a, err := p.Typed("yes", "demo", "Type the name:", true); err != nil || !a {
		t.Errorf("--yes on a typed confirmation: %v %v", a, err)
	}
	if a, err := p.Choice(Pair{"reset-acme", "keep-acme"}, "Reset the store?", No); err != nil || a {
		t.Errorf("--keep-acme: %v %v", a, err)
	}
	if errb.Len() != 0 {
		t.Errorf("answering from a flag says nothing, said %q", errb.String())
	}
}

// Case 2: no flag and no terminal is a hard failure naming the flags.
func TestNoTerminalFails(t *testing.T) {
	cases := []struct {
		name string
		call func(p *Prompter) error
		want string
	}{
		{"bool", func(p *Prompter) error { _, err := p.Bool("mail", "Enable mail?", Unset); return err },
			"cannot ask: Enable mail?\nstdin is not a terminal — pass --with-mail or --no-mail instead"},
		{"value", func(p *Prompter) error { _, err := p.Value("domain", "Domain?", "", ""); return err },
			"cannot ask: Domain?\nstdin is not a terminal — pass --domain=<value> instead"},
		// A default is not an answer: without a terminal the flag is still required.
		{"value-default", func(p *Prompter) error { _, err := p.Value("domain", "Domain?", "", "app.example.com"); return err },
			"cannot ask: Domain?\nstdin is not a terminal — pass --domain=<value> instead"},
		{"secret", func(p *Prompter) error { _, err := p.Secret("traefik-auth", "Password?", ""); return err },
			"cannot ask: Password?\nstdin is not a terminal — pass --traefik-auth=<value> instead"},
		{"confirm", func(p *Prompter) error { _, err := p.Confirm("yes", "Reset acme.json?", false); return err },
			"cannot ask: Reset acme.json?\nstdin is not a terminal — pass --yes instead"},
		{"typed", func(p *Prompter) error { _, err := p.Typed("yes", "demo", "Type the name:", false); return err },
			"cannot ask: Type the name:\nstdin is not a terminal — pass --yes instead"},
		{"choice", func(p *Prompter) error {
			_, err := p.Choice(Pair{"reset-acme", "keep-acme"}, "Reset the store?", Unset)
			return err
		}, "cannot ask: Reset the store?\nstdin is not a terminal — pass --reset-acme or --keep-acme instead"},
	}
	for _, c := range cases {
		p, errb := closed()
		err := c.call(p)
		if got := failText(t, err); got != c.want {
			t.Errorf("%s:\n%s\nwant\n%s", c.name, got, c.want)
		}
		if errb.Len() != 0 {
			t.Errorf("%s: printed before failing: %q", c.name, errb.String())
		}
	}
	// The whole failure as the operator reads it.
	var errb bytes.Buffer
	_, err := (&Prompter{In: strings.NewReader(""), Out: &cli.Output{Stderr: &errb}}).Confirm("yes", "Reset acme.json?", false)
	(&cli.Output{Stderr: &errb}).Report(err)
	want := "error: cannot ask: Reset acme.json?\n       stdin is not a terminal — pass --yes instead\n"
	if errb.String() != want {
		t.Errorf("reported %q, want %q", errb.String(), want)
	}
}

// Case 3: the terminal branch.
func TestTerminal(t *testing.T) {
	p, errb := tty("y\n")
	if a, err := p.Bool("mail", "Enable mail?", Unset); err != nil || !a {
		t.Errorf("y: %v %v", a, err)
	}
	if errb.String() != "Enable mail? [y/n] " {
		t.Errorf("the question reaches the terminal as %q", errb.String())
	}

	p, _ = tty("n\n")
	if a, err := p.Bool("mail", "Enable mail?", Unset); err != nil || a {
		t.Errorf("n: %v %v", a, err)
	}

	// A flag outranks the terminal: the question never appears.
	p, errb = tty("")
	if a, err := p.Bool("mail", "Enable mail?", Yes); err != nil || !a || errb.Len() != 0 {
		t.Errorf("flag over terminal: %v %v %q", a, err, errb.String())
	}

	p, errb = tty("maybe\ny\n")
	if a, err := p.Bool("mail", "Enable mail?", Unset); err != nil || !a {
		t.Errorf("re-ask: %v %v", a, err)
	}
	if want := "Enable mail? [y/n] warning: answer y or n\nEnable mail? [y/n] "; errb.String() != want {
		t.Errorf("re-ask said %q, want %q", errb.String(), want)
	}

	// EOF at the prompt is as unanswered as no terminal — and a line cut off
	// by EOF is no answer, whatever it held, as with bash's read.
	for _, in := range []string{"", "y"} {
		p, _ = tty(in)
		_, err := p.Bool("mail", "Enable mail?", Unset)
		want := "cannot ask: Enable mail?\nno answer given — pass --with-mail or --no-mail instead"
		if got := failText(t, err); got != want {
			t.Errorf("EOF after %q: %q", in, got)
		}
	}

	p, _ = tty("app.example.com\n")
	if a, err := p.Value("domain", "Domain?", "", ""); err != nil || a != "app.example.com" {
		t.Errorf("typed value: %q %v", a, err)
	}

	p, errb = tty("\n")
	if a, err := p.Value("domain", "Domain?", "", "fallback.example.com"); err != nil || a != "fallback.example.com" {
		t.Errorf("default: %q %v", a, err)
	}
	if errb.String() != "Domain? [fallback.example.com]: " {
		t.Errorf("the default is shown: %q", errb.String())
	}

	p, errb = tty("\nreal.example.com\n")
	if a, err := p.Value("domain", "Domain?", "", ""); err != nil || a != "real.example.com" {
		t.Errorf("re-asked value: %q %v", a, err)
	}
	if want := "Domain?: warning: an answer is required\nDomain?: "; errb.String() != want {
		t.Errorf("value re-ask said %q", errb.String())
	}

	// read's trimming: blanks and tabs off both ends, then one CR.
	p, _ = tty(" \tY\r\n")
	if a, err := p.Bool("mail", "Enable mail?", Unset); err != nil || !a {
		t.Errorf("trimmed answer: %v %v", a, err)
	}

	p, errb = tty("hunter2\n")
	hidden := 0
	p.NoEcho = func() (func() error, error) { hidden++; return func() error { hidden--; return nil }, nil }
	if a, err := p.Secret("traefik-auth", "Password?", ""); err != nil || a != "hunter2" {
		t.Errorf("secret: %q %v", a, err)
	}
	if hidden != 0 || errb.String() != "Password?: \n" {
		t.Errorf("secret: echo balance %d, said %q", hidden, errb.String())
	}
}

// Case 6: confirming a destructive act — one flag, and declining is an answer.
func TestConfirm(t *testing.T) {
	p, _ := tty("y\n")
	if a, err := p.Confirm("yes", "Reset acme.json?", false); err != nil || !a {
		t.Errorf("y: %v %v", a, err)
	}
	p, _ = tty("n\n")
	if a, err := p.Confirm("yes", "Reset acme.json?", false); err != nil || a {
		t.Errorf("n is an answer, not an error: %v %v", a, err)
	}
	p, _ = tty("")
	_, err := p.Confirm("yes", "Reset acme.json?", false)
	if got := failText(t, err); !strings.Contains(got, "pass --yes instead") || strings.Contains(got, "--no-yes") {
		t.Errorf("EOF at the confirmation: %q", got)
	}
}

// Case 8: the typed half of a double confirmation.
func TestTyped(t *testing.T) {
	cases := []struct {
		in, expected string
		want         bool
	}{
		{"demo\n", "demo", true},
		{"vps.example.com\n", "vps.example.com", true},
		{"  demo  \n", "demo", true},
		{"demonstration\n", "demo", false},
		{"dem\n", "demo", false},
	}
	for _, c := range cases {
		p, errb := tty(c.in)
		a, err := p.Typed("yes", c.expected, "Type the name:", false)
		if err != nil || a != c.want {
			t.Errorf("%q against %q: %v %v", c.in, c.expected, a, err)
		}
		if errb.String() != "Type the name: " {
			t.Errorf("typed prompt %q", errb.String())
		}
	}
	p, _ := tty("")
	if _, err := p.Typed("yes", "demo", "Type the name:", false); !strings.Contains(failText(t, err), "pass --yes instead") {
		t.Errorf("EOF at the typed prompt: %v", err)
	}
	if _, err := p.Typed("yes", "", "Type the name:", true); err == nil || !strings.Contains(err.Error(), "nothing for the operator to type") {
		t.Errorf("an empty expectation is a caller mistake: %v", err)
	}
}

// Case 7: a choice's flags are both named, never derived.
func TestChoice(t *testing.T) {
	p, _ := tty("n\n")
	if a, err := p.Choice(Pair{"reset-acme", "keep-acme"}, "Reset the store?", Unset); err != nil || a {
		t.Errorf("n at a choice: %v %v", a, err)
	}
	p, _ = tty("")
	_, err := p.Choice(Pair{"reset-acme", "keep-acme"}, "Reset the store?", Unset)
	if got := failText(t, err); !strings.Contains(got, "--reset-acme or --keep-acme") || strings.Contains(got, "--with-") {
		t.Errorf("EOF at a choice: %q", got)
	}
}

func TestGiven(t *testing.T) {
	var g Given
	mail := Feature("mail")
	if err := g.Set(Yes, mail, "server init"); err != nil || g != Yes {
		t.Fatal(err)
	}
	if err := g.Set(Yes, mail, "server init"); err != nil {
		t.Errorf("repeating a flag is not a conflict: %v", err)
	}
	err := g.Set(No, mail, "server init")
	if err == nil || err.Error() != "server init: --with-mail and --no-mail cannot both be given" {
		t.Errorf("conflict: %v", err)
	}
}
