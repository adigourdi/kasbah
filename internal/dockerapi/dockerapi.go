// Package dockerapi is the few Docker Engine API calls the backup scheduler
// makes over the daemon's unix socket: the restic image carries no docker CLI.
package dockerapi

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Socket is the daemon's socket, where the scheduler's compose file mounts it.
const Socket = "/var/run/docker.sock"

// MaxVersion is the newest API version this client speaks; a daemon that
// speaks less is spoken to in its own.
const MaxVersion = "1.47"

// Client is one daemon. Version is negotiated on the first call.
type Client struct {
	http    *http.Client
	Version string
}

// New is a client over the unix socket at sock.
func New(sock string) *Client {
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		var d net.Dialer
		return d.DialContext(ctx, "unix", sock)
	}}
	return &Client{http: &http.Client{Transport: tr}}
}

// Error is a daemon's refusal: its status and message.
type Error struct {
	Status  int
	Message string
}

func (e *Error) Error() string { return fmt.Sprintf("%s (HTTP %d)", e.Message, e.Status) }

// IsNotFound is whether err is the daemon saying "no such" container or image.
func IsNotFound(err error) bool {
	var e *Error
	return errors.As(err, &e) && e.Status == http.StatusNotFound
}

// newer is whether API version a is newer than b ("1.44" > "1.9").
func newer(a, b string) bool {
	am, an, _ := strings.Cut(a, ".")
	bm, bn, _ := strings.Cut(b, ".")
	x, _ := strconv.Atoi(am)
	y, _ := strconv.Atoi(bm)
	if x != y {
		return x > y
	}
	x, _ = strconv.Atoi(an)
	y, _ = strconv.Atoi(bn)
	return x > y
}

// negotiate settles Version: the daemon's own, capped at MaxVersion and
// raised to its minimum — every field sent here predates both.
func (c *Client) negotiate(ctx context.Context) error {
	if c.Version != "" {
		return nil
	}
	var v struct{ ApiVersion, MinAPIVersion string }
	if err := c.call(ctx, "GET", "/version", nil, nil, &v, false); err != nil {
		return err
	}
	c.Version = MaxVersion
	if v.ApiVersion != "" && newer(MaxVersion, v.ApiVersion) {
		c.Version = v.ApiVersion
	}
	if v.MinAPIVersion != "" && newer(v.MinAPIVersion, c.Version) {
		c.Version = v.MinAPIVersion
	}
	return nil
}

func (c *Client) do(ctx context.Context, method, path string, q url.Values, body any) (*http.Response, error) {
	if err := c.negotiate(ctx); err != nil {
		return nil, err
	}
	return c.raw(ctx, method, "/v"+c.Version+path, q, body)
}

func (c *Client) raw(ctx context.Context, method, path string, q url.Values, body any) (*http.Response, error) {
	var rd io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rd = bytes.NewReader(b)
	}
	u := "http://docker" + path
	if len(q) > 0 {
		u += "?" + q.Encode()
	}
	req, err := http.NewRequestWithContext(ctx, method, u, rd)
	if err != nil {
		return nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	resp, err := c.http.Do(req)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 300 && resp.StatusCode != http.StatusNotModified {
		defer resp.Body.Close()
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		var m struct{ Message string }
		if json.Unmarshal(b, &m) != nil || m.Message == "" {
			m.Message = strings.TrimSpace(string(b))
		}
		return nil, &Error{Status: resp.StatusCode, Message: m.Message}
	}
	return resp, nil
}

// call is one request whose answer, if out is non-nil, is JSON.
func (c *Client) call(ctx context.Context, method, path string, q url.Values, body, out any, versioned bool) error {
	var resp *http.Response
	var err error
	if versioned {
		resp, err = c.do(ctx, method, path, q, body)
	} else {
		resp, err = c.raw(ctx, method, path, q, body)
	}
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if out == nil {
		io.Copy(io.Discard, resp.Body)
		return nil
	}
	return json.NewDecoder(resp.Body).Decode(out)
}

// HostConfig is the part of a container's host config the launcher sets.
type HostConfig struct {
	Binds       []string
	NetworkMode string
	// PidMode "" is a private pid namespace.
	PidMode    string `json:",omitempty"`
	Init       bool
	Privileged bool
	AutoRemove bool
	LogConfig  *LogConfig `json:",omitempty"`
}

// LogConfig is a container's log driver and its options.
type LogConfig struct {
	Type   string
	Config map[string]string
}

// Config is a container to create.
type Config struct {
	Image      string
	Entrypoint []string
	Cmd        []string
	Env        []string
	Labels     map[string]string
	HostConfig HostConfig
}

