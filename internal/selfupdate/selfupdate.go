// Package selfupdate installs a released kasbah from GitHub Releases into the
// versioned library install-dev.sh writes (<lib>/<ver>/kasbah beside
// <lib>/<ver>/server/), after verifying the release's minisign-signed
// checksums.txt against the key in release.pub and each asset against it.
// The server builds a version lacks are fetched the same way, on demand.
package selfupdate

import (
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
	"strconv"
	"strings"
	"time"

	"github.com/adigourdi/kasbah/internal/atexit"
	"github.com/adigourdi/kasbah/internal/cli"
	"github.com/adigourdi/kasbah/internal/minisign"
	"github.com/adigourdi/kasbah/internal/releasekey"
	"github.com/adigourdi/kasbah/internal/version"
)

// The release contract (docs/overview.md → Distribution): where the releases
// live, and what their assets are called.
const (
	Repo       = "adigourdi/kasbah"
	DefaultAPI = "https://api.github.com"
)

// AssetName is the one-file-per-arch release asset, the workstation binary
// and that arch's server build alike.
func AssetName(ver, arch string) string { return "kasbah_" + ver + "_linux_" + arch }

// Client reaches the releases of Repo through the GitHub API.
type Client struct {
	// API is the GitHub API base (KASBAH_RELEASES_API).
	API string
	// Token authenticates the API when set; anonymous otherwise. TokenFrom
	// names where it came from (GITHUB_TOKEN, gh), for a refusal.
	Token, TokenFrom string
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
	c := &Client{API: DefaultAPI, Key: key, Out: out}
	if v := getenv("KASBAH_RELEASES_API"); v != "" {
		c.API = strings.TrimRight(v, "/")
	}
	c.Token, c.TokenFrom = Token(c.API, getenv, exec.LookPath, func(name string, args ...string) ([]byte, error) {
		return exec.Command(name, args...).Output()
	})
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

// Token is the token for api and where it came from, "" for none:
// GITHUB_TOKEN, else — when api is GitHub's own — what
// `gh auth token --hostname github.com` prints when gh is on PATH. gh is not
// asked for any other host.
func Token(api string, getenv func(string) string, lookPath func(string) (string, error), run func(string, ...string) ([]byte, error)) (tok, from string) {
	if t := strings.TrimSpace(getenv("GITHUB_TOKEN")); t != "" {
		return t, "GITHUB_TOKEN"
	}
	if u, err := url.Parse(api); err != nil || u.Scheme != "https" || u.Host != "api.github.com" {
		return "", ""
	}
	if _, err := lookPath("gh"); err != nil {
		return "", ""
	}
	out, err := run("gh", "auth", "token", "--hostname", "github.com")
	if t := strings.TrimSpace(string(out)); err == nil && t != "" {
		return t, "gh"
	}
	return "", ""
}

// perPage and maxPages bound the releases listing: 5000 releases at most.
const (
	perPage  = 100
	maxPages = 50
)

// Releases lists Repo's published releases as versions, highest first:
// drafts, and tag names that are not v<semver>, left out.
func (c *Client) Releases() ([]version.Version, error) {
	var out []version.Version
	for page := 1; ; page++ {
		if page > maxPages {
			return nil, cli.Fail("the releases of %s run past %d pages of %d — stopped listing", Repo, maxPages, perPage)
		}
		url := fmt.Sprintf("%s/repos/%s/releases?per_page=%d&page=%d", c.API, Repo, perPage, page)
		body, err := c.get(url, "application/vnd.github+json", 64<<20)
		if err != nil {
			return nil, failed(err, "could not list the releases of %s", Repo)
		}
		var list []struct {
			Tag   string `json:"tag_name"`
			Draft bool   `json:"draft"`
		}
		if err := json.Unmarshal(body, &list); err != nil {
			return nil, cli.Fail("%s answered with something that is not a list of releases — nothing was installed", url)
		}
		for _, r := range list {
			if !r.Draft {
				out = append(out, version.Tags([]string{r.Tag})...)
			}
		}
		if len(list) < perPage {
			break
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return version.Compare(out[i], out[j]) > 0 })
	return out, nil
}

// exact is whether arg names one version (`vN.M.P[-rc.K]`) rather than the
// newest of a major or minor.
func exact(arg string) bool {
	return strings.Count(strings.TrimSpace(strings.TrimSuffix(arg, "\r")), ".") >= 2
}

// Resolve turns the command's argument into a published release through
// version.Pick: "" is the newest of major, `vN` the newest of N, `vN.M` the
// newest of N.M, `vN.M.P` that one exactly; pre-releases count only with pre,
// or when named exactly. how says what was resolved, for the run's report.
func (c *Client) Resolve(arg string, major uint64, pre bool) (v version.Version, how string, err error) {
	want := strings.TrimSpace(strings.TrimSuffix(arg, "\r"))
	if want == "" {
		want = fmt.Sprintf("v%d", major)
	}
	var nm *version.NoMatch
	if _, err := version.Pick(want, nil, pre); !errors.As(err, &nm) {
		return v, "", cli.Fail("%v", err)
	}
	name := "v" + strings.TrimPrefix(want, "v")
	rels, err := c.Releases()
	if err != nil {
		return v, "", err
	}
	v, err = version.Pick(want, rels, pre)
	if errors.As(err, &nm) {
		f := cli.Fail("no release of %s matches %s", Repo, name)
		if nm.Skipped > 0 {
			f.Cont(fmt.Sprintf("%d pre-release(s) were skipped — --pre takes them", nm.Skipped))
		}
		return v, "", f.Cont("drafts, and tags without a published release, do not count")
	}
	if err != nil {
		return v, "", cli.Fail("%v", err)
	}
	if exact(want) {
		return v, "release " + name + " of " + Repo, nil
	}
	how = "newest " + name + ".* release of " + Repo
	if !pre {
		skipped := 0
		for _, r := range rels {
			if len(r.Pre) > 0 && version.Compare(r, v) > 0 {
				if _, err := version.Pick(want, []version.Version{r}, true); err == nil {
					skipped++
				}
			}
		}
		if skipped > 0 {
			how += fmt.Sprintf(" (%d newer pre-release(s) skipped — --pre takes them)", skipped)
		}
	}
	return v, how, nil
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
		return nil, failed(err, "could not read the release %s", tag)
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
		return nil, failed(err, "could not download %s of %s", name, r.Tag)
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
	f := cli.Fail("the release lists asset %s at %s, outside %s — not fetched", a.Name, host, c.API)
	if c.Token != "" {
		f.Lines[0] += ", the token is not sent there"
	}
	return f
}

func (c *Client) request(url, accept string) (*http.Response, error) {
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", accept)
	if c.Token != "" {
		req.Header.Set("Authorization", "Bearer "+c.Token)
	}
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		resp.Body.Close()
		return nil, c.refusal(url, resp)
	}
	return resp, nil
}

