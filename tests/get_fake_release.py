"""A fake GitHub release host for tests/get_test.sh.

Usage: python3 -I get_fake_release.py ROOT — binds servers on 127.0.0.1,
prints "<host port> <storage port> <tls port or 0> <pid>", and leaves a child
serving. The TLS server (when ROOT/tls.pem, key and certificate, exists) is the
host again over https, with that self-signed certificate.

The host serves
  /download/v<ver>/<asset>                          bare downloads (404 when ROOT/private exists)
  /api/repos/adigourdi/kasbah/releases/tags/v<ver>  release JSON (needs the token in ROOT/token)
  /api/repos/adigourdi/kasbah/releases/assets/<id>  302 to its own /blob/<tag>/<asset>, same
                                                    host and port (token needed)
from ROOT/releases/v<ver>/<asset>. ROOT/json is "compact" (slashes escaped) or
"pretty" (other key order); either way each asset holds an "uploader" object
with the asset's name and an asset-shaped url that 404s. ROOT/outside lists the
asset URLs on the storage server, which only logs and 404s; ROOT/nolocation
answers the asset 302 without a Location. Every request is appended to
ROOT/requests.log: "<host|storage|tls> <path> auth=<Authorization> accept=<Accept>".
"""

import http.server
import json
import os
import sys
import threading

root = sys.argv[1]
repo = "/api/repos/adigourdi/kasbah/releases"
lock = threading.Lock()
ids = {}  # asset id -> (tag, name)
keys = {}  # tag/name -> asset id


def flag(name):
    return os.path.exists(os.path.join(root, name))


def read(name):
    try:
        with open(os.path.join(root, name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return ""


class Handler(http.server.BaseHTTPRequestHandler):
    role = ""
    protocol_version = "HTTP/1.0"

    def log_message(self, *args):
        pass

    def record(self):
        with lock, open(os.path.join(root, "requests.log"), "a") as f:
            f.write("%s %s auth=%s accept=%s\n" % (
                self.role, self.path,
                self.headers.get("Authorization", "-"), self.headers.get("Accept", "-")))

    def send(self, code, body=b"", ctype="application/octet-stream", location=None):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        if location:
            self.send_header("Location", location)
        self.end_headers()
        self.wfile.write(body)

    def asset(self, tag, name):
        p = os.path.join(root, "releases", tag, name)
        if "/" in tag or "/" in name or not os.path.isfile(p):
            return None
        with open(p, "rb") as f:
            return f.read()

    def authed(self):
        tok = read("token")
        return tok != "" and self.headers.get("Authorization") == "Bearer " + tok


class Host(Handler):
    role = "host"

    def do_GET(self):
        self.record()
        parts = self.path.split("/")
        if self.path.startswith("/download/") and len(parts) == 4:
            body = None if flag("private") else self.asset(parts[2], parts[3])
            return self.send(404, b"Not Found") if body is None else self.send(200, body)
        if self.path.startswith(repo + "/tags/"):
            tag = self.path[len(repo + "/tags/"):]
            d = os.path.join(root, "releases", tag)
            if not self.authed() or "/" in tag or not os.path.isdir(d):
                return self.send(404, b'{"message":"Not Found"}', "application/json")
            return self.send(200, self.release(tag, sorted(os.listdir(d))), "application/json")
        if self.path.startswith(repo + "/assets/"):
            key = self.path[len(repo + "/assets/"):]
            if not self.authed() or key not in ids:
                return self.send(404, b'{"message":"Not Found"}', "application/json")
            if self.headers.get("Accept") != "application/octet-stream":
                return self.send(415, b"wants application/octet-stream")
            tag, name = ids[key]
            if flag("nolocation"):
                return self.send(302)
            return self.send(302, location="http://127.0.0.1:%d/blob/%s/%s" % (host_port, tag, name))
        if self.path.startswith("/blob/") and len(parts) == 4:
            body = self.asset(parts[2], parts[3])
            return self.send(404, b"Not Found") if body is None else self.send(200, body)
        self.send(404, b"Not Found")

    def release(self, tag, names):
        api = "http://127.0.0.1:%d/api" % host_port
        ours = api + "/repos/adigourdi/kasbah/releases/assets"
        base = "http://127.0.0.1:%d/repos/adigourdi/kasbah/releases/assets" % storage_port if flag("outside") else ours
        assets = []
        for name in names:
            with lock:
                key = keys.setdefault(tag + "/" + name, str(len(keys) + 100))
                ids[key] = (tag, name)
            uploader = {"login": "x", "name": name, "url": ours + "/9" + key}
            if read("json") == "pretty":
                assets.append({"name": name, "uploader": uploader, "id": int(key), "label": None,
                               "url": base + "/" + key, "size": 1})
            else:
                assets.append({"url": base + "/" + key, "id": int(key), "name": name,
                               "label": None, "uploader": uploader, "size": 1})
        rel = {"url": api + "/repos/adigourdi/kasbah/releases/1", "name": tag, "tag_name": tag,
               "body": 'notes with "quotes", {braces} and [brackets] \\ ', "assets": assets}
        if read("json") == "pretty":
            return json.dumps(rel, indent=2).encode()
        return json.dumps(rel, separators=(",", ":")).replace("/", "\\/").encode()


class Storage(Handler):
    role = "storage"

    def do_GET(self):
        self.record()
        self.send(404, b"Not Found")


class TLS(Host):
    role = "tls"


host = http.server.HTTPServer(("127.0.0.1", 0), Host)
storage = http.server.HTTPServer(("127.0.0.1", 0), Storage)
host_port, storage_port = host.server_address[1], storage.server_address[1]
servers, tls_port = [storage], 0
if flag("tls.pem"):
    import ssl
    tls = http.server.HTTPServer(("127.0.0.1", 0), TLS)
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(os.path.join(root, "tls.pem"))
    tls.socket = ctx.wrap_socket(tls.socket, server_side=True)
    servers.append(tls)
    tls_port = tls.server_address[1]

pid = os.fork()
if pid:
    print(host_port, storage_port, tls_port, pid, flush=True)
    os._exit(0)
os.setsid()
null = os.open(os.devnull, os.O_RDWR)
for fd in (0, 1, 2):
    os.dup2(null, fd)
for srv in servers:
    threading.Thread(target=srv.serve_forever, daemon=True).start()
host.serve_forever()
