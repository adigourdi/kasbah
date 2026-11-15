// Package help is `kasbah help [topic]`: summaries of what kasbah is, a
// project's files, its setups, check's rules, the debug trace and the common
// failures, each ending with the link to its doc at this build's version.
// `help <command>` is the command's own --help, which the CLI runs in its place.
package help

import (
	"embed"
	"fmt"
	"strings"

	"github.com/adigourdi/kasbah/internal/check"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/version"
)

//go:embed topics/*.txt
var topics embed.FS

func text(name string) string {
	b, err := topics.ReadFile("topics/" + name + ".txt")
	if err != nil {
		panic(err)
	}
	return string(b)
}

// Topics are the named topics, in the order an unknown one lists them.
var Topics = []string{"files", "setups", "rules", "debug", "troubleshooting"}

// Topic is the text for topic under build: "" (or -h, --help) is the index.
// An unknown topic is an error naming the valid ones.
func Topic(build, topic string) (string, error) {
	var body, doc string
	switch topic {
	case "", "-h", "--help", "help":
		body, doc = text("index"), "README.md"
	case "files":
		body, doc = text("files"), "authoring.md"
	case "setups":
		body, doc = text("setups"), "authoring.md#setups"
	case "rules":
		body, doc = text("rules")+rules(), "compliance.md"
	case "debug":
		body, doc = text("debug"), "cli.md#debugging-a-failure"
	case "troubleshooting":
		body, doc = text("troubleshooting"), "troubleshooting.md"
	default:
		r, ok := check.Lookup(topic)
		if !ok {
			return "", cli.Fail("help: unknown topic '%s' — the topics are %s, a rule ID (C01), or a command; `kasbah help` lists them", topic, strings.Join(Topics, ", "))
		}
		body, doc = rule(r), "compliance.md"
	}
	return body + "\n" + version.DocsURL(build, doc) + "\n", nil
}

// rules is one line a rule, grouped by area.
func rules() string {
	var b strings.Builder
	for _, a := range check.Areas {
		fmt.Fprintf(&b, "\n%s:\n", a)
		for _, r := range check.Rules {
			if r.Area != a {
				continue
			}
			srv := ""
			if r.Server {
				srv = "[--server] "
			}
			fmt.Fprintf(&b, "  %-4s  %-9s  %s%s\n", r.ID, r.Level, srv, r.Title)
		}
	}
	return b.String()
}

func rule(r check.Rule) string {
	var b strings.Builder
	where := r.Area
	if r.Server {
		where += ", asked by check --server"
	}
	fmt.Fprintf(&b, "%s  %s  (%s)\n%s\n\n", r.ID, r.Level, where, r.Title)
	b.WriteString(wrap("Why: "+r.Why, 76))
	b.WriteString("\n")
	b.WriteString(wrap("Change: "+r.Change, 76))
	return b.String()
}

// wrap breaks s into lines of at most width characters at spaces, the lines
// after the first indented two.
func wrap(s string, width int) string {
	var b strings.Builder
	n := 0
	for i, w := range strings.Fields(s) {
		l := len([]rune(w))
		switch {
		case i == 0:
		case n+1+l > width:
			b.WriteString("\n  ")
			n = 2
		default:
			b.WriteString(" ")
			n++
		}
		b.WriteString(w)
		n += l
	}
	b.WriteString("\n")
	return b.String()
}
