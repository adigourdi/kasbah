// Package composefile reads what a project's compose.yml, as the server holds
// it, declares.
package composefile

import (
	"path/filepath"

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
