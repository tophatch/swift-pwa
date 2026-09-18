#!/usr/bin/env python3
"""A stand-in OAuth 2.0 authorization server, for verifying `auth.*` for real.

Not a mock of swift-pwa's own code — it is the *other side* of the protocol, so
what it checks is what a real provider would check: that the authorization
request carries the parameters RFC 6749 and RFC 7636 require, and that the code
verifier presented at the token endpoint actually hashes to the challenge sent
at the start. A test double inside the process could not catch a challenge that
is well-formed and wrong.

Endpoints:
  GET  /control        records a hit; the proof that this box can open a browser
                       at all, so "the consent page never loaded" can be told
                       apart from "there is no browser here"
  GET  /authorize      records the query and renders a consent page
  POST /token          verifies code + PKCE, returns tokens
  GET  /recorded       what it has seen, as JSON, for the driving script
"""

import base64
import hashlib
import json
import secrets
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlparse

STATE = {"control": 0, "authorize": [], "token": [], "issued": []}
LOCK = threading.Lock()


def page(title, body):
    return f"<!doctype html><meta charset=utf-8><title>{title}</title><h1>{title}</h1><p>{body}</p>".encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *_args):
        pass  # the driving script reads /recorded, not our stderr

    def _send(self, status, body, content_type="text/html; charset=utf-8"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        url = urlparse(self.path)
        query = {k: v[0] for k, v in parse_qs(url.query).items()}

        if url.path == "/control":
            with LOCK:
                STATE["control"] += 1
            self._send(200, page("Control", "The app can open a browser."))
        elif url.path == "/authorize":
            with LOCK:
                STATE["authorize"].append(query)
            # `auto_redirect=1` makes this answer with a real 302 to the
            # redirect_uri, consent presumed. The desktop and Android scripts
            # don't use it: there the redirect is delivered directly (a curl to
            # the loopback port, an ACTION_VIEW intent), which is closer to what
            # the OS really does on those platforms. On iOS it has to travel
            # through ASWebAuthenticationSession's *own* navigation — the
            # session is what catches the callback — so the far side has to
            # actually redirect, and a human tapping Allow can't be scripted.
            if query.get("auto_redirect"):
                code = "probe-code-" + secrets.token_hex(4)
                with LOCK:
                    STATE["issued"].append(code)
                target = "%s?code=%s&state=%s" % (
                    query.get("redirect_uri", ""), quote(code, safe=""), quote(query.get("state", ""), safe=""))
                body = page("Redirecting", "Returning to the app.")
                self.send_response(302)
                self.send_header("Location", target)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)
                return
            self._send(200, page("Consent", "Pretend you pressed Allow."))
        elif url.path == "/recorded":
            with LOCK:
                body = json.dumps(STATE).encode()
            self._send(200, body, "application/json")
        else:
            self._send(404, page("Not found", self.path))

    def do_POST(self):
        url = urlparse(self.path)
        if url.path != "/token":
            self._send(404, page("Not found", self.path))
            return
        length = int(self.headers.get("Content-Length", "0"))
        form = {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode()).items()}
        with LOCK:
            STATE["token"].append(form)
            # One flow at a time, so the challenge to check against is the one
            # from the most recent authorization request.
            recent = STATE["authorize"][-1] if STATE["authorize"] else None
            challenge = (recent or {}).get("code_challenge")

        # The real check, and the reason this is a separate process rather than
        # a test double: does the verifier the app presents hash to the
        # challenge it sent at the start? A challenge can be well-formed and
        # wrong, and only the other side of the protocol notices.
        digest = hashlib.sha256(form.get("code_verifier", "").encode("ascii")).digest()
        computed = base64.urlsafe_b64encode(digest).decode().rstrip("=")
        if challenge is None:
            self._send(400, json.dumps({"error": "invalid_grant",
                                        "error_description": "no authorization request to match"}).encode(),
                       "application/json")
        elif computed != challenge:
            self._send(400, json.dumps({"error": "invalid_grant",
                                        "error_description": "PKCE verifier does not match the challenge"}).encode(),
                       "application/json")
        else:
            self._send(200, json.dumps({
                "access_token": "verified-access-token",
                "refresh_token": "verified-refresh-token",
                "expires_in": 3599,
                "token_type": "Bearer",
            }).encode(), "application/json")


def main():
    # `<port> [host]`. The host matters for the iOS run: a cabled device has no
    # `adb reverse` equivalent, so it reaches the provider over the LAN and the
    # socket has to be bound somewhere other than 127.0.0.1. Everything else
    # binds loopback, which is where a bind belongs by default.
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    host = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    server = ThreadingHTTPServer((host, port), Handler)
    print(f"provider listening port={server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
