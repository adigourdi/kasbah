package selfupdate

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.org/x/crypto/blake2b"

	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/minisign"
	"github.com/adigourdi/kasbah/internal/prompt"
)

// signer is a minisign-shaped key pair made in-test.
type signer struct {
	id   [8]byte
	priv ed25519.PrivateKey
	pub  minisign.PublicKey
}

func newSigner(t *testing.T) *signer {
	t.Helper()
	pk, sk, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	s := &signer{priv: sk}
	rand.Read(s.id[:])
	s.pub = minisign.PublicKey{ID: s.id, Key: pk}
	return s
}

func (s *signer) sign(file []byte, comment string) []byte {
	h := blake2b.Sum512(file)
	sig := ed25519.Sign(s.priv, h[:])
	global := ed25519.Sign(s.priv, append(append([]byte{}, sig...), comment...))
	raw := append(append([]byte("ED"), s.id[:]...), sig...)
	return []byte("untrusted comment: signature from minisign secret key\n" +
		base64.StdEncoding.EncodeToString(raw) + "\ntrusted comment: " + comment + "\n" +
		base64.StdEncoding.EncodeToString(global) + "\n")
}

// github is a fake: the releases API on one host, the asset bytes on another
// (the redirect target), which records the headers it was sent.
type github struct {
	api, cdn *httptest.Server
	mu       sync.Mutex
	releases map[string]map[string][]byte // tag -> asset name -> bytes
	// listed are entries the releases list carries beyond releases: drafts,
	// odd tag names, filler.
	listed  []listed
	private bool // anonymous requests get 404
	// hook, when set, answers an API request first; true when it did.
	hook    func(w http.ResponseWriter, r *http.Request) bool
	cdnAuth []string // Authorization headers the cdn saw
	cdnCode int      // when set, the cdn answers every request with it
	// storage, when set, replaces the cdn as the redirect target.
	storage string
	apiAuth []string
	paths   []string // every request, "api <path?query>" or "cdn <path>"
}

type listed struct {
	tag   string
	draft bool
}

