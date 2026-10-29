// Package tmpl renders kasbah's templates/ files: __NAME__ tokens, one pass.
package tmpl

import (
	"fmt"
	"regexp"
	"strings"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

var reToken = regexp.MustCompile(`__[A-Z0-9_]+__`)

// Render substitutes __NAME__ tokens in one left-to-right pass; a token with
// no value is a hard failure, looked for in the template only.
func Render(tpl, label string, subst map[string]string) (string, error) {
	var b strings.Builder
	rest := tpl
	for {
		loc := reToken.FindStringIndex(rest)
		if loc == nil {
			break
		}
		tok := rest[loc[0]:loc[1]]
		val, ok := subst[strings.Trim(tok, "_")]
		if !ok {
			return "", cli.Fail("internal: the %s template uses %s, which the renderer has no value for — templates and renderer are out of step", label, tok)
		}
		b.WriteString(rest[:loc[0]])
		b.WriteString(val)
		rest = rest[loc[1]:]
	}
	b.WriteString(rest)
	return b.String(), nil
}

// CheckYAML reports whether the document parses and is not empty, null or false.
func CheckYAML(s string) error {
	docs, err := yamlx.Load([]byte(s))
	if err != nil {
		return err
	}
	if len(docs) == 0 || docs[len(docs)-1] == nil || docs[len(docs)-1] == false {
		return fmt.Errorf("the document is empty, null or false")
	}
	return nil
}

// Section keeps or drops the lines between `# [name]` and `# [/name]`; the
// marker lines themselves never survive. An unbalanced marker is a failure.
func Section(tpl, label, name string, keep bool) (string, error) {
	open, shut := "# ["+name+"]", "# [/"+name+"]"
	var b strings.Builder
	in := false
	for _, line := range strings.SplitAfter(tpl, "\n") {
		switch strings.TrimSpace(line) {
		case open:
			if in {
				return "", cli.Fail("internal: the %s template opens %s twice", label, open)
			}
			in = true
			continue
		case shut:
			if !in {
				return "", cli.Fail("internal: the %s template closes %s without opening it", label, shut)
			}
			in = false
			continue
		}
		if !in || keep {
			b.WriteString(line)
		}
	}
	if in {
		return "", cli.Fail("internal: the %s template never closes %s", label, open)
	}
	return b.String(), nil
}
