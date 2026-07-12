# The `secrets.*` plugin — secure secret storage

Store small secrets — an API token, a sync credential, a license key — in the
operating system's **secure store**, from either JS or Swift. It's the
secure-by-default alternative to dropping a secret in `localStorage`, a
plaintext file, or `pwa.json`.

| Platform | Backing store |
|---|---|
| **macOS / iOS** | **Keychain** (`kSecClassGenericPassword`, `kSecAttrAccessibleAfterFirstUnlock`, service = bundle id) |
| **Android** | **`EncryptedSharedPreferences`** (Jetpack Security — AES-256 values, master key in the Android Keystore, hardware-backed where available) |
| **Windows** | **DPAPI** (`CryptProtectData`, user scope) → encrypted blob under `%LOCALAPPDATA%\<service>\secrets\` |
| **Linux** | **Secret Service** (libsecret / GNOME Keyring / KWallet) — *planned follow-up* |

On Linux, registering `SecretsPlugin` without your own store falls back to
`NoneSecretStore`: the command set exists but every call returns `E_SECRETS`.
Inject your own `SecretStore` to fill the gap.

> **Windows DPAPI needs an interactive user session.** The user-scope master key
> is unlocked by the interactive logon — a real desktop user has it, but a *network
> logon* (e.g. an SSH session, or some service contexts) does not, and
> `CryptProtectData` returns `ERROR_ACCESS_DENIED` there. This is expected: run the
> app in a normal desktop session.

> **swift-pwa never persists a secret for you.** This plugin is a thin, audited
> bridge to the OS store — where a value lives is the store's business. Never
> bake a secret into `pwa.json`, source, or a commit.

## Enabling it

Opt-in, like `net.*` / `process.*`. Register it Swift-side with the platform
store:

```swift
#if os(Android)
    ctx.use(SecretsPlugin(AndroidSecretStore()))
#elseif canImport(Security)
    ctx.use(SecretsPlugin(KeychainSecretStore()))
#elseif os(Windows)
    ctx.use(SecretsPlugin(WindowsSecretStore()))
#else
    ctx.use(SecretsPlugin()) // NoneSecretStore — Linux (libsecret) not yet shipped
#endif
```

`KeychainSecretStore(service:)` defaults its Keychain service to the app's
bundle identifier, so two apps get separate namespaces with no configuration.

## JS API

Values are strings — encode binary as base64. Keys are opaque identifiers,
namespaced per app by the underlying store, so a plain `"google-ai"` is fine.

```js
// Store (replaces any existing value).
await __SWIFT_PWA__.invoke('secrets.set', { key: 'google-ai', value: 'sk-…' });

// Read. A missing key is `null`, NOT an error.
const { value } = await __SWIFT_PWA__.invoke('secrets.get', { key: 'google-ai' });
if (value === null) promptForKey();

// Delete (idempotent — deleting a missing key succeeds).
await __SWIFT_PWA__.invoke('secrets.delete', { key: 'google-ai' });
```

- `secrets.get` → `{ value: string | null }`.
- `secrets.set` / `secrets.delete` → `{}` on success.
- A store failure (unavailable, access denied, I/O) rejects with `E_SECRETS`.
  A *missing key is not a failure* — it comes back as `value: null`.

## Swift API — using `SecretStore` directly

`SecretStore` is the injectable seam behind the plugin; you can read secrets in
Swift too (e.g. from an `AIBackend`), without going through JS:

```swift
public protocol SecretStore: Sendable {
    func get(_ key: String) async throws -> String?
    func set(_ key: String, _ value: String) async throws
    func delete(_ key: String) async throws
}
```

The canonical pairing is a remote `AIBackend`'s API-key closure reading straight
through the store, so a key entered at runtime is picked up on the next call
with no re-init:

```swift
let store = KeychainSecretStore()
ctx.use(SecretsPlugin(store))
let imagen = ImagenProvider(apiKey: { try? await store.get("google-ai") })
```

## The `needsSetup → enter → ready` pattern

A cloud provider that needs a key it doesn't have at build time should advertise
its model as **`needsSetup`** until a key exists, flipping to `ready` once one is
stored — rather than failing only at generate time. The key check is app-owned
(only the app knows which store / key name), so compute the availability where
you assemble `ai.info().models`:

```swift
let hasKey = (try? await store.get("google-ai")) != nil
let availability: AIModelAvailability = hasKey ? .ready : .needsSetup(reason: "Add a Google AI API key")
```

The page renders `availability`: a `needsSetup` model reveals a password field
instead of the generate button; **Save** calls `secrets.set`, re-fetches
`ai.info()` (now `ready`), and generates. See
[docs/remote-ai.md](remote-ai.md) for the worked CritterFacts example.

## Notes

- **Per device.** A key stored on one device isn't synced to another — the store
  is local. Rotation/revocation is `secrets.delete` + re-enter.
- **Android at rest.** The prefs file (`swift_pwa_secrets`) is AES-encrypted with
  a Keystore master key; it is *not* readable by pulling the file off the device.
- **Keychain accessibility.** Items are `kSecAttrAccessibleAfterFirstUnlock` —
  readable in the background after the first unlock since boot (what a
  generate-on-launch flow needs), but not before first unlock.

## Error codes

| Code | Meaning |
|---|---|
| `E_SECRETS` | Store unavailable, access denied, I/O failure, or no store configured (`NoneSecretStore`). A missing key is **not** this — it returns `value: null`. |