func newGithub(t *testing.T) *github {
	g := &github{releases: map[string]map[string][]byte{}}
	g.cdn = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		g.cdnAuth = append(g.cdnAuth, r.Header.Get("Authorization"))
		g.paths = append(g.paths, "cdn "+r.URL.Path)
		g.mu.Unlock()
		if g.cdnCode != 0 {
			http.Error(w, "refused", g.cdnCode)
			return
		}
		tag, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/blob/"), "/")
		b, ok := g.releases[tag][name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(b)
	}))
	g.api = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		g.mu.Lock()
		g.apiAuth = append(g.apiAuth, auth)
		g.paths = append(g.paths, "api "+r.URL.RequestURI())
		g.mu.Unlock()
		if g.hook != nil && g.hook(w, r) {
			return
		}
		switch {
		case auth != "" && auth != "Bearer "+secret:
			http.Error(w, "bad credentials", http.StatusUnauthorized)
			return
		case auth == "" && g.private:
			http.NotFound(w, r)
			return
		}
		switch {
		case r.URL.Path == "/repos/adigourdi/kasbah/releases":
			var all []map[string]any
			for tag := range g.releases {
				all = append(all, map[string]any{"tag_name": tag, "draft": false})
			}
			for _, l := range g.listed {
				all = append(all, map[string]any{"tag_name": l.tag, "draft": l.draft})
			}
			n, _ := strconv.Atoi(r.URL.Query().Get("per_page"))
			page, _ := strconv.Atoi(r.URL.Query().Get("page"))
			if n <= 0 || n > 100 || page < 1 {
				http.Error(w, "bad paging", http.StatusBadRequest)
				return
			}
			from, to := min((page-1)*n, len(all)), min(page*n, len(all))
			json.NewEncoder(w).Encode(append([]map[string]any{}, all[from:to]...))
		case strings.HasPrefix(r.URL.Path, "/repos/adigourdi/kasbah/releases/tags/"):
			tag := strings.TrimPrefix(r.URL.Path, "/repos/adigourdi/kasbah/releases/tags/")
			rel, ok := g.releases[tag]
			if !ok {
				http.NotFound(w, r)
				return
			}
			var assets []Asset
			for name, b := range rel {
				assets = append(assets, Asset{Name: name, Size: int64(len(b)), URL: g.api.URL + "/assets/" + tag + "/" + name})
			}
			json.NewEncoder(w).Encode(map[string]any{"tag_name": tag, "assets": assets})
		case strings.HasPrefix(r.URL.Path, "/assets/"):
			if r.Header.Get("Accept") != "application/octet-stream" {
				http.Error(w, "octet-stream only", http.StatusBadRequest)
				return
			}
			to := g.cdn.URL
			if g.storage != "" {
				to = g.storage
			}
			// Signed like GitHub's storage URLs: the query is a credential.
			http.Redirect(w, r, to+"/blob/"+strings.TrimPrefix(r.URL.Path, "/assets/")+"?X-Amz-Signature="+signed, http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(g.api.Close)
	t.Cleanup(g.cdn.Close)
	return g
}

// hits counts the requests whose "api …"/"cdn …" line contains part.
func (g *github) hits(part string) int {
	g.mu.Lock()
	defer g.mu.Unlock()
	n := 0
	for _, p := range g.paths {
		if strings.Contains(p, part) {
			n++
		}
	}
	return n
}

// release publishes tag with one fake binary per arch (a script reporting
// ver), checksums.txt and its signature by s.
func (g *github) release(s *signer, ver string, sign bool) {
	assets := map[string][]byte{}
	var sums []string
	for _, arch := range []string{"amd64", "arm64"} {
		name := AssetName(ver, arch)
		b := []byte("#!/bin/sh\necho \"kasbah " + ver + " (schema 1)\"\n# " + arch + "\n")
		assets[name] = b
		sum := sha256.Sum256(b)
		sums = append(sums, hex.EncodeToString(sum[:])+"  "+name)
	}
	checksums := []byte(strings.Join(sums, "\n") + "\n")
	assets["checksums.txt"] = checksums
	if sign {
		assets["checksums.txt.minisig"] = s.sign(checksums, "kasbah "+ver)
	}
	g.releases["v"+ver] = assets
}

func client(t *testing.T, g *github, s *signer) (*Client, *bytes.Buffer) {
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	c := &Client{API: g.api.URL, Token: secret, Key: s.pub, HTTP: NewHTTP(), Out: out}
	return c, &buf
}

// secret is the token the fake API accepts; a substring no message spells.
const secret = "ghp_Q7xK2vLm9ZpR"

// signed is the fake storage URLs' signature, which no message may spell either.
const signed = "SIG4hV9wQ2"

// noToken is every failure the suite sees: none may carry the token.
func noToken(t *testing.T, err error) error {
	t.Helper()
	if err != nil && strings.Contains(err.Error(), secret) {
		t.Errorf("the token leaked into an error: %v", err)
	}
	if err != nil && strings.Contains(err.Error(), signed) {
		t.Errorf("a signed storage URL leaked into an error: %v", err)
	}
	return err
}

func TestToken(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	noGh := func(string) (string, error) { return "", os.ErrNotExist }
	gh := func(string) (string, error) { return "/usr/bin/gh", nil }
	if tok, from := Token(DefaultAPI, env(map[string]string{"GITHUB_TOKEN": " abc\n"}), noGh, nil); tok != "abc" || from != "GITHUB_TOKEN" {
		t.Errorf("GITHUB_TOKEN: %q %q", tok, from)
	}
	if tok, from := Token(DefaultAPI, env(nil), noGh, nil); tok != "" || from != "" {
		t.Errorf("no token, no gh: %q %q", tok, from)
	}
	var ran []string
	run := func(name string, args ...string) ([]byte, error) {
		ran = append(ran, name+" "+strings.Join(args, " "))
		return []byte("ghtok\n"), nil
	}
	// gh is asked for github.com's token, whatever its default host is.
	if tok, from := Token(DefaultAPI, env(nil), gh, run); tok != "ghtok" || from != "gh" || len(ran) != 1 || ran[0] != "gh auth token --hostname github.com" {
		t.Errorf("gh: %q %q, %v", tok, from, ran)
	}
	if tok, _ := Token(DefaultAPI, env(nil), gh, func(string, ...string) ([]byte, error) { return []byte("junk"), fmt.Errorf("not logged in") }); tok != "" {
		t.Errorf("gh without login: %q", tok)
	}
	// Another API host: gh is never asked; GITHUB_TOKEN still applies.
	ran = nil
	for _, api := range []string{"http://127.0.0.1:8080", "https://ghe.example.com/api/v3", "http://api.github.com"} {
		if tok, _ := Token(api, env(nil), gh, run); tok != "" {
			t.Errorf("%s: gh's token %q", api, tok)
		}
		if tok, from := Token(api, env(map[string]string{"GITHUB_TOKEN": "abc"}), gh, run); tok != "abc" || from != "GITHUB_TOKEN" {
			t.Errorf("%s with GITHUB_TOKEN: %q %q", api, tok, from)
		}
	}
	if len(ran) != 0 {
		t.Errorf("gh was asked for another host: %v", ran)
	}
}

// catalogue lists, beside the published releases, a draft, odd tag names and
// enough filler to need a second page.
func catalogue(g *github, s *signer) {
	for _, v := range []string{"1.0.0", "1.0.1", "1.2.0", "1.3.0-rc.1", "2.0.0", "2.1.0-dev.3.5"} {
		g.release(s, v, true)
	}
	g.listed = append(g.listed, listed{"v1.4.0", true}, listed{"v3.0.0", true}, listed{"vjunk", false}, listed{"other", false}, listed{"v01.2.3", false})
	for i := 0; i < 150; i++ {
		g.listed = append(g.listed, listed{fmt.Sprintf("v0.0.%d", i), false})
	}
}

func TestResolve(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	catalogue(g, s)
	c, _ := client(t, g, s)
	cases := []struct {
		arg       string
		major     uint64
		pre       bool
		want, how string
	}{
		{"", 1, false, "1.2.0", "newest v1.* release of adigourdi/kasbah (1 newer pre-release(s) skipped"},
		{"", 1, true, "1.3.0-rc.1", "newest v1.* release"},
		{"", 0, false, "0.0.149", "newest v0.*"},
		{"v1", 2, false, "1.2.0", "1 newer pre-release(s) skipped"},
		{"2", 1, false, "2.0.0", "newest v2.*"},
		{"v2", 1, true, "2.1.0-dev.3.5", ""},
		{"v1.0", 2, false, "1.0.1", "newest v1.0.* release"},
		{"v1.2\r", 2, false, "1.2.0", "newest v1.2.*"},
		{"v1.3", 1, true, "1.3.0-rc.1", "newest v1.3.*"},
		{"v1.0.0", 2, false, "1.0.0", "release v1.0.0 of adigourdi/kasbah"},
		{"v1.3.0-rc.1", 2, false, "1.3.0-rc.1", "release v1.3.0-rc.1"},
	}
	for _, tt := range cases {
		v, how, err := c.Resolve(tt.arg, tt.major, tt.pre)
		if err != nil || v.String() != tt.want || !strings.Contains(how, tt.how) {
			t.Errorf("Resolve(%q, %d, %v) = %s, %q, %v; want %s", tt.arg, tt.major, tt.pre, v, how, err, tt.want)
		}
	}
	// The listing is paged: two pages of 100, never a third.
	if g.hits("per_page=100&page=2") == 0 || g.hits("page=3") != 0 {
		t.Errorf("paging: %d second-page requests, %d third", g.hits("page=2"), g.hits("page=3"))
	}
	// A draft and a tag with no release are invisible, even with --pre.
	for _, arg := range []string{"v1.4.0", "v1.5.0", "v3", "v1.1"} {
		_, _, err := c.Resolve(arg, 1, true)
		if noToken(t, err) == nil || !strings.Contains(err.Error(), "no release of adigourdi/kasbah matches "+arg) ||
			!strings.Contains(err.Error(), "drafts, and tags without a published release, do not count") {
			t.Errorf("Resolve(%q): %v", arg, err)
		}
	}
	if v, _, err := c.Resolve("v1", 1, true); err != nil || v.String() != "1.3.0-rc.1" {
		t.Errorf("the draft v1.4.0 resolved: %s, %v", v, err)
	}
	if _, _, err := c.Resolve("v1.3", 1, false); err == nil || !strings.Contains(err.Error(), "1 pre-release(s) were skipped — --pre takes them") {
		t.Errorf("v1.3 without --pre: %v", err)
	}
	// Not a version: refused before the API is asked.
	before := g.hits("api ")
	for _, bad := range []string{"vx", "1.2.3.4", "v1.x", "v01"} {
		if _, _, err := c.Resolve(bad, 1, false); noToken(t, err) == nil || !strings.Contains(err.Error(), "is not a version") {
			t.Errorf("Resolve(%q): %v", bad, err)
		}
	}
	if g.hits("api ") != before {
		t.Error("a malformed version reached the API")
	}
}

func TestExact(t *testing.T) {
	for arg, want := range map[string]bool{"v1.2.3": true, "1.2.3-rc.1": true, "v1.2.3\r": true, "v1.2": false, "v1": false, "": false} {
		if exact(arg) != want {
			t.Errorf("exact(%q) = %v", arg, !want)
		}
	}
}

func TestAnonymous(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	catalogue(g, s)
	c, _ := client(t, g, s)
	c.Token = ""
	v, _, err := c.Resolve("v1", 1, false)
	if err != nil || v.String() != "1.2.0" {
		t.Fatalf("anonymous resolve: %s, %v", v, err)
	}
	rel, err := c.Release("1.2.0")
	if err != nil {
		t.Fatalf("anonymous release: %v", err)
	}
	if err := c.Download(rel, AssetName("1.2.0", "amd64"), filepath.Join(t.TempDir(), "kasbah")); err != nil {
		t.Fatalf("anonymous download: %v", err)
	}
	for _, a := range append(append([]string{}, g.apiAuth...), g.cdnAuth...) {
		if a != "" {
			t.Errorf("an anonymous client sent Authorization %q", a)
		}
	}

	// A private repository: the API answers 404 without a token.
	g.private = true
	for what, err := range map[string]error{
		"list":    func() error { _, _, err := c.Resolve("v1", 1, false); return err }(),
		"release": func() error { _, err := c.Release("1.2.0"); return err }(),
	} {
		if err == nil || !strings.Contains(err.Error(), "404") || !strings.Contains(err.Error(), "may be private") ||
			!strings.Contains(err.Error(), "GITHUB_TOKEN") || !strings.Contains(err.Error(), "gh auth login") {
			t.Errorf("%s, private and anonymous: %v", what, err)
		}
	}
	// With the token it is visible, and the 404 wording says nothing of privacy.
	c.Token = secret
	if v, _, err := c.Resolve("v1", 1, false); err != nil || v.String() != "1.2.0" {
		t.Errorf("private with a token: %s, %v", v, err)
	}
	if _, err := c.Release("9.9.9"); noToken(t, err) == nil || !strings.Contains(err.Error(), "the token cannot see") || strings.Contains(err.Error(), "may be private") {
		t.Errorf("404 with a token: %v", err)
	}
}

// refuse makes every API request answer code with the headers given.
func refuse(code int, headers ...string) func(w http.ResponseWriter, r *http.Request) bool {
	return func(w http.ResponseWriter, r *http.Request) bool {
		for i := 0; i+1 < len(headers); i += 2 {
			w.Header().Set(headers[i], headers[i+1])
		}
		http.Error(w, "refused", code)
		return true
	}
}

func TestRefusals(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	catalogue(g, s)
	c, _ := client(t, g, s)
	cases := []struct {
		name, token, from string
		hook              func(http.ResponseWriter, *http.Request) bool
		want              []string
		not               []string
	}{
		{"primary, anonymous", "", "", refuse(403, "X-RateLimit-Remaining", "0", "X-RateLimit-Reset", "1798761600"),
			[]string{"rate limit is used up, until 2027-01-01 00:00:00 UTC", "60 an hour: set GITHUB_TOKEN"}, nil},
		{"primary, token", secret, "gh", refuse(403, "X-RateLimit-Remaining", "0"),
			[]string{"rate limit is used up", "set GITHUB_TOKEN to another token"}, []string{"60 an hour"}},
		{"secondary", "", "", refuse(403, "Retry-After", "30", "X-RateLimit-Remaining", "0", "X-RateLimit-Reset", "1798761600"),
			[]string{"wait 30 second(s) before retrying (a secondary rate limit)", "retry after that wait", "GITHUB_TOKEN"}, []string{"used up", "60 an hour", "2027"}},
		{"secondary 429, token", secret, "GITHUB_TOKEN", refuse(429, "Retry-After", "5"),
			[]string{"wait 5 second(s)", "retry after that wait"}, []string{"GITHUB_TOKEN"}},
		{"429, anonymous", "", "", refuse(429),
			[]string{"429", "GitHub is throttling requests", "retry later; a token gets a higher limit: set GITHUB_TOKEN"}, nil},
	}
	for _, tt := range cases {
		g.hook, c.Token, c.TokenFrom = tt.hook, tt.token, tt.from
		_, _, err := c.Resolve("v1", 1, false)
		if noToken(t, err) == nil {
			t.Errorf("%s: resolved", tt.name)
			continue
		}
		for _, w := range tt.want {
			if !strings.Contains(err.Error(), w) {
				t.Errorf("%s: lacks %q: %v", tt.name, w, err)
			}
		}
		for _, w := range tt.not {
			if strings.Contains(err.Error(), w) {
				t.Errorf("%s: says %q: %v", tt.name, w, err)
			}
		}
	}
	c.Token, c.TokenFrom = secret, "gh"

	// Not a release list: neither JSON nor an array, and no Go type named.
	for _, body := range []string{"<html>maintenance</html>", `{"message":"Moved Permanently"}`} {
		g.hook = func(w http.ResponseWriter, r *http.Request) bool { w.Write([]byte(body)); return true }
		_, _, err := c.Resolve("v1", 1, false)
		if err == nil || !strings.Contains(err.Error(), "answered with something that is not a list of releases") || strings.Contains(err.Error(), "Go value") || strings.Contains(err.Error(), "struct") {
			t.Errorf("body %q: %v", body, err)
		}
	}

	// The page cap: a listing that never ends is cut off.
	g.hook = func(w http.ResponseWriter, r *http.Request) bool {
		if r.URL.Path != "/repos/adigourdi/kasbah/releases" {
			return false
		}
		page := make([]map[string]any, 100)
		for i := range page {
			page[i] = map[string]any{"tag_name": fmt.Sprintf("v0.%s.%d", r.URL.Query().Get("page"), i)}
		}
		json.NewEncoder(w).Encode(page)
		return true
	}
	before := g.hits("api /repos/adigourdi/kasbah/releases?")
	if _, _, err := c.Resolve("v0", 1, false); err == nil || !strings.Contains(err.Error(), "run past 50 pages of 100") {
		t.Errorf("page cap: %v", err)
	}
	if n := g.hits("api /repos/adigourdi/kasbah/releases?") - before; n != 50 {
		t.Errorf("page cap: %d pages read, want 50", n)
	}
}

func TestReleaseVerifies(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	g.release(s, "1.2.0", true)
	c, _ := client(t, g, s)
	rel, err := c.Release("1.2.0")
	if err != nil {
		t.Fatal(err)
	}
	if rel.Comment != "kasbah 1.2.0" || rel.KeyID != s.pub.IDString() || len(rel.Sums) != 2 {
		t.Errorf("release: %+v", rel)
	}
	// The redirect target never sees the token; the API always does.
	for _, a := range g.cdnAuth {
		if a != "" {
			t.Errorf("the cdn was sent Authorization %q", a)
		}
	}
	if len(g.cdnAuth) != 2 || len(g.apiAuth) < 3 {
		t.Errorf("cdn %d requests, api %d", len(g.cdnAuth), len(g.apiAuth))
	}

	// Wrong key: same files, another key embedded.
	other := newSigner(t)
	c.Key = other.pub
	if _, err := c.Release("1.2.0"); noToken(t, err) == nil || !strings.Contains(err.Error(), "signed by key") {
		t.Errorf("wrong key id: %v", err)
	}
	// Same key id, another key.
	other.id = s.id
	c.Key = minisign.PublicKey{ID: s.id, Key: other.pub.Key}
	if _, err := c.Release("1.2.0"); noToken(t, err) == nil || !strings.Contains(err.Error(), "does not verify") {
		t.Errorf("wrong key: %v", err)
	}
	c.Key = s.pub
	// A tampered checksums.txt.
	g.releases["v1.2.0"]["checksums.txt"] = append([]byte("0000"), g.releases["v1.2.0"]["checksums.txt"][4:]...)
	if _, err := c.Release("1.2.0"); noToken(t, err) == nil || !strings.Contains(err.Error(), "does not verify") {
		t.Errorf("tampered checksums: %v", err)
	}
	// No signature at all.
	g.release(s, "1.2.0", false)
	if _, err := c.Release("1.2.0"); noToken(t, err) == nil || !strings.Contains(err.Error(), "no asset checksums.txt.minisig") {
		t.Errorf("unsigned: %v", err)
	}
	// No release.
	if _, err := c.Release("9.9.9"); noToken(t, err) == nil || !strings.Contains(err.Error(), "404") {
		t.Errorf("missing release: %v", err)
	}
	// A signature of another release: refused, though the key is right.
	g.release(s, "1.2.0", true)
	g.releases["v1.2.0"]["checksums.txt.minisig"] = s.sign(g.releases["v1.2.0"]["checksums.txt"], "kasbah 1.1.0")
	if _, err := c.Release("1.2.0"); noToken(t, err) == nil || !strings.Contains(err.Error(), `signed as "kasbah 1.1.0", not "kasbah 1.2.0"`) {
		t.Errorf("another release's signature: %v", err)
	}
}

// TestRefusedToken is a token GitHub answers 401: dropped with one warning
// naming its source, the request retried, and every later one, anonymously.
func TestRefusedToken(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	catalogue(g, s)
	c, buf := client(t, g, s)
	for _, tt := range []struct{ from, says string }{
		{"GITHUB_TOKEN", "warning: GitHub refused the token in GITHUB_TOKEN — continuing without it\n"},
		{"gh", "warning: GitHub refused the token `gh auth token` printed — continuing without it\n"},
	} {
		buf.Reset()
		g.mu.Lock()
		g.apiAuth, g.cdnAuth = nil, nil
		g.mu.Unlock()
		c.Token, c.TokenFrom = "nope", tt.from
		v, _, err := c.Resolve("v1", 1, false)
		if err != nil || v.String() != "1.2.0" {
			t.Fatalf("%s: resolve: %s, %v\n%s", tt.from, v, err, buf)
		}
		rel, err := c.Release("1.2.0")
		if err == nil {
			err = c.Download(rel, AssetName("1.2.0", "amd64"), filepath.Join(t.TempDir(), "kasbah"))
		}
		if err != nil {
			t.Fatalf("%s: release: %v", tt.from, err)
		}
		if buf.String() != tt.says+"downloading "+AssetName("1.2.0", "amd64")+" ("+strconv.Itoa(len(g.releases["v1.2.0"][AssetName("1.2.0", "amd64")]))+" bytes)\n" {
			t.Errorf("%s: output:\n%s", tt.from, buf)
		}
		if c.Token != "" || len(g.apiAuth) < 3 || g.apiAuth[0] != "Bearer nope" {
			t.Errorf("%s: token %q, api saw %q", tt.from, c.Token, g.apiAuth)
		}
		for _, a := range append(append([]string{}, g.apiAuth[1:]...), g.cdnAuth...) {
			if a != "" {
				t.Errorf("%s: the refused token was sent again: %q", tt.from, a)
			}
		}
	}

	// Private: the anonymous retry's 404 is the refusal, after the warning.
	g.private = true
	buf.Reset()
	c.Token, c.TokenFrom = "nope", "GITHUB_TOKEN"
	_, err := c.Release("1.2.0")
	if noToken(t, err) == nil || !strings.Contains(err.Error(), "404") || !strings.Contains(err.Error(), "may be private") ||
		strings.Count(buf.String(), "refused the token") != 1 {
		t.Errorf("private, refused token: %v\n%s", err, buf)
	}

	// The storage host's 401 is not the token's: kept, no warning, and the
	// refusal names the host that answered, not the API asset URL.
	g.private = false
	g.cdnCode = http.StatusUnauthorized
	buf.Reset()
	c.Token, c.TokenFrom = secret, "GITHUB_TOKEN"
	_, err = c.Release("1.2.0")
	if noToken(t, err) == nil || !strings.Contains(err.Error(), g.cdn.URL+"/blob/v1.2.0/checksums.txt: 401") ||
		strings.Contains(err.Error(), "/assets/") || strings.Contains(buf.String(), "refused the token") || c.Token != secret {
		t.Errorf("storage 401: %v, token %q\n%s", err, c.Token, buf)
	}
	g.cdnCode = 0

	// The storage host unreachable: the dial error names it, its query dropped.
	l, lerr := net.Listen("tcp", "127.0.0.1:0")
	if lerr != nil {
		t.Fatal(lerr)
	}
	g.storage = "http://" + l.Addr().String()
	l.Close()
	_, err = c.Release("1.2.0")
	if noToken(t, err) == nil || !strings.Contains(err.Error(), g.storage+"/blob/v1.2.0/checksums.txt\"") {
		t.Errorf("storage unreachable: %v", err)
	}
	g.storage = ""
	g.mu.Lock()
	g.apiAuth = nil
	g.mu.Unlock()
	if _, err := c.Release("1.2.0"); err != nil || len(g.apiAuth) != 3 {
		t.Errorf("after a storage 401: %v, api saw %q", err, g.apiAuth)
	}
	for _, a := range g.apiAuth {
		if a != "Bearer "+secret {
			t.Errorf("after a storage 401 the API was sent %q", a)
		}
	}

	// An anonymous 401 is reported as it is, no token blamed.
	c.Token, c.TokenFrom = "", ""
	g.hook = refuse(401)
	buf.Reset()
	if _, _, err := c.Resolve("v1", 1, false); err == nil || !strings.Contains(err.Error(), "401") || strings.Contains(err.Error()+buf.String(), "token") {
		t.Errorf("anonymous 401: %v\n%s", err, buf)
	}
}

func TestDownload(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	g.release(s, "1.2.0", true)
	c, _ := client(t, g, s)
	rel, err := c.Release("1.2.0")
	if err != nil {
		t.Fatal(err)
	}
	dir := t.TempDir()
	dst := filepath.Join(dir, "sub", "kasbah")
	if err := c.Download(rel, AssetName("1.2.0", "arm64"), dst); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(dst)
	if !bytes.Equal(b, g.releases["v1.2.0"][AssetName("1.2.0", "arm64")]) {
		t.Error("downloaded bytes differ")
	}
	if fi, _ := os.Stat(dst); fi.Mode().Perm()&0o111 == 0 {
		t.Error("not executable")
	}
	leftovers := func() {
		t.Helper()
		ents, _ := os.ReadDir(filepath.Dir(dst))
		for _, e := range ents {
			if strings.HasSuffix(e.Name(), ".part") {
				t.Errorf("temp file left: %s", e.Name())
			}
		}
	}
	// The bytes on the cdn differ from what checksums.txt signed.
	name := AssetName("1.2.0", "amd64")
	good := g.releases["v1.2.0"][name]
	g.releases["v1.2.0"][name] = append([]byte{}, bytes.ToUpper(good)...)
	other := filepath.Join(dir, "sub", "other")
	if err := noToken(t, c.Download(rel, name, other)); err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Errorf("wrong sha256: %v", err)
	}
	if _, err := os.Stat(other); err == nil {
		t.Error("a file with the wrong sha256 was installed")
	}
	leftovers()
	// Shorter than the API says.
	g.releases["v1.2.0"][name] = good[:len(good)-1]
	if err := noToken(t, c.Download(rel, name, other)); err == nil || !strings.Contains(err.Error(), "bytes downloaded") {
		t.Errorf("short: %v", err)
	}
	leftovers()
	// Longer than the API says.
	g.releases["v1.2.0"][name] = append(append([]byte{}, good...), '\n')
	if err := noToken(t, c.Download(rel, name, other)); err == nil || !strings.Contains(err.Error(), "bytes downloaded") {
		t.Errorf("long: %v", err)
	}
	if _, err := os.Stat(other); err == nil {
		t.Error("a file longer than the release lists was installed")
	}
	leftovers()
	g.releases["v1.2.0"][name] = good
	// An asset URL on another host: refused, and that host never asked.
	elsewhere := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("a request reached the foreign host: %s %s", r.Method, r.URL)
	}))
	defer elsewhere.Close()
	rel.Assets[name] = Asset{Name: name, URL: elsewhere.URL + "/" + name, Size: int64(len(good))}
	if err := noToken(t, c.Download(rel, name, other)); err == nil || !strings.Contains(err.Error(), "outside "+g.api.URL) || !strings.Contains(err.Error(), strings.TrimPrefix(elsewhere.URL, "http://")) || !strings.Contains(err.Error(), "the token is not sent there") {
		t.Errorf("foreign host: %v", err)
	}
	c.Token = ""
	if err := c.Download(rel, name, other); err == nil || !strings.Contains(err.Error(), "outside") || strings.Contains(err.Error(), "token") {
		t.Errorf("foreign host, anonymous: %v", err)
	}
	c.Token = secret
	rel.Assets["checksums.txt"] = Asset{Name: "checksums.txt", URL: elsewhere.URL + "/checksums.txt", Size: 1}
	if _, err := c.fetch(rel, "checksums.txt"); err == nil || !strings.Contains(err.Error(), "outside") {
		t.Errorf("foreign host, fetch: %v", err)
	}
	rel.Assets[name] = Asset{Name: name, URL: g.api.URL + "/assets/v1.2.0/" + name, Size: int64(len(good))}
	// An asset the release lacks, and one checksums.txt lacks.
	if err := noToken(t, c.Download(rel, "kasbah_1.2.0_linux_riscv64", other)); err == nil || !strings.Contains(err.Error(), "no asset") {
		t.Errorf("missing asset: %v", err)
	}
	rel.Assets["extra"] = Asset{Name: "extra", URL: g.api.URL + "/assets/v1.2.0/checksums.txt", Size: 1}
	if err := noToken(t, c.Download(rel, "extra", other)); err == nil || !strings.Contains(err.Error(), "no entry") {
		t.Errorf("no checksum entry: %v", err)
	}
}

