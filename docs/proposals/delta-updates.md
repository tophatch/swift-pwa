# Proposal: delta (binary-patch) updates

> **Status: proposed.** The last open sub-item of the auto-updates epic. Today
> every update is a **full-bundle download**: a 40 MB AppImage / portable `.exe`
> is re-fetched in its entirety even when the release changed 200 KB of code. A
> *delta* update ships only the binary difference between the installed artifact
> and the new one — the client downloads a small patch, reconstructs the new
> artifact **locally**, and then runs it through the **exact same Ed25519
> verification** as a full download before installing. Smaller, cheaper, faster;
> **not one gram less safe**, because trust still rests on the signature of the
> *reconstructed full artifact*, never on the patch.
>
> **The load-bearing observation** that scopes v1: a delta can only be applied
> where the client already has the *old signed artifact bytes* on disk to patch
> against. That is true on exactly two of our backends — **Linux AppImage** and
> **Windows portable `.exe`** — because there the installed file *is* the signed
> artifact, byte-for-byte. macOS installs the *extracted* `.app` (not the signed
> `.app.tar.gz`), and Android re-installs an APK the system re-derives; neither
> keeps the signed bytes around. So **v1 = Linux + Windows portable**, the two
> backends we can also verify end-to-end on real boxes — matching the
> learn-by-doing stance the rest of this epic was built under.
>
> **Decision preview** (rationale in the body): (1) diff engine = **zstd
> `--patch-from`** (one modern, static-linkable library; no bzip2; good ratios via
> long-distance matching) rather than classic bsdiff. (2) **No per-delta
> signature.** The manifest carries the full artifact's signature only; a corrupt
> or wrong-base patch simply fails the post-reconstruction signature check and we
> fall back to a full download. This retires the speculative `signature_delta`
> field that older docs "reserved". (3) The wire addition is a single additive
> `deltas` array on each `PlatformEntry` — invisible to Tauri readers and to
> older swift-pwa clients, both of which keep full-downloading.

## Goals & non-goals

**Goals**
- Cut the bytes-on-the-wire for a typical point release by ~1–2 orders of
  magnitude on the two backends where it's safe, with **zero change to the
  security model** (signature of the reconstructed full artifact against the
  baked-in public key, same as today).
- **Additive, backward-compatible wire format.** A manifest with `deltas` is
  still a valid Tauri-v1 manifest and still drives every existing client; a
  client that understands `deltas` but finds none applicable (or fails to apply
  one) transparently full-downloads. There is never a hard dependency on the
  delta path.
- **Automatic, invisible fallback.** Delta is a fast path, never a failure mode:
  base-mismatch, corrupt patch, missing engine, or any reconstruction error
  drops to the full download of `url` and the user still gets the update.
- Publish-side ergonomics: one `swift-pwa updater manifest` invocation produces
  the full artifact entry *and* the deltas from N prior versions in one pass,
  plus standalone `updater diff` / `updater patch` for scripting and for the
  manual-test recipe.
- Verify it for real on the GTK Linux box and the x64 Windows box (the two v1
  backends), the same way macOS/Linux/Windows-portable full updates were
  verified.

**Non-goals (v1)**
- **macOS and Android deltas.** Neither keeps the signed artifact bytes on disk
  (macOS: extracted `.app`; Android: system-managed APK). Doing them right needs
  either caching the last signed artifact or a content-tree diff — a separate,
  larger design. Deferred, with a sketch in [Later](#later-macos-android-ios).
- **iOS.** `itms-services://` hands the transfer to Apple; there is no local
  artifact to patch. N/A, permanently.
- **Multi-hop / cumulative patches.** v1 ships one patch per (from → new) pair.
  A client more than one release behind, with no patch from *its* version,
  full-downloads. (Chained patches — apply 0.3.0→0.3.1→0.4.0 — are a possible
  later optimization; not worth the reconstruction-error surface in v1.)
- **A new dependency on the network for the base.** We patch against the
  *installed* file only. We never re-download the old artifact to diff against.

## Security model (the part that must be right)

Full updates today: download artifact → `verifyEd25519(artifactBytes, signature)`
against the baked-in public key → install. The signature is the whole game.

Delta updates keep that final check **unchanged** and simply change how the
artifact bytes are *obtained*:

1. Client has `base` = the installed artifact on disk (the running AppImage /
   `.exe`).
2. Client downloads `patch` from `delta.url`.
3. Client reconstructs `candidate = apply(base, patch)` into the staging dir.
4. Client runs **the existing** `verifyEd25519(candidate, entry.signature)`.
5. On success → install `candidate` exactly as a full download would. On **any**
   failure in 2–4 → discard, download `url` in full, verify, install.

Why this needs no patch signature: the attacker's goal is to get us to install
bytes we'd otherwise reject. But step 4 verifies the *output* against our public
key. A forged/tampered patch can only produce a `candidate` whose signature
won't match `entry.signature` (which the attacker cannot forge without our
private key) — so it's rejected and we fall back. The patch is untrusted input
whose only power is to waste a download. That is exactly the property that lets
us drop `signature_delta`.

