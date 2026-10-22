// Package minisign verifies minisign signatures in the prehashed form
// `minisign -S` writes (alg ED: ed25519 over Blake2b-512 of the file), which
// is how release.sh signs checksums.txt against the key in release.pub.
package minisign

import (
	"bytes"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"

	"golang.org/x/crypto/blake2b"
)

// PublicKey is a parsed minisign public key.
type PublicKey struct {
	ID  [8]byte
	Key ed25519.PublicKey
}

// IDString is the key id the way minisign prints it: the eight bytes as a
// little-endian integer, upper-case hex.
func (p PublicKey) IDString() string { return idString(p.ID) }

func idString(id [8]byte) string {
	return fmt.Sprintf("%016X", binary.LittleEndian.Uint64(id[:]))
}

// ParsePublicKey reads a public key file (or just its base64 line): an
// untrusted comment line, then base64 of "Ed" + key id (8) + key (32).
func ParsePublicKey(file []byte) (PublicKey, error) {
	lines := lines(file)
	var enc string
	switch len(lines) {
	case 1:
		enc = lines[0]
	case 2:
		if !strings.HasPrefix(lines[0], "untrusted comment:") {
			return PublicKey{}, errors.New("public key: the first line is not an untrusted comment")
		}
		enc = lines[1]
	default:
		return PublicKey{}, fmt.Errorf("public key: %d lines, expected a comment and the key", len(lines))
	}
	raw, err := base64.StdEncoding.DecodeString(enc)
	if err != nil {
		return PublicKey{}, fmt.Errorf("public key: not base64: %v", err)
	}
	if len(raw) != 2+8+ed25519.PublicKeySize {
		return PublicKey{}, fmt.Errorf("public key: %d bytes decoded, expected %d", len(raw), 2+8+ed25519.PublicKeySize)
	}
	if string(raw[:2]) != "Ed" {
		return PublicKey{}, fmt.Errorf("public key: algorithm %q, expected Ed", raw[:2])
	}
	var p PublicKey
	copy(p.ID[:], raw[2:10])
	p.Key = ed25519.PublicKey(raw[10:])
	return p, nil
}

// Verify checks sigFile, a .minisig, against file with pub: the prehashed
// signature over Blake2b-512(file), the key id, and the global signature
// over the signature and the trusted comment. It returns the trusted comment.
func Verify(pub PublicKey, file, sigFile []byte) (trustedComment string, err error) {
	ls := lines(sigFile)
	if len(ls) != 4 {
		return "", fmt.Errorf("signature: %d lines, expected 4", len(ls))
	}
	if !strings.HasPrefix(ls[0], "untrusted comment:") {
		return "", errors.New("signature: the first line is not an untrusted comment")
	}
	raw, err := base64.StdEncoding.DecodeString(ls[1])
	if err != nil {
		return "", fmt.Errorf("signature: not base64: %v", err)
	}
	if len(raw) != 2+8+ed25519.SignatureSize {
		return "", fmt.Errorf("signature: %d bytes decoded, expected %d", len(raw), 2+8+ed25519.SignatureSize)
	}
	switch string(raw[:2]) {
	case "ED":
	case "Ed":
		return "", errors.New("signature: legacy (non-prehashed) form, which release.sh does not produce")
	default:
		return "", fmt.Errorf("signature: algorithm %q, expected ED", raw[:2])
	}
	var id [8]byte
	copy(id[:], raw[2:10])
	if id != pub.ID {
		return "", fmt.Errorf("signature: signed by key %s, not %s", idString(id), pub.IDString())
	}
	sig := raw[10:]
	comment, ok := strings.CutPrefix(ls[2], "trusted comment: ")
	if !ok {
		return "", errors.New("signature: the third line is not a trusted comment")
	}
	global, err := base64.StdEncoding.DecodeString(ls[3])
	if err != nil {
		return "", fmt.Errorf("signature: the global signature is not base64: %v", err)
	}
	if len(global) != ed25519.SignatureSize {
		return "", fmt.Errorf("signature: the global signature is %d bytes, expected %d", len(global), ed25519.SignatureSize)
	}
	h := blake2b.Sum512(file)
	if !ed25519.Verify(pub.Key, h[:], sig) {
		return "", errors.New("signature: does not verify — the file is not what was signed")
	}
	if !ed25519.Verify(pub.Key, append(append([]byte{}, sig...), comment...), global) {
		return "", errors.New("signature: the trusted comment does not verify")
	}
	return comment, nil
}

// lines splits a file into its non-empty lines, CRLF tolerated.
func lines(b []byte) []string {
	var out []string
	for _, l := range bytes.Split(b, []byte("\n")) {
		l = bytes.TrimRight(l, "\r")
		if len(l) > 0 {
			out = append(out, string(l))
		}
	}
	return out
}