// fakeTTY is a prompter answering from a string, as a terminal would.
func fakeTTY(answer string, out *cli.Output) *prompt.Prompter {
	return &prompt.Prompter{In: strings.NewReader(answer), Out: out, TTY: answer != ""}
}

func TestRun(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	for _, v := range []string{"1.1.0", "1.2.0", "2.0.0"} {
		g.release(s, v, true)
	}
	c, buf := client(t, g, s)
	root, binDir := t.TempDir(), filepath.Join(t.TempDir(), "bin")
	ctx := func(answer string) Ctx {
		return Ctx{Client: c, Out: c.Out, Prompter: fakeTTY(answer, c.Out), Root: root, BinDir: binDir, Arch: "amd64", Self: "1.0.0", RunTimeout: 5 * time.Second}
	}
	link := filepath.Join(binDir, "kasbah")
	target := func() string { s, _ := os.Readlink(link); return s }

	// No argument: the newest of this build's major, 1.2.0.
	if err := Run(ctx(""), Options{}); err != nil {
		t.Fatalf("run: %v\n%s", err, buf)
	}
	for _, want := range []string{"resolved 1.2.0 (newest v1.*", "verified checksums.txt: key " + s.pub.IDString() + ", trusted comment \"kasbah 1.2.0\"", "installed kasbah 1.2.0", "bin: " + link + " -> " + filepath.Join(root, "1.2.0", "kasbah")} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, buf)
		}
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("symlink -> %s", target())
	}
	bin, _ := os.ReadFile(filepath.Join(root, "1.2.0", "kasbah"))
	srv, _ := os.ReadFile(filepath.Join(root, "1.2.0", "server", "kasbah-linux-amd64"))
	if !bytes.Equal(bin, srv) || !bytes.Contains(bin, []byte("# amd64")) {
		t.Error("the server build is not the same bytes as the binary")
	}
	if _, err := os.Stat(filepath.Join(root, "1.2.0", "server", "kasbah-linux-arm64")); err == nil {
		t.Error("the other arch was installed up front")
	}

	// Again: already installed, nothing downloaded, and still a success.
	buf.Reset()
	before := len(g.cdnAuth)
	if err := Run(ctx(""), Options{}); err != nil || !strings.Contains(buf.String(), "kasbah 1.2.0 is already installed, nothing downloaded") {
		t.Errorf("second run: %v\n%s", err, buf)
	}
	if len(g.cdnAuth) != before {
		t.Error("a second run downloaded")
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("second run: symlink -> %s", target())
	}

	// An older version named exactly installs and the symlink moves to it:
	// the one asked for is the one to run.
	buf.Reset()
	if err := Run(ctx(""), Options{Version: "v1.1.0"}); err != nil {
		t.Fatalf("v1.1.0: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "1.1.0", "kasbah") {
		t.Errorf("after v1.1.0: symlink -> %s", target())
	}
	if !strings.Contains(buf.String(), "bin: "+link+" -> "+filepath.Join(root, "1.1.0", "kasbah")) {
		t.Errorf("the report does not name the repoint:\n%s", buf)
	}
	// A bare run: 1.2.0 already installed, and the symlink back on the newest.
	buf.Reset()
	if err := Run(ctx(""), Options{}); err != nil || !strings.Contains(buf.String(), "already installed") {
		t.Errorf("bare run after v1.1.0: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("bare run after v1.1.0: symlink -> %s", target())
	}
	// A major named bare: the newest of it, and the link follows the install
	// (asked below; here 1.2.0 is the same major, so no question).
	os.RemoveAll(filepath.Join(root, "1.2.0"))
	buf.Reset()
	if err := Run(ctx(""), Options{Version: "v1"}); err != nil {
		t.Fatalf("v1: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("after v1: symlink -> %s", target())
	}
	// Named exactly and already installed: nothing downloaded, and the symlink
	// still moves to it — that is what was asked for.
	buf.Reset()
	before = len(g.cdnAuth)
	if err := Run(ctx(""), Options{Version: "v1.1.0"}); err != nil {
		t.Fatalf("v1.1.0 again: %v\n%s", err, buf)
	}
	if len(g.cdnAuth) != before {
		t.Error("a named, installed version was downloaded again")
	}
	if target() != filepath.Join(root, "1.1.0", "kasbah") {
		t.Errorf("v1.1.0 again: symlink -> %s", target())
	}
	for _, want := range []string{"already installed", "bin: " + link + " -> " + filepath.Join(root, "1.1.0", "kasbah")} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, buf)
		}
	}
	// Back to the newest, by name, for what follows.
	if err := Run(ctx(""), Options{Version: "v1.2.0"}); err != nil {
		t.Fatalf("v1.2.0 again: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("v1.2.0 again: symlink -> %s", target())
	}
	// vN.M pins too: installed already or afresh, the symlink goes to what it
	// resolved to; a bare run puts it back on the newest.
	buf.Reset()
	if err := Run(ctx(""), Options{Version: "v1.1"}); err != nil || !strings.Contains(buf.String(), "already installed") {
		t.Errorf("v1.1 installed: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "1.1.0", "kasbah") {
		t.Errorf("v1.1 installed: symlink -> %s", target())
	}
	if err := Run(ctx(""), Options{}); err != nil || target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("bare run: %v, symlink -> %s", err, target())
	}
	os.RemoveAll(filepath.Join(root, "1.1.0"))
	if err := Run(ctx(""), Options{Version: "v1.1"}); err != nil {
		t.Fatalf("v1.1: %v\n%s", err, buf)
	}
	if _, err := os.Stat(filepath.Join(root, "1.1.0", "kasbah")); err != nil {
		t.Errorf("v1.1 did not install 1.1.0: %v", err)
	}
	if target() != filepath.Join(root, "1.1.0", "kasbah") {
		t.Errorf("v1.1 afresh: symlink -> %s", target())
	}
	if err := Run(ctx(""), Options{}); err != nil || target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("bare run: %v, symlink -> %s", err, target())
	}

	// A new major: the symlink would move majors — asked; no TTY fails naming --yes.
	buf.Reset()
	err := noToken(t, Run(ctx(""), Options{Version: "v2"}))
	if err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Errorf("no tty: %v", err)
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("no tty moved the symlink -> %s", target())
	}
	// Each answer below meets a fresh install of 2.0.0.
	os.RemoveAll(filepath.Join(root, "2.0.0"))
	buf.Reset()
	if err := noToken(t, Run(ctx("n\n"), Options{Version: "v2"})); err == nil || !strings.Contains(err.Error(), "not confirmed") {
		t.Errorf("declined: %v", err)
	}
	if !strings.Contains(buf.String(), "different major") {
		t.Errorf("no question asked:\n%s", buf)
	}
	os.RemoveAll(filepath.Join(root, "2.0.0"))
	buf.Reset()
	if err := Run(ctx(""), Options{Version: "v2", Yes: true}); err != nil {
		t.Fatalf("--yes: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "2.0.0", "kasbah") {
		t.Errorf("--yes: symlink -> %s", target())
	}
	if strings.Contains(buf.String(), "different major") {
		t.Error("--yes still asked")
	}
	// Already installed, named in another major: the same question, no download.
	buf.Reset()
	before = len(g.cdnAuth)
	if err := noToken(t, Run(ctx(""), Options{Version: "v1.2.0"})); err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Errorf("installed, other major, no tty: %v", err)
	}
	if target() != filepath.Join(root, "2.0.0", "kasbah") || len(g.cdnAuth) != before {
		t.Errorf("installed, other major, no tty: symlink -> %s, %d downloads", target(), len(g.cdnAuth)-before)
	}
	// v1 beside an installed v2: the link goes to the v1.x it resolved to, not
	// to the newest; a bare run (here of a 2.x build) puts it back.
	buf.Reset()
	if err := Run(ctx(""), Options{Version: "v1"}); err == nil || !strings.Contains(err.Error(), "--yes") || target() != filepath.Join(root, "2.0.0", "kasbah") {
		t.Errorf("v1 beside v2, no tty: %v, symlink -> %s", err, target())
	}
	if err := Run(ctx(""), Options{Version: "v1", Yes: true}); err != nil || target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("v1 beside v2: %v, symlink -> %s\n%s", err, target(), buf)
	}
	on2 := ctx("")
	on2.Self = "2.0.0"
	if err := Run(on2, Options{Yes: true}); err != nil || target() != filepath.Join(root, "2.0.0", "kasbah") {
		t.Errorf("bare run on 2.x: %v, symlink -> %s\n%s", err, target(), buf)
	}

	// A binary that does not report its version is not repointed to.
	g.releases["v1.1.0"][AssetName("1.1.0", "amd64")] = []byte("#!/bin/sh\necho kasbah 9.9.9\n")
	g.release2(s, "1.1.0")
	os.RemoveAll(filepath.Join(root, "1.1.0"))
	buf.Reset()
	if err := noToken(t, Run(ctx(""), Options{Version: "v1.1.0"})); err == nil || !strings.Contains(err.Error(), "does not report kasbah 1.1.0") {
		t.Errorf("lying binary: %v", err)
	}
	if target() != filepath.Join(root, "2.0.0", "kasbah") {
		t.Errorf("lying binary moved the symlink -> %s", target())
	}

	// A library that is not kasbah's: refused before the API or the cdn is asked.
	foreign := t.TempDir()
	os.WriteFile(filepath.Join(foreign, "notes.txt"), []byte("mine\n"), 0o644)
	api, cdn := len(g.apiAuth), len(g.cdnAuth)
	fc := ctx("")
	fc.Root = foreign
	if err := Run(fc, Options{Version: "v1.1.0"}); err == nil || !strings.Contains(err.Error(), "not a kasbah library directory") {
		t.Errorf("foreign library: %v", err)
	}
	if len(g.apiAuth) != api || len(g.cdnAuth) != cdn {
		t.Error("a refused library still reached GitHub")
	}
	if ents, _ := os.ReadDir(foreign); len(ents) != 1 {
		t.Errorf("the foreign library was written: %v", ents)
	}

	// Unstamped and no argument.
	c2 := ctx("")
	c2.Self = ""
	if err := noToken(t, Run(c2, Options{})); err == nil || !strings.Contains(err.Error(), "no build stamp") {
		t.Errorf("unstamped: %v", err)
	}
}

