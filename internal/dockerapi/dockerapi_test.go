package dockerapi

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type seen struct {
	method, path, query string
	body                map[string]any
}

// fake is a daemon on a unix socket answering by handler, recording calls.
func fake(t *testing.T, apiVersion string, h func(w http.ResponseWriter, r *http.Request)) (*Client, *[]seen) {
	return fakeMin(t, apiVersion, "1.24", h)
}

func fakeMin(t *testing.T, apiVersion, minVersion string, h func(w http.ResponseWriter, r *http.Request)) (*Client, *[]seen) {
	t.Helper()
	sock := filepath.Join(t.TempDir(), "d.sock")
	l, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	calls := &[]seen{}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		s := seen{method: r.Method, path: r.URL.Path, query: r.URL.RawQuery}
		if b, _ := io.ReadAll(r.Body); len(b) > 0 {
			json.Unmarshal(b, &s.body)
		}
		mu.Lock()
		*calls = append(*calls, s)
		mu.Unlock()
		if r.URL.Path == "/version" {
			w.Write([]byte(`{"ApiVersion":"` + apiVersion + `","MinAPIVersion":"` + minVersion + `"}`))
			return
		}
		h(w, r)
	})}
	go srv.Serve(l)
	t.Cleanup(func() { srv.Close() })
	return New(sock), calls
}

// The create body carries every field the launcher sets, a private pid
// namespace and no added capability, on the negotiated version.
func TestCreateBodyAndVersion(t *testing.T) {
	c, calls := fake(t, "1.44", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(201)
		w.Write([]byte(`{"Id":"abc","Warnings":[]}`))
	})
	cfg := Config{Image: "restic/restic:0.18.0", Entrypoint: []string{"/host/apps/.kasbah/bin/kasbah"}, Cmd: []string{"remote", "backup"},
		Env: []string{}, Labels: map[string]string{"kasbah.backup.launcher": "1"},
		HostConfig: HostConfig{Binds: []string{"/:/host"}, NetworkMode: "host", Init: true,
			LogConfig: &LogConfig{Type: "json-file", Config: map[string]string{"max-size": "10m", "max-file": "3"}}}}
	id, err := c.Create(context.Background(), "kasbah-backup-launcher", cfg)
	if err != nil || id != "abc" {
		t.Fatal(id, err)
	}
	got := (*calls)[1]
	if got.method != "POST" || got.path != "/v1.44/containers/create" || got.query != "name=kasbah-backup-launcher" {
		t.Errorf("%+v", got)
	}
	hc := got.body["HostConfig"].(map[string]any)
	if b := hc["Binds"].([]any); len(b) != 1 || b[0] != "/:/host" || hc["NetworkMode"] != "host" || hc["Init"] != true ||
		hc["Privileged"] != false || hc["AutoRemove"] != false {
		t.Errorf("host config %v", hc)
	}
	if lc := hc["LogConfig"].(map[string]any); lc["Type"] != "json-file" || lc["Config"].(map[string]any)["max-size"] != "10m" {
		t.Errorf("log config %v", lc)
	}
	if _, ok := hc["PidMode"]; ok {
		t.Errorf("a pid mode was sent: %v", hc)
	}
	if _, ok := hc["CapAdd"]; ok {
		t.Errorf("capabilities were added: %v", hc)
	}
	if got.body["Image"] != "restic/restic:0.18.0" || got.body["Labels"].(map[string]any)["kasbah.backup.launcher"] != "1" {
		t.Errorf("%v", got.body)
	}
	// A daemon newer than this client is spoken to in MaxVersion.
	c2, calls2 := fake(t, "1.52", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	if err := c2.Start(context.Background(), "abc"); err != nil || (*calls2)[1].path != "/v"+MaxVersion+"/containers/abc/start" {
		t.Errorf("%v %+v", err, *calls2)
	}
	// One whose minimum is past MaxVersion is spoken to in its minimum.
	c3, calls3 := fakeMin(t, "1.60", "1.50", func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(204) })
	if err := c3.Start(context.Background(), "abc"); err != nil || (*calls3)[1].path != "/v1.50/containers/abc/start" {
		t.Errorf("%v %+v", err, *calls3)
	}
}

