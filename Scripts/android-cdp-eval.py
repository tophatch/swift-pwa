#!/usr/bin/env python3
"""Evaluate JavaScript in an Android WebView over the Chrome DevTools Protocol.

`swift-pwa drive` can't reach an Android app (the driver socket is on the
device's loopback), so on-device verification goes through the WebView's own
CDP endpoint instead. This wraps the whole dance — find the process, forward
its abstract socket, discover the page target, evaluate — so a verification
run is one command rather than four copy-pasted ones:

    Scripts/android-cdp-eval.py com.example.myapp '1 + 1'
    Scripts/android-cdp-eval.py com.example.myapp \
        "(async()=>JSON.stringify(await __SWIFT_PWA__.invoke('__platform.info')))()"

Several expressions run in order against one connection, which is what you
want when a command's effect is only visible to the next call.

Promises are awaited, so an `invoke` that blocks on native UI blocks here —
pass `--timeout 0` to wait forever, or read a timeout as "a modal dialog is
holding the JS thread", which is itself a useful measurement.

Stdlib only, including the WebSocket framing: this is a test tool, and
`pip install websockets` on the machine running it is a dependency the repo
doesn't otherwise have.
"""

import argparse
import base64
import json
import os
import socket
import struct
import subprocess
import sys
import urllib.request


def adb(*args, serial=None):
    cmd = ["adb"] + (["-s", serial] if serial else []) + list(args)
    out = subprocess.run(cmd, capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"{' '.join(cmd)} failed: {out.stderr.strip() or out.stdout.strip()}")
    return out.stdout.strip()


class WebSocket:
    """The three frames' worth of RFC 6455 this needs, by hand."""

    def __init__(self, host, port, path, timeout):
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.settimeout(timeout if timeout else None)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall(
            f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\n"
            f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
            f"Sec-WebSocket-Version: 13\r\n\r\n".encode()
        )
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            self.buf += self._recv(1)
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        if b"101" not in head.split(b"\r\n")[0]:
            sys.exit(f"websocket upgrade refused: {head.decode(errors='replace')}")

    def _recv(self, n):
        chunk = self.sock.recv(n)
        if not chunk:
            sys.exit("websocket closed by the device")
        return chunk

    def _read(self, n):
        while len(self.buf) < n:
            self.buf += self._recv(max(n - len(self.buf), 4096))
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def send(self, text):
        payload = text.encode()
        header = b"\x81"  # FIN + text
        mask = os.urandom(4)
        if len(payload) < 126:
            header += bytes([0x80 | len(payload)])
        elif len(payload) < 1 << 16:
            header += b"\xfe" + struct.pack(">H", len(payload))
        else:
            header += b"\xff" + struct.pack(">Q", len(payload))
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(header + mask + masked)

    def recv(self):
        while True:
            b0, b1 = self._read(2)
            length = b1 & 0x7F
            if length == 126:
                length = struct.unpack(">H", self._read(2))[0]
            elif length == 127:
                length = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(length)
            opcode = b0 & 0x0F
            if opcode == 0x9:  # ping
                self.sock.sendall(b"\x8a" + bytes([0x80]) + os.urandom(4))
                continue
            if opcode == 0x8:
                sys.exit("websocket closed by the device")
            if opcode in (0x1, 0x2):
                return payload.decode(errors="replace")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("package", help="the app's Android package id")
    ap.add_argument("expressions", nargs="+", help="JavaScript to evaluate, in order")
    ap.add_argument("-s", "--serial", help="adb device serial (default: the only device)")
    ap.add_argument("--port", type=int, default=9222, help="local forward port (default 9222)")
    ap.add_argument(
        "--timeout",
        type=float,
        default=30,
        help="seconds to wait for each result; 0 waits forever (default 30)",
    )
    args = ap.parse_args()

    pid = adb("shell", "pidof", args.package, serial=args.serial).split()
    if not pid:
        sys.exit(f"{args.package} is not running — launch it first")
    # The abstract socket is bound to the process at creation, so the
    # forward is re-established on every run rather than assumed.
    adb("forward", f"tcp:{args.port}",
        f"localabstract:webview_devtools_remote_{pid[0]}", serial=args.serial)

    with urllib.request.urlopen(f"http://localhost:{args.port}/json", timeout=10) as r:
        targets = json.load(r)
    pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
    if not pages:
        sys.exit("no page target — is the WebView loaded?")
    ws_url = pages[0]["webSocketDebuggerUrl"]
    path = ws_url.split(f"localhost:{args.port}", 1)[-1]

    ws = WebSocket("localhost", args.port, path, args.timeout)
    status = 0
    for i, expr in enumerate(args.expressions, start=1):
        ws.send(json.dumps({
            "id": i,
            "method": "Runtime.evaluate",
            "params": {"expression": expr, "awaitPromise": True, "returnByValue": True},
        }))
        try:
            while True:
                message = json.loads(ws.recv())
                if message.get("id") == i:
                    break
        except socket.timeout:
            print(f"TIMEOUT after {args.timeout}s (a modal dialog may be holding the JS thread)")
            status = 1
            continue
        if "error" in message:
            print("ERROR " + json.dumps(message["error"]))
            status = 1
            continue
        result = message.get("result", {})
        if "exceptionDetails" in result:
            print("THREW " + result["exceptionDetails"].get("text", "") + " "
                  + json.dumps(result["exceptionDetails"].get("exception", {}).get("description", "")))
            status = 1
            continue
        value = result.get("result", {})
        print(json.dumps(value.get("value", value)))
    sys.exit(status)


if __name__ == "__main__":
    main()