// httpError is an API refusal; hint, when set, is the remedy line.
type httpError struct{ msg, hint string }

func (e *httpError) Error() string { return e.msg }

// failed is a failure whose first line wraps err, its remedy on the next.
func failed(err error, format string, args ...any) error {
	f := cli.Fail(format+": %v", append(args, err)...)
	var h *httpError
	if errors.As(err, &h) && h.hint != "" {
		f.Cont(h.hint)
	}
	return f
}

const tokenHint = "set GITHUB_TOKEN, or run `gh auth login` — kasbah then uses `gh auth token`"

// refusal says why the API answered url with resp's non-200 status.
func (c *Client) refusal(url string, resp *http.Response) error {
	e := &httpError{msg: url + ": " + resp.Status}
	code := resp.StatusCode
	throttled := code == http.StatusForbidden || code == http.StatusTooManyRequests
	switch {
	case throttled && resp.Header.Get("Retry-After") != "":
		e.msg += " — GitHub asks to wait " + resp.Header.Get("Retry-After") + " second(s) before retrying (a secondary rate limit)"
		e.hint = "retry after that wait"
		if c.Token == "" {
			e.hint += "; a token gets higher limits: " + tokenHint
		}
	case throttled && resp.Header.Get("X-RateLimit-Remaining") == "0":
		e.msg += " — GitHub's API rate limit is used up"
		if n, err := strconv.ParseInt(resp.Header.Get("X-RateLimit-Reset"), 10, 64); err == nil {
			e.msg += ", until " + time.Unix(n, 0).UTC().Format("2006-01-02 15:04:05 UTC")
		}
		e.hint = "anonymous requests get 60 an hour: " + tokenHint
		if c.Token != "" {
			e.hint = "the token's own limit is used up: wait, or set GITHUB_TOKEN to another token"
		}
	case code == http.StatusTooManyRequests:
		e.msg += " — GitHub is throttling requests"
		e.hint = "retry later"
		if c.Token == "" {
			e.hint += "; a token gets a higher limit: " + tokenHint
		}
	case code == http.StatusNotFound && c.Token == "":
		e.msg += " — nothing there without a token; the repository " + Repo + " may be private"
		e.hint = tokenHint
	case code == http.StatusNotFound:
		e.msg += " — no such release, or the token cannot see " + Repo
	case code == http.StatusUnauthorized && c.TokenFrom == "gh":
		e.msg += " — GitHub refused the token `gh auth token` printed"
		e.hint = "run `gh auth login` again; a public repository needs no token"
	case code == http.StatusUnauthorized:
		e.msg += " — GitHub refused the token in GITHUB_TOKEN"
		e.hint = "set GITHUB_TOKEN to a valid token, or unset it; a public repository needs no token"
	}
	return e
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
		return failed(err, "could not download %s of %s", name, r.Tag)
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
