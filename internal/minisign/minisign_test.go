package minisign

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"golang.org/x/crypto/blake2b"
)

// pair is a minisign-shaped key pair made in-test.
type pair struct {
	id   [8]byte
	priv ed25519.PrivateKey
	pub  []byte
}

func newPair(t *testing.T) pair {
	t.Helper()
	pk, sk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	p := pair{priv: sk}
	rand.Read(p.id[:])
	raw := append(append([]byte("Ed"), p.id[:]...), pk...)
	p.pub = []byte("untrusted comment: test key\n" + base64.StdEncoding.EncodeToString(raw) + "\n")
	return p
}

// sign is what `minisign -S -t comment -m file` writes, with alg selectable.
func (p pair) sign(file []byte, comment, alg string) []byte {
	h := blake2b.Sum512(file)
	msg := h[:]
	if alg == "Ed" {
		msg = file
	}
	sig := ed25519.Sign(p.priv, msg)
	global := ed25519.Sign(p.priv, append(append([]byte{}, sig...), comment...))
	raw := append(append([]byte(alg), p.id[:]...), sig...)
	return []byte("untrusted comment: signature from minisign secret key\n" +
		base64.StdEncoding.EncodeToString(raw) + "\n" +
		"trusted comment: " + comment + "\n" +
		base64.StdEncoding.EncodeToString(global) + "\n")
}

func TestVerifyGenerated(t *testing.T) {
	p := newPair(t)
	pub, err := ParsePublicKey(p.pub)
	if err != nil {
		t.Fatal(err)
	}
	file := []byte("abc  kasbah_1.0.0_linux_amd64\n")
	sig := p.sign(file, "kasbah 1.0.0", "ED")
	comment, err := Verify(pub, file, sig)
	if err != nil || comment != "kasbah 1.0.0" {
		t.Fatalf("verify: %q, %v", comment, err)
	}
	if _, err := Verify(pub, []byte("abc  kasbah_1.0.0_linux_amd64\r\n"), sig); err == nil {
		t.Error("a changed file verified")
	}
	if _, err := Verify(pub, file, p.sign(file, "kasbah 1.0.0", "Ed")); err == nil || !strings.Contains(err.Error(), "legacy") {
		t.Errorf("legacy form: %v", err)
	}
	other := newPair(t)
	if _, err := Verify(pub, file, other.sign(file, "x", "ED")); err == nil || !strings.Contains(err.Error(), "signed by key") {
		t.Errorf("wrong key id: %v", err)
	}
	// Same key id, different key: the key id matches, the signature does not.
	other.id = p.id
	if _, err := Verify(pub, file, other.sign(file, "x", "ED")); err == nil || !strings.Contains(err.Error(), "does not verify") {
		t.Errorf("wrong key, same id: %v", err)
	}
	// A tampered trusted comment fails the global signature.
	tampered := strings.Replace(string(sig), "trusted comment: kasbah 1.0.0", "trusted comment: kasbah 9.9.9", 1)
	if _, err := Verify(pub, file, []byte(tampered)); err == nil || !strings.Contains(err.Error(), "trusted comment") {
		t.Errorf("tampered comment: %v", err)
	}
	if _, err := Verify(pub, file, []byte("untrusted comment: x\nabc\n")); err == nil {
		t.Error("a truncated signature verified")
	}
	if _, err := ParsePublicKey([]byte("untrusted comment: x\nabc\n")); err == nil {
		t.Error("a bad key parsed")
	}
	if _, err := ParsePublicKey([]byte("untrusted comment: x\r\n" + strings.Split(string(p.pub), "\n")[1] + "\r\n")); err != nil {
		t.Errorf("CRLF key: %v", err)
	}
}

func TestVerifyGolden(t *testing.T) {
	read := func(name string) []byte {
		b, err := os.ReadFile(filepath.Join("testdata", name))
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
	pub, err := ParsePublicKey(read("probe.pub"))
	if err != nil {
		t.Fatal(err)
	}
	if pub.IDString() != "0CA1DABD4DB1515A" {
		t.Errorf("key id %s", pub.IDString())
	}
	file, sig := read("f.txt"), read("f.txt.minisig")
	comment, err := Verify(pub, file, sig)
	if err != nil || comment != "probe" {
		t.Fatalf("golden: %q, %v", comment, err)
	}
	flipped := append([]byte{}, file...)
	flipped[0] ^= 1
	if _, err := Verify(pub, flipped, sig); err == nil {
		t.Error("a flipped byte verified")
	}
}
