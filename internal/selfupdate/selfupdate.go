// Package selfupdate installs a released kasbah from GitHub Releases into the
// versioned library install.sh writes (<lib>/<ver>/kasbah beside
// <lib>/<ver>/server/), after verifying the release's minisign-signed
// checksums.txt against the key in release.pub and each asset against it.
// The server builds a version lacks are fetched the same way, on demand.
package selfupdate

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/minisign"
	"github.com/adigourdi/kasbah/internal/releasekey"
	"github.com/adigourdi/kasbah/internal/version"
)

// The release contract (docs/overview.md → Distribution): where the tags and
// assets live, and what the assets are called.
const (
	Repo          = "adigourdi/kasbah"
	DefaultAPI    = "https://api.github.com"
	DefaultRemote = "git@github.com:adigourdi/kasbah.git"
)

// AssetName is the one-file-per-arch release asset, the workstation binary
// and that arch's server build alike.
func AssetName(ver, arch string) string { return "kasbah_" + ver + "_linux_" + arch }

// Client reaches one release source: tags over git, assets over the API.
type Client struct {
	// API is the GitHub API base (KASBAH_RELEASES_API).
	API string
	// Remote is what `git ls-remote` lists tags from (KASBAH_RELEASES_REMOTE).
	Remote string
	// Token authenticates the API: the repository is private.
	Token string
	// Key verifies checksums.txt; release.pub unless a test says otherwise.
	Key  minisign.PublicKey
	HTTP *http.Client
	Out  *cli.Output
}

// New is the client the environment configures, its token from Token.
func New(out *cli.Output, getenv func(string) string) (*Client, error) {
	key, err := releasekey.Key()
	if err != nil {
		return nil, cli.Fail("the embedded release.pub does not parse: %v", err)
	}
	tok, err := Token(getenv, exec.LookPath, func(name string, args ...string) ([]byte, error) {
		return exec.Command(name, args...).Output()
	})
	if err != nil {
		return nil, err
	}
	c := &Client{API: DefaultAPI, Remote: DefaultRemote, Token: tok, Key: key, Out: out}
	if v := getenv("KASBAH_RELEASES_API"); v != "" {
		c.API = strings.TrimRight(v, "/")
	}
	if v := getenv("KASBAH_RELEASES_REMOTE"); v != "" {
		c.Remote = v
	}
	c.HTTP = NewHTTP()
	return c, nil
}

// NewHTTP is the client downloads go through: a redirect (the asset endpoint
// answers with a signed URL on another host) never carries the token on.
func NewHTTP() *http.Client {
	return &http.Client{
		Timeout: 15 * time.Minute,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("stopped after 10 redirects")
			}
			req.Header.Del("Authorization")
			return nil
		},
	}
}

// Token is the GitHub token: GITHUB_TOKEN, else what `gh auth token` prints
// when gh is on PATH, else a failure naming both.
func Token(getenv func(string) string, lookPath func(string) (string, error), run func(string, ...string) ([]byte, error)) (string, error) {
	if t := strings.TrimSpace(getenv("GITHUB_TOKEN")); t != "" {
		return t, nil
	}
	fail := cli.Fail("no GitHub token: the kasbah repository is private, and fetching a release needs one").Cont(
		"set GITHUB_TOKEN, or install gh and run `gh auth login` — kasbah then uses `gh auth token`")
	if _, err := lookPath("gh"); err != nil {
		return "", fail
	}
	out, err := run("gh", "auth", "token")
	if t := strings.TrimSpace(string(out)); err == nil && t != "" {
		return t, nil
	}
	return "", fail.Cont("(`gh auth token` printed no token)")
}

// Tags lists the release tags on Remote matching pattern (`v1.*`,
// `v1.2.3`), as versions, highest first. Anything not `v<semver>` is ignored.
func (c *Client) Tags(pattern string) ([]version.Version, error) {
	cmd := exec.Command("git", "ls-remote", "--tags", "--refs", c.Remote, pattern)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	cmd.Stdin = os.Stdin
	if err := cmd.Run(); err != nil {
		f := cli.Fail("could not list the release tags on %s: %v", c.Remote, err)
		if msg := strings.TrimRight(strings.ReplaceAll(stderr.String(), "\r", ""), "\n"); msg != "" {
			f.Cont(strings.Split(msg, "\n")...)
		}
		return nil, f
	}
	var out []version.Version
	for _, l := range strings.Split(strings.ReplaceAll(stdout.String(), "\r", ""), "\n") {
		_, ref, ok := strings.Cut(l, "\t")
		if !ok {
			continue
		}
		tag, ok := strings.CutPrefix(strings.TrimSpace(ref), "refs/tags/v")
		if !ok {
			continue
		}
		v, err := version.Parse(tag)
		if err != nil {
			continue
		}
		out = append(out, v)
	}
	sort.SliceStable(out, func(i, j int) bool { return version.Compare(out[i], out[j]) > 0 })
	return out, nil
}

