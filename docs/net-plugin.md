# The `net.*` plugin — native HTTP from JS

`NetPlugin` exposes a native, **CORS-free** HTTP client to the web app. It's the
cross-platform counterpart to `fetch`, but running on the Swift side of the
bridge — so it isn't bound by the WebView's same-origin / CORS policy, can set
headers a page can't (`Authorization`, custom `User-Agent`), reach LAN
appliances, and talk to third-party APIs that don't send CORS headers.

It's also the transport foundation the **remote AI backends** build on: the same
injected `NetworkClient` that answers `net.*` is what a cloud/local-network
image `AIBackend` uses, so there's one HTTP abstraction and (on Android) one RPC
bridge behind both surfaces.

> **Opt-in.** Arbitrary outbound requests from the native side are powerful, so
> `net.*` is not auto-installed — register it explicitly (like `process.*`).

## Enabling it

Register the plugin with the platform-appropriate `NetworkClient`, exactly the
way `AIPlugin` / `ProcessPlugin` take an injected backend:

```swift
import SwiftPWA
#if os(Android)
    import SwiftPWAAndroid
#endif

func configure(_ ctx: any AppContext) {
    #if os(Android)
        ctx.use(NetPlugin(AndroidNetworkClient()))
    #else
        ctx.use(NetPlugin(URLSessionNetworkClient()))
    #endif
}
```

- **`URLSessionNetworkClient`** (Apple / Linux / Windows) — Foundation
  `URLSession`, system CA store, works with HTTPS and plain HTTP out of the box.
- **`AndroidNetworkClient`** (Android, from `SwiftPWAAndroid`) — routes through
  Android's own HTTP stack via the Kotlin RPC bridge, because swift-corelibs
  `URLSession` on Android has no injectable CA trust store (HTTPS would fail with
  "unable to get local issuer certificate"). See [Android notes](#android-notes).

## JS API

### `net.request` — unary request/response

```js
const res = await __SWIFT_PWA__.invoke('net.request', {
  method: 'POST',                       // default 'GET'
  url: 'https://api.example.com/v1/thing',
  headers: { 'Authorization': 'Bearer …', 'Content-Type': 'application/json' },
  bodyBase64: btoa(JSON.stringify({ hello: 'world' })),   // body rides as base64
  timeoutMs: 30000,                     // default 60000
});
// res: { status, headers: { … }, bodyBase64 }
if (res.status === 200) {
  const text = atob(res.bodyBase64);
}
```

The **body is base64** in both directions so binary payloads survive the JSON
bridge intact. A non-2xx response is returned as a `status` — **not** an error;
only a transport failure (DNS, connection, timeout) rejects with `E_NET`. Read
`res.status` / `res.headers` to decide what a 4xx/5xx means.

### `net.download` — streamed download to a file

For large payloads that shouldn't cross the bridge as base64, `net.download`
writes to a native path and streams progress:

```js
const unsub = __SWIFT_PWA__.subscribe('net.download', {
  url: 'https://example.com/big.bin',
  destPath: '/path/on/device/big.bin',   // a native filesystem path
  headers: { 'Authorization': 'Bearer …' },  // optional
  sha256: 'abcd…',                        // optional; verified on completion
}, (frame) => {
  if (frame.type === 'progress') {
    // frame.bytesDownloaded / frame.totalBytes (totalBytes null if no Content-Length)
  } else if (frame.type === 'done') {
    // frame.path — the written file
  }
});
```

A `sha256` mismatch, a non-2xx status, or an I/O error ends the stream with
`E_NET`. (SHA-256 verification needs a crypto module: available on Apple and
Linux; on a platform without one a requested checksum is a hard error rather
than a silent skip.)

## Swift API — using `NetworkClient` directly

Backends (and any Swift-side code) consume the same transport without going
through JS. Build `NetRequest` with `URL` / `Data` directly:

```swift
let client: any NetworkClient = URLSessionNetworkClient()
let response = try await client.send(NetRequest(
    method: "POST",
    url: URL(string: "https://api.example.com/predict")!,
    headers: ["x-goog-api-key": key],
    body: try JSONEncoder().encode(payload)
))
guard response.isSuccess else { throw … }
let result = try JSONDecoder().decode(Predictions.self, from: response.body)
```

This is exactly how the remote image `AIBackend` providers will call out —
inject the platform `NetworkClient` once, reuse it for the plugin and the AI
tier.

## Android notes

Two pieces of Android plumbing back this plugin; both are handled by
`AndroidNetworkClient` + the bundler, but worth understanding:

1. **All HTTP goes through the Kotlin `net.request` RPC** (system TLS + CA
   store), never Swift's `URLSession`. This is the same reason model downloads
   route through `net.downloadFile`.
2. **Plain `http://` to a LAN endpoint is blocked by default.** Android sets
   `usesCleartextTraffic="false"`, enforced by the OS regardless of which HTTP
   client makes the call — so a local ComfyUI on `http://192.168.x.x:8188`
   won't connect until you opt the host in. Do that with a **scoped** allow-list
   in `pwa.json` (see below); HTTPS endpoints need nothing extra.

### `android.network.cleartext_domains`

```json
{
  "android": {
    "network": { "cleartext_domains": ["nas.local", "192.168.1.50", "*.local"] }
  }
}
```

The bundler generates a `res/xml/network_security_config.xml` whose global
`base-config` keeps cleartext **off**, with a scoped `domain-config` permitting
it only for the listed hosts, and references it from the manifest. This is the
least-broad fix and the shape least likely to draw app-store scrutiny — a
blanket `usesCleartextTraffic="true"` is deliberately **not** offered.

Entries are Android network-security-config *domains*: a concrete hostname
(`"nas.local"`, `"192.168.1.50"`) or an mDNS-style suffix (`"*.local"` → the
base domain `local` with `includeSubdomains`). Bare CIDR ranges aren't
expressible — list the concrete host(s). Omitting the key leaves the manifest
byte-for-byte unchanged (cleartext stays off).

**Other platforms need nothing for LAN http.** Desktop (macOS/Linux/Windows) has
no cleartext restriction. On **iOS**, add an `NSAppTransportSecurity` exception
via the existing `ios.info_plist` passthrough if you target a plain-http
endpoint.

## Error codes

| Code    | When                                                                 |
| ------- | -------------------------------------------------------------------- |
| `E_NET` | Transport failure, invalid URL / body, non-2xx download, or checksum mismatch. |

A non-2xx **request** response is not an error — it's a `status` on the result.
