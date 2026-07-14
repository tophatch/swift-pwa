# Calling a cloud API with a stored key

**Who this is for:** your app needs to call a third-party API that requires a key — a weather service, a maps API, an LLM, whatever — and you want to (a) store that key securely (not in `localStorage` or a config file) and (b) actually make the request without the browser's CORS rules getting in the way.

swift-pwa gives you both: **`secrets.*`** keeps the key in the OS keychain, and **`net.*`** makes HTTP requests from the *native* side, so there's no CORS preflight and you can set any header you like (including `Authorization`).

You'll add two plugins in Swift (a few lines) and write some JavaScript. If you haven't met the bridge yet, skim [Talking to the native side](talking-to-the-native-side.md) first.

> Uses swift-pwa **0.8+**.

---

## The big picture

```
  Store the key once          Call the API any time
  ┌──────────────────┐        ┌───────────────────────────────┐
  │ secrets.set  ────▶ OS     │ net.request ───▶ the API server │
  │   keychain       │  key   │   (no CORS, any header)         │
  └──────────────────┘  kept  │ ◀─── { status, headers, body }  │
                        safe   └───────────────────────────────┘
```

Two facts that make this pleasant:

- **`net.request` runs in Swift**, not the WebView — so it isn't bound by same-origin/CORS, and it can send headers a page can't (`Authorization`, a custom `User-Agent`), reach LAN devices, and call APIs that don't send CORS headers.
- **`secrets.*` uses the real OS keychain** (Keychain / Keystore / DPAPI / libsecret), so a key survives restarts and never sits in plaintext.

---

## Step 1 — Turn on the two plugins (Swift)

Open `Sources/MyApp/App.swift` and, inside `configure`, register both plugins. Each picks the right backing store/client for the OS it's built on:

```swift
// --- Secure storage: the OS keychain for whatever platform we're on ---
#if os(Android)
    let secretStore: any SecretStore = AndroidSecretStore()
#elseif canImport(Security)
    let secretStore: any SecretStore = KeychainSecretStore()   // macOS + iOS
#elseif os(Windows)
    let secretStore: any SecretStore = WindowsSecretStore()
#elseif os(Linux)
    let secretStore: any SecretStore = LinuxSecretStore()
#else
    let secretStore: any SecretStore = NoneSecretStore()
#endif
ctx.use(SecretsPlugin(secretStore))

// --- Native HTTP client ---
#if os(Android)
    ctx.use(NetPlugin(AndroidNetworkClient()))
#else
    ctx.use(NetPlugin(URLSessionNetworkClient()))
#endif
```

That's the only Swift you need for the simple version. (We reuse `secretStore` again in Step 4.)

> **Linux/Windows keychain prerequisites:** the Linux store needs a running Secret Service (a desktop keyring); Windows DPAPI needs an interactive login session. On a headless box, `secrets.*` calls fail with `E_SECRETS` rather than silently losing the key. Full detail in [docs/secrets.md](../secrets.md).

---

## Step 2 — Store the key

Give the user a little settings field and stash what they type. From JS:

```js
// Save (e.g. from a "Save key" button):
await __SWIFT_PWA__.invoke('secrets.set', { key: 'weather-api-key', value: theKeyString });

// Read it back:
const { value } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'weather-api-key' });
// value is the string, or null if nothing's stored yet

// Forget it:
await __SWIFT_PWA__.invoke('secrets.delete', { key: 'weather-api-key' });
```

`secrets.get` returns `{ value: null }` for a key that was never set — that's how you decide whether to show your "enter your API key" screen:

```js
async function needsSetup() {
  const { value } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'weather-api-key' });
  return value === null;
}
```

---

## Step 3 — Call the API

`net.request` takes a method, URL, headers, and an optional **base64-encoded** body, and returns `{ status, headers, bodyBase64 }`. The body is base64 in both directions (so binary responses work too) — decode it in JS:

