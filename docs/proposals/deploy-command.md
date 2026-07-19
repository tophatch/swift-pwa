# Proposal: a `deploy` command (build → package → install → launch)

> **Status: proposal, not yet implemented.** Adds `swift-pwa deploy` as a
> first-class verb alongside `build`. Scoped as two work items that land in one
> release: **Cut 1** (android + macos + ios-simulator + linux + windows, plus the
> cross-compile toolchain auto-discovery and doctor-preflight reuse) and **Cut 2**
> (ios *physical device*, on top of the device-targeting + signing groundwork in
> [`ios-free-team-provisioning.md`](ios-free-team-provisioning.md)). The two are
> separable to build and review, but the release ships **both** — a `deploy` that
> silently omits on-device iOS would surprise Apple-first adopters. Origin: real
> consumer handoff notes (see [`deploy.md`](deploy.md), the untracked scratch this
> supersedes).

## The problem

Getting a build onto a device today is `build` **plus by-hand steps** the CLI
doesn't own. On Android that's three: `./gradlew assembleDebug`, `adb install -r`,
`adb shell am start`. A real consumer scripted the whole thing into a ~90-line
`deploy-android.sh` and reported that *keeping* that wrapper — re-deriving the
right toolchain, the APK path, device selection, wireless connect every session —
is the signal that this belongs in the CLI.

Concretely, the friction they hit (all reproducible from the current CLI):

1. **`build --target android` stages but does not assemble.** By design —
   [`AndroidBundler.swift`](../../Sources/SwiftPWACLISupport/Bundlers/AndroidBundler.swift)
   emits an *offline-complete* Gradle project and leaves `./gradlew assembleDebug`
   to the caller. So there is no single command that yields an installable APK,
   let alone an installed-and-launched app.
2. **The cross-compile toolchain must be selected by hand.** `--cross-compile-android`
   requires `export TOOLCHAINS=<the 6.2 xctoolchain bundle id>` so the cross
   compiler matches the Android SDK's Swift exactly. Omit or mismatch it and the
   build fails *deep*, with a non-obvious error. The consumer's script greps
   `Info.plist`'s `CFBundleIdentifier` as a stopgap — but the CLI already knows it
   is targeting the 6.2 Android SDK and could resolve this itself.
3. **Device selection is hand-rolled.** With several devices attached, every
   `adb` call needs an explicit serial; wireless adb rotates the port per session,
   so `adb connect <ip:port>` is a required first step that nothing automates.
4. **No fast path.** Re-testing an install means rebuilding the whole (possibly
   multi-GB — see Non-goals) bundle; there's no "install the artifact I already
   built."

The through-line: `build` produces an artifact; **nothing carries it the last
mile to a running process on a device.** That last mile is per-platform,
error-prone, and exactly what a CLI verb should absorb.

## The shape: `deploy` = the last mile, per platform

```
swift-pwa deploy --target <platform> [--device <serial|udid|ip:port>] [flags]
```

Semantically, for each platform, `deploy` runs `build` → **package/assemble** →
**install** → **launch**:

| Platform | package | install | launch |
|---|---|---|---|
| **android** | `./gradlew assembleDebug` (invoked by the CLI) | `adb -s <serial> install -r <apk>` | `adb … shell am start -n <pkg>/.MainActivity -W` |
| **ios** (sim) | existing `xcodebuild` sim build | `xcrun simctl install booted <app>` | `xcrun simctl launch booted <bundleid>` |
| **ios** (device) | existing signed `xcodebuild` build | `xcrun devicectl device install app --device <udid>` | `xcrun devicectl device process launch` |
| **macos** | existing `.app` bundle | — | `open <build>/<Name>.app` |
| **linux** | existing AppImage / binary | — | run the produced binary |
| **windows** | existing portable `.exe` | — | run the produced `.exe` |

`deploy` is a **new capability**, not an alias — on Android it invokes gradle,
which `build` deliberately never does. Keep that separation: `build` stays
staging-only (offline-complete project, no gradle run); `deploy` owns
assemble+install+launch. That keeps `build` usable in CI/signing pipelines that
run gradle themselves, and keeps `deploy` the one-shot device loop.

## Command surface

```
swift-pwa deploy --target <android|ios|macos|linux|windows>
  --device <serial|udid|ip:port>   # explicit target; honors ANDROID_SERIAL too
  --simulator                      # ios: target a booted simulator (skips signing)
  --no-build                       # install/launch the already-built artifact
  --launch / --no-launch           # default: launch (default true)
  --reinstall / -r                 # default on: adb install -r / replace
  --release                        # android: assembleRelease (default debug)
  [pass-through build flags: --path, --android-abis, --team, …]
```

