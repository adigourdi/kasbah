package remote

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"regexp"
	"strconv"
)

// Digest is a payload's byte count and sha256, as the workstation passes them
// in argv beside a body it sends on stdin.
func Digest(body []byte) (size, sum string) {
	h := sha256.Sum256(body)
	return strconv.Itoa(len(body)), hex.EncodeToString(h[:])
}

var reSum = regexp.MustCompile(`^[0-9a-f]{64}$`)

// Payload reads stdin whole and accepts it only when it is non-empty and
// matches size and sum: a cut or absent stream must never be installed. A
// malformed size or sum is never quoted: it may be the payload's first line.
func Payload(r io.Reader, size, sum string) ([]byte, error) {
	want, err := strconv.Atoi(size)
	if err != nil || want <= 0 || !reSum.MatchString(sum) {
		return nil, fmt.Errorf("the size and sha256 are malformed (a positive byte count and 64 hex digits expected)")
	}
	body, err := io.ReadAll(io.LimitReader(r, int64(want)+1))
	if err != nil {
		return nil, fmt.Errorf("could not read the payload: %v", err)
	}
	if len(body) != want {
		return nil, fmt.Errorf("the payload is %d bytes, %d expected — it was cut short or padded, nothing was installed", len(body), want)
	}
	if _, got := Digest(body); got != sum {
		return nil, fmt.Errorf("the payload's sha256 is %s, %s expected — nothing was installed", got, sum)
	}
	return body, nil
}
