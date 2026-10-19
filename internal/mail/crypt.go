package mail

import (
	"crypto/rand"
	"crypto/sha512"
)

const itoa64 = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

// Salt is 16 characters of the crypt alphabet, as `openssl passwd -6` draws.
func Salt() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	for i := range b {
		b[i] = itoa64[int(b[i])&0x3f]
	}
	return string(b), nil
}

// SHA512Crypt is glibc's `$6$` scheme at its default 5000 rounds — what
// `openssl passwd -6` and docker-mailserver's own provisioner write.
func SHA512Crypt(pass, salt string) string {
	if len(salt) > 16 {
		salt = salt[:16]
	}
	p, s := []byte(pass), []byte(salt)

	alt := sha512.New()
	alt.Write(p)
	alt.Write(s)
	alt.Write(p)
	b := alt.Sum(nil)

	a := sha512.New()
	a.Write(p)
	a.Write(s)
	i := len(p)
	for ; i > 64; i -= 64 {
		a.Write(b)
	}
	a.Write(b[:i])
	for i = len(p); i > 0; i >>= 1 {
		if i&1 != 0 {
			a.Write(b)
		} else {
			a.Write(p)
		}
	}
	c := a.Sum(nil)

	dp := sha512.New()
	for range p {
		dp.Write(p)
	}
	pseq := repeat(dp.Sum(nil), len(p))

	ds := sha512.New()
	for n := 0; n < 16+int(c[0]); n++ {
		ds.Write(s)
	}
	sseq := repeat(ds.Sum(nil), len(s))

	for r := 0; r < 5000; r++ {
		h := sha512.New()
		if r&1 != 0 {
			h.Write(pseq)
		} else {
			h.Write(c)
		}
		if r%3 != 0 {
			h.Write(sseq)
		}
		if r%7 != 0 {
			h.Write(pseq)
		}
		if r&1 != 0 {
			h.Write(c)
		} else {
			h.Write(pseq)
		}
		c = h.Sum(nil)
	}

	out := []byte("$6$" + salt + "$")
	enc := func(b2, b1, b0 byte, n int) {
		w := uint(b2)<<16 | uint(b1)<<8 | uint(b0)
		for ; n > 0; n-- {
			out = append(out, itoa64[w&0x3f])
			w >>= 6
		}
	}
	for _, t := range order {
		enc(c[t[0]], c[t[1]], c[t[2]], 4)
	}
	enc(0, 0, c[63], 2)
	return string(out)
}

// order is the byte permutation of the final encoding.
var order = [21][3]int{
	{0, 21, 42}, {22, 43, 1}, {44, 2, 23}, {3, 24, 45}, {25, 46, 4}, {47, 5, 26}, {6, 27, 48},
	{28, 49, 7}, {50, 8, 29}, {9, 30, 51}, {31, 52, 10}, {53, 11, 32}, {12, 33, 54}, {34, 55, 13},
	{56, 14, 35}, {15, 36, 57}, {37, 58, 16}, {59, 17, 38}, {18, 39, 60}, {40, 61, 19}, {62, 20, 41},
}

func repeat(d []byte, n int) []byte {
	out := make([]byte, 0, n)
	for len(out)+len(d) <= n {
		out = append(out, d...)
	}
	return append(out, d[:n-len(out)]...)
}
