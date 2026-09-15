# Contributing to swift-pwa

Practical notes for working in this repo — the build/test loop, the handful of
**generated files you must regenerate**, and the gotchas that otherwise cost a
CI round. For the *why* behind the architecture (the bridge, the concurrency
model, the Linux backends), read [`CLAUDE.md`](../CLAUDE.md); this doc is the
operational companion.

## Build & test

```bash
swift build                                    # build everything (Apple)
swift test                                     # unit + WKWebView integration on macOS
swift test --filter SwiftPWACoreTests          # one target
swift test --filter "BridgeRuntime duplex sessions"   # one suite (by display name)
swiftformat --lint .                           # what CI's lint job runs
swiftformat .                                  # apply it
```

- **Run the CLI target too, not just Core.** `swift test --filter SwiftPWACoreTests`
  and `SwiftPWAWebKitTests` miss `SwiftPWACLITests`, which holds drift guards for
  the generated files below. When in doubt, run the whole `swift test`.
- **Linux:** `SwiftPWACore` + `swift-pwa-cli` are the only targets CI gates on
  Linux; a full `SwiftPWAGTK` build needs `libgtk-3-dev` + `libwebkit2gtk-4.1-dev`
  (see [linux-setup.md](linux-setup.md)). GTK integration tests are opt-in:
  `SWIFT_PWA_LINUX_GUI=1 swift test`.
- **A GTK GUI test that closes a window wraps its body in
  `withGTKMainThreadForTesting { … }`.** `initGTKForTesting` never enters
  `gtk_main`, so without it `MainThread.run` falls back to libdispatch and the
  adapter's deferred WebKit calls fire on a worker thread at an arbitrary later
  moment. The wrapper installs the real `g_idle_add` dispatch hook for the
  duration — deferred work then queues into the GMainContext and runs when the
  test calls `pumpMainContextForTesting(seconds:)` — and restores the default
  on the way out. The restore is not optional: `MainThread`'s hook is
  process-global and a GTK hook only delivers while something pumps, so one
  left installed hangs every later test that awaits `MainThread.run`. Keep the
  body synchronous for the same reason (it is non-`async` so you can't suspend
  by accident).
- **Keyboard, editing and drag are checked by driving a real app, not by a unit
  test.** `Scripts/verify-driven-input.sh` (and `verify-driven-input.ps1` on
  Windows, which has no bash) builds a probe app, launches it, and drives it
  through select-all / cut / type, cut-and-paste, type → undo → redo, a page
  claiming the undo key with `preventDefault`, typing into a freshly focused
  field, and a multi-segment drag. Run it on a box whose backend you touched;
  the opt-in `driven-input` CI job runs the Linux one weekly.

  Two things it is written around, because both make a run green while proving
  nothing. The obvious editing sequence (⌘A → ⌘C → ⌘V → ⌘X → ⌘Z) **round-trips
  to its starting value**, which is equally consistent with everything working
  and with only select-all working — so every step leaves a *distinct* value.
  And **a quiet environment is not a passing test**: a locked macOS screen has
  no key window and an SSH shell has no interactive desktop, in which every
  shortcut fails exactly as a broken fix would. Hence the leading control
  keystroke, the second macOS control for whether the app can become active at
  all, and `SKIP` rather than `PASS` wherever a backend or session genuinely
  can't run a check. If you add a check, give it the same treatment.

- **swiftformat is enforced by CI.** 4-space indent, 120 columns, `--self remove`.
  Run it before you push.
- **Tests use [swift-testing](https://github.com/apple/swift-testing)** (`@Test`,
  `#expect`), not XCTest.

## Generated files — regenerate, don't hand-edit

A few sources are **base64-embedded copies** of a canonical asset, so the
prebuilt single-file `swift-pwa` CLI can stage them without a SwiftPM resource
bundle beside it. Each has a **drift-guard test** that fails CI if the copy is
stale. If you edit the canonical source, run its regenerate script:

| You edited | Run | Guarded by |
| :--- | :--- | :--- |
| `Sources/SwiftPWACore/Resources/bridge.js` | `Scripts/regenerate-bridge-js.sh` | `BridgeJSEmbedTests` (in `SwiftPWACLITests`) |
| `Vendor/gradle-wrapper/*` (bumping Gradle) | `Scripts/regenerate-gradle-wrapper.sh` | — (no drift guard; run it by hand when you bump the pinned Gradle version) |