// Resolve turns the command's argument into a released version: "" is the
// newest release of major, `vN` the newest of N, `vN.M.P` that tag exactly;
// pre-releases count only with pre, or when named exactly. how says what was
// resolved, for the run's report.
func (c *Client) Resolve(arg string, major uint64, pre bool) (v version.Version, how string, err error) {
	arg = strings.TrimPrefix(strings.TrimSuffix(arg, "\r"), "v")
	if arg != "" && !strings.Contains(arg, ".") {
		n, ok := parseMajor(arg)
		if !ok {
			return v, "", cli.Fail("'%s' is not a version: expected vN or vN.M.P", arg)
		}
		major = n
		arg = ""
	}
	if arg != "" {
		want, perr := version.Parse(arg)
		if perr != nil {
			return v, "", cli.Fail("'v%s' is not a version: expected vN or vN.M.P", arg)
		}
		tags, err := c.Tags("v" + arg)
		if err != nil {
			return v, "", err
		}
		for _, t := range tags {
			if version.Compare(t, want) == 0 && t.String() == want.String() {
				return t, "tag v" + t.String() + " on " + c.Remote, nil
			}
		}
		return v, "", cli.Fail("there is no tag v%s on %s", arg, c.Remote)
	}
	tags, err := c.Tags(fmt.Sprintf("v%d.*", major))
	if err != nil {
		return v, "", err
	}
	var skipped int
	for _, t := range tags {
		if t.Major != major {
			continue
		}
		if len(t.Pre) > 0 && !pre {
			skipped++
			continue
		}
		how = fmt.Sprintf("newest v%d.* on %s", major, c.Remote)
		if skipped > 0 {
			how += fmt.Sprintf(" (%d pre-release tag(s) skipped — --pre takes them)", skipped)
		}
		return t, how, nil
	}
	f := cli.Fail("there is no release of v%d.* on %s", major, c.Remote)
	if skipped > 0 {
		f.Cont(fmt.Sprintf("%d pre-release tag(s) were skipped — --pre takes them", skipped))
	}
	return v, "", f
}

func parseMajor(s string) (uint64, bool) {
	var n uint64
	if s == "" || (len(s) > 1 && s[0] == '0') {
		return 0, false
	}
	for _, ch := range s {
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n*10 + uint64(ch-'0')
	}
	return n, true
}

// Asset is one file of a release as the API lists it.
type Asset struct {
	Name string `json:"name"`
	URL  string `json:"url"`
	Size int64  `json:"size"`
}

// Release is a verified release: its assets, and the sha256 of each as the
// signed checksums.txt states them.
type Release struct {
	Tag    string
	Assets map[string]Asset
	Sums   map[string]string
	// Comment is the signature's trusted comment (`kasbah <ver>`); KeyID the
	// key it verified against.
	Comment, KeyID string
}

// Release fetches v<ver>'s asset list, then checksums.txt and its signature,
// and verifies the signature before anything in checksums.txt is trusted.
func (c *Client) Release(ver string) (*Release, error) {
	tag := "v" + ver
	body, err := c.get(c.API+"/repos/"+Repo+"/releases/tags/"+tag, "application/vnd.github+json", -1)
	if err != nil {
		return nil, cli.Fail("could not read the release %s: %v", tag, err)
	}
	var rel struct {
		Assets []Asset `json:"assets"`
	}
	if err := json.Unmarshal(body, &rel); err != nil {
		return nil, cli.Fail("the release %s did not answer with JSON: %v", tag, err)
	}
	r := &Release{Tag: tag, Assets: map[string]Asset{}, Sums: map[string]string{}}
	for _, a := range rel.Assets {
		r.Assets[a.Name] = a
	}
	sums, err := c.fetch(r, "checksums.txt")
	if err != nil {
		return nil, err
	}
	sig, err := c.fetch(r, "checksums.txt.minisig")
	if err != nil {
		return nil, err
	}
	comment, err := minisign.Verify(c.Key, sums, sig)
	if err != nil {
		return nil, cli.Fail("%s's checksums.txt does not verify against release.pub (key %s): %v", tag, c.Key.IDString(), err).Cont(
			"nothing was installed — the release is not one kasbah's key signed")
	}
	r.Comment, r.KeyID = comment, c.Key.IDString()
	for _, l := range strings.Split(strings.ReplaceAll(string(sums), "\r", ""), "\n") {
		f := strings.Fields(l)
		if len(f) != 2 {
			continue
		}
		r.Sums[strings.TrimPrefix(f[1], "*")] = f[0]
	}
	return r, nil
}