One integrity nicety worth adding (cheap, not load-bearing): verify the
**base** matches what the patch was cut against before applying, so a
base-mismatch fails *fast and locally* instead of producing megabytes of garbage
that then fail the signature check. We do this with a `from_signature` — the
Ed25519 signature of the *old* artifact, which we already published in the old
release's manifest — or, simpler, a plain SHA-256 of the base in the delta entry
(`base_sha256`). SHA-256 is enough here because this check is an optimization,
not a trust boundary (trust is step 4). **Recommendation: include `base_sha256`**
so the client can skip a doomed download+apply when its installed bytes don't
match any advertised base (e.g. a user hand-modified the AppImage).

## Wire format

Additive to `UpdateManifest.PlatformEntry`. Everything new is optional; absence =
today's behavior.

```json
"platforms": {
  "linux-x86_64-appimage": {
    "url": "https://updates.example.com/MyApp-0.4.0.AppImage",
    "signature": "<base64 Ed25519 over the FULL 0.4.0 AppImage>",
    "deltas": [
      {
        "from": "0.3.0",
        "url": "https://updates.example.com/MyApp-0.3.0-to-0.4.0.zstpatch",
        "size": 214512,
        "base_sha256": "<hex sha256 of the 0.3.0 AppImage>"
      },
      {
        "from": "0.3.1",
        "url": "https://updates.example.com/MyApp-0.3.1-to-0.4.0.zstpatch",
        "size": 98304,
        "base_sha256": "<hex sha256 of the 0.3.1 AppImage>"
      }
    ]
  }
}
```

- `deltas` is a list because one release commonly serves several prior versions.
- `from` is matched exactly against the client's `currentVersion`. No range
  logic in v1 (keeps selection trivial and predictable).
- `signature` (the existing field) is still the signature of the **full** new
  artifact, and is what step 4 verifies — the delta path and the full path share
  it. No separate delta signature.
- `size` is advisory, for the progress bar and for a client policy like "skip the
  delta if it's >70% of the full size."
- `base_sha256` gates the fast path locally (see above); optional but recommended.

### Core type changes

```swift
public struct UpdateManifest {
  public struct PlatformEntry: Codable, Sendable, Equatable {
    public var url: URL
    public var signature: String
    public var deltas: [Delta]?          // NEW, decodeIfPresent → nil

    public struct Delta: Codable, Sendable, Equatable {
      public var from: String
      public var url: URL
      public var size: Int?
      public var baseSHA256: String?     // wire key "base_sha256"
    }
  }
}
```

`updateInfo(for:currentVersion:)` gains one line: after resolving the entry, pick
`entry.deltas?.first { $0.from == currentVersion }` and attach it to the
`UpdateInfo`:

```swift
public struct UpdateInfo {
  // ...existing...
  public var delta: DeltaInfo?           // NEW; nil when no applicable patch

  public struct DeltaInfo: Codable, Sendable, Equatable {
    public var url: URL
    public var size: Int?
    public var baseSHA256: String?
  }
}
```

`DeltaInfo` is deliberately a projection of `Delta` minus `from` (already matched)
so the backend `download(_:)` gets exactly what it needs and JS can see (via the
`available` event) that a delta path exists — useful for telemetry / "downloading
a small update" copy, though no JS change is *required*.

`UpdaterEvent` needs **no new case**: `downloadProgress` already carries
`(bytesDownloaded, contentLength)` and reports the patch transfer for free. If we
want the UI to distinguish, the cheapest signal is that `contentLength` will be
the small patch size; a dedicated `usingDelta` boolean is possible but I'd leave
it out of v1 unless a concrete UI needs it.

## Diff engine: zstd `--patch-from`

Options weighed:

