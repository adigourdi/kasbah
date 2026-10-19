package history

import (
	"strings"
	"testing"
)

func TestParse(t *testing.T) {
	if o, err := Parse("history", []string{"d@h", "--all"}); err != nil || o.Target != "d@h" || !o.All {
		t.Fatalf("history: %+v %v", o, err)
	}
	if o, err := Parse("pending", []string{"2.0.0", "d@h"}); err != nil || o.Version != "2.0.0" || o.Target != "d@h" {
		t.Fatalf("pending: %+v %v", o, err)
	}
	for _, c := range []struct {
		cmd  string
		args []string
		want string
	}{
		{"pending", []string{"--all"}, "the archived half of the record is `kasbah history USER@HOST --all`"},
		{"history", []string{"--all=yes"}, "--all takes no value"},
		{"history", []string{"vps"}, "'vps' is not a server"},
		{"changelog", []string{"1.2.3"}, "takes no version"},
		{"pending", []string{"a@b", "c@d"}, "two servers given"},
		{"pending", []string{"v1.0.0"}, "write the version without the 'v'"},
		{"changelog", []string{"--x"}, "changelog: unknown flag '--x' (changelog takes USER@HOST)"},
	} {
		if _, err := Parse(c.cmd, c.args); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s %v = %v", c.cmd, c.args, err)
		}
	}
	if _, err := Parse("changelog", []string{"-h"}); err != ErrHelp {
		t.Errorf("-h = %v", err)
	}
}