// fetch reads one small asset whole.
func (c *Client) fetch(r *Release, name string) ([]byte, error) {
	a, ok := r.Assets[name]
	if !ok {
		return nil, cli.Fail("the release %s has no asset %s", r.Tag, name)
	}
	if err := c.underAPI(a); err != nil {
		return nil, err
	}
	body, err := c.get(a.URL, "application/octet-stream", 1<<20)
	if err != nil {
		return nil, cli.Fail("could not download %s of %s: %v", name, r.Tag, err)
	}
	return body, nil
}

// underAPI refuses an asset whose URL is not under the API base: the token
// goes only there (a redirect onwards goes without it, NewHTTP).
func (c *Client) underAPI(a Asset) error {
	if strings.HasPrefix(a.URL, c.API+"/") {
		return nil
	}
	host := a.URL
	if u, err := url.Parse(a.URL); err == nil && u.Host != "" {
		host = u.Host
	}
	return cli.Fail("the release lists asset %s at %s, outside %s — not fetched, the token is not sent there", a.Name, host, c.API)
}

func (c *Client) request(url, accept string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", accept)
	req.Header.Set("Authorization", "Bearer "+c.Token)
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		if resp.StatusCode == http.StatusNotFound {
			return nil, fmt.Errorf("%s: 404 — no such release, or the token cannot see %s", url, Repo)
		}
		return nil, fmt.Errorf("%s: %s", url, resp.Status)
	}
	return resp, nil
}

func (c *Client) get(url, accept string, limit int64) ([]byte, error) {
	resp, err := c.request(url, accept)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var r io.Reader = resp.Body
	if limit > 0 {
		r = io.LimitReader(resp.Body, limit+1)
	}
	body, err := io.ReadAll(r)
	if err != nil {
		return nil, err
	}
	if limit > 0 && int64(len(body)) > limit {
		return nil, fmt.Errorf("%s: longer than %d bytes", url, limit)
	}
	return body, nil
}

// Download puts asset name of r at dst, mode 0755: streamed to a temp file
// beside dst, its size and sha256 checked against the API and checksums.txt,
// and renamed into place only then. A failure leaves nothing behind.
func (c *Client) Download(r *Release, name, dst string) error {
	a, ok := r.Assets[name]
	if !ok {
		return cli.Fail("the release %s has no asset %s", r.Tag, name)
	}
	want, ok := r.Sums[name]
	if !ok {
		return cli.Fail("%s's checksums.txt has no entry for %s", r.Tag, name)
	}
	if err := c.underAPI(a); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return cli.Fail("%v", err)
	}
	tmp := filepath.Join(filepath.Dir(dst), "."+filepath.Base(dst)+".part")
	pop := atexit.Push(func() { os.Remove(tmp) })
	defer pop()
	defer os.Remove(tmp)
	if c.Out != nil {
		c.Out.Info("downloading %s (%d bytes)", name, a.Size)
	}
	resp, err := c.request(a.URL, "application/octet-stream")
	if err != nil {
		return cli.Fail("could not download %s of %s: %v", name, r.Tag, err)
	}
	defer resp.Body.Close()
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
	if err != nil {
		return cli.Fail("%v", err)
	}
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(f, h), io.LimitReader(resp.Body, a.Size+1))
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	if err != nil {
		return cli.Fail("could not write %s: %v", tmp, err)
	}
	if n != a.Size {
		return cli.Fail("%s of %s: %d bytes downloaded, the release lists %d — nothing was installed", name, r.Tag, n, a.Size)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return cli.Fail("%s of %s: sha256 %s, checksums.txt says %s — nothing was installed", name, r.Tag, got, want)
	}
	if err := os.Rename(tmp, dst); err != nil {
		return cli.Fail("%v", err)
	}
	return nil
}

// FetchServerBuild is the lazy path: the linux/arch build of release ver into
// <home>/server/, verified like every asset. home is the version directory.
func FetchServerBuild(out *cli.Output, home, ver, arch string) error {
	c, err := New(out, os.Getenv)
	if err != nil {
		return err
	}
	r, err := c.Release(ver)
	if err != nil {
		return err
	}
	return c.Download(r, AssetName(ver, arch), filepath.Join(home, "server", "kasbah-linux-"+arch))
}
