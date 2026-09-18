# Proposal: OAuth authorization (`auth.*`)

> **Status: shipped** — see [`docs/auth.md`](../auth.md) and the CHANGELOG.
> Tracked by [#221](https://github.com/tophatch/swift-pwa/issues/221), written
> against 0.10.7 out of designing Google Drive support for a real adopter. Kept
> for the reasoning, which the implementation followed: loopback on desktop and
> a scheme on mobile, `auto` refusing rather than guessing, PKCE and `state`
> non-configurable, and a callback with a bad `state` dropped rather than fatal.
>
> **Three things the build changed.**
>
> 1. **Registration takes no platform adapter at all.** The proposal assumed the
>    app would hand `AuthPlugin` a `URLOpener`, which is a per-platform branch in
>    every adopter's shared `main.swift` — the thing the parity rule exists to
>    prevent. `AppContext` gained `urlOpener` and `authorizationSession` instead,
>    so `ctx.use(AuthPlugin(networkClient: …))` compiles on all five and picks up
>    `ASWebAuthenticationSession` on Apple by itself.
> 2. **The retained-`app.openURL` special case wasn't needed.** The concern below
>    is real — the channel replays its last value, so an app cold-started by a
>    deep link has a stale URL waiting — but `state` already makes it harmless:
>    a URL from before this flow can't carry a `state` generated moments ago. The
>    check that was going to run anyway does the work, and there is a test that
>    says so rather than a branch.
> 3. **The loopback receiver has to read the browser's whole header block**, not
>    just the request line it uses. Closing a socket with unread input sends an
>    RST and *discards the response already written*, so the user would have seen
>    a connection-reset page after a sign-in that actually worked. Not foreseen
>    here at all; found by asserting on the response body in a real-socket test.
>
> The **open question** below — whether `auth.exchange` should also take the
> refresh grant — was decided *no* for this change. It stays a `net.request` in
> the app, and the tutorial shows the POST.
>
> Read [`docs/net-plugin.md`](../net-plugin.md) and [`docs/secrets.md`](../secrets.md)
> first — this is the missing step between them, and deliberately does nothing
> either of those already does.

## The problem

An app in a swift-pwa shell can do every part of an OAuth 2.0 authorization-code
flow *except the step in the middle*: open the provider's consent page and get
the redirect back.

Everything around it is already here.

| Step | Today |
| :--- | :--- |
| Build the authorization URL | the app, by hand |
| Open the consent page | `system.openURL` |
| **Catch the redirect** | **nothing that works on every platform** |
| Exchange the code for tokens | `net.request` / `NetworkClient` — CORS-free, right TLS stack on Android |
| Store the refresh token | `secrets.*` / `SecretStore` |
| Call the API | `net.request` |

The missing row is per-platform in a way an app shouldn't own, and it is the
same row for every app that reaches a cloud API — Drive, Dropbox, OneDrive,
GitHub, Workspace, Microsoft Graph. It is the shape the parity rule in
[`CLAUDE.md`](../../CLAUDE.md) exists for: a capability that works on one
platform, half-works on two, and is invisible on the rest — a gap an adopter who
doesn't own all five can't discover, let alone report.

### Why the page can't just do it

The obvious answer — run the flow in the WebView with a `https://` redirect back
to the app's own origin — fails on the two platforms that matter most for it.
Google, GitHub and Microsoft all refuse to render their consent page inside an
embedded WebView (Google returns `disallowed_useragent`), which is
[RFC 8252 §8.12](https://www.rfc-editor.org/rfc/rfc8252#section-8.12) working as
intended: an app that hosts the consent page can read the password out of it.
The consent page has to be the system browser, and once it is, the redirect has
to come back across a process boundary.

### What the two halves of that cost

**A loopback HTTP receiver.** Google's *Desktop app* client type — the one a
macOS, Windows or Linux build uses — only redirects to `http://127.0.0.1:<port>/…`.
swift-pwa has no HTTP listener. It has
[`LoopbackServer`](../../Sources/SwiftPWACore/Net/LoopbackServer.swift), but that
is NDJSON-framed and `package`-scoped, serving the driver and the agent surface.
On the portable Windows `.exe` a custom scheme additionally costs the user a
`register-url-schemes.cmd` run *before* sign-in can ever complete, so loopback is
the right desktop shape independent of which provider is on the other end.

**The per-platform choice.** iOS and Android client types redirect to a
reverse-DNS scheme (`com.googleusercontent.apps.<client-id>:/…`); desktop types
to loopback. Which one a build should use, how to catch it, and how to wait for
exactly one callback matching the request's `state` is knowledge the framework
has and the app currently has to guess at. On Apple,
`ASWebAuthenticationSession` does the browser *and* the scheme callback in one,
with the session-cookie sharing prompt the OS wants — and nothing in `Sources/`
uses it today.

### One premise from #221 that turned out to be wrong

The issue says PKCE can't be done on Windows or Android because swift-pwa's
SHA-256 is "a handful of private file-hashing helpers". It isn't: `SwiftPWACore`
declares a `Crypto` edge for `.linux`, `.windows` and `.android`
([`Package.swift`](../../Package.swift), `cryptoPlatforms`) and uses CryptoKit on
Apple, so `SHA256` is available in Core on all five platforms. The
`"sha256 verification is unavailable on this platform"` branch in
[`URLSessionNetworkClient`](../../Sources/SwiftPWACore/Net/URLSessionNetworkClient.swift)
is unreachable on all five — and has been since #229 made the edge explicit
rather than borrowed from whichever backend happened to pull `Crypto` in. Worth
deleting in the same change, or at least re-wording, because it is the reason
#221 concluded the framework couldn't hash on two platforms.

So PKCE is free. It is still the primitive's job — an *app* on Windows or
Android has no hash without bringing one — but it costs us nothing to give it.

## Shape

Two commands, opt-in, plus a Swift API beside them so an app can run the whole
flow natively and never let a token near the page.

```js
const { code, codeVerifier, redirectUri, state } =
  await __SWIFT_PWA__.invoke('auth.authorize', {
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    clientId: '…',
    scopes: ['https://www.googleapis.com/auth/drive.readonly'],
    redirect: 'auto',         // 'auto' | 'loopback' | { scheme: 'com.googleusercontent.apps.…' }
    extraParams: { access_type: 'offline', prompt: 'consent' },
    timeoutMs: 300000,
  });

const tokens = await __SWIFT_PWA__.invoke('auth.exchange', {
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
  clientId: '…',
  code, codeVerifier, redirectUri,
});
// → { accessToken, refreshToken, expiresIn, tokenType, scope, idToken }
```

`redirectUri` is returned rather than passed because with loopback it isn't
known until the OS assigns a port, and
[RFC 6749 §4.1.3](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.3) requires
the exchange to repeat it byte-for-byte. Returning it removes the one thing an
app would otherwise get subtly wrong.

### What `auth.authorize` does

1. Generate a PKCE verifier (32 random bytes, base64url — 43 chars of the
   unreserved set RFC 7636 requires) and its `S256` challenge, plus a 32-byte
   `state`.
2. Resolve the redirect mode (below) and start the receiver **before** opening
   the browser, so a fast provider can't redirect into a socket that isn't
   listening yet.
3. Build the authorization URL, run it past
   [`ExternalURLPolicy`](../../Sources/SwiftPWACore/URLs/ExternalURLPolicy.swift)
   exactly as `system.openURL` does, and hand it to the browser.
4. Wait for a callback whose `state` matches, up to `timeoutMs`.
5. Return `{ code, codeVerifier, redirectUri, state }`.

### Resolving `redirect: 'auto'`

| Platform | `auto` picks | Why |
| :--- | :--- | :--- |
| macOS | loopback | the desktop client type; no scheme registration needed |
| Linux | loopback | same; a `.desktop` handler needs the app *installed* |
| Windows | loopback | same, and a portable `.exe` can't register a scheme without `register-url-schemes.cmd` |
| iOS | scheme | the iOS client type only accepts one; loopback needs the app foregrounded, which it isn't while the browser is |
| Android | scheme | same |

**`auto` on mobile still needs the scheme from the caller**, and this is the one
place the issue's suggested shape can't be implemented as written. It proposes
taking it "from `url_schemes`, refusing if none is declared". Two things stop
that:

- `url_schemes` is **build-time only**. It generates `CFBundleURLTypes`, an
  Android `<intent-filter>`, a `.desktop` `MimeType=`, and Windows registry
  scripts; nothing carries it into the runtime. Apple could read it back out of
  `Info.plist`, Android could not without a JNI `PackageManager` query, and the
  two would disagree.
- Even with the list in hand, **the framework can't pick from it.** Google's
  mobile redirect scheme is the reversed client ID, which is provider-specific
  and derived from a value only the caller knows. An app that declares one
  scheme for its own deep links and another for Google would get a coin flip.

So: `auto` on iOS/Android uses `redirect.scheme` when given and otherwise
refuses with `E_AUTH_REDIRECT` naming both fixes (pass a scheme, or force
`'loopback'`). Guessing here would fail at the provider's redirect — minutes
later, in a browser, with the app showing nothing — which is the worst place in
the flow to be wrong.

The framework *can* still check the scheme it was handed: on Apple, against
`CFBundleURLTypes`, refusing up front with the same error rather than letting
the callback vanish. That check is Apple-only and better than nothing, which is
what every platform has today.

### The loopback receiver

New in Core, beside `LoopbackServer` rather than inside it — the framing is
different (HTTP request line vs. NDJSON), the lifetime is different (one flow,
then gone), and `LoopbackServer`'s two existing consumers shouldn't grow an HTTP
mode they don't use. What it reuses is
[`LoopbackSocket`](../../Sources/SwiftPWACore/Net/LoopbackSocket.swift), which
already covers bind / listen / poll / accept / recv / send across BSD sockets and
Winsock. The new code is request-line parsing, not sockets.

- Bind `127.0.0.1:0`; the OS picks the port. Google's desktop client type accepts
  any port on loopback, which is what makes this work without registering
  anything.
- **Accept repeatedly, not once.** A browser opens speculative connections and
  asks for `/favicon.ico`; a receiver that closes after the first connection
  loses the real callback roughly as often as it catches it. Answer 404 to any
  path that isn't the redirect path, keep listening.
- On a request to the redirect path: parse the query, compare `state` in constant
  time, answer `200` with a small self-contained "you can close this tab" page,
  close, stop.
- A callback with a **wrong or missing `state` is dropped** and the wait
  continues to the timeout — a mismatched `state` is either an attack or another
  app's stray request, and neither should end a flow the user is still in.
- `127.0.0.1` literal, never `localhost`: the name can resolve to `::1` first,
  and a receiver bound to IPv4 then never hears the browser.

The listener thread is a detached `Thread`, like `LoopbackServer`'s, because it
blocks in `poll`.

### The scheme receiver

Almost free: `app.openURL` is already a Core `EventBus` channel that every
backend feeds ([`OpenURL`](../../Sources/SwiftPWACore/Events/OpenURL.swift)). The
receiver subscribes for the duration of the call, resolves on the first URL whose
`state` matches, and cancels. Anything else stays an ordinary deep link and
reaches the page's own `on('app.openURL', …)` as it does now.

One wrinkle worth pinning in a test: the channel is emitted **retained**, so a
subscriber gets the last URL delivered before it subscribed. The receiver has to
ignore a retained payload that predates the flow, or an app that was cold-started
by a deep link would resolve its next `authorize` instantly with a stale URL.

### Apple: `ASWebAuthenticationSession`

An injected backend seam, the same shape as `BiometricAuth` and `URLOpener`:

```swift
public protocol AuthorizationSessionPresenter: Sendable {
    /// Present the OS's authorization browser for `url` and return the callback
    /// URL it was redirected to. Throws `E_AUTH_CANCELLED` if the user dismisses it.
    func present(authorizationURL: URL, callbackScheme: String) async throws -> URL
}
```

`SwiftPWAWebKit` implements it with `ASWebAuthenticationSession`, which is what
Apple wants an app to use: the browser, the callback and cancellation in one
object, and the "Do you want to allow … to use … to sign in?" prompt that decides
whether the session shares Safari's cookies (so an already-signed-in user gets one
tap instead of a password). Core's default — used on Linux, Windows and Android —
is `URLOpener` plus the `app.openURL` receiver above.

It is **scheme mode only**. `ASWebAuthenticationSession` has no http-loopback
callback, so macOS in loopback mode uses the default path and opens the default
browser. That is the correct trade: a Mac desktop-client build wants loopback
anyway, and an iOS build wants the session.

Android's nicer equivalent, Custom Tabs, needs `androidx.browser` — a runtime
dependency for a better-looking browser launch. Out of scope; `ACTION_VIEW`
through the existing `URLOpener` is what ships.

### `auth.exchange`

One POST — `application/x-www-form-urlencoded`, `grant_type=authorization_code`,
`code`, `redirect_uri`, `client_id`, `code_verifier`, and `client_secret` when
the caller passes one (Google's desktop client type still issues a "secret" that
isn't one, and refusing to send it would block the most common provider). It goes
through the injected `NetworkClient`, so Android gets the Kotlin TLS bridge and
nothing bypasses the transport `net.*` already uses.

It exists because it is the same nine lines in every app, and because with it an
app that runs the flow from Swift can put the result straight into `SecretStore`
without a token ever being visible to the page.

## Errors

| Code | Means |
| :--- | :--- |
| `E_AUTH_CANCELLED` | the user dismissed the browser / session |
| `E_AUTH_TIMEOUT` | no matching callback within `timeoutMs` |
| `E_AUTH_DENIED` | the provider returned `error=…`; the message carries its `error_description` |
| `E_AUTH_STATE` | a one-shot session returned with a wrong or missing `state` (in loopback/scheme mode such a callback is dropped and the wait continues instead) |
| `E_AUTH_REDIRECT` | `auto` couldn't resolve a redirect, or the scheme isn't one this build registered |
| `E_AUTH_TOKEN` | `auth.exchange` got a non-2xx or an unparseable token response |

`E_AUTH_STATE` reads as a contradiction in #221 — listed as an error *and*
described as "dropped, and the wait continues". Both are right, for different
receivers: a socket or an event channel can keep waiting, a one-shot
`ASWebAuthenticationSession` that has already completed cannot.

## Security notes

- **PKCE is not optional.** `S256` always, no `plain`, no way to turn it off.
  RFC 7636 is mandatory for native clients and the flow is not safe without it on
  a machine where another local app can register the same scheme.
- **`state` is always generated and always verified.** The caller can't supply
  one; there is no reason to want to and every reason not to be able to.
- **No frame gate.** `bridge.js` is injected into the top frame only, which is
  the defence — a cross-origin `<iframe>` has no bridge object on any of the five
  backends, and a same-origin one reaches the parent's realm no matter what we
  check (settled in #204 / PR #209). The authorization URL still goes through
  `ExternalURLPolicy` like every other URL the page asks to open.
- **Nothing is stored.** No token cache, no refresh scheduling, no keychain
  writes. The app puts the result where it wants it, which is `secrets.*`.

## Not in scope

Token refresh scheduling, provider discovery (`.well-known`), device-code flow,
implicit flow, and storing anything. `NetworkClient` and `SecretStore` already
own the last one.

**Open question:** `auth.exchange` is one `grant_type` away from also doing the
refresh grant — same endpoint, same encoding, ~5 lines. Excluding it means every
adopter hand-writes that POST with `net.request`, which is exactly the
duplication this proposal exists to remove; including it edges toward the
scheduling we don't want. Leaning: accept `refreshToken` as an alternative to
`code` on the *same* command, and still ship no scheduler.

## Verification

Per the parity rule, this needs checking on real hardware per platform, not
generalising from macOS.

- **Unit (CI, macOS + Linux):** PKCE vectors from RFC 7636 appendix B, URL
  construction, `state` mismatch dropping, retained-`app.openURL` ignoring,
  timeout.
- **Loopback receiver, for real (CI, macOS + Linux):** start it, `curl` the
  redirect URI with a matching `state`, assert the flow resolves; then the
  favicon case, the wrong-`state` case, and the timeout. This is a genuine
  cross-platform socket test, not a mock.
- **`Scripts/verify-oauth.sh` / `.ps1`:** build a probe app, run the flow against
  a local stand-in authorization server, assert the app received the code. Covers
  the desktop three end-to-end including the browser launch. Needs the control a
  probe in this repo always needs — a run with the receiver deliberately not
  started must *fail* — or a green result proves nothing.
- **Devices:** iOS (`ASWebAuthenticationSession`, including the cookie-sharing
  prompt and cancelling it) and Android (scheme callback via `ACTION_VIEW`)
  against a real Google client, on the Tab S10+ and an iPad.
- **Manual:** the cookie-sharing prompt's wording and the "you can close this
  tab" page are eyes-on; the rest is scripted.

## Documentation

- `docs/auth.md` — the capability page, per-platform behaviour, the redirect
  table above, the error list.
- `docs/tutorials/signing-in-with-a-cloud-provider.md` — sits between
  [`calling-a-cloud-api.md`](../tutorials/calling-a-cloud-api.md) and
  [`secrets.md`](../secrets.md), which currently jump straight to "get an API key
  from somewhere".
- README feature matrix row, with a footnote for the `auto` resolution.
- `CHANGELOG.md` `## [Unreleased]`.
