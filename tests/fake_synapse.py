#!/usr/bin/env python3
"""A fake Synapse, enough of one to prove the provisioner still speaks it.

Three properties this defends, none of which a static read of the script can
establish:

  1. the HMAC-SHA1 over nonce\\0user\\0pass\\0admin is still computed over
     exactly those bytes after the password moved out of argv and into a file,
  2. a passwordFile carrying a trailing newline produces the same MAC and the
     same login as one without, because $( ) stripped it before and must
     still strip it now,
  3. no argument to any child process carried the secret, the password or the
     access token, asserted from /proc/<pid>/cmdline of every descendant
     while the script runs.
"""

import hashlib
import hmac
import json
import os
import pathlib
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

SECRET = pathlib.Path(os.environ["FAKE_SECRET_FILE"]).read_bytes().strip()
EXPECT_PASSWORD = os.environ["FAKE_EXPECT_PASSWORD"]
TOKEN = "syt_fake_access_token_aaaaaaaaaaaa"
NONCE = "fixednonce123456"

seen = {"register": None, "login": None, "displayname": None, "joins": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n) or b"{}")

    def do_GET(self):
        if self.path == "/_matrix/client/versions":
            return self._send(200, {"versions": ["v1.11"]})
        if self.path == "/_synapse/admin/v1/register":
            return self._send(200, {"nonce": NONCE})
        if self.path == "/_matrix/client/v3/account/whoami":
            if self.headers.get("Authorization") == f"Bearer {TOKEN}":
                return self._send(200, {"user_id": "@echo:test"})
            return self._send(401, {"errcode": "M_UNKNOWN_TOKEN"})
        return self._send(404, {"errcode": "M_NOT_FOUND"})

    def do_POST(self):
        if self.path == "/_synapse/admin/v1/register":
            b = self._body()
            want = hmac.new(
                SECRET,
                b"\0".join(
                    [
                        b["nonce"].encode(),
                        b["username"].encode(),
                        b["password"].encode(),
                        b"admin" if b["admin"] else b"notadmin",
                    ]
                ),
                hashlib.sha1,
            ).hexdigest()
            seen["register"] = {
                "mac_ok": hmac.compare_digest(want, b["mac"]),
                "password_ok": b["password"] == EXPECT_PASSWORD,
                "username": b["username"],
            }
            if not seen["register"]["mac_ok"]:
                return self._send(403, {"errcode": "M_FORBIDDEN", "error": "bad mac"})
            return self._send(200, {"access_token": TOKEN, "user_id": "@echo:test"})
        if self.path == "/_matrix/client/v3/login":
            b = self._body()
            seen["login"] = {"password_ok": b["password"] == EXPECT_PASSWORD}
            if not seen["login"]["password_ok"]:
                return self._send(403, {"errcode": "M_FORBIDDEN"})
            return self._send(200, {"access_token": TOKEN})
        if self.path.startswith("/_matrix/client/v3/join/"):
            if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                return self._send(401, {"errcode": "M_UNKNOWN_TOKEN"})
            seen["joins"].append(self.path.rsplit("/", 1)[-1])
            return self._send(200, {"room_id": "!fake:test"})
        return self._send(404, {"errcode": "M_NOT_FOUND"})

    def do_PUT(self):
        if "/displayname" in self.path:
            if self.headers.get("Authorization") != f"Bearer {TOKEN}":
                return self._send(401, {"errcode": "M_UNKNOWN_TOKEN"})
            seen["displayname"] = self._body().get("displayname")
            return self._send(200, {})
        return self._send(404, {"errcode": "M_NOT_FOUND"})


def main():
    port = int(sys.argv[1])
    out = sys.argv[2]
    srv = HTTPServer(("127.0.0.1", port), Handler)
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    # The caller runs the provisioner, then signals by removing the flag file.
    flag = pathlib.Path(out + ".running")
    flag.write_text("1")
    while flag.exists():
        time.sleep(0.05)
    srv.shutdown()
    pathlib.Path(out).write_text(json.dumps(seen))


if __name__ == "__main__":
    main()
