package env

import (
	"fmt"
	"os"
	"strings"

	"github.com/adigourdi/kasbah/internal/envtpl"
)

// Report is always four key=value lines — existence of each file and the
// drift between them; a path there but not a regular file is an error.
func Report(dir string) (string, error) {
	template, envfile := dir+"/.env.prod.example", dir+"/.env"
	exists := map[string]bool{}
	for _, p := range []string{envfile, template} {
		fi, err := os.Stat(p)
		if err != nil {
			continue
		}
		if !fi.Mode().IsRegular() {
			return "", fmt.Errorf("%s exists and is not a regular file", p)
		}
		exists[p] = true
	}
	yn := func(b bool) string {
		if b {
			return "yes"
		}
		return "no"
	}
	missing, extra := envtpl.Drift(template, envfile)
	return fmt.Sprintf("template_exists=%s\nenv_exists=%s\nmissing=%s\nextra=%s\n",
		yn(exists[template]), yn(exists[envfile]), strings.Join(missing, " "), strings.Join(extra, " ")), nil
}

// State is a Report read back on the workstation.
type State struct {
	TemplateExists, EnvExists bool
	Missing, Extra            string
}

// ParseReport reads a Report, checking its key set as a protocol first: an
// answer that never arrived must not be absorbed into a passing branch.
func ParseReport(out string) (State, []string) {
	var st State
	seen := map[string]bool{}
	for _, l := range strings.Split(out, "\n") {
		k, v, ok := strings.Cut(strings.TrimSuffix(l, "\r"), "=")
		if !ok {
			continue
		}
		switch k {
		case "template_exists":
			st.TemplateExists = v == "yes"
		case "env_exists":
			st.EnvExists = v == "yes"
		case "missing":
			st.Missing = v
		case "extra":
			st.Extra = v
		default:
			continue
		}
		seen[k] = true
	}
	var absent []string
	for _, k := range []string{"template_exists", "env_exists", "missing", "extra"} {
		if !seen[k] {
			absent = append(absent, k)
		}
	}
	return st, absent
}