| Engine | Pros | Cons |
|---|---|---|
| **zstd `--patch-from`** ✅ | One modern lib, statically linkable, permissive license, already cross-platform, no bzip2; long-distance matching gives good ratios on executables; simple `ZSTD_decompress`-with-window reconstruction | Ratios slightly behind bsdiff on some binaries; needs a large window param for big artifacts |
| classic **bsdiff/bspatch** | Best-in-class ratios on executables (suffix-sort diff) | Depends on **bzip2**; two vendored C bodies; older code; slower/among the memory-hungriest at diff time |
| **xdelta3 / VCDIFF** | Standardized format | Another vendored lib; no advantage over zstd for our sizes |
| Google **Courgette** | Chrome-grade PE/ELF-aware ratios | Enormous, Chromium-coupled; absurd overkill |

**Recommendation: zstd `--patch-from`.** It collapses "diff engine" and
"compression" into one dependency we can vendor the same way we vendor ONNX /
llama / stb — a per-platform prebuilt (or system `libzstd` where reliably
present) behind a tiny `Czstd`-style `.systemLibrary`/shim. Publish-side we can
even shell out to the `zstd` CLI in the packaging workflow; runtime-side we link
`libzstd` and call `ZSTD_decompress_usingDict`-style reconstruction (patch-from
is dictionary compression with the base as the dictionary and a window ≥ artifact
size).

Patch file naming: `.zstpatch` (our extension; the bytes are a zstd frame whose
dictionary is the base).

### Packaging

Mirrors the established vendored-native-lib pattern:
- **Linux**: prefer the distro `libzstd.so` if present at build; otherwise vendor
  a pinned static lib. `linuxdeploy --library` stages it into the AppImage
  (SONAME-correct), same as the ONNX `.so`.
- **Windows**: vendor `libzstd` (static `.lib` or a `zstd.dll` staged next to the
  `.exe`, like the DirectML DLLs).
- Behind a build gate consistent with the epic's opt-ins — but note deltas want
  to be **on by default** for the two v1 backends (they degrade to full download
  with zero downside), so the gate should default-enabled, not opt-in like GPU.
  Simplest: no new `pwa.json` flag; the backends always attempt delta when the
  manifest offers one and the engine linked.

## Runtime flow (per v1 backend)

Both `LinuxAppImageUpdater` and `WindowsUpdater` (portable mode) get the same
shape, factored into a shared helper next to `UpdaterDownload`:

```
download(info):
  if let delta = info.delta, let base = installedArtifactURL():
     try:
        if delta.baseSHA256, sha256(base) != delta.baseSHA256 { throw .baseMismatch }
        patch  ← UpdaterDownload.download(delta.url, onProgress:…)   // small
        cand   ← ZstdPatch.apply(base: base, patch: patch, to: stagingCandidate)
        verifyEd25519(cand, info.signature)                          // SAME check
        stage(cand); yield .readyToInstall; return
     catch {
        log("delta failed (\(error)); falling back to full download")
        // fall through
     }
  // full path, unchanged from today:
  full ← UpdaterDownload.download(info.downloadURL, onProgress:…)
  verifyEd25519(full, info.signature)
  stage(full); yield .readyToInstall
```

- `installedArtifactURL()` is trivial and *exact* on these two: Linux =
  `$APPIMAGE` (the env var AppImage sets) or the running executable path;
  Windows = `Bundle.main`/argv[0] `.exe` path. This is precisely why v1 is these
  two: `sha256(installed) == base_sha256` holds.
- `install()` is **unchanged** — it swaps the staged candidate exactly as it
  swaps a full download today (atomic `rename(2)` / `Move-Item`). The delta path
  produces an identical staged artifact; install neither knows nor cares how it
  was obtained.
- A shared `UpdaterDeltaStaging` helper (Core) holds `apply` + `sha256` +
  fallback orchestration so the two backends don't duplicate it, and so it's unit
  testable without a backend.

## CLI

Extend the existing `updater manifest` and add two scripting primitives.

**`updater manifest`** — a repeatable `--delta` option that both *generates* the
patch and *embeds* the entry:

```
--delta <target>=<from-version>=<old-artifact-path>=<patch-download-url>
```

For each `--delta`, the CLI: reads `old-artifact-path` and the target's new
artifact (already provided via `--platform`), runs the diff to produce a
`.zstpatch` next to `--output`, computes `size` + `base_sha256`, and appends a
`Delta` to that target's `deltas`. Requires the target to also appear in
`--platform` (so the CLI has the new bytes). No private key needed for deltas —
the delta carries no signature.

