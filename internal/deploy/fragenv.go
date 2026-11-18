package deploy

import (
	"fmt"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/adigourdi/kasbah/internal/envtpl"
	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// fragRef is `$${`, a literal `${`, or a `${KEY}` the fragment takes from the
// project's .env. Anything else — `$1`, `${1}`, `$apr1$…` — is left as written.
var fragRef = regexp.MustCompile(`\$\$\{|\$\{([A-Za-z_][A-Za-z0-9_]*)\}`)

// FragmentKeys is each ${KEY} a fragment names, in file order, once.
func FragmentKeys(text []byte) []string {
	var keys []string
	seen := map[string]bool{}
	for _, m := range fragRef.FindAllSubmatch(text, -1) {
		if k := string(m[1]); k != "" && !seen[k] {
			seen[k] = true
			keys = append(keys, k)
		}
	}
	return keys
}

// RenderFragment fills each ${KEY} from dir's .env and writes `$${` as `${`,
// keeping the template's YAML structure; no refusal quotes a value. tagged (an
// old version's text) leaves an undeclared or KASBAH_ ${…} as written, in kept.
func RenderFragment(dir string, text []byte, target string, tagged bool) (out []byte, kept []string, err error) {
	if !fragRef.Match(text) {
		return text, nil, nil
	}
	keys := FragmentKeys(text)
	vals := map[string]string{}
	filled := map[string]bool{}
	var bad []string
	if len(keys) > 0 {
		declared := map[string]bool{}
		for _, k := range envtpl.Keys(dir + "/.env.prod.example") {
			declared[k] = true
		}
		data, rerr := os.ReadFile(dir + "/.env")
		var verr error
		if rerr == nil {
			vals, verr = envtpl.ValuesOf(data)
		}
		set := func(k string) string { return "`" + strings.TrimSpace("kasbah env set "+k+" "+target) + "`" }
		for _, k := range keys {
			v, ok := vals[k]
			reserved := strings.HasPrefix(k, envtpl.ReservedPrefix)
			switch {
			case tagged && (reserved || !declared[k]):
				kept = append(kept, k)
				continue
			case reserved:
				bad = append(bad, fmt.Sprintf("${%s} is a %s key — kasbah's own, never the fragment's: name a key of .env.prod.example instead (kasbah help T12)", k, envtpl.ReservedPrefix))
			case !declared[k]:
				bad = append(bad, fmt.Sprintf("${%s} is not declared in %s/.env.prod.example — declare it there, then %s sets it (kasbah help T12)", k, dir, set(k)))
			case rerr != nil:
				bad = append(bad, fmt.Sprintf("${%s} has no value: %s/.env cannot be read — %s sets it", k, dir, set(k)))
			case !ok && verr != nil:
				bad = append(bad, fmt.Sprintf("${%s} has no value: a line of %s/.env does not read (not quoted here: it may hold a value) — fix that line, or %s sets it", k, dir, set(k)))
			case !ok:
				// A refused deploy puts the server's template back, which env
				// set reads: a key new to it is `kasbah env`'s to ask for.
				bad = append(bad, fmt.Sprintf("${%s} is not set in %s/.env — %s sets it (a key new to .env.prod.example: `%s`, which ships the template and asks for it)",
					k, dir, set(k), strings.TrimSpace("kasbah env "+target)))
			case v == "":
				bad = append(bad, fmt.Sprintf("${%s} is empty in %s/.env — %s sets it", k, dir, set(k)))
			case strings.ContainsAny(v, "\r\n"):
				bad = append(bad, fmt.Sprintf("${%s}'s value in %s/.env spans lines, and a fragment takes one-line values only — %s sets one", k, dir, set(k)))
			case strings.Contains(v, "{{"):
				bad = append(bad, fmt.Sprintf("${%s}'s value in %s/.env holds {{, which Traefik would read as a Go template — %s sets one without it", k, dir, set(k)))
			}
			filled[k] = true
		}
	}
	if len(bad) > 0 {
		return nil, nil, fmt.Errorf("%s cannot be rendered: %s", Fragment, strings.Join(bad, "; "))
	}
	out = fill(text, vals, filled)
	if err := renderedShape(text, vals, filled, target); err != nil {
		return nil, nil, err
	}
	return out, kept, nil
}

// fill is text with each key in only replaced by its value and `$${` by `${`.
func fill(text []byte, vals map[string]string, only map[string]bool) []byte {
	return fragRef.ReplaceAllFunc(text, func(m []byte) []byte {
		if m[1] == '$' {
			return []byte("${")
		}
		if k := string(m[2 : len(m)-1]); only[k] {
			return []byte(vals[k])
		}
		return m
	})
}

// renderedShape refuses a render that reads as other YAML than its template:
// a {{ built across text and value, a parse failure, a duplicated key, or keys,
// items or nesting added or removed. It names keys and lines, never values.
func renderedShape(text []byte, vals map[string]string, filled map[string]bool, target string) error {
	tdocs, err := yamlx.Load(text)
	if err != nil {
		return fmt.Errorf("%s does not parse as YAML as written (%v), so its filled form cannot be checked against it — quote each ${KEY} as a whole scalar (single quotes take a value as written) (kasbah help T01)", Fragment, err)
	}
	strict := yamlx.Strict(text)
	braces := countBraces(text)
	check := func(only map[string]bool) string {
		out := fill(text, vals, only)
		if countBraces(out) > braces {
			return "brace"
		}
		odocs, err := yamlx.Load(out)
		if err != nil {
			return "parse"
		}
		same := len(tdocs) == len(odocs) && (!strict || yamlx.Strict(out))
		for i := 0; same && i < len(tdocs); i++ {
			same = sameShape(tdocs[i], odocs[i])
		}
		if !same {
			return "shape"
		}
		return ""
	}
	what := check(filled)
	if what == "" {
		return nil
	}
	// The culprits are the keys that fail the same way filled alone.
	var ks []string
	for _, k := range FragmentKeys(text) {
		if filled[k] && check(map[string]bool{k: true}) == what {
			ks = append(ks, k)
		}
	}
	if len(ks) == 0 {
		for _, k := range FragmentKeys(text) {
			if filled[k] {
				ks = append(ks, k)
			}
		}
	}
	if len(ks) == 0 {
		ks = []string{"KEY"}
	}
	at := keyLines(text, ks)
	set := "`" + strings.TrimSpace("kasbah env set "+ks[0]+" "+target) + "`"
	switch what {
	case "brace":
		return fmt.Errorf("%s cannot be rendered: filling %s%s makes a {{ the template does not have, which Traefik would read as a Go template — %s sets a value that does not", Fragment, refs(ks), at, set)
	case "parse":
		return fmt.Errorf("%s does not parse as YAML once %s%s is filled from .env — quote it in the fragment (single quotes take a value as written), or %s sets one YAML reads as text", Fragment, refs(ks), at, set)
	}
	return fmt.Errorf("%s cannot be rendered: the value of %s%s changes the fragment's YAML structure (keys, list items or nesting the template does not have) — quote it in the fragment as one scalar, or %s sets one that reads as a single value", Fragment, refs(ks), at, set)
}

// sameShape is whether r has t's structure: the same keys, items and nesting,
// and the same scalars but where t's held a ${KEY} or $${.
func sameShape(t, r tree.Value) bool {
	switch x := t.(type) {
	case *tree.Map:
		y, ok := r.(*tree.Map)
		if !ok || x.Len() != y.Len() {
			return false
		}
		yk := y.Keys()
		for i, k := range x.Keys() {
			tv, _ := x.Get(k)
			rv, _ := y.Get(yk[i])
			if k != yk[i] && !fragRef.MatchString(k) || !sameShape(tv, rv) {
				return false
			}
		}
		return true
	case []tree.Value:
		y, ok := r.([]tree.Value)
		if !ok || len(x) != len(y) {
			return false
		}
		for i := range x {
			if !sameShape(x[i], y[i]) {
				return false
			}
		}
		return true
	case string:
		if fragRef.MatchString(x) {
			switch r.(type) {
			case *tree.Map, []tree.Value:
				return false
			}
			return true
		}
	}
	return tree.Compact(t) == tree.Compact(r)
}

func refs(keys []string) string {
	s := "${" + strings.Join(keys, "}, ${") + "}"
	if len(keys) > 1 {
		return "one of " + s
	}
	return s
}

// keyLines is " on line N" or " on lines N, M" for the lines naming keys.
func keyLines(text []byte, keys []string) string {
	var at []string
	for i, l := range strings.Split(string(text), "\n") {
		for _, k := range FragmentKeys([]byte(l)) {
			if slices.Contains(keys, k) {
				at = append(at, strconv.Itoa(i+1))
				break
			}
		}
	}
	switch len(at) {
	case 0:
		return ""
	case 1:
		return " on line " + at[0]
	}
	return " on lines " + strings.Join(at, ", ")
}

// countBraces counts "{{" overlapping, so "{{{" is two: a value's "{" next to
// the text's "{{" opens a template action as surely as a whole "{{".
func countBraces(b []byte) int {
	n := 0
	for i := 0; i+1 < len(b); i++ {
		if b[i] == '{' && b[i+1] == '{' {
			n++
		}
	}
	return n
}