// release2 re-signs tag ver's checksums after its assets were changed.
func (g *github) release2(s *signer, ver string) {
	assets := g.releases["v"+ver]
	var sums []string
	for _, arch := range []string{"amd64", "arm64"} {
		name := AssetName(ver, arch)
		sum := sha256.Sum256(assets[name])
		sums = append(sums, hex.EncodeToString(sum[:])+"  "+name)
	}
	checksums := []byte(strings.Join(sums, "\n") + "\n")
	assets["checksums.txt"] = checksums
	assets["checksums.txt.minisig"] = s.sign(checksums, "kasbah "+ver)
}

// TestLoose is a release binary run from outside any library: asked for its
// own version it installs its own bytes, verified, and downloads no binary.
func TestLoose(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	for _, v := range []string{"1.1.0", "1.2.0", "1.3.0-dev.3.5"} {
		g.release(s, v, true)
	}
	c, buf := client(t, g, s)
	asset := func(ver string) string { return "v" + ver + "/" + AssetName(ver, "amd64") }
	// exe is a loose copy of ver's published asset, tail appended.
	exe := func(ver, tail string) string {
		p := filepath.Join(t.TempDir(), AssetName(ver, "amd64"))
		os.WriteFile(p, append(append([]byte{}, g.releases["v"+ver][AssetName(ver, "amd64")]...), tail...), 0o755)
		return p
	}
	var link string
	run := func(self, exe string, loose bool, o Options, installed ...string) (root string, err error) {
		root = filepath.Join(t.TempDir(), "lib")
		for _, v := range installed {
			os.MkdirAll(filepath.Join(root, v), 0o755)
			os.WriteFile(filepath.Join(root, v, "kasbah"), []byte("#!/bin/sh\necho 'kasbah "+v+" (schema 1)'\n"), 0o755)
		}
		bin := filepath.Join(t.TempDir(), "bin")
		link = filepath.Join(bin, "kasbah")
		buf.Reset()
		err = Run(Ctx{Client: c, Out: c.Out, Prompter: fakeTTY("", c.Out), Root: root, BinDir: bin,
			Arch: "amd64", Self: self, Exe: exe, Loose: loose, RunTimeout: 5 * time.Second}, o)
		return root, err
	}
	target := func() string { s, _ := os.Readlink(link); return s }

	// Its own version, by no argument: its bytes installed, as binary and server build.
	self := exe("1.2.0", "")
	root, err := run("1.2.0", self, true, Options{})
	if err != nil {
		t.Fatalf("self-install: %v\n%s", err, buf)
	}
	want, _ := os.ReadFile(self)
	for _, p := range []string{filepath.Join(root, "1.2.0", "kasbah"), filepath.Join(root, "1.2.0", "server", "kasbah-linux-amd64")} {
		if b, _ := os.ReadFile(p); !bytes.Equal(b, want) {
			t.Errorf("%s is not this binary's bytes", p)
		}
	}
	for _, want := range []string{"resolved 1.2.0", "verified checksums.txt", "this binary is the published " + AssetName("1.2.0", "amd64"), "nothing downloaded", "installed kasbah 1.2.0"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("output lacks %q:\n%s", want, buf)
		}
	}
	if n := g.hits(asset("1.2.0")); n != 0 {
		t.Errorf("the binary was downloaded anyway (%d requests)", n)
	}
	if g.hits("checksums.txt.minisig") == 0 {
		t.Error("the signature was not fetched")
	}

	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("self-install: symlink -> %s", target())
	}

	// No argument beside a newer installed version: the link goes to the newest;
	// `v1` (resolving to 1.2.0) pins it to 1.2.0 instead.
	if root, err := run("1.2.0", self, true, Options{}, "1.9.0"); err != nil || target() != filepath.Join(root, "1.9.0", "kasbah") {
		t.Errorf("self-install, no argument, 1.9.0 installed: %v, symlink -> %s\n%s", err, target(), buf)
	}
	if root, err := run("1.2.0", self, true, Options{Version: "v1"}, "1.9.0"); err != nil || target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("self-install, v1, 1.9.0 installed: %v, symlink -> %s\n%s", err, target(), buf)
	}

	// Named exactly, same thing — and pinned, though a newer one is installed.
	if root, err := run("1.2.0", self, true, Options{Version: "v1.2.0"}, "1.9.0"); err != nil || !fileIs(filepath.Join(root, "1.2.0", "kasbah"), want) {
		t.Errorf("self-install by name: %v\n%s", err, buf)
	} else if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("self-install by name: symlink -> %s, not pinned", target())
	}
	if n := g.hits(asset("1.2.0")); n != 0 {
		t.Errorf("the binary was downloaded anyway (%d requests)", n)
	}

	// Bytes that are not the published asset: refused, nothing installed.
	root, err = run("1.2.0", exe("1.2.0", "# patched\n"), true, Options{})
	if noToken(t, err) == nil || !strings.Contains(err.Error(), "is not the published "+AssetName("1.2.0", "amd64")) || !strings.Contains(err.Error(), "nothing was installed") {
		t.Errorf("tampered self: %v", err)
	}
	if _, serr := os.Stat(filepath.Join(root, "1.2.0")); serr == nil {
		t.Error("a tampered binary was installed")
	}
	if n := g.hits(asset("1.2.0")); n != 0 {
		t.Errorf("a refused self-install downloaded (%d requests)", n)
	}

	// Another version: downloaded as usual.
	if root, err := run("1.2.0", self, true, Options{Version: "v1.1.0"}); err != nil || !fileIs(filepath.Join(root, "1.1.0", "kasbah"), g.releases["v1.1.0"][AssetName("1.1.0", "amd64")]) {
		t.Errorf("loose, another version: %v\n%s", err, buf)
	}
	if g.hits("api /assets/"+asset("1.1.0")) != 1 || g.hits("cdn /blob/"+asset("1.1.0")) != 1 {
		t.Error("another version was not downloaded")
	}

	// A dev build, even one a release was cut from: downloads.
	dev := exe("1.3.0-dev.3.5", "")
	if _, err := run("1.3.0-dev.3.5", dev, true, Options{Version: "v1.3.0-dev.3.5"}); err != nil {
		t.Errorf("loose dev build: %v\n%s", err, buf)
	}
	if g.hits(asset("1.3.0-dev.3.5")) != 2 || strings.Contains(buf.String(), "nothing downloaded") {
		t.Errorf("a loose dev build installed itself:\n%s", buf)
	}

	// Not loose (an installed release): downloads, as before.
	if _, err := run("1.2.0", self, false, Options{Version: "v1.2.0"}); err != nil {
		t.Errorf("installed release: %v\n%s", err, buf)
	}
	if g.hits("api /assets/"+asset("1.2.0")) != 1 || g.hits("cdn /blob/"+asset("1.2.0")) != 1 {
		t.Error("an installed release did not download")
	}
}