**`updater diff --old A --new B -o patch.zstpatch`** and **`updater patch --old A
--patch P -o B`** — standalone, engine-exposed, for CI scripting and for the
manual-test recipe (prove `patch(old, diff(old,new)) == new` by hand).

## Testing

- **Core unit tests** (no backend, no network):
  - `Delta` / `DeltaInfo` decode: additive keys present + absent (older manifest
    → `deltas == nil`, no throw); `base_sha256` snake_case wire key.
  - `updateInfo(for:currentVersion:)` selects the matching `from`, attaches
    `DeltaInfo`, and yields `delta == nil` when no `from` matches.
  - `ZstdPatch` round-trip: `apply(base, diff(base, new)) == new` for a few
    payload shapes; corrupt-patch → throws; wrong-base + `base_sha256` → fast
    `baseMismatch`.
- **CLI tests**: `updater diff`/`patch` round-trip; `manifest --delta` emits a
  well-formed `deltas` array with correct `size`/`base_sha256`; `manifest`
  without `--delta` is byte-identical to today (no empty `deltas` key).
- **Real-box E2E** (the learn-by-doing bar, both v1 backends):
  1. Build + install 0.3.0. 2. Cut 0.4.0 with `manifest --delta 0.3.0=…`. 3. Point
     the endpoint at it. 4. Run 0.3.0, trigger `updater.run`, confirm the
     `downloadProgress` bytes ≈ patch size (not full), the signature verifies, the
     swap lands 0.4.0. 5. **Fallback proof**: corrupt the served patch → confirm
     the log shows the fallback and 0.4.0 still installs from `url`.
  - GTK Linux box (AppImage) + x64 Windows box (portable `.exe`).

## Docs to touch (travel-with-code)

- `docs/auto-updates.md`: replace the "reserves room for `signature_delta` /
  `url_delta`" note (which this design supersedes) with a real "Delta updates"
  section — wire shape, the two supported backends + *why* only those, fallback
  guarantee, publishing with `--delta`.
- `docs/tutorials/auto-updates.md`: a short "Ship smaller updates (deltas)" step
  after Publish — one `--delta` example + the "it just falls back" reassurance.
- `docs/manual-test-cases.md`: add the delta + fallback cases above under Updater
  for Linux and Windows.
- `README.md`: matrix footnote / Roadmap — move "Delta updates" from Roadmap to
  shipped (Linux + Windows portable) once verified; keep macOS/Android/iOS as
  explicitly out of scope with the reason.
- `CHANGELOG.md`: `[Unreleased] → Added`, with the *why* (bandwidth) and the
  scoping reason (installed-bytes == signed-bytes).
- Doc comment on `UpdateManifest` / `Updater` scope block: delete "Delta updates
  are deferred", describe the two-backend support + fallback.

## Phasing

1. **Core + CLI + engine, no backend wiring** — `Delta`/`DeltaInfo` types,
   `updateInfo` selection, `ZstdPatch` (vendored `libzstd` + `Czstd` shim),
   `updater diff`/`patch`/`manifest --delta`, all unit-tested. Nothing user-facing
   changes yet (backends ignore `info.delta`).
2. **Linux AppImage** — `installedArtifactURL()` + delta path + fallback +
   `UpdaterDeltaStaging`; verify E2E + fallback on the GTK box; AppImage libzstd
   staging.
3. **Windows portable** — same for `WindowsUpdater(installMode: .portable)`;
   verify E2E + fallback on the x64 box; DLL/lib staging. MSIX stays full-only
   (the OS installer owns the bytes).
4. **Docs + README/CHANGELOG + manual-test cases**, then tag.

Each phase is independently shippable and independently verifiable — same cadence
as the rest of this epic.

## Later (macOS, Android, iOS)

- **macOS**: the signed artifact is a `.app.tar.gz`; the installed thing is the
  extracted `.app`. Two viable paths, both v2: (a) **cache the last signed
  tarball** in the staging root and delta against it (simple, costs one artifact's
  disk); (b) **content-tree delta** — diff the installed `.app` tree against the
  new one (per-file patches), which sidesteps gzip's diff-hostility entirely but
  is a bigger engine. (a) is the likely first step.
- **Android**: `PackageInstaller` wants a full APK; Play delivers deltas itself
  for store apps. Sideload delta would need Google's archived `archive-patcher`
  approach (APK-aware, recompress-matching) — real work, low payoff for the
  sideload audience. Deferred.
- **iOS**: N/A (system installer owns the transfer).
- **Cumulative/chained patches** and a **"skip delta if >X% of full" size
  policy** are easy follow-ons once v1 is proven.
