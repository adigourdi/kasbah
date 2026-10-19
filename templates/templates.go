// Package templates is the files kasbah renders onto servers, built into the
// binary so an installed kasbah carries nothing beside it.
package templates

import "embed"

// FS holds backup/, mail/ and traefik/ as they are in the tree; all: because
// _shared.yml and _mail.yml start with an underscore.
//
//go:embed all:backup all:mail all:traefik
var FS embed.FS