> **The bridge.js one bites.** `bridge.js` is the JS runtime injected at
> document-start; a copy is embedded into the CLI (`BridgeJSData`) for the
> Android bundler. Edit `bridge.js`, forget the script, and `swift test` on Core
> stays green — but `SwiftPWACLITests` (and CI's macOS + Linux jobs) fail on the
> `matchesCanonical` drift guard. Regenerate, then run `SwiftPWACLITests`.

## Gotchas that cost a CI round

- **`rm -rf .build/debug` does nothing useful.** It's a symlink to the
  triple-specific dir (`.build/arm64-apple-macosx/debug`). After changing a
  generic function signature you can hit a stale-object *undefined symbol* link
  error; clear it with **`swift package clean`**, not by removing the symlink.
- **Examples pull in env-gated binary tiers.** `Examples/CritterFacts` links
  ONNX Runtime / llama.cpp / Stable Diffusion products only when the matching
  env var is set (`SWIFT_PWA_ONNXRUNTIME`, `SWIFT_PWA_LLAMA`, …), which
  `swift-pwa build` sets from `pwa.json`. If those vars are exported in your
  shell but the vendored binaries aren't present, the example fails with
  `missing required module 'ONNXRuntime'` (or similar). Build it with the vars
  unset (`env -u SWIFT_PWA_ONNXRUNTIME …`) or vendor the libs (the
  `Scripts/vendor-*.sh` scripts fetch them). This is an environment condition,
  not a code error.
- **A malformed `#expect` can crash the Windows compiler.** `swiftc` 6.1.2 on
  Windows has SILGen-crashed on `#expect(someOptionalUInt64 == literal)` — unwrap
  the optional first. (Noted here because it only reproduces on the Windows CI
  box.)

## Vendored binary tiers

The on-device AI backends and ONNX Runtime ship as **checksum-pinned prebuilt
artifacts**, not sources, fetched on demand. You rarely touch these, but if you
bump a model/runtime version, the flow is: build the artifact
(`Scripts/build-llama-*.sh`, `Scripts/vendor-*.sh`), let the matching
`.github/workflows/*-vendor.yml` re-host it, and the checksum auto-pins. The
runtime/CLI never link a system copy — see the per-platform setup docs
([macos](macos-setup.md) / [linux](linux-setup.md) / [windows](windows-setup.md)
/ [android](android-setup.md)) and [remote-ai.md](remote-ai.md).

## Conventions

These are enforced by review (and mostly by CI). Full rationale in
[`CLAUDE.md`](../CLAUDE.md):

- **Every feature works everywhere, with minimal developer requirement.** An
  adopting app should get a capability on every platform it targets without
  per-platform code — ideally without writing anything beyond the standard web
  API. Adopters rarely own all five platforms, so a capability that works on
  three is a gap they can't report. Prefer making an existing web API work
  everywhere over adding a parallel one beside it.
- **Cross-platform parity is the default.** A feature that lands on one backend
  ships the equivalent on the others in the same change, adapted to each
  platform's norms. If parity isn't feasible, document the gap in the relevant
  `docs/<platform>-setup.md` "Known limitations".
- **Docs travel with code.** Every behavioral change updates the docs that
  mention the symbol/flag *in the same change*, plus a `## [Unreleased]` entry in
  [`CHANGELOG.md`](../CHANGELOG.md) with the *why*.
- **README is the pitch; deep docs live under `docs/`.** Don't grow a per-version
  changelog into the README — the Roadmap is forward-looking only, and shipped
  items move to the CHANGELOG.
- **Strict concurrency (Swift 6 tools).** Don't add
  `enableUpcomingFeature("StrictConcurrency")` — under Swift 6 on Linux it's an
  error, not a warning. Use `MainThread.run` (not `await MainActor.run`) on any
  path that may run under `gtk_main` on Linux.
- **Merge commits, titled `Merge: <summary>`.** PRs merge (not squash) with that
  subject convention.

## Before you open a PR

- `swift test` green (including `SwiftPWACLITests`), `swiftformat --lint .` clean.
- New behavior has a test, a doc update, and a CHANGELOG `[Unreleased]` line.
- Ideally verify the real path, not just the unit mock — this project leans on
  end-to-end checks (a real WKWebView, a real device, a live service) to catch
  what mocks can't.

## Before a release

Walk the OS-level cases in [manual-test-cases.md](manual-test-cases.md) — install
machinery, on-device installer flows, and visual smoothness the unit suite can't
reach — and do a full doc sweep (platform setup docs, tutorials, API docs,
version strings), not just the CHANGELOG.