// Create makes a container, named when name is not "": its id.
func (c *Client) Create(ctx context.Context, name string, cfg Config) (string, error) {
	q := url.Values{}
	if name != "" {
		q.Set("name", name)
	}
	var out struct{ Id string }
	if err := c.call(ctx, "POST", "/containers/create", q, cfg, &out, true); err != nil {
		return "", err
	}
	if out.Id == "" {
		return "", errors.New("the daemon created a container and named no id")
	}
	return out.Id, nil
}

// Start starts a created container.
func (c *Client) Start(ctx context.Context, id string) error {
	return c.call(ctx, "POST", "/containers/"+url.PathEscape(id)+"/start", nil, nil, nil, true)
}

// Wait blocks until the container is not running, or ctx ends: its exit code.
func (c *Client) Wait(ctx context.Context, id string) (int, error) {
	var out struct {
		StatusCode int
		Error      *struct{ Message string }
	}
	q := url.Values{"condition": {"not-running"}}
	if err := c.call(ctx, "POST", "/containers/"+url.PathEscape(id)+"/wait", q, nil, &out, true); err != nil {
		return -1, err
	}
	if out.Error != nil && out.Error.Message != "" {
		return out.StatusCode, errors.New(out.Error.Message)
	}
	return out.StatusCode, nil
}

// Stop sends the stop signal, and SIGKILL after grace; a stopped one is fine.
func (c *Client) Stop(ctx context.Context, id string, grace time.Duration) error {
	q := url.Values{"t": {strconv.Itoa(int(grace / time.Second))}}
	return c.call(ctx, "POST", "/containers/"+url.PathEscape(id)+"/stop", q, nil, nil, true)
}

// Remove removes a container, running or not, with its anonymous volumes.
func (c *Client) Remove(ctx context.Context, id string) error {
	q := url.Values{"force": {"1"}, "v": {"1"}}
	return c.call(ctx, "DELETE", "/containers/"+url.PathEscape(id), q, nil, nil, true)
}

// Container is a listed container; Created is a unix time.
type Container struct {
	Id      string
	Names   []string
	State   string
	Created int64
}

// List is every container, running or not, carrying label (KEY or KEY=VALUE).
func (c *Client) List(ctx context.Context, label string) ([]Container, error) {
	f, _ := json.Marshal(map[string][]string{"label": {label}})
	q := url.Values{"all": {"1"}, "filters": {string(f)}}
	var out []Container
	if err := c.call(ctx, "GET", "/containers/json", q, nil, &out, true); err != nil {
		return nil, err
	}
	return out, nil
}

// Output is a stopped container's log read back: the tails of its stdout
// and stderr, and whether each was cut.
type Output struct {
	Stdout, Stderr       []byte
	StdoutCut, StderrCut bool
}

// Logs is a stopped container's last outMax bytes of stdout and, when errMax
// is not 0, its last errMax bytes of stderr. Without a TTY the daemon sends
// them multiplexed: an 8-byte header per frame.
func (c *Client) Logs(ctx context.Context, id string, outMax, errMax int) (Output, error) {
	q := url.Values{"stdout": {"1"}}
	if errMax > 0 {
		q.Set("stderr", "1")
	}
	resp, err := c.do(ctx, "GET", "/containers/"+url.PathEscape(id)+"/logs", q, nil)
	if err != nil {
		return Output{}, err
	}
	defer resp.Body.Close()
	o, e := &Tail{Max: outMax}, &Tail{Max: errMax}
	var ew io.Writer = io.Discard
	if errMax > 0 {
		ew = e
	}
	err = Demux(resp.Body, o, ew)
	return Output{Stdout: o.Bytes(), Stderr: e.Bytes(), StdoutCut: o.Cut, StderrCut: e.Cut}, err
}

// Tail keeps the last Max bytes written to it; Cut is whether it dropped any.
type Tail struct {
	Max int
	Cut bool
	b   []byte
}

// Write compacts only past twice Max, so a long stream costs linear time.
func (t *Tail) Write(p []byte) (int, error) {
	t.b = append(t.b, p...)
	if len(t.b) > 2*t.Max {
		t.b = append(t.b[:0], t.b[len(t.b)-t.Max:]...)
		t.Cut = true
	}
	return len(p), nil
}

// Bytes is what it kept.
func (t *Tail) Bytes() []byte {
	if over := len(t.b) - t.Max; over > 0 {
		t.b, t.Cut = t.b[over:], true
	}
	return t.b
}

// Demux splits a multiplexed stream: stream 1 to stdout, 2 to stderr.
func Demux(r io.Reader, stdout, stderr io.Writer) error {
	var h [8]byte
	for {
		if _, err := io.ReadFull(r, h[:]); err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		w := stdout
		if h[0] == 2 {
			w = stderr
		}
		if _, err := io.CopyN(w, r, int64(binary.BigEndian.Uint32(h[4:]))); err != nil {
			return err
		}
	}
}