```js
async function fetchWeather(city) {
  const { value: key } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'weather-api-key' });

  const res = await __SWIFT_PWA__.invoke('net.request', {
    method: 'GET',
    url: `https://api.example.com/v1/weather?city=${encodeURIComponent(city)}`,
    headers: { 'Authorization': `Bearer ${key}` },
    // For a POST with a JSON body:
    // method: 'POST',
    // headers: { 'Content-Type': 'application/json', 'Authorization': `Bearer ${key}` },
    // bodyBase64: btoa(JSON.stringify({ city })),
  });

  if (res.status !== 200) throw new Error(`API returned ${res.status}`);

  const text = atob(res.bodyBase64);   // decode base64 → text
  return JSON.parse(text);
}
```

Two things to know about errors:

- **A non-2xx response is *not* an exception** — you get it back as `res.status` (like `401` for a bad key). Check it yourself, as above.
- **Only a transport failure throws** (bad URL, no connection, timeout) — with code `E_NET`. So wrap the call in `try/catch` for "the network died," and check `res.status` for "the server said no."

That's a working cloud-API call. For many apps — a desktop tool where the user pastes their own key — this is completely fine.

---

## Step 4 — (Recommended) keep the key out of your web code

Notice that Step 3 reads the key back into JavaScript to put it in a header. That means the key briefly lives in the WebView's memory. For a lot of apps that's an acceptable trade-off; if you'd rather the key **never** cross into web code, do the request in Swift and hand only the *result* back — the pattern swift-pwa's own cloud providers use.

Register a small custom command (see [Talking to the native side](talking-to-the-native-side.md)) that reads the key from the store and makes the call, capturing the `secretStore` and a client from Step 1:

```swift
struct WeatherArgs: Codable, Sendable { let city: String }

let netClient: any NetworkClient = {
    #if os(Android)
        return AndroidNetworkClient()
    #else
        return URLSessionNetworkClient()
    #endif
}()

ctx.registry.register("weather.today", typed: { (args: WeatherArgs, _) -> [String: String] in
    let key = (try? await secretStore.get("weather-api-key")) ?? ""
    let url = URL(string: "https://api.example.com/v1/weather?city=\(args.city)")!
    var req = NetRequest(url: url)
    req.headers["Authorization"] = "Bearer \(key)"

    let res = try await netClient.send(req)
    guard res.isSuccess else {
        throw BridgeError(code: "E_WEATHER", message: "API returned \(res.status)")
    }
    // Return whatever shape you like; here we just pass the raw JSON string.
    return ["json": String(decoding: res.body, as: UTF8.self)]
})
```

Now the web side never touches the key at all:

```js
const { json } = await __SWIFT_PWA__.invoke('weather.today', { city: 'Wellington' });
const weather = JSON.parse(json);
```

The key is read from the keychain and attached to the request entirely in Swift. JS only ever *stores* it (`secrets.set`) and *deletes* it (`secrets.delete`) — it never reads it back.

> **Which should you use?** The Step 3 approach is simpler and fine when the user supplies their own key. The Step 4 approach keeps the key strictly native — worth it for a key you don't want exposed to page scripts (e.g. a shared key baked into a build, or defence against a compromised dependency in your web bundle).

---

## Notes & gotchas

- **Calling a device on your LAN over plain `http://`?** Desktop is fine out of the box. Android blocks cleartext by default — opt specific hosts in with `android.network.cleartext_domains` in `pwa.json` (e.g. `["*.local", "printer.local"]`); iOS needs an ATS exception via `ios.info_plist`. See [docs/net-plugin.md](../net-plugin.md).
- **Big downloads** go through `net.download` (a streaming `subscribe` with `progress`/`done` frames and optional `sha256` verification) rather than `net.request`, so the bytes stream to disk instead of through the bridge.
- **A missing keychain backend** (no store registered, or a headless Linux/Windows box) makes `secrets.*` throw `E_SECRETS` — handle it so your settings screen can tell the user secure storage isn't available.

---

## Where to go next

- [Talking to the native side](talking-to-the-native-side.md) — the custom-command pattern Step 4 builds on.
- [docs/secrets.md](../secrets.md) and [docs/net-plugin.md](../net-plugin.md) — the full plugin references.
- [On-device AI](on-device-ai.md) — if the "cloud API" you're calling is an image/LLM service, swift-pwa also has a config-driven remote-AI tier that handles the key with `secretRef` (no key in JS) for you.
- [Shipping your app](shipping-your-app.md) — when you're ready to release.
