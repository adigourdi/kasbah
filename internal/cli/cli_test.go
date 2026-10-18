package cli

import (
	"bytes"
	"errors"
	"fmt"
	"testing"
)

func capture(color bool) (*Output, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	return &Output{Stdout: &out, Stderr: &errb, Color: color}, &out, &errb
}

// The codes are a contract (docs/cli.md); a renumbering is a break.
func TestExitCodes(t *testing.T) {
	got := []int{ExitOK, ExitFailure, ExitNoProject, ExitSSHUnreachable, ExitNoRemoteState, ExitEnvSetup, ExitComplianceFail, ExitInterrupted}
	want := []int{0, 1, 2, 3, 4, 5, 6, 130}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("code %d is %d, want %d", i, got[i], want[i])
		}
	}
}

// The formats lib/common.sh prints, byte for byte, and nothing on stdout.
func TestFormats(t *testing.T) {
	o, out, errb := capture(false)
	o.Info("Initialized kasbah project '%s'", "demo")
	o.Warn("domain is empty")
	o.Err("No kasbah.yml in current directory.")
	o.ErrCont("Run from the project root.")
	want := "Initialized kasbah project 'demo'\n" +
		"warning: domain is empty\n" +
		"error: No kasbah.yml in current directory.\n" +
		"       Run from the project root.\n"
	if errb.String() != want {
		t.Errorf("stderr:\n%q\nwant\n%q", errb.String(), want)
	}
	if out.Len() != 0 {
		t.Errorf("stdout carries messages: %q", out.String())
	}
}

func TestColor(t *testing.T) {
	o, _, errb := capture(true)
	o.Info("i")
	o.Warn("w")
	o.Err("e")
	o.ErrCont("c")
	want := "\033[36mi\033[0m\n\033[33mwarning:\033[0m w\n\033[31merror:\033[0m e\n       c\n"
	if errb.String() != want {
		t.Errorf("stderr %q, want %q", errb.String(), want)
	}
}

func TestReport(t *testing.T) {
	o, _, errb := capture(false)
	e := Failf(ExitNoProject, "No kasbah.yml in current directory.").Cont("Run from the project root, or `kasbah init-project` to scaffold.")
	if code := o.Report(fmt.Errorf("wrapped: %w", e)); code != 2 {
		t.Errorf("code %d, want 2", code)
	}
	want := "error: No kasbah.yml in current directory.\n       Run from the project root, or `kasbah init-project` to scaffold.\n"
	if errb.String() != want {
		t.Errorf("stderr %q, want %q", errb.String(), want)
	}

	o, _, errb = capture(false)
	if code := o.Report(errors.New("plain")); code != 1 || errb.String() != "error: plain\n" {
		t.Errorf("plain error: code %d, stderr %q", code, errb.String())
	}
	o, _, errb = capture(false)
	if code := o.Report(nil); code != 0 || errb.Len() != 0 {
		t.Errorf("nil error: code %d, stderr %q", code, errb.String())
	}
	if Fail("x").Code != 1 {
		t.Error("Fail is exit 1")
	}
}
