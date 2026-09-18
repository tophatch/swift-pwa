# Signing in with a cloud provider (OAuth)

**Who this is for:** your app needs to act on behalf of the person using it — read their Drive, post to their GitHub, sync to their Dropbox. That means OAuth, which means sending them to the provider's consent page and getting them back again.

That last part is the bit that's genuinely hard in a native shell, and it's the bit swift-pwa now does for you. Everything either side of it you already have: [`net.*`](calling-a-cloud-api.md) makes the API calls, [`secrets.*`](../secrets.md) keeps the refresh token in the OS keychain.

You'll add one plugin in Swift (one line) and write some JavaScript. If you haven't met the bridge yet, skim [Talking to the native side](talking-to-the-native-side.md) first.

> Uses swift-pwa **0.11+**.

---

## The big picture

```
  ┌─────────┐   1. auth.authorize    ┌──────────────┐
  │ your JS │ ─────────────────────▶ │  swift-pwa   │
  └─────────┘                        └──────┬───────┘
       ▲                                    │ 2. opens the SYSTEM browser
       │                                    ▼
       │                            ┌────────────────┐
       │                            │ accounts.      │  the user signs in
       │                            │ google.com     │  and presses Allow
       │                            └───────┬────────┘
       │                                    │ 3. redirects
       │  5. { code, codeVerifier,          ▼
       │       redirectUri }        ┌────────────────────────────┐
       └─────────────────────────── │ 4. swift-pwa catches it:   │
                                    │    127.0.0.1 on desktop,   │
                                    │    your URL scheme on iOS  │
                                    │    and Android             │
                                    └────────────────────────────┘
```

Then one more call — `auth.exchange` — swaps that `code` for an access token and a refresh token.

**Why the system browser and not a window in your app?** Because Google, GitHub and Microsoft all refuse to render their consent page inside an embedded webview. Google answers `disallowed_useragent` and stops. That's [RFC 8252 §8.12](https://www.rfc-editor.org/rfc/rfc8252#section-8.12) working as designed: an app that hosts the sign-in page could read the password out of it. So the page has to be the real browser, and the redirect has to find its way back across a process boundary — which is exactly what `auth.authorize` is.

---

## Step 1 — Create the right kind of OAuth client

This is the step most likely to cost you an afternoon, so do it first and do it deliberately. **Providers issue different client types, and each accepts only one kind of redirect.**

| You're shipping | Create a | It redirects to |
|---|---|---|
| macOS / Linux / Windows | **Desktop app** client | `http://127.0.0.1:<any port>/…` |
| iOS | **iOS** client | `com.googleusercontent.apps.<id>:/…` |
| Android | **Android** client | the same reverse-DNS scheme |

