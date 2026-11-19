// Package composefile reads what a project's compose.yml, as the server holds
// it, declares.
package composefile

import (
	"errors"
	"fmt"
	"path/filepath"
	"slices"
	"strings"

	"github.com/adigourdi/kasbah/internal/tree"
	"github.com/adigourdi/kasbah/internal/yamlx"
)

// Serviceless says whether dir's compose.yml declares no service, which
// compose up refuses ("no service selected"): a redirect-only project's. A file
// that includes others, or cannot be read, is not.
func Serviceless(dir string) bool {
	docs, err := yamlx.LoadFile(filepath.Join(dir, "compose.yml"))
	if err != nil || len(docs) != 1 {
		return false
	}
	return ServicelessDoc(docs[0])
}

// ServicelessDoc is Serviceless for a compose document already parsed.
func ServicelessDoc(doc tree.Value) bool {
	m, ok := doc.(*tree.Map)
	if !ok || m.Has("include") {
		return false
	}
	s, _ := m.Get("services")
	switch s := s.(type) {
	case nil:
		return true
	case *tree.Map:
		return s.Len() == 0
	}
	return false
}

// Services is the service names under a compose document's services:, in
// file order; an empty document has none.
func Services(doc tree.Value) ([]string, error) {
	var s tree.Value
	switch d := doc.(type) {
	case nil:
		return nil, nil
	case *tree.Map:
		s, _ = d.Get("services")
	default:
		return nil, errors.New("the file is not a map of compose keys")
	}
	switch s := s.(type) {
	case nil:
		return nil, nil
	case *tree.Map:
		return s.Keys(), nil
	}
	return nil, errors.New("its services: is not a map of services")
}

// AllServices is Services with those of the files doc's include: names, which
// compose reads relative to the including file's directory, dir for doc; an
// include that cannot be read is an error, as compose would stop on it.
func AllServices(dir string, doc tree.Value) ([]string, error) {
	var out []string
	seen := map[string]bool{}
	var walk func(dir string, doc tree.Value) error
	walk = func(dir string, doc tree.Value) error {
		names, err := Services(doc)
		if err != nil {
			return err
		}
		for _, n := range names {
			if !slices.Contains(out, n) {
				out = append(out, n)
			}
		}
		paths, err := includes(doc)
		if err != nil {
			return err
		}
		for _, p := range paths {
			if !filepath.IsAbs(p) {
				p = filepath.Join(dir, p)
			}
			if seen[p] {
				continue
			}
			seen[p] = true
			docs, err := yamlx.LoadFile(p)
			if err != nil {
				return fmt.Errorf("its include %s cannot be read: %w", p, err)
			}
			if len(docs) > 1 {
				return fmt.Errorf("its include %s holds more than one YAML document", p)
			}
			var d tree.Value
			if len(docs) == 1 {
				d = docs[0]
			}
			if err := walk(filepath.Dir(p), d); err != nil {
				return fmt.Errorf("in %s: %w", p, err)
			}
		}
		return nil
	}
	err := walk(dir, doc)
	return out, err
}

// includes is the paths a compose document's include: names, in either of
// compose's spellings: a path, or a map whose path: is one or a list.
func includes(doc tree.Value) ([]string, error) {
	m, ok := doc.(*tree.Map)
	if !ok {
		return nil, nil
	}
	v, ok := m.Get("include")
	if !ok || v == nil {
		return nil, nil
	}
	list, ok := v.([]any)
	if !ok {
		return nil, errors.New("its include: is not a list")
	}
	var out []string
	add := func(v tree.Value) error {
		p, ok := tree.String(v)
		if p = strings.TrimSuffix(p, "\r"); !ok || p == "" {
			return errors.New("its include: has an entry that is not a path")
		}
		if strings.Contains(p, "$") || strings.Contains(p, "://") {
			return fmt.Errorf("its include %s is not a file kasbah can read here", p)
		}
		out = append(out, p)
		return nil
	}
	for _, e := range list {
		if em, ok := e.(*tree.Map); ok {
			pv, _ := em.Get("path")
			ps, isList := pv.([]any)
			if !isList {
				ps = []any{pv}
			}
			for _, p := range ps {
				if err := add(p); err != nil {
					return nil, err
				}
			}
			continue
		}
		if err := add(e); err != nil {
			return nil, err
		}
	}
	return out, nil
}
