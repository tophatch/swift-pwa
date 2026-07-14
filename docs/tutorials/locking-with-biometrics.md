# Locking your app with biometrics

**Who this is for:** you want to gate your app (or a sensitive screen) behind the device's biometric check — Touch ID / Face ID on Apple, Windows Hello, a fingerprint/face on Android. Two commands do it: ask *can we?*, then *authenticate*.

Assumes you've met the bridge — see [Talking to the native side](talking-to-the-native-side.md).

> Uses swift-pwa **0.8+**. Works on macOS, iOS, Windows, and Android — **not** Linux.

---

## Step 1 — Turn on the plugin (Swift)

In `configure` (`Sources/MyApp/App.swift`) — no `#if os()` needed, each platform ships the right implementation (Linux's is a stub that reports "unavailable"):

```swift
ctx.use(BiometricAuthPlugin(SystemBiometricAuth()))
```

> **iOS Face ID gotcha:** Apple refuses to show a Face ID prompt unless your app declares `NSFaceIDUsageDescription`. Add it via the `ios.info_plist` passthrough in `pwa.json` (Touch ID doesn't need it, but adding it is harmless):
> ```json
> "ios": { "info_plist": { "NSFaceIDUsageDescription": "Unlock your vault with Face ID." } }
> ```

---

## Step 2 — Check availability, then authenticate

Always check first — the user may have no sensor, or none enrolled. Then authenticate with a **reason** string (shown in the system prompt; required on Apple):

```js
async function unlock() {
  const status = await __SWIFT_PWA__.invoke('biometric.canAuthenticate');
  // status: { available: boolean, kind: string, reason?: string }

  if (!status.available) {
    // No usable biometrics — fall back to a passcode/password screen.
    // status.reason explains why ("not enrolled", "no sensor", …)
    showPasswordFallback(status.reason);
    return;
  }

  try {
    const { authenticated, error } = await __SWIFT_PWA__.invoke(
      'biometric.authenticate',
      { reason: 'Unlock your journal' }
    );
    if (authenticated) {
      revealApp();
    } else {
      // User cancelled or dismissed — NOT an error. error === 'cancelled'
      // Leave them on the lock screen (offer a retry / password option).
    }
  } catch (err) {
    // A real system failure (sensor error, lockout, disabled by policy).
    // err.code === 'E_HANDLER', err.message has the detail.
    showPasswordFallback(err.message);
  }
}
```

The two outcomes to handle differently:

- **User cancel / dismiss** → resolves with `{ authenticated: false, error: 'cancelled' }`. This is *not* an exception — don't treat it as a failure to log; just keep them locked out.
- **Real failure** (no hardware, lockout, policy) → the Promise **rejects** with `E_HANDLER`. That's your cue to offer the fallback.

---

## Step 3 — Word the prompt (optional) and degrade gracefully

`canAuthenticate` returns a `kind` — `'touchID'`, `'faceID'`, `'opticID'`, `'windowsHello'`, `'unknown'`, or `'none'` — which you can use to label your own UI ("Unlock with Face ID"):

```js
const label = {
  touchID: 'Touch ID', faceID: 'Face ID', opticID: 'Optic ID',
  windowsHello: 'Windows Hello',
}[status.kind] ?? 'biometrics';
```

> **Android caveat:** Android reports `kind: 'unknown'` even when biometrics work, because it doesn't distinguish fingerprint/face/iris. **Gate your UI on `available`, never on `kind`** — only use `kind` to pick nicer wording on Apple/Windows.

And because Linux has no biometrics (and a user may have none enrolled anywhere), **always provide a non-biometric way in** (password, passcode). Feature-detect the plugin itself if you want to hide the option entirely where it wasn't wired:

```js
const { commands } = await __SWIFT_PWA__.invoke('__platform.info');
const canOfferBiometrics = commands.includes('biometric.authenticate');
```

---

## Important: what this does and doesn't protect

Biometric auth here is a **UI gate** — it decides whether to reveal your app's screen. It does **not** by itself encrypt your data. If you're protecting genuinely sensitive data, pair the unlock with real storage protection: keep secrets in the OS keychain via [`secrets.*`](calling-a-cloud-api.md) (encrypted at rest by the platform), and treat the biometric check as the gate that authorizes reading them — not as the only thing standing between an attacker and plaintext on disk.

---

## Where to go next

- [Calling a cloud API with a stored key](calling-a-cloud-api.md) — `secrets.*`, the natural partner for storing what a biometric unlock protects.
- [JavaScript API](../javascript-api.md) — the full `biometric.*` reference.
- [Shipping your app](shipping-your-app.md) — release, including the iOS Info.plist keys.