// TestFrom is get.sh's hand-off: a loose release binary installs itself from
// a checksums.txt and signature already on disk, asking no server anything.
func TestFrom(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	g.release(s, "1.2.0", true)
	c, buf := client(t, g, s)
	name := AssetName("1.2.0", "amd64")
	published := g.releases["v1.2.0"][name]
	// files is a --from directory: checksums.txt, and its signature unless sig is nil.
	files := func(sums, sig []byte) string {
		d := t.TempDir()
		os.WriteFile(filepath.Join(d, "checksums.txt"), sums, 0o644)
		if sig != nil {
			os.WriteFile(filepath.Join(d, "checksums.txt.minisig"), sig, 0o644)
		}
		return d
	}
	sums := g.releases["v1.2.0"]["checksums.txt"]
	good := files(sums, g.releases["v1.2.0"]["checksums.txt.minisig"])
	exe := func(b []byte) string {
		p := filepath.Join(t.TempDir(), name)
		os.WriteFile(p, b, 0o755)
		return p
	}
	self := exe(published)
	var root, link string
	run := func(stamp, exe string, loose bool, o Options, installed ...string) error {
		root = filepath.Join(t.TempDir(), "lib")
		for _, v := range installed {
			os.MkdirAll(filepath.Join(root, v), 0o755)
			os.WriteFile(filepath.Join(root, v, "kasbah"), []byte("#!/bin/sh\necho 'kasbah "+v+" (schema 1)'\n"), 0o755)
		}
		bin := filepath.Join(t.TempDir(), "bin")
		link = filepath.Join(bin, "kasbah")
		buf.Reset()
		return Run(Ctx{Client: c, Out: c.Out, Prompter: fakeTTY("", c.Out), Root: root, BinDir: bin,
			Arch: "amd64", Self: stamp, Exe: exe, Loose: loose, RunTimeout: 5 * time.Second}, o)
	}
	target := func() string { s, _ := os.Readlink(link); return s }
	quiet := func(what string) {
		t.Helper()
		g.mu.Lock()
		defer g.mu.Unlock()
		if len(g.paths) != 0 {
			t.Errorf("%s: requests made: %v", what, g.paths)
		}
		g.paths = nil
	}

	// Its own version, the files at hand: installed and pinned, beside a newer one.
	if err := run("1.2.0", self, true, Options{Version: "v1.2.0", From: good}, "1.9.0"); err != nil {
		t.Fatalf("--from: %v\n%s", err, buf)
	}
	for _, p := range []string{filepath.Join(root, "1.2.0", "kasbah"), filepath.Join(root, "1.2.0", "server", "kasbah-linux-amd64")} {
		if !fileIs(p, published) {
			t.Errorf("%s is not this binary's bytes", p)
		}
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("--from: symlink -> %s, not pinned", target())
	}
	for _, want := range []string{"resolved 1.2.0 (this binary's own release, checksums.txt from " + good + ")",
		"verified checksums.txt: key " + s.pub.IDString() + ", trusted comment \"kasbah 1.2.0\"",
		"this binary is the published " + name, "installed kasbah 1.2.0"} {
		if !strings.Contains(buf.String(), want) {
			t.Errorf("--from: output lacks %q:\n%s", want, buf)
		}
	}
	quiet("--from")

	// Already installed: exit 0, the symlink pinned, still no request.
	if err := run("1.2.0", self, true, Options{Version: "1.2.0", From: good}, "1.2.0", "1.9.0"); err != nil ||
		!strings.Contains(buf.String(), "kasbah 1.2.0 is already installed") || target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("--from, installed: %v, symlink -> %s\n%s", err, target(), buf)
	}
	quiet("--from, installed")

	other := newSigner(t)
	cases := []struct {
		name, stamp, exe string
		loose            bool
		o                Options
		want             string
	}{
		{"not loose", "1.2.0", self, false, Options{Version: "v1.2.0", From: good}, "is already in the library"},
		{"another version", "1.2.0", self, true, Options{Version: "v1.1.0", From: good}, "it is kasbah 1.2.0, not 1.1.0"},
		{"a dev build", "1.3.0-dev.3.5", self, true, Options{Version: "v1.3.0-dev.3.5", From: good}, "a dev build (1.3.0-dev.3.5), not a release"},
		{"unstamped", "", self, true, Options{Version: "v1.2.0", From: good}, "carries no build stamp"},
		{"oversized checksums.txt", "1.2.0", self, true, Options{Version: "v1.2.0", From: files(append(append([]byte{}, sums...), bytes.Repeat([]byte("#"), 1<<20)...), g.releases["v1.2.0"]["checksums.txt.minisig"])}, "checksums.txt: longer than 1 MiB"},
		{"no signature", "1.2.0", self, true, Options{Version: "v1.2.0", From: files(sums, nil)}, "checksums.txt.minisig"},
		{"no directory", "1.2.0", self, true, Options{Version: "v1.2.0", From: filepath.Join(good, "nope")}, "cannot read"},
		{"garbled signature", "1.2.0", self, true, Options{Version: "v1.2.0", From: files(sums, []byte("junk\n"))}, "does not verify against release.pub"},
		{"another key", "1.2.0", self, true, Options{Version: "v1.2.0", From: files(sums, other.sign(sums, "kasbah 1.2.0"))}, "does not verify against release.pub"},
		{"tampered sums", "1.2.0", self, true, Options{Version: "v1.2.0", From: files(append([]byte("0000"), sums[4:]...), g.releases["v1.2.0"]["checksums.txt.minisig"])}, "does not verify against release.pub"},
		{"another release's signature", "1.2.0", self, true, Options{Version: "v1.2.0", From: files(sums, s.sign(sums, "kasbah 1.1.0"))}, `signed as "kasbah 1.1.0"`},
		{"other bytes", "1.2.0", exe(append(append([]byte{}, published...), "# patched\n"...)), true, Options{Version: "v1.2.0", From: good}, "is not the published " + name},
	}
	for _, tt := range cases {
		err := run(tt.stamp, tt.exe, tt.loose, tt.o)
		if err == nil || !strings.Contains(err.Error(), tt.want) || !strings.Contains(err.Error(), "nothing was installed") {
			t.Errorf("%s: %v", tt.name, err)
		}
		if ents, _ := os.ReadDir(root); len(ents) != 0 {
			t.Errorf("%s: the library holds %d entries", tt.name, len(ents))
		}
		if _, err := os.Lstat(link); err == nil {
			t.Errorf("%s: the symlink was made", tt.name)
		}
		quiet(tt.name)
	}
}

