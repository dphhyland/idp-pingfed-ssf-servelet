#!/usr/bin/env python3
"""Minimal SSF demo UI server: serves index.html and proxies the SSF API to PingFederate,
injecting the receiver credentials server-side (the browser never sees secrets).

Env:
  PF_INTERNAL   PF base the proxy calls (default https://pingfederate:9031 — compose network)
  ISSUER        the transmitter issuer (must equal OIDF_SSF_ISSUER; used for id_token_hint minting)
  CLIENT_ID / CLIENT_SECRET   the ssf.manage receiver client (default ssf-receiver / ssf-demo-secret-123)
  PUSH_TOKEN    bearer for the loopback receiver endpoint (default loopback-push-token-456)
  PORT          listen port (default 8080)
"""
import base64
import json
import os
import socket
import ssl
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PF = os.environ.get("PF_INTERNAL", "https://pingfederate:9031").rstrip("/")
ISSUER = os.environ.get("ISSUER", "https://localhost:19031").rstrip("/")
CLIENT_ID = os.environ.get("CLIENT_ID", "ssf-receiver")
CLIENT_SECRET = os.environ.get("CLIENT_SECRET", "ssf-demo-secret-123")
PUSH_TOKEN = os.environ.get("PUSH_TOKEN", "loopback-push-token-456")
PORT = int(os.environ.get("PORT", "8080"))

CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE  # demo PF serves a self-signed cert


def pf(method, path, body=None, bearer=None, content_type="application/json"):
    req = urllib.request.Request(PF + path, method=method)
    if bearer:
        req.add_header("Authorization", "Bearer " + bearer)
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        req.add_header("Content-Type", content_type)
    try:
        with urllib.request.urlopen(req, data=data, context=CTX, timeout=15) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except Exception as e:  # noqa: BLE001 - surface any transport error to the UI
        return 502, json.dumps({"error": "proxy_error", "detail": str(e)}).encode()


def token():
    basic = base64.b64encode(f"{CLIENT_ID}:{CLIENT_SECRET}".encode()).decode()
    req = urllib.request.Request(PF + "/as/token.oauth2", method="POST",
                                 data=b"grant_type=client_credentials&scope=ssf.manage")
    req.add_header("Authorization", "Basic " + basic)
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, context=CTX, timeout=15) as r:
        return json.loads(r.read()).get("access_token")


def unsigned_id_token(sub):
    b64 = lambda o: base64.urlsafe_b64encode(json.dumps(o).encode()).rstrip(b"=").decode()  # noqa: E731
    return b64({"alg": "none"}) + "." + b64({"iss": ISSUER, "sub": sub}) + "."


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload, ctype="application/json"):
        body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}") if n else {}

    def do_GET(self):  # noqa: N802
        if self.path in ("/", "/index.html"):
            with open(os.path.join(os.path.dirname(__file__), "index.html"), "rb") as f:
                self._send(200, f.read(), "text/html; charset=utf-8")
        elif self.path == "/api/config":
            self._send(200, {"issuer": ISSUER, "pf": PF})
        elif self.path == "/api/metadata":
            self._send(*pf("GET", "/.well-known/ssf-configuration"))
        elif self.path == "/api/streams":
            self._send(*pf("GET", "/ssf/streams", bearer=token()))
        elif self.path == "/api/received":
            self._send(*pf("GET", "/ssf/receiver/events", bearer=PUSH_TOKEN))
        else:
            self._send(404, {"error": "not_found"})

    def do_POST(self):  # noqa: N802
        b = self._body()
        if self.path == "/api/streams":
            self._send(*pf("POST", "/ssf/streams", body=b, bearer=token()))
        elif self.path == "/api/subjects":
            self._send(*pf("POST", "/ssf/subjects:add", body=b, bearer=token()))
        elif self.path == "/api/scim":
            self._send(*pf("POST", "/ssf/scim/v2/Users", body=b, bearer=token()))
        elif self.path == "/api/verify":
            self._send(*pf("POST", "/ssf/verify", body=b, bearer=token()))
        elif self.path == "/api/poll":
            sid = b.pop("stream_id", "")
            self._send(*pf("POST", f"/ssf/poll?stream_id={sid}", body=b, bearer=token()))
        elif self.path == "/api/logout":
            idt = unsigned_id_token(b.get("sub", "bob"))
            self._send(*pf("GET", f"/idp/init_logout.openid?id_token_hint={idt}"))
        elif self.path == "/api/delete-stream":
            self._send(*pf("DELETE", f"/ssf/streams?stream_id={b.get('stream_id','')}", bearer=token()))
        else:
            self._send(404, {"error": "not_found"})

    def log_message(self, fmt, *args):  # quiet
        pass


class DualStackServer(ThreadingHTTPServer):
    address_family = socket.AF_INET6

    def server_bind(self):
        self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 0)  # Railway edge needs dual-stack
        super().server_bind()


if __name__ == "__main__":
    print(f"SSF demo UI on :{PORT} -> {PF} (issuer {ISSUER})")
    DualStackServer(("::", PORT), Handler).serve_forever()
