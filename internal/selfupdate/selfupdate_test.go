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
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
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
	cdnAuth  []string                     // Authorization headers the cdn saw
	apiAuth  []string
}

func newGithub(t *testing.T) *github {
	g := &github{releases: map[string]map[string][]byte{}}
	g.cdn = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		g.cdnAuth = append(g.cdnAuth, r.Header.Get("Authorization"))
		g.mu.Unlock()
		tag, name, _ := strings.Cut(strings.TrimPrefix(r.URL.Path, "/blob/"), "/")
		b, ok := g.releases[tag][name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(b)
	}))
	g.api = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		g.mu.Lock()
		g.apiAuth = append(g.apiAuth, r.Header.Get("Authorization"))
		g.mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer "+secret {
			http.Error(w, "bad credentials", http.StatusUnauthorized)
			return
		}
		switch {
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
			http.Redirect(w, r, g.cdn.URL+"/blob/"+strings.TrimPrefix(r.URL.Path, "/assets/"), http.StatusFound)
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(g.api.Close)
	t.Cleanup(g.cdn.Close)
	return g
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

// repo is a git repository with the given tags, for ls-remote.
func repo(t *testing.T, tags ...string) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"}, args...)...)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	run("commit", "-q", "--allow-empty", "-m", "x")
	for _, tag := range tags {
		run("tag", tag)
	}
	return dir
}

func client(t *testing.T, g *github, s *signer, remote string) (*Client, *bytes.Buffer) {
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	c := &Client{API: g.api.URL, Remote: remote, Token: secret, Key: s.pub, HTTP: NewHTTP(), Out: out}
	return c, &buf
}

// secret is the token the fake API accepts; a substring no message spells.
const secret = "ghp_Q7xK2vLm9ZpR"

// noToken is every failure the suite sees: none may carry the token.
func noToken(t *testing.T, err error) error {
	t.Helper()
	if err != nil && strings.Contains(err.Error(), secret) {
		t.Errorf("the token leaked into an error: %v", err)
	}
	return err
}

func TestToken(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	noGh := func(string) (string, error) { return "", os.ErrNotExist }
	gh := func(string) (string, error) { return "/usr/bin/gh", nil }
	if tok, err := Token(env(map[string]string{"GITHUB_TOKEN": " abc\n"}), noGh, nil); err != nil || tok != "abc" {
		t.Errorf("GITHUB_TOKEN: %q, %v", tok, err)
	}
	_, err := Token(env(nil), noGh, nil)
	if err == nil || !strings.Contains(err.Error(), "GITHUB_TOKEN") || !strings.Contains(err.Error(), "gh auth login") {
		t.Errorf("no token: %v", err)
	}
	var ran []string
	run := func(name string, args ...string) ([]byte, error) {
		ran = append(ran, name+" "+strings.Join(args, " "))
		return []byte("ghtok\n"), nil
	}
	if tok, err := Token(env(nil), gh, run); err != nil || tok != "ghtok" || len(ran) != 1 || ran[0] != "gh auth token" {
		t.Errorf("gh: %q, %v, %v", tok, err, ran)
	}
	_, err = Token(env(nil), gh, func(string, ...string) ([]byte, error) { return nil, fmt.Errorf("not logged in") })
	if err == nil || !strings.Contains(err.Error(), "gh auth login") {
		t.Errorf("gh without login: %v", err)
	}
}

func TestResolve(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	c, _ := client(t, g, s, repo(t, "v1.0.0", "v1.2.0", "v1.3.0-rc.1", "v2.0.0", "v2.1.0-dev.3.5", "vjunk", "other"))
	cases := []struct {
		arg       string
		major     uint64
		pre       bool
		want, how string
	}{
		{"", 1, false, "1.2.0", "newest v1.*"},
		{"", 1, true, "1.3.0-rc.1", "newest v1.*"},
		{"v1", 2, false, "1.2.0", "1 pre-release tag(s) skipped"},
		{"2", 1, false, "2.0.0", "newest v2.*"},
		{"v2", 1, true, "2.1.0-dev.3.5", ""},
		{"v1.0.0", 2, false, "1.0.0", "tag v1.0.0"},
		{"v1.3.0-rc.1", 2, false, "1.3.0-rc.1", "tag v1.3.0-rc.1"},
	}
	for _, tt := range cases {
		v, how, err := c.Resolve(tt.arg, tt.major, tt.pre)
		if err != nil || v.String() != tt.want || !strings.Contains(how, tt.how) {
			t.Errorf("Resolve(%q, %d, %v) = %s, %q, %v; want %s", tt.arg, tt.major, tt.pre, v, how, err, tt.want)
		}
	}
	for _, bad := range []string{"v1.9.9", "v3", "vx", "v1.2", "1.2.3.4"} {
		_, _, err := c.Resolve(bad, 1, false)
		if noToken(t, err) == nil {
			t.Errorf("Resolve(%q) succeeded", bad)
		}
	}
	if _, _, err := c.Resolve("v3", 1, false); err == nil || !strings.Contains(err.Error(), "no release of v3.*") {
		t.Errorf("v3: %v", err)
	}
	c.Remote = filepath.Join(t.TempDir(), "nowhere")
	_, _, err := c.Resolve("", 1, false)
	if noToken(t, err) == nil || !strings.Contains(err.Error(), "could not list the release tags") {
		t.Errorf("no remote: %v", err)
	}

}