(Google's names; other providers differ in wording but not in shape.)

If you're shipping desktop *and* mobile, you need both — one client id per platform, chosen in your app. That's not swift-pwa being fussy; it's how the providers work.

---

## Step 2 — Turn on the plugin (Swift)

Open `Sources/MyApp/App.swift` and add one line inside `configure`:

```swift
ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))
```

On Android, swap the client (same reason as `net.*` — Android's `URLSession` has no injectable CA trust store):

```swift
#if os(Android)
    ctx.use(AuthPlugin(networkClient: AndroidNetworkClient()))
#else
    ctx.use(AuthPlugin(networkClient: URLSessionNetworkClient()))
#endif
```

That's the whole native side. You don't name a browser, and you don't name an Apple type — the backend hands those in, so the same line builds on all five platforms.

---

## Step 3 — Declare your URL scheme (mobile only)

Skip this if you only ship desktop.

In `pwa.json`, add the scheme your mobile OAuth client redirects to:

```json
"url_schemes": ["com.googleusercontent.apps.123456789-abcdefghijklmnop"]
```

Rebuild (`swift-pwa build --target ios`, `--target android`) so the declaration reaches `Info.plist` and the Android manifest. More on how that works: [Receiving deep links](receiving-deep-links.md).

---

## Step 4 — Run the flow (JavaScript)

```js
const CLIENT_ID = {
  macos:   '…apps.googleusercontent.com',   // Desktop app client
  linux:   '…apps.googleusercontent.com',
  windows: '…apps.googleusercontent.com',
  ios:     '…apps.googleusercontent.com',   // iOS client
  android: '…apps.googleusercontent.com',   // Android client
};

async function signIn() {
  const { os } = await __SWIFT_PWA__.invoke('__platform.info');
  const clientId = CLIENT_ID[os];

  // On mobile the redirect is your *reversed* client id; on desktop it's loopback.
  // Google's client id is `<digits>-<hash>.apps.googleusercontent.com`, and the
  // scheme is the whole thing turned around:
  // `com.googleusercontent.apps.<digits>-<hash>`.
  const mobile = os === 'ios' || os === 'android';
  const redirect = mobile
    ? { scheme: 'com.googleusercontent.apps.' + clientId.replace('.apps.googleusercontent.com', '') }
    : 'auto';

  const grant = await __SWIFT_PWA__.invoke('auth.authorize', {
    authorizationEndpoint: 'https://accounts.google.com/o/oauth2/v2/auth',
    clientId,
    scopes: ['https://www.googleapis.com/auth/drive.readonly'],
    redirect,
    // access_type=offline is what makes Google send a refresh token at all,
    // and prompt=consent is what makes it send one on a *repeat* sign-in.
    extraParams: { access_type: 'offline', prompt: 'consent' },
  });

  const tokens = await __SWIFT_PWA__.invoke('auth.exchange', {
    tokenEndpoint: 'https://oauth2.googleapis.com/token',
    clientId,
    code: grant.code,
    codeVerifier: grant.codeVerifier,
    redirectUri: grant.redirectUri,
  });

  // Keep the refresh token in the OS keychain, never in localStorage.
  if (tokens.refreshToken) {
    await __SWIFT_PWA__.invoke('secrets.set', {
      key: 'google-refresh', value: tokens.refreshToken,
    });
  }
  return tokens.accessToken;
}
```

**Pass `grant.codeVerifier` and `grant.redirectUri` straight through.** You didn't choose either — the verifier was generated inside the flow, and on desktop the redirect URI contains a port the OS picked a moment ago. The token endpoint checks that redirect URI byte for byte, so anything you reconstruct by hand is a coin flip.

---

## Step 5 — Call the API

```js
const accessToken = await signIn();

const res = await __SWIFT_PWA__.invoke('net.request', {
  url: 'https://www.googleapis.com/drive/v3/files?pageSize=10',
  headers: { Authorization: 'Bearer ' + accessToken },
});
const files = JSON.parse(atob(res.bodyBase64)).files;
```

---

## Handling the ways it doesn't work

```js
try {
  await signIn();
} catch (error) {
  switch (error.code) {
    case 'E_AUTH_CANCELLED':                        // they dismissed the sheet
      showSignedOut();
      break;
    case 'E_AUTH_DENIED':                           // they pressed Deny, or the scope was refused
      showMessage(error.message);                   // carries the provider's own error_description
      break;
    case 'E_AUTH_TIMEOUT':                          // they wandered off
      showRetry();
      break;
    default:
      reportBug(error);
  }
}
```

`E_AUTH_CANCELLED` only fires on Apple, where `ASWebAuthenticationSession` reports a dismissal immediately. Everywhere else a browser tab the user closed is indistinguishable from one they haven't finished with, so the flow keeps waiting until `timeoutMs` (default five minutes). Show a "waiting for sign-in…" state with a **Cancel** button rather than a spinner with no way out.

`timeoutMs` is honoured on all five, iOS included — the session is dismissed from under the user when it elapses. Pick it for how long you're willing to leave that waiting state on screen, not for how long a sign-in "should" take.

---

## What's happening underneath (worth knowing)

**PKCE is always on.** Every flow generates a code verifier, sends the SHA-256 of it, and presents the original at the exchange. You can't turn it off, and you shouldn't want to: on every platform where the redirect returns over a custom scheme, another app installed on the same device can register the same scheme and receive your authorization code. Without the verifier, that code is a signed-in session.

**`state` is always checked.** A redirect that doesn't carry the exact value this flow generated is dropped, and the flow keeps waiting. You don't pass one and you can't read it until the flow succeeds.

**Nothing is stored for you.** No token cache, no background refresh. That's `secrets.*` and your own code, deliberately — where a refresh token lives is your app's decision, and a framework that quietly kept one would have to answer awkward questions about where.

To refresh an expired access token later, it's a plain POST with `net.request`:

```js
const { value: refreshToken } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'google-refresh' });
const body = new URLSearchParams({
  grant_type: 'refresh_token', refresh_token: refreshToken, client_id: clientId,
}).toString();
const res = await __SWIFT_PWA__.invoke('net.request', {
  url: 'https://oauth2.googleapis.com/token',
  method: 'POST',
  headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
  bodyBase64: btoa(body),
});
```

---

## Keeping the token out of your web code entirely

If you'd rather no token ever reached JavaScript, run the whole flow in Swift. `OAuthAuthorizer` is the same object the plugin uses:

```swift
let auth = OAuthAuthorizer(
    urlOpener: ctx.urlOpener,
    events: ctx.events,
    networkClient: URLSessionNetworkClient(),
    presenter: ctx.authorizationSession
)
ctx.registry.register("drive.listFiles", typed: { (_: EmptyArgs, _) async throws -> FileList in
    let grant = try await auth.authorize(request)
    let tokens = try await auth.exchange(exchangeRequest(for: grant))
    // call the API here with tokens.accessToken, and return only what the page needs
    return try await listFiles(using: tokens.accessToken)
})
```

Your page calls `drive.listFiles` and never sees a credential. Same pattern as the API-key section in [Calling a cloud API](calling-a-cloud-api.md).

---

## Per-platform reality

| Platform | Consent page | Redirect caught by | Notes |
|---|---|---|---|
| macOS | default browser | `127.0.0.1` | |
| iOS | `ASWebAuthenticationSession` | the session | asks whether to share Safari's cookies — say yes and an already-signed-in user taps once. The callback goes **straight back to the session**, so it never appears on your `app.openURL` handler |
| Linux | default browser | `127.0.0.1` | |
| Windows | default browser | `127.0.0.1` | loopback avoids the `register-url-schemes.cmd` a portable `.exe` would otherwise need first |
| Android | default browser | your URL scheme | |

**Two iOS details worth knowing if you handle deep links too.** The callback
never reaches the `app.openURL` channel — the session takes it directly — so
your deep-link router will not see it and doesn't need to filter it out. And if
your app expects people to switch between several accounts, register the session
as ephemeral:

```swift
#if os(iOS) || os(macOS)
ctx.use(AuthPlugin(
    urlOpener: ctx.urlOpener,
    events: ctx.events,
    networkClient: URLSessionNetworkClient(),
    presenter: SystemAuthorizationSession(ephemeral: true)
))
#endif
```

That skips the cookie-sharing prompt and starts from a clean session each time —
worth it when a shared session would silently sign them back into the account
they were trying to leave, and not worth it otherwise, since the shared session
is what makes the common case one tap.

Full reference, including every argument and error: [docs/auth.md](../auth.md).