- **`--device`** accepts an adb serial, an `ip:port` (wireless), or an iOS UDID —
  disambiguated by target. When it looks like `ip:port`, run `adb connect` first
  (particular #1 in the handoff notes; the daily friction point).
- **`--no-build`** is the fast path: skip build+package, resolve the existing
  artifact by its known output path, install+launch. Pairs with `--launch` for a
  pure "relaunch what's installed" when even install is skippable (android:
  `am start` only).
- Build-relevant flags pass through to the underlying `build` (`--path`,
  `--android-abis`, `--team`, `--simulator`, output dir, etc.) so `deploy` is a
  true superset, not a second flag vocabulary to learn.

## Cut 1 — everything but on-device iOS

The high-payoff / low-risk core. Ships:

**android** — the whole reason. `deploy`:
1. Runs the doctor preflight for `.android` (below), failing fast on missing
   NDK / JDK / adb with the *same* message `doctor`/`build` already print.
2. Resolves + exports the cross-compile toolchain (below) so `TOOLCHAINS` is no
   longer a manual export.
3. `build --target android --cross-compile-android [--android-abis …]`.
4. Invokes `./gradlew assembleDebug` (or `assembleRelease` under `--release`) in
   the staged project — a new step the CLI now owns.
5. Resolves the APK path from the staged project layout (the consumer's script
   hardcodes `build/App-android/app/build/outputs/apk/debug/app-debug.apk`; the
   CLI can derive it from the bundler's known output dir + variant).
6. `adb connect` (if `--device` is `ip:port`) → device selection (below) →
   `adb -s <serial> install -r <apk>` → `am start -n <pkg>/.MainActivity -W`.

**ios simulator** — a clean, cheap win worth shipping in the first cut. Existing
`--simulator` build already skips signing and produces a `.app`; deploy adds
`simctl install booted` + `simctl launch booted`. (Booting/selecting a specific
sim can be a later refinement; "booted" covers the common case.)

**macos / linux / windows** — trivial: `open` the `.app`, or run the produced
binary. Low value individually but they make `deploy` uniform across every target
the project already builds, and cost almost nothing.

### Cross-cutting fix folded into Cut 1: toolchain auto-discovery

Independent of `deploy`, worth doing on its own — but `deploy` is the forcing
function. When `--cross-compile-android` is set and `TOOLCHAINS` is unset (or
doesn't match the SDK's Swift), resolve the matching `.xctoolchain`:

- Enumerate `~/Library/Developer/Toolchains/*.xctoolchain`, read each
  `Info.plist` `CFBundleIdentifier`, pick the one matching the Android SDK's Swift
  version (the CLI knows the target SDK). Set `TOOLCHAINS` for the child build.
- Print a status line in the existing `build` style
  (`swift-pwa: cross-compile toolchain <id>`), matching how `--team` /
  `--device` already announce resolution.
- If none matches: fail fast with a clear message (which toolchains were found,
  which version is needed) instead of the current deep, cryptic build failure.

This lives in the `build` cross-compile path (benefits `build` users directly),
and `deploy` inherits it.

### Cross-cutting: reuse `doctor`'s preflight

Nearly free. [`Doctor`](../../Sources/SwiftPWACLISupport/Commands/Doctor.swift)
already exposes `requiredToolGaps(for:)` per target, and `build` already calls it
via `reportToolGaps`. `deploy` calls the same path up front so a missing
NDK/JDK/adb (android) or `xcrun`/simulator (ios) fails fast with the identical
message — no new preflight vocabulary.

## Cut 2 — on-device iOS

Higher value *and* higher cost: physical-device iOS deploy needs a **signed**
`.app` and `devicectl` install/launch, and the sharp edge is provisioning. This
is separable work but the release gates on it — see Status.

Cut 2 stands on groundwork already designed in
[`ios-free-team-provisioning.md`](ios-free-team-provisioning.md):

- That proposal notes **"no device targeting exists today"** and specifies the
  exact primitive `deploy` needs: a `--device <UDID>` flag with **auto-detect via
  `xcrun devicectl list devices --json-output -`** (one physical device → use it
  and print a status line; zero or several → fail fast asking for `--device`).
  `deploy --target ios` (no `--simulator`) reuses that resolver verbatim.
- Signing: `deploy` passes `--team` / `--allow-provisioning-registration` through
  to the build. The signed `.app` produced by the existing `xcodebuild` path is
  what `devicectl device install app` consumes.
- Launch: `xcrun devicectl device process launch --device <udid> <bundleid>`.

Sequencing note: if `ios-free-team-provisioning` lands first, Cut 2 is mostly
wiring `devicectl install/launch` after its build. If not, Cut 2 pulls in the
`--device`/`devicectl list devices` resolver itself (it's small and self-contained
per that proposal). Either way the device-resolution logic should be **shared**,
not duplicated between the two proposals.

## Design decisions

1. **Device selection follows adb's own rules — and nothing more.** Sole
   connected device by default; honor `--device` and `ANDROID_SERIAL`; **clear
   error, not a silent pick, when several are attached and none is chosen.** This
   is particular #2 from the notes, and it's correct. Deliberately **drop** the
   consumer script's "prefer a tablet-looking device" heuristic (its `for … *:* `
   wireless-preference and `TAB_SERIAL` fallback) — that's environment-specific
   magic and exactly the silent-pick behavior we're arguing against. The CLI's job
   is to be predictable; ambiguity is a fail-fast, not a guess.
2. **`build` stays staging-only; `deploy` owns assemble+install+launch.** Rather
   than teach `build --target android` to run gradle (which would break the
   CI/signing flows that run gradle themselves), the gradle invocation is a
   `deploy` step. `build`'s contract — "an offline-complete project you can
   `gradlew` yourself" — is preserved.
3. **`deploy` is a superset of `build`, not a parallel flag set.** Build flags
   pass through; `deploy`-only flags (`--device`, `--no-build`, `--launch`,
   `--reinstall`) are the last-mile additions. One mental model.
4. **Default variant is debug.** The device loop is a debug loop; `--release`
   opts into `assembleRelease` (which needs the signing env the bundler already
   documents). Same for iOS: `--simulator` is unsigned; device is signed.
5. **`--no-launch` exists** because CI smoke tests and "install for later" both
   want install-without-foreground. Launch-by-default matches the interactive
   loop the command is built for.

## Affected scope

- **New:** `Sources/SwiftPWACLISupport/Commands/Deploy.swift` (the verb), added to
  `SwiftPWACLIRoot.subcommands`
  ([`SwiftPWACLIRoot.swift:35`](../../Sources/SwiftPWACLISupport/SwiftPWACLIRoot.swift#L35)).
- **New:** small install/launch helpers per platform (adb / simctl / devicectl /
  open), shelling out via the existing `Shell.run` / `Shell.capture` pattern used
  throughout the bundlers and `IOSSigning`.
- **Changed (Cut 1 cross-cutting):** the `--cross-compile-android` path in
  `Build.swift` gains toolchain auto-discovery (shared, so `build` benefits).
- **Reused:** `Doctor.requiredToolGaps(for:)`; the android output-path/layout the
  `AndroidBundler` already establishes; (Cut 2) the `--device` /
  `devicectl list devices` resolver from `ios-free-team-provisioning`.
- **Docs (travel with the code):** a `## [Unreleased]` CHANGELOG entry (the
  *why*); a `deploy` section in the README feature list + a dedicated
  `docs/deploy.md` walkthrough (per the README-is-marketing / deep-docs-under-docs
  convention); the feature matrix gains a `deploy` row with per-platform footnotes
  (ios-device requires signing; linux/windows are "run the binary"). `doctor` docs
  note that its preflight now also gates `deploy`.

## Non-goals / deferred

- **Web-asset excludes (`.swiftpwaignore` / `exclude` glob).** The same handoff
  notes raise a real, arguably bigger papercut: `web.directory` is copied
  *wholesale*, so a 2.2 GB `web/` → a 2.3 GB APK, and every build re-copies the
  lot. `deploy` makes this *more* visible (multi-GB sideload every loop), so it's
  a natural companion — but it's a **separate change** (bundler staging, not the
  CLI verb) and gets its own proposal. Tracked alongside, not folded in.
- **Release-signing automation for Android** beyond passing through the existing
  keystore env the bundler documents.
- **Simulator boot/creation orchestration** — Cut 1 targets an already-booted
  sim; picking/booting a named sim is a later refinement.
- **Linux/Windows remote deploy** (ssh/scp to another box) — out of scope; these
  targets just run the local binary.

## Verification plan

Consistent with how this repo verifies device work (real hardware, not just
compiles):

- **android**: end-to-end on a real device over wireless adb — `deploy --target
  android --device <ip:port>` cold, then `--no-build` fast path, then the
  multi-device fail-fast (attach two, confirm the clear error). Toolchain
  auto-discovery: unset `TOOLCHAINS`, confirm the CLI resolves + announces it and
  the build succeeds.
- **ios simulator**: `deploy --target ios --simulator` installs + launches on a
  booted sim.
- **ios device (Cut 2)**: `deploy --target ios --device <udid> --team … 
  --allow-provisioning-registration` installs + launches on a tethered phone;
  device auto-detect with one phone attached; fail-fast with zero/several.
- **macos**: `.app` opens.
- **linux/windows**: builds run (CI-compile + a manual box run, matching the
  existing per-backend verification recipe).