func TestReleaseVerifies(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	g.release(s, "1.2.0", true)
	c, _ := client(t, g, s, "")
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
	// A bad token.
	c.Token = "nope"
	if _, err := c.Release("1.2.0"); noToken(t, err) == nil || !strings.Contains(err.Error(), "401") {
		t.Errorf("bad token: %v", err)
	}
}

func TestDownload(t *testing.T) {
	g := newGithub(t)
	s := newSigner(t)
	g.release(s, "1.2.0", true)
	c, _ := client(t, g, s, "")
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
	if err := noToken(t, c.Download(rel, name, other)); err == nil || !strings.Contains(err.Error(), "outside "+g.api.URL) || !strings.Contains(err.Error(), strings.TrimPrefix(elsewhere.URL, "http://")) {
		t.Errorf("foreign host: %v", err)
	}
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
	remote := repo(t, "v1.1.0", "v1.2.0", "v2.0.0")
	c, buf := client(t, g, s, remote)
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

	// Again: already installed, nothing downloaded.
	buf.Reset()
	before := len(g.cdnAuth)
	if err := noToken(t, Run(ctx(""), Options{})); err == nil || !strings.Contains(err.Error(), "already installed") {
		t.Errorf("second run: %v", err)
	}
	if len(g.cdnAuth) != before {
		t.Error("a second run downloaded")
	}

	// An older exact version installs but the symlink stays on the newest.
	buf.Reset()
	if err := Run(ctx(""), Options{Version: "v1.1.0"}); err != nil {
		t.Fatalf("v1.1.0: %v\n%s", err, buf)
	}
	if target() != filepath.Join(root, "1.2.0", "kasbah") {
		t.Errorf("after 1.1.0: symlink -> %s", target())
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
	// 2.0.0 is installed now, so the next run says so before asking anything;
	// clear it to exercise the answers.
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

func TestRepoint(t *testing.T) {
	root, binDir := t.TempDir(), t.TempDir()
	plant := func(ver, script string) {
		os.MkdirAll(filepath.Join(root, ver), 0o755)
		os.WriteFile(filepath.Join(root, ver, "kasbah"), []byte(script), 0o755)
	}
	plant("1.2.0", "#!/bin/sh\necho kasbah 1.2.0\n")
	plant("1.3.0", "#!/bin/sh\nexit 1\n")
	var buf bytes.Buffer
	out := &cli.Output{Stdout: &buf, Stderr: &buf}
	link := filepath.Join(binDir, "kasbah")
	// A 1.0.x regular file there: replaced, its version read by running it.
	os.WriteFile(link, []byte("#!/bin/sh\necho kasbah 0.9.0\n"), 0o755)
	if _, err := Repoint(root, binDir, fakeTTY("", out), false, 5*time.Second); err == nil || !strings.Contains(err.Error(), "--yes") {
		t.Errorf("regular file of another major without a tty: %v", err)
	}
	got, err := Repoint(root, binDir, fakeTTY("y\n", out), false, 5*time.Second)
	if err != nil || got != filepath.Join(root, "1.2.0", "kasbah") {
		t.Fatalf("repoint: %s, %v", got, err)
	}
	if target, _ := os.Readlink(link); target != got {
		t.Errorf("symlink -> %s", target)
	}
	// Same major: no question even without a tty.
	plant("1.4.0", "#!/bin/sh\necho kasbah 1.4.0\n")
	if got, err := Repoint(root, binDir, fakeTTY("", out), false, 5*time.Second); err != nil || !strings.HasSuffix(got, "/1.4.0/kasbah") {
		t.Errorf("same major: %s, %v", got, err)
	}
	// Something else there is refused.
	os.Remove(link)
	os.Mkdir(link, 0o755)
	if _, err := Repoint(root, binDir, fakeTTY("", out), true, 5*time.Second); err == nil || !strings.Contains(err.Error(), "refusing to replace") {
		t.Errorf("a directory: %v", err)
	}
	// Nothing runs.
	if _, err := Repoint(t.TempDir(), t.TempDir(), fakeTTY("", out), true, 5*time.Second); err == nil || !strings.Contains(err.Error(), "no installed kasbah runs") {
		t.Errorf("empty: %v", err)
	}
}

func TestParse(t *testing.T) {
	o, err := Parse([]string{"v1.2.0\r", "--pre", "--yes"})
	if err != nil || o.Version != "v1.2.0" || !o.Pre || !o.Yes {
		t.Errorf("%+v, %v", o, err)
	}
	if _, err := Parse([]string{"--help"}); err != ErrHelp {
		t.Error("--help")
	}
	for _, bad := range [][]string{{"--yes=1"}, {"--nope"}, {"v1", "v2"}} {
		if _, err := Parse(bad); err == nil {
			t.Errorf("%v parsed", bad)
		}
	}
}