func TestWaitStopRemoveList(t *testing.T) {
	c, calls := fake(t, "1.41", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasSuffix(r.URL.Path, "/wait"):
			w.Write([]byte(`{"StatusCode":3}`))
		case strings.HasSuffix(r.URL.Path, "/stop"):
			w.WriteHeader(304)
		case r.Method == "DELETE":
			w.WriteHeader(204)
		case strings.HasSuffix(r.URL.Path, "/containers/json"):
			w.Write([]byte(`[{"Id":"x1","Names":["/kasbah-backup-launcher"],"State":"running","Created":1700000000}]`))
		case strings.HasSuffix(r.URL.Path, "/containers/gone/start"):
			w.WriteHeader(404)
			w.Write([]byte(`{"message":"No such container: gone"}`))
		}
	})
	ctx := context.Background()
	if code, err := c.Wait(ctx, "abc"); err != nil || code != 3 {
		t.Errorf("wait: %d %v", code, err)
	}
	if err := c.Stop(ctx, "abc", 10*time.Second); err != nil {
		t.Errorf("stop of a stopped one: %v", err)
	}
	if err := c.Remove(ctx, "abc"); err != nil {
		t.Errorf("remove: %v", err)
	}
	l, err := c.List(ctx, "kasbah.backup.launcher")
	if err != nil || len(l) != 1 || l[0].Id != "x1" || l[0].State != "running" || l[0].Created != 1700000000 {
		t.Errorf("list: %+v %v", l, err)
	}
	err = c.Start(ctx, "gone")
	if !IsNotFound(err) || !strings.Contains(err.Error(), "No such container: gone") {
		t.Errorf("start of a missing one: %v", err)
	}
	want := []string{
		"POST /v1.41/containers/abc/wait condition=not-running",
		"POST /v1.41/containers/abc/stop t=10",
		"DELETE /v1.41/containers/abc force=1&v=1",
		`GET /v1.41/containers/json all=1&filters=%7B%22label%22%3A%5B%22kasbah.backup.launcher%22%5D%7D`,
	}
	for i, w := range want {
		s := (*calls)[i+1]
		if got := s.method + " " + s.path + " " + s.query; got != w {
			t.Errorf("call %d: %s, want %s", i, got, w)
		}
	}
}

// A wait the context ends returns at once with the context's error.
func TestWaitBoundedByContext(t *testing.T) {
	c, _ := fake(t, "1.44", func(w http.ResponseWriter, r *http.Request) { <-r.Context().Done() })
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	start := time.Now()
	if _, err := c.Wait(ctx, "abc"); err == nil || time.Since(start) > 5*time.Second {
		t.Errorf("%v after %v", err, time.Since(start))
	}
}

func frame(stream byte, s string) []byte {
	h := make([]byte, 8)
	h[0] = stream
	binary.BigEndian.PutUint32(h[4:], uint32(len(s)))
	return append(h, s...)
}

// Only stdout is asked for without a stderr cap, and each stream keeps its
// own tail.
func TestLogsDemux(t *testing.T) {
	body := append(append(frame(1, "project a ok\n"), frame(2, "hook said\n")...), frame(1, "project b failed x\n")...)
	var asked []string
	c, _ := fake(t, "1.44", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		asked = append(asked, q.Get("stdout")+"/"+q.Get("stderr"))
		if q.Get("stdout") != "1" {
			w.WriteHeader(400)
		}
		w.Write(body)
	})
	o, err := c.Logs(context.Background(), "abc", 1<<20, 0)
	if err != nil || o.StdoutCut || o.StderrCut || string(o.Stdout) != "project a ok\nproject b failed x\n" || len(o.Stderr) != 0 {
		t.Errorf("%+v %v", o, err)
	}
	o, err = c.Logs(context.Background(), "abc", 20, 4)
	want := "ok\nproject b failed x\n"[len("ok\nproject b failed x\n")-20:]
	if err != nil || !o.StdoutCut || string(o.Stdout) != want || !o.StderrCut || string(o.Stderr) != "aid\n" {
		t.Errorf("tails: %+v %v", o, err)
	}
	o, _ = c.Logs(context.Background(), "abc", 1<<20, 64)
	if o.StderrCut || string(o.Stderr) != "hook said\n" {
		t.Errorf("stderr whole: %+v", o)
	}
	if strings.Join(asked, ",") != "1/,1/1,1/1" {
		t.Errorf("asked %v", asked)
	}
	var x, y bytes.Buffer
	if err := Demux(bytes.NewReader(frame(1, "cut")[:9]), &x, &y); err == nil {
		t.Error("a truncated frame read as whole")
	}
}

func TestTail(t *testing.T) {
	tl := &Tail{Max: 5}
	for _, s := range []string{"ab", "cd", "efgh", "i"} {
		tl.Write([]byte(s))
	}
	if b := tl.Bytes(); string(b) != "efghi" || !tl.Cut {
		t.Errorf("%q %v", tl.Bytes(), tl.Cut)
	}
	if tl := (&Tail{Max: 5}); tl.Cut || len(tl.Bytes()) != 0 {
		t.Error("an empty tail")
	}
}

// No socket is an error naming it, not a hang.
func TestNoSocket(t *testing.T) {
	c := New(filepath.Join(t.TempDir(), "absent.sock"))
	if _, err := c.List(context.Background(), "x"); err == nil || !strings.Contains(err.Error(), "absent.sock") {
		t.Errorf("%v", err)
	}
}
