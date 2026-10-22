// Package releasekey carries release.pub, the minisign public key every
// release's checksums.txt is signed with, into the binary.
package releasekey

import (
	_ "embed"

	"github.com/adigourdi/kasbah/internal/minisign"
)

// File is release.pub as committed at the repository root (a copy kept equal
// to it by a test).
//
//go:embed release.pub
var File []byte

// ID is the key's id as minisign prints it.
const ID = "FC8BCEC04912A5B7"

// Key is the parsed key.
func Key() (minisign.PublicKey, error) { return minisign.ParsePublicKey(File) }
