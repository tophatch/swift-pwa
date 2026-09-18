# The `auth.*` plugin — signing in with a cloud provider

Open a provider's consent page in the **system browser** and catch the OAuth
redirect back, on all five platforms, with PKCE. This is the one step of an
OAuth 2.0 authorization-code flow an app in a swift-pwa shell couldn't do for
itself.

Everything either side of it already existed. `net.*` does the token exchange and
every API call after it, CORS-free and with the right TLS stack on Android;
`secrets.*` holds the refresh token in the OS keychain. The middle — *open the
consent page, get the redirect* — is per-platform in a way an app shouldn't own,
and it is the same middle for Drive, Dropbox, OneDrive, GitHub, Workspace and
Microsoft Graph alike.

| Platform | Consent page | Redirect caught by |
|---|---|---|
| **macOS** | default browser | loopback HTTP on `127.0.0.1:<os-assigned>` |
| **iOS** | `ASWebAuthenticationSession` | the session itself (custom scheme) |
| **Linux** (GTK3 / GTK4) | default browser | loopback HTTP |
| **Windows** | default browser | loopback HTTP |
| **Android** | default browser (`ACTION_VIEW`) | `ACTION_VIEW` intent → `app.openURL` |

## Why not just do it in the page

An `<iframe>` or an in-app navigation is not an option, and not because of
anything swift-pwa does. Google, GitHub and Microsoft all refuse to render their
consent page inside an embedded webview — Google answers `disallowed_useragent`
— which is [RFC 8252 §8.12](https://www.rfc-editor.org/rfc/rfc8252#section-8.12)
working as designed: an app that hosts the consent page can read the password out
of it. So the consent page is the system browser, and the redirect then has to
cross a process boundary.

## Setup

Opt-in, like `net.*` and `secrets.*`. One line, and the same line on every
platform:

```swift
import SwiftPWA

@MainActor
func configure(_ ctx: any AppContext) throws {
    ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))
    // on Android: ctx.use(AuthPlugin(networkClient: AndroidNetworkClient()))
    …
}
```

The browser — and on Apple the OS authorization session — come from the backend
through `AppContext.urlOpener` / `AppContext.authorizationSession`, so you never
name `AppleURLOpener` or `GTKURLOpener`. That matters more than it looks: a
per-platform branch in a shared `main.swift` is a branch that breaks on the
platform its author can't test.

`networkClient` is still per-platform, because it already is for `net.*` and the
remote-AI tier — Android's `URLSession` has no injectable CA trust store, so
HTTPS there routes through the Kotlin bridge. Omit it entirely and
`auth.authorize` still works; only `auth.exchange` refuses.

## Using it

```js
const { code, codeVerifier, redirectUri } =
  await __SWIFT_PWA__.invoke('auth.authorize', {
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    clientId: '…',
    scopes: ['https://www.googleapis.com/auth/drive.readonly'],
    redirect: 'auto',
    extraParams: { access_type: 'offline', prompt: 'consent' },
  });

const tokens = await __SWIFT_PWA__.invoke('auth.exchange', {
  tokenEndpoint: 'https://oauth2.googleapis.com/token',
  clientId: '…',
  code, codeVerifier, redirectUri,
});
// { accessToken, refreshToken, expiresIn, tokenType, scope, idToken }

await __SWIFT_PWA__.invoke('secrets.set', {
  key: 'drive-refresh', value: tokens.refreshToken,
});
```

### `auth.authorize(args)`

| Field | Type | Default | Meaning |
|---|---|---|---|
| `authorizationEndpoint` | string | — | the provider's consent URL |
| `clientId` | string | — | the OAuth client id |
| `scopes` | string[] | `[]` | joined with spaces; omitted entirely when empty |
| `redirect` | see below | `'auto'` | where the provider sends the user back |
| `extraParams` | object | `{}` | appended verbatim |
| `timeoutMs` | number | `300000` | how long to wait for the redirect, on every platform |

Returns `{ code, codeVerifier, redirectUri, state }`.

`codeVerifier` and `redirectUri` come back because the exchange needs both and
neither is reconstructable: the verifier was generated inside the flow, and with
a loopback redirect the URI isn't known until the OS assigns a port.
[RFC 6749 §4.1.3](https://www.rfc-editor.org/rfc/rfc6749#section-4.1.3) requires
the exchange to repeat the redirect URI **byte for byte**, which is the single
easiest thing to get wrong by hand.

`timeoutMs` applies to the **presented session** on Apple as well, not just to
the two receivers: `ASWebAuthenticationSession` has no deadline of its own and
will wait for the user indefinitely, so the runtime dismisses it when the
timeout elapses. Choose the value for how long you're willing to leave a
"waiting for sign-in" state on screen.

`extraParams` may not set `client_id`, `redirect_uri`, `response_type`, `scope`,
`state`, `code_challenge` or `code_challenge_method` — the flow owns those, and
silently letting a caller overwrite `state` or `code_challenge` would disable the
two protections the flow exists to provide.

### `redirect`

| Value | Means |
|---|---|
| `'auto'` | loopback on macOS / Linux / Windows; on iOS / Android, the `scheme` you pass — see below |
| `'loopback'` | bind `127.0.0.1` on an OS-assigned port, serve `/callback` |
| `{ path: '/x' }` | loopback on a different path |
| `{ scheme: 'com.example' }` | custom scheme; `redirect_uri` becomes `com.example:/oauth2redirect` |
| `{ uri: 'myapp://cb' }` | a full redirect URI, scheme taken from it |

**Which one your provider accepts is not up to you.** Google's *Desktop app*
client type only redirects to `http://127.0.0.1:<port>/…`; its iOS and Android
client types only to a reverse-DNS custom scheme. Create the client type that
matches the build you're shipping.

Loopback is what `auto` picks on desktop because it needs nothing registered —
which matters most on a portable Windows `.exe`, where a custom scheme costs the
user a `register-url-schemes.cmd` run *before* they can ever finish signing in,
and there's no way for the app to tell them that at the right moment.

> **`auto` on iOS / Android refuses unless you pass a scheme.** That is
> deliberate, and it is the one place the framework can't work it out for you.
> `url_schemes` in `pwa.json` is build-time only — it generates
> `CFBundleURLTypes`, an `<intent-filter>`, a `.desktop` handler and Windows
> registry scripts, and nothing carries it into the running process. Even with
> that list in hand the right entry is provider-specific: Google's is the
> *reversed client ID*, derived from a value only you know. A wrong guess
> wouldn't fail at the call; it would fail minutes later at the provider's
> redirect, in a browser, with the app showing nothing.
>
> So pass `redirect: { scheme: 'com.googleusercontent.apps.…' }` on mobile, and
> declare that same scheme in `pwa.json`'s `url_schemes`.

### `auth.exchange(args)`

| Field | Type | Meaning |
|---|---|---|
| `tokenEndpoint` | string | the provider's token URL |
| `clientId` | string | the OAuth client id |
| `clientSecret` | string? | sent when present |
| `code`, `codeVerifier`, `redirectUri` | string | straight from `authorize` |
| `extraParams` | object? | appended to the form body |

Returns `{ accessToken, refreshToken?, expiresIn?, tokenType?, scope?, idToken? }`.

Everything but `accessToken` is optional because everything but `accessToken` is
optional in practice: `refresh_token` only arrives when the request asked for
offline access (and with Google, only on the *first* consent), `id_token` only
for OpenID scopes, `scope` only when the grant differs from what was asked for.

`expiresIn` is the provider's own number of seconds, not converted to an absolute
date — your app decides which clock to trust, and a framework stamping
`expiresAt` from the local clock would be wrong on a device whose time is off,
which is a real state rather than a hypothetical.

> **`clientSecret` on a desktop client is not a secret.** Google's Desktop app
> type still issues one, [RFC 8252 §8.5](https://www.rfc-editor.org/rfc/rfc8252#section-8.5)
> acknowledges that it can't be kept, and PKCE is what actually protects the
> flow. Refusing to send it would block the most common provider there is, so it
> is sent when given — but don't treat it as protecting anything.

## PKCE, and the two things that aren't configurable

**PKCE is always on, `S256`, with no `plain` and no opt-out.** RFC 7636 is
mandatory for native clients and the reason is exactly this runtime's situation:
on every platform where the redirect returns over a custom scheme, another
locally installed app can register the same scheme and receive the code. Without
the verifier, that code is a session.

**`state` is always generated and always verified**, and you can't supply one.
There is no reason to want to and every reason not to be able to — a constant, a
counter or a reused value all turn `state` into decoration.

A callback whose `state` doesn't match is **dropped and the wait continues**
(loopback and custom-scheme), because a mismatch is either an attack or another
app's stray request and neither should end a flow the user is still in. The one
exception is Apple's `ASWebAuthenticationSession`, which is one-shot: there is
nothing left to wait on, so a mismatch there throws `E_AUTH_STATE`.

## `auth.*` can't be handed to an agent

`agent.expose` refuses the whole namespace at build time, the way it refuses
`secrets.*`. The reason is the same one step earlier: `secrets.get` hands over a
key your app already had, `auth.exchange` **mints a new one** — and because both
commands take the provider's endpoints as arguments, an agent holding them
chooses whose credential to get. The consent sheet, built from your own
description, would honestly say "Sign in".

Expose the command that *uses* the sign-in — `myapp.syncLibrary` — and keep the
token on the native side. See [docs/agent-tools.md](agent-tools.md).

## What it doesn't do

No token cache, no refresh scheduling, no keychain writes, no provider discovery
(`.well-known`), no device-code or implicit flow. `secrets.*` is where a refresh
token belongs and your app decides that. Refreshing an access token is a POST to
the same endpoint with `grant_type=refresh_token` — `net.request` does it in a
few lines, and doing it here would pull storage and scheduling in behind it.

## Errors

| Code | Means |
|---|---|
| `E_AUTH_CANCELLED` | the user dismissed the consent browser (Apple only — elsewhere a closed browser is indistinguishable from a slow user, and the flow waits) |
| `E_AUTH_TIMEOUT` | no matching callback within `timeoutMs` |
| `E_AUTH_DENIED` | the provider returned `error=…`; the message carries its `error_description` |
| `E_AUTH_STATE` | a one-shot session came back with a wrong or missing `state` |
| `E_AUTH_REDIRECT` | the redirect couldn't be resolved, bound, or opened |
| `E_AUTH_TOKEN` | the token endpoint refused the grant or answered without an `access_token` |
| `E_UNIMPLEMENTED` | this backend has no browser, or `auth.exchange` was registered with no `NetworkClient` |

`E_AUTH_DENIED` covers the user pressing **Deny** on the consent screen
(`error=access_denied`) as well as a client-side refusal like `invalid_scope`: a
deliberate refusal is a decision your app should show, which is a different event
from the browser window being dismissed.

## Running the whole flow from Swift

`OAuthAuthorizer` is the same object the plugin uses, so an app can run the flow
natively and never let a token near the page:

```swift
let auth = OAuthAuthorizer(
    urlOpener: ctx.urlOpener,
    events: ctx.events,
    networkClient: URLSessionNetworkClient(),
    presenter: ctx.authorizationSession
)
let grant = try await auth.authorize(AuthorizationRequest(
    authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
    clientId: clientID,
    scopes: ["https://www.googleapis.com/auth/drive.readonly"],
    extraParams: ["access_type": "offline"]
))
let tokens = try await auth.exchange(TokenExchangeRequest(
    tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
    clientId: clientID,
    code: grant.code,
    codeVerifier: grant.codeVerifier,
    redirectURI: grant.redirectURI
))
try await store.set("drive-refresh", tokens.refreshToken ?? "")
```

Registering `AuthPlugin(_: authorizer)` with that same object gives the page the
JS commands backed by it, if you want both.

## Per-platform notes

**Apple.** `ASWebAuthenticationSession` is used for the custom-scheme flow
because it does three things an externally opened browser can't: it shows the
"Do you want to allow … to sign in?" prompt that decides whether the session
shares Safari's cookies (the difference between one tap and typing a password on
a phone keyboard), it reports cancellation immediately instead of at the timeout,
and the callback never touches the `app.openURL` channel where anything else
could see it. It has no http-loopback variant, so a Mac using a loopback
redirect goes through the default browser — which is the right way round, since
loopback exists for the desktop client types.

Pass `SystemAuthorizationSession(ephemeral: true)` explicitly if you want a
private session with no shared cookies: worth it for an app that expects several
accounts, where a shared session silently signs the user back into the one they
were trying to leave.

**Don't fire a sign-in at the instant the app launches.** The session refuses
any anchor whose scene isn't `.foregroundActive`, and a freshly launched app is
`.foregroundInactive` for a moment — so an `auth.authorize` called from a
startup path, or straight off a deep link, used to fail with Apple's
`presentationContextInvalid` and a message naming nothing. The runtime now waits
briefly for a presentable scene, and appends the anchor it actually found to the
error when it still can't present, so the remaining failures are diagnosable. It
is still better to start the flow from a user action.

**Linux.** No OS authorization browser exists across desktops, so a sign-in opens
the default browser and catches the redirect on loopback. Nothing to install.

**Windows.** Same, and loopback is doubly right here: a portable `.exe` can't
register a URL scheme without the user running `register-url-schemes.cmd` first.

**Android.** The consent page opens through `ACTION_VIEW` and the callback
arrives as an `ACTION_VIEW` intent on the app's declared scheme, which reaches
the `app.openURL` channel the receiver listens on. Custom Tabs would look nicer
but needs `androidx.browser` — a runtime dependency for a browser launch, which
isn't a trade this project makes.

## Verifying it

`Scripts/verify-oauth.sh` (and `Scripts/verify-oauth.ps1`, since Windows has no
bash) drives a real app through a real flow against a
stand-in authorization server that runs as its **own process**
(`Scripts/oauth-probe/provider.py`), so it checks what a provider checks: that
the authorization request carries what RFC 6749 and RFC 7636 require, and that
the verifier presented at the token endpoint actually hashes to the challenge
sent at the start. A challenge can be well-formed and wrong; only the far side
notices.

It carries the two controls every probe in this repo needs. A leading
`system.openURL` check decides whether this box can open a browser at all, so a
headless machine reports SKIP rather than a broken feature — and a final flow
that nothing redirects to **must** fail with `E_AUTH_TIMEOUT`, or every check
above it is equally consistent with a receiver that resolves whatever it is
handed.

`Scripts/verify-oauth-android.sh` and `Scripts/verify-oauth-ios.sh` cover the
two platforms the desktop script can't: they are the only runs that exercise the
custom-scheme path, and on iOS the only one that exercises
`ASWebAuthenticationSession` at all. Both need the device on USB. The iOS one
also asserts that the callback **never reaches the `app.openURL` channel** —
the security property the session is chosen for.

On Windows the script needs somebody **logged on at the console**, because it
launches the app as the interactive user through a scheduled task (an SSH shell
lands in the non-interactive services session, where there is no desktop for a
browser). It detects an empty console and SKIPs. Point
`$env:SWIFT_PWA_WINDOWS_PACKAGES` at your WebView2 / WIL NuGet packages; since
Swift 6.4 they have to reach the compiler as flags rather than through
`$env:INCLUDE` (see [windows-setup.md](windows-setup.md)).