func fileIs(path string, want []byte) bool {
	b, err := os.ReadFile(path)
	return err == nil && bytes.Equal(b, want)
}

func TestParse(t *testing.T) {
	o, err := Parse([]string{"v1.2.0\r", "--pre", "--yes"})
	if err != nil || o.Version != "v1.2.0" || !o.Pre || !o.Yes {
		t.Errorf("%+v, %v", o, err)
	}
	if _, err := Parse([]string{"--help"}); err != ErrHelp {
		t.Error("--help")
	}
	for _, ok := range []string{"v1", "v1.2", "1.2.3", "v1.2.3-rc.1"} {
		if o, err := Parse([]string{ok}); err != nil || o.Version != ok {
			t.Errorf("%s: %+v, %v", ok, o, err)
		}
	}
	for _, args := range [][]string{{"v1.2.0", "--from", "/d\r"}, {"--from=/d", "v1.2.0"}, {"--from", "/d", "1.2.0-rc.1"}} {
		if o, err := Parse(args); err != nil || o.From != "/d" || !exact(o.Version) {
			t.Errorf("%v: %+v, %v", args, o, err)
		}
	}
	for _, bad := range [][]string{{"--yes=1"}, {"--nope"}, {"v1", "v2"}, {"vx"}, {"v1.2.3.4"},
		{"--from", "/d"}, {"v1", "--from", "/d"}, {"v1.2", "--from=/d"}, {"v1.2.0", "--from"}, {"v1.2.0", "--from="},
		{"v1.2.0", "--from", "/d", "--from", "/e"}} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("%v parsed", bad)
		}
	}
}
