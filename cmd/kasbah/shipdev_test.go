package main

import (
	"io"
	"reflect"
	"strings"
	"testing"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/prompt"
	"github.com/adigourdi/kasbah/internal/serverbin"
)

func TestDevFlags(t *testing.T) {
	for _, tt := range []struct {
		args  []string
		rest  []string
		given prompt.Given
		err   string
	}{
		{[]string{"deploy", "u@h"}, []string{"deploy", "u@h"}, prompt.Unset, ""},
		{[]string{"--ship-dev", "deploy", "u@h"}, []string{"deploy", "u@h"}, prompt.Yes, ""},
		{[]string{"server", "status", "u@h", "--keep-server"}, []string{"server", "status", "u@h"}, prompt.No, ""},
		{[]string{"deploy", "--keep-server", "--keep-server"}, []string{"deploy"}, prompt.No, ""},
		// What follows `--` is exec's command, never kasbah's flags.
		{[]string{"exec", "web", "--", "app", "--ship-dev"}, []string{"exec", "web", "--", "app", "--ship-dev"}, prompt.Unset, ""},
		{[]string{"deploy", "--ship-dev", "--keep-server"}, nil, 0, "--ship-dev and --keep-server cannot both be given"},
	} {
		rest, given, err := devFlags(tt.args)
		if tt.err != "" {
			if err == nil || !strings.Contains(err.Error(), tt.err) {
				t.Errorf("%q: got %v, want %q", tt.args, err, tt.err)
			}
			continue
		}
		if err != nil || !reflect.DeepEqual(rest, tt.rest) || given != tt.given {
			t.Errorf("%q: got %q, %v, %v; want %q, %v", tt.args, rest, given, err, tt.rest, tt.given)
		}
	}
}

// The flags answer serverbin's question — in a hand-off, KASBAH_SHIP_DEV —
// and without either or a terminal the run fails naming both flags.
func TestAnswerShipDev(t *testing.T) {
	saved := serverbin.ShipDev
	t.Cleanup(func() { serverbin.ShipDev = saved })
	noTTY := &prompt.Prompter{In: strings.NewReader(""), Out: &cli.Output{Stdout: io.Discard, Stderr: io.Discard}}
	handoff := map[string]string{"KASBAH_HANDOFF": "1.1.0"}
	for _, tt := range []struct {
		flag   string
		env    map[string]string
		want   bool
		answer string
		err    string
	}{
		{"--ship-dev", nil, true, "ship", ""},
		{"--keep-server", nil, false, "keep", ""},
		{"", nil, false, "", "pass --ship-dev or --keep-server instead"},
		{"", map[string]string{"KASBAH_HANDOFF": "1.1.0", "KASBAH_SHIP_DEV": "ship"}, true, "ship", ""},
		{"", map[string]string{"KASBAH_HANDOFF": "1.1.0", "KASBAH_SHIP_DEV": "keep"}, false, "keep", ""},
		// Outside a hand-off the variable answers nothing.
		{"", map[string]string{"KASBAH_SHIP_DEV": "ship"}, false, "", "pass --ship-dev or --keep-server instead"},
		{"", handoff, false, "", "pass --ship-dev or --keep-server instead"},
		{"--keep-server", map[string]string{"KASBAH_HANDOFF": "1.1.0", "KASBAH_SHIP_DEV": "ship"}, false, "keep", ""},
	} {
		args := []string{"deploy"}
		if tt.flag != "" {
			args = append(args, tt.flag)
		}
		rest, answer, err := answerShipDev(noTTY, args, func(k string) string { return tt.env[k] })
		if err != nil || !reflect.DeepEqual(rest, []string{"deploy"}) || answer != tt.answer {
			t.Fatalf("%q %v: %q, %q, %v; want answer %q", args, tt.env, rest, answer, err, tt.answer)
		}
		got, err := serverbin.ShipDev("1.1.0", "1.1.1-dev.14.1")
		if tt.err != "" {
			if err == nil || !strings.Contains(err.Error(), tt.err) || !strings.Contains(err.Error(), "1.1.0") {
				t.Errorf("%q %v: got %v, %v; want a refusal saying %q", args, tt.env, got, err, tt.err)
			}
			continue
		}
		if err != nil || got != tt.want {
			t.Errorf("%q %v: got %v, %v; want %v", args, tt.env, got, err, tt.want)
		}
	}
	env := map[string]string{"KASBAH_HANDOFF": "1.1.0", "KASBAH_SHIP_DEV": "yes"}
	if _, _, err := answerShipDev(noTTY, []string{"deploy"}, func(k string) string { return env[k] }); err == nil || !strings.Contains(err.Error(), "KASBAH_SHIP_DEV='yes'") {
		t.Errorf("an unknown answer: %v", err)
	}
}

// Unwired, serverbin's question reads no terminal: it fails naming the flags.
func TestShipDevDefault(t *testing.T) {
	got, err := serverbin.ShipDev("1.1.0", "1.1.1-dev.14.1")
	if err == nil || got || !strings.Contains(err.Error(), "pass --ship-dev or --keep-server instead") {
		t.Errorf("got %v, %v", got, err)
	}
}
