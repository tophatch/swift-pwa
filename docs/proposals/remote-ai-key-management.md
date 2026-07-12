# Proposal: runtime API keys + secure storage (`secrets.*`) for remote AI

> **Status: proposed (followup to the remote-AI tier, PR #82).** The remote
> image tier ships an `ImagenProvider` whose API key is injected via a closure
> and *never persisted by swift-pwa* — the right stance, but it punts two things
> every real app then hits: **(1) what happens when there's no key yet**, and
> **(2) where the key is stored securely.** This proposal adds a runtime
> key-requirement flow to the sample, a first-class **`secrets.*` secure-storage
> plugin**, and a "secure key storage" writeup. Framing: this is "good practice
> for real devs" made concrete — the same learn-by-doing stance that drove #82.
>
> Depends on the remote-AI tier (`SwiftPWARemoteAI`, `docs/remote-ai.md`) and the
> `net.*`/`NetworkClient` foundation (`docs/net-plugin.md`).

## The gap

A cloud provider needs a secret the app doesn't have at build time:

- **No key yet.** Today `ImagenProvider`'s models advertise `availability: .ready`
  unconditionally; a nil key only surfaces as an `E_AI_GENERATION` *after* the
  user picks Imagen and generates. The honest behavior is: advertise
  **`needsSetup("Add a Google AI API key")`** until a key exists, and let the
  user enter one at runtime, after which it flips to `.ready`.
- **Where does the key live?** The framework must never persist it (that's the
  `apiKey: () async -> String?` closure seam). But the *adopter* needs a real,
  secure place to keep it — Keychain, Android Keystore, Windows DPAPI, Linux
  Secret Service — and today there's nothing shipped, so each adopter rolls
  their own (or, worse, drops the key in `localStorage` / a plaintext file /
  `pwa.json`). A `secrets.*` plugin makes the secure path the easy path.

`AIModelAvailability` already models exactly this — `.needsSetup(reason:)` was
added in the model-selection work precisely for "present but not usable until
the user does something." This proposal makes something *use* it.

## Part 1 — `secrets.*` secure-storage plugin (the core addition)

A first-class, opt-in plugin for storing small secrets in the OS's secure store.
Broadly useful beyond Imagen (any API token, a sync credential, a license key).

### JS surface (`secrets.*`)

Opt-in like `net.*` / `process.*` (register explicitly). Values are strings
(base64 for binary). Namespaced per app by the platform store.

```js
await __SWIFT_PWA__.invoke('secrets.set',    { key: 'google-ai', value: '…' });
const { value } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'google-ai' }); // value: string | null
await __SWIFT_PWA__.invoke('secrets.delete', { key: 'google-ai' });
```

- `secrets.get` returns `{ value: null }` for a missing key (not an error).
- Errors (store unavailable, access denied) → a stable `E_SECRETS` bridge code.

### Swift seam + plugin

Mirror `ProcessPlugin(ProcessRunner)` / `NetPlugin(NetworkClient)`:

```swift
public protocol SecretStore: Sendable {
    func get(_ key: String) async throws -> String?
    func set(_ key: String, _ value: String) async throws
    func delete(_ key: String) async throws
}
public struct SecretsPlugin: Plugin { public init(_ store: any SecretStore) … }
```

The `apiKey` closure an adopter passes to `ImagenProvider` then just reads the
store: `ImagenProvider(apiKey: { try? await store.get("google-ai") })`. The
provider is unchanged.

### Platform implementations (parity is the bar)

| Platform | Backing store | Notes |
|---|---|---|
| **macOS / iOS** | **Keychain** (`SecItemAdd`/`CopyMatching`/`Delete`, `kSecClassGenericPassword`, service = bundle id) | The obvious native store; `kSecAttrAccessibleAfterFirstUnlock`. |
| **Android** | **`EncryptedSharedPreferences`** (Jetpack Security, AES via a Keystore master key) over the Kotlin RPC | Same RPC bridge pattern as `net.request` — a `secrets.*` dispatch case in `AndroidTemplates.swift`. Keystore-backed. |
| **Windows** | **DPAPI** (`CryptProtectData`/`CryptUnprotectData`, user scope) → encrypted blob in `%LOCALAPPDATA%`, **or** the Credential Manager (`CredWrite`/`CredRead`) | DPAPI is simplest (no extra deps); per-user, machine-bound. |
| **Linux** | **Secret Service** via **libsecret** (GNOME Keyring / KWallet) | A `.systemLibrary` dep. **Gotcha:** needs a running keyring + D-Bus session — headless/CI has none. Document a clear fallback (see open questions). |

Each is a small target/file gated in-source (`#if canImport(...)` / `#if os(...)`),
the same shape as the rest of the codebase. `NoneSecretStore` (throws
`unavailable`) is the default when an app uses `SecretsPlugin()` without one, so
the JS contract exists before every platform lands.

## Part 2 — runtime key requirement in the sample

`Examples/CritterFacts` grows an **Imagen arm** next to the on-device models and
the ComfyUI arm, demonstrating the whole `needsSetup → enter key → ready` loop.

- **Availability reflects key presence.** The adopter owns the key, so the
  adopter decides Imagen's availability. In the sample's `CompositeAIBackend`
  (which already composes the arms), compute Imagen's `AIModelInfo.availability`
  = `store.get("google-ai") == nil ? .needsSetup("Add a Google AI API key") :
  .ready` when assembling `info().models`. No framework change needed.
  - *Optional general path (decide during impl):* add
    `RemoteImageProvider.availability(client:) async -> AIModelAvailability`
    (default `.ready`) so a provider can self-report. Cleaner for reuse, but the
    key check is inherently app-owned (only the app knows the store), so the
    composite-computes-it approach is likely better and needs no new API.
- **Page flow (`generate.html`).** The dropdown already renders `availability`.
  Extend it: a model with `availability.kind === 'needsSetup'` shows the
  `reason` and, when selected, reveals a small **key input** (a `<input
  type=password>` + Save) instead of the generate button. Save →
  `secrets.set('google-ai', …)` → re-fetch `ai.info()` (Imagen now `ready`) →
  generate. A "clear key" affordance calls `secrets.delete`.
- Wiring: `ctx.use(SecretsPlugin(KeychainSecretStore()))` (etc. per platform,
  the usual `#if os(Android)` split), and
  `ImagenProvider(apiKey: { try? await store.get("google-ai") })`.

## Part 3 — the "secure key storage" writeup

A **Secure key storage** section in `docs/remote-ai.md` + the on-device-AI
tutorial's remote section, covering:

- **swift-pwa never persists your key.** The `apiKey` closure is the seam; the
  key lives wherever *you* put it. Corollary: never bake a key into `pwa.json`,
  source, or commits (link `[[no-environment-identifiers-in-repo]]`).
- **Use the OS secure store, not `localStorage`/a file.** The `secrets.*` plugin
  gives you Keychain/Keystore/DPAPI/Secret Service behind one API; the per-
  platform table + the "Linux needs a keyring" caveat.
- The **`needsSetup → enter → ready`** UX pattern, with the CritterFacts code as
  the worked example.
- A note on **rotation / revocation** (delete + re-enter) and that a key entered
  on one device isn't synced (per-device store).

## Open questions

1. **Linux fallback when no keyring/D-Bus** (headless, minimal WMs). Options:
   (a) error clearly (`E_SECRETS`, "no Secret Service available"); (b) fall back
   to an encrypted-file store with a machine-derived key (weaker, but works
   headless); (c) let the adopter inject a fallback `SecretStore`. Lean: (a) by
   default + (c) as the escape hatch — don't silently downgrade security.
2. **Key-entry UI: page vs native.** The sample uses an in-page password field
   (portable, demonstrates the JS surface). A native secure-input dialog is more
   "correct" but per-platform. Lean: in-page for the sample; note the trade-off.
3. **Windows: DPAPI blob vs Credential Manager.** DPAPI is dependency-free and
   simplest; Credential Manager is more discoverable/manageable by the user.
   Lean: DPAPI first, Credential Manager as a follow-up.
4. **Is `secrets.*` in scope, or documented-adopter-storage only?** This proposal
   assumes the plugin (the recommended answer — secure storage shouldn't be
   every adopter's DIY). If we'd rather stay minimal, drop Part 1 and the sample
   uses a documented, clearly-caveated minimal store.

## Phasing

- **Phase A — `secrets.*` core + Apple/Android** (the two the sample is verified
  on): `SecretStore` + `SecretsPlugin` + `KeychainSecretStore` +
  `AndroidSecretStore` (RPC + Kotlin `EncryptedSharedPreferences`). Unit tests
  (mock store + plugin wiring) + device verify.
- **Phase B — desktop stores:** Windows DPAPI, Linux libsecret (+ the fallback
  decision). Verify on the Windows/Linux boxes.
- **Phase C — sample + docs:** CritterFacts Imagen arm + `needsSetup` flow;
  `docs/remote-ai.md`/tutorial "Secure key storage" section; README matrix row
  for `SecretsPlugin`; CHANGELOG.

## Verification plan

- Unit: `MockSecretStore` drives `SecretsPlugin` (set/get/delete, missing-key →
  null, error → `E_SECRETS`); Imagen availability computed from a stubbed store.
- Device (Tab S10+): `secrets.set` → app restart → `secrets.get` returns it
  (Keystore persistence); Imagen shows `needsSetup`, enter a key (real
  `GEMINI_API_KEY`, via the runtime field — not committed), flips to `ready`,
  generates. Same on macOS (Keychain) + a Windows/Linux box for Phase B.
- Reuse the CDP recipe; keep the real key in the runtime field only, never in
  the repo (per `[[no-environment-identifiers-in-repo]]`).
