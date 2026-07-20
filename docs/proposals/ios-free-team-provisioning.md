# Proposal: `build --team` for free personal Apple Developer accounts (+ Xcode 16 scheme regression)

> **Status: implemented.** `--allow-provisioning-registration` on `build`
> (forwarded by `deploy --target ios`) internalises the free-team minter:
> `PersonalTeamProfileMinter` generates the throwaway app project (with the
> explicit Xcode-16 `.xcscheme`), builds it against the device resolved through
> the shared `IOSDeviceResolver`, and hands the minted profile + entitlements to
> the existing embed + re-sign path. The pure project-file generation is
> unit-tested (the pbxproj parses as an OpenStep plist; the scheme's
> `BlueprintIdentifier` resolves to the target) and the generated project loads
> in real `xcodebuild` (`-list` / `-showBuildSettings`); the live
> device-registration/mint step is left to the adopter (it needs a connected
> free-team device and mutates the Apple account). Docs:
> [../ios-setup.md](../ios-setup.md) (Free personal teams) + [../deploy.md](../deploy.md).
> The sections below are kept as the design record.
>
> The provisioning + entitlements signing story was landed in 0.7.0–0.7.1
> (`--provisioning-profile`, `--entitlements`, `--team`). This proposal covered
> the remaining gap: **`--team` did not work for free personal-team accounts**
> because no portal profile exists for it to find, and separately documents an
> **Xcode 16 regression** that breaks the throwaway-project workaround apps had
> been using in the interim.
>
> A code-level review against the current `Sources/SwiftPWACLISupport` found
> one gap the original draft didn't account for: there was no device-UDID
> concept anywhere in the CLI (`IPABundler` always builds against the
> untethered `generic/platform=iOS`, and `docs/ios-setup.md` already admits
> "the CLI's device path is incomplete"). The minter needs a concrete device
> to register. The four open questions from the original draft are answered in
> **Design decisions**.
>
> **Update (deploy Cut 2 shipped this prerequisite).** `swift-pwa deploy`
> ([docs/deploy.md](../deploy.md), proposal
> [deploy-command.md](deploy-command.md)) now **implements the device-targeting
> layer this proposal scoped out** — the physical-iOS-device resolver over
> `xcrun devicectl list devices --json-output -` (sole *connected* device by
> default, `--device <udid|name>` to choose, fail-fast listing paired devices on
> none/several) lives in `Deploy.swift` (`parseDevicectlDevices` /
> `resolveIOSDevice`, unit-tested), and the on-device **install + launch**
> plumbing (`devicectl device install app` / `process launch
> --terminate-existing`) ships there too. So the remaining work here is *only*
> the minter (§ Proposed fix), and it should **reuse** deploy's resolver rather
> than re-add a `--device` auto-detect to `build` — see the reframed
> **Prerequisite gap** section. The gating fact that motivates the whole
> proposal is now concretely visible in deploy: a free-team machine has a valid
> "Apple Development" identity but **no provisioning profile** for the bundle
> id, so `deploy --target ios --team …` gets as far as the `devicectl install`
> call and then can't produce an installable signed `.app` — exactly what the
> minter closes.

## Background: what landed in 0.7.x

`0.7.0` added `--provisioning-profile <path>` + `--entitlements <path>` so apps
could obtain a profile out-of-band and pass it in. `0.7.1` added `--team <TEAMID>`
as a convenience: it looks for an already-installed matching profile and selects the
right identity automatically. For **paid developer accounts**, `--team` is
sufficient — Apple's portal pre-generates wildcard or app-specific profiles that
are downloaded to `~/Library/MobileDevice/Provisioning Profiles/` by Xcode,
and `--team` finds them there.

For **free personal teams** (the `XXXXXX` team Xcode creates when you add a
personal Apple ID), no such portal profile exists. Personal teams can only obtain
a profile by building an app-typed target with `CODE_SIGN_STYLE=Automatic` against
a specific device — Xcode then registers the device, creates the App ID, and
emits `embedded.mobileprovision` inside the built `.app`. Because the swift-pwa
product is a SwiftPM executable target (not an app target), this automation never
fires for it.

## What apps do today: the "minter" workaround

Apps using a free team carry a shell script that synthesises a one-file iOS app
project with the same bundle ID, builds it to the target device with
`-allowProvisioningUpdates -allowProvisioningDeviceRegistration`, pulls the
resulting `embedded.mobileprovision` out of the built `.app`, and passes it to
`swift-pwa build --provisioning-profile … --entitlements …`. Roughly:

```bash
# 1. generate a throwaway Xcode project
mkdir -p Minter.xcodeproj/xcshareddata/xcschemes Minter
cat > Minter/App.swift << 'SWIFT'
import SwiftUI
@main struct MinterApp: App { var body: some Scene { WindowGroup { Text("") } } }
SWIFT
# ... write project.pbxproj and Minter.xcscheme (see below) ...

# 2. build it — Xcode registers the device + emits a profile
xcodebuild -project Minter.xcodeproj -scheme Minter \
  -destination "id=$DEVICE_UDID" -configuration Release \
  -derivedDataPath ./dd \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build

# 3. hand the profile to swift-pwa
PROFILE=dd/Build/Products/Release-iphoneos/Minter.app/embedded.mobileprovision
security cms -D -i "$PROFILE" > profile.plist
/usr/libexec/PlistBuddy -x -c "Print :Entitlements" profile.plist > ents.plist
swift-pwa build --target ios \
  --sign "$IDENTITY" \
  --provisioning-profile "$PROFILE" \
  --entitlements ents.plist
```

This works, but it is friction every free-team adopter has to rediscover and
maintain. The 7-day expiry of personal-team profiles means the script must be
re-run weekly for any active development on a device.

## Xcode 16 regression: explicit xcscheme required

Prior to Xcode 16, `xcodebuild -scheme <name>` would synthesise a usable scheme
from `project.pbxproj` alone if no `.xcscheme` file was present. Xcode 16 removed
this behaviour. Building the minter project now fails with:

```
IDERunDestination: Supported platforms for the buildables in the current scheme is empty.
```

… unless an explicit `xcshareddata/xcschemes/Minter.xcscheme` is written alongside
the `project.pbxproj`. The required minimal scheme:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.7">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries>
      <BuildActionEntry buildForRunning="YES" buildForArchiving="YES">
        <BuildableReference BuildableIdentifier="primary"
          BlueprintIdentifier="A30" BuildableName="Minter.app"
          BlueprintName="Minter" ReferencedContainer="container:Minter.xcodeproj"/>
      </BuildActionEntry>
    </BuildActionEntries>
  </BuildAction>
  <LaunchAction buildConfiguration="Release"
    selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB"
    selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB">
    <BuildableProductRunnable runnableDebuggingMode="0">
      <BuildableReference BuildableIdentifier="primary"
        BlueprintIdentifier="A30" BuildableName="Minter.app"
        BlueprintName="Minter" ReferencedContainer="container:Minter.xcodeproj"/>
    </BuildableProductRunnable>
  </LaunchAction>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
```

Anyone running the minter pattern on Xcode 16+ without this file will see a
silent failure where `xcodebuild` exits 0 but produces no `embedded.mobileprovision`.

## Prerequisite: device targeting (now shipped in `deploy`)

The manual minter script takes `$DEVICE_UDID` as a given — the developer looks
it up once (Xcode's Devices window, `xcrun devicectl list devices`, or
`idevice_id -l`) and exports it. Internalising the minter means swift-pwa has to
obtain that UDID itself.

**This is now done** — `deploy` (Cut 2) resolves a physical iOS device exactly as
the original draft of this section proposed:

- The resolver shells out to `xcrun devicectl list devices --json-output -`
  (following the existing `Shell.capture` idiom), keeps physical iOS/iPadOS
  devices, and derives connected state from `connectionProperties.tunnelState`.
  It lives in `Deploy.swift` as `parseDevicectlDevices` (pure, unit-tested) +
  `resolveIOSDevice`.
- Selection: the sole *connected* device by default; `--device <udid|name>` to
  choose (passed through even when currently disconnected — `devicectl` brings
  the tunnel up); zero or several connected → fail-fast listing what's paired,
  asking for `--device`. This is the same no-silent-pick rule the draft
  specified, mirroring the Android selection in the same file.

So the minter no longer needs to *add* device targeting — it needs to **reuse
it**. Two things follow for the implementation:

1. **Share the resolver, don't duplicate it.** Extract `parseDevicectlDevices` /
   `resolveIOSDevice` from `Deploy` into a small shared helper (e.g.
   `IOSDeviceResolver`) that both `deploy` and the minter call. Re-adding a
   separate `--device` auto-detect to `Build.swift` would fork the exact logic
   this file argued should be shared.
2. **Decide where the minter is driven from.** The minter must run *before* the
   `IPABundler` build so a profile exists to sign with. Cleanest given deploy:
   `deploy --target ios --team … --allow-provisioning-registration` resolves the
   device (it already does), mints against that UDID, then runs the signed
   build + `devicectl` install it already runs. `build --target ios --team …
   --allow-provisioning-registration` should keep working standalone (not
   everyone uses deploy), so `Build` still needs the `--allow-provisioning-registration`
   flag and a `--device` (feeding the minter's `xcodebuild -destination "id=…"`)
   — but both resolve through the shared helper above, and `deploy` forwards its
   already-resolved UDID to `build` via that `--device`.

`IPABundler` still builds against the untethered `generic/platform=iOS`
(`IPABundler.swift:54-56`); the minter's `-destination "id=…"` is on its own
throwaway project, so none of this changes `IPABundler`'s main build phase or
signing model.

This keeps the common case — one phone plugged in over USB, `--team` +
`--allow-provisioning-registration` — a no-manual-UDID-lookup invocation,
strictly better DX than the hand-rolled script it replaces.

## Proposed fix

Extend `--team` to work for free personal accounts by internalising the minter
pattern behind an explicit opt-in flag (see **Design decisions #1** for why it's
a separate flag rather than automatic under `--team` alone). When `--team` and
`--allow-provisioning-registration` are both given and no matching installed
profile is found, fall through to the automatic-minter path:

1. **Resolve the target device** — via the shared resolver already shipped in
   `deploy` (`resolveIOSDevice`; see the Prerequisite section), not a new
   auto-detect in `build`.
2. **Synthesise a throwaway app project** in a temp directory — the same
   `project.pbxproj` + explicit `xcscheme` (required for Xcode 16+) that apps
   currently write by hand — using the app's bundle ID from `pwa.json` and
   the supplied `--team` value. Written under `FileManager.default.temporaryDirectory`
   with a UUID-suffixed name and cleaned up afterward, matching the existing
   temp-scratch idiom in `IPABundler.swift:254-257` / `316-319`.
3. **Build it** to the target device with `-allowProvisioningUpdates
   -allowProvisioningDeviceRegistration`, via `Shell.run` (inherited stdio, so
   the ~30–60s `xcodebuild` run streams to the terminal exactly like the main
   build phase already does — no new progress-reporting mechanism needed; see
   **Design decisions #2**). This registers the device if new and emits an
   `embedded.mobileprovision` in the product.
4. **Extract the entitlements** from the profile — reuse `IOSSigning`'s
   existing `security cms -D` + `PropertyListSerialization` decode
   (`IOSSigning.swift:132-140`, `entitlements(from:)` at line 97) rather than
   shelling to `PlistBuddy` separately; the pure logic is already there and
   already unit-tested.
5. **Continue** with the existing embed + re-sign path, exactly as if
   `--provisioning-profile` and `--entitlements` had been passed explicitly.

### Sketch of the change

```swift
// Build.swift, in the existing --team block (around line 225), after the
// existing IOSSigning.resolve(...) lookup:
if let team, !simulator {
    let bundleID = pwa.ios?.bundleIdentifier ?? pwa.id
    var resolved = await IOSSigning.resolve(team: team, bundleID: bundleID, scratch: outputDir)

    if resolved.profile == nil, allowProvisioningRegistration {
        // Shared with deploy — the resolver `deploy` already ships (extract
        // `resolveIOSDevice`/`parseDevicectlDevices` from Deploy into a shared
        // `IOSDeviceResolver` rather than re-implementing here).
        let deviceUDID = try await IOSDeviceResolver.resolve(explicit: device).udid
        let minter = PersonalTeamProfileMinter(
            bundleID: bundleID,
            teamID: team,
            deviceUDID: deviceUDID,
            scratch: outputDir
        )
        resolved = try await minter.mint()  // writes throwaway project, builds it, extracts entitlements
    }
    // ... existing signIdentity / profileURL / entitlementsURL fill-in unchanged
}
```

`PersonalTeamProfileMinter.mint()` would:
- write the throwaway project + xcscheme to a temp dir (using `FileManager`,
  following the existing `IPABundler` scratch-dir idiom)
- invoke `xcodebuild` via `Shell.run` with `-allowProvisioningUpdates
  -allowProvisioningDeviceRegistration`
- locate the resulting `embedded.mobileprovision` and decode it via the
  existing `IOSSigning` plist-decode helpers
- clean up the temp dir on completion (success or failure)

Following the existing `IOSSigning.swift` split (`IOSSigning.swift:14`: "The
parsing / matching is split into pure functions so it's unit-testable without a
real keychain or on-disk profiles"), the pbxproj/xcscheme template-string
generation should be a pure function (`PersonalTeamProfileMinter.projectFiles(bundleID:teamID:) -> [String: String]`
or similar) so it gets the same unit-test treatment as `IOSSigningTests.swift` —
the actual `xcodebuild` invocation against a real free-team account and device
stays untested, consistent with how `IPABundler`'s real build path is untested
today.

## Affected scope

- The minter logic is macOS-only (it shells out to `xcodebuild`), so it would
  live behind `#if os(macOS)` and only engage on the build machine — not in
  the app itself.
- The generated `xcscheme` format is stable since Xcode 14; targeting
  `LastUpgradeVersion = 1600` (Xcode 16) is forward-compatible.
- Free-team profiles expire in 7 days. No change needed here — users already
  must re-run the build weekly; with this change they just run `swift-pwa build`
  rather than a separate minting script.
- New public surface: `--allow-provisioning-registration` (and `--device`,
  which already exists on `deploy` and would be added to `build` for the
  standalone `build --team …` path) on `swift-pwa build`. Per the docs
  convention in `CLAUDE.md` ("Anything affecting the public Swift API or
  `pwa.json` schema → README.md's API / configuration sections"), both need a
  line in [README.md](../../README.md) and a `## [Unreleased]` CHANGELOG entry
  alongside the implementation, plus updates to
  [docs/ios-setup.md](../ios-setup.md) — including striking or narrowing its
  existing "the CLI's device path is incomplete" caveat.
- Refactor: extract `deploy`'s `resolveIOSDevice` / `parseDevicectlDevices`
  (currently in `Deploy.swift`) into a shared `IOSDeviceResolver` so the minter
  and `deploy` share one implementation (they already agree on the selection
  rules — this just makes them one code path).

## Design decisions

1. **`--team` implicit fallthrough vs. explicit flag → explicit flag,
   `--allow-provisioning-registration`.** `--team` today is documented as
   read-only/local (`Build.swift:74-83`: "it does not create one") and never
   touches the network. Minting does two things `--team` alone never has:
   it runs a ~30-60s `xcodebuild` invocation, and it registers the device with
   Apple's portal. Folding that silently into `--team` would make an
   already-slow-sounding flag surprising the first time it hits a machine with
   no cached profile. A separate, explicitly-named flag —
   `--allow-provisioning-registration`, deliberately echoing `xcodebuild`'s own
   `-allowProvisioningDeviceRegistration` so it reads as "the same consent
   you'd give Xcode directly" — keeps `--team` alone exactly as fast and local
   as it is today, and doubles as the answer to #3 below. Rejected the
   `--mint-profile` / `provision` subcommand alternative from the original
   draft: it reintroduces the two-step friction (mint, then build) this
   proposal exists to remove.
2. **Progress output → stream it, no new mechanism.** `Shell.run`
   (`MacAppBundler.swift:242-262`) already inherits stdio for the *existing*
   `xcodebuild` build phase in `IPABundler.swift:72` specifically so a long
   build doesn't look hung. The minter's `xcodebuild` call should use the same
   `Shell.run`, so its output streams identically — no spinner, no
   suppression, no new code path to maintain.
3. **Device registration consent → the `--allow-provisioning-registration` flag
   *is* the consent.** Resolved by decision #1: the network-touching,
   portal-registering path only ever runs when the user has passed that flag
   explicitly. `--team` by itself never triggers it, so there's no case where
   a device gets silently registered.
4. **Windows/Linux CI → no new gating needed; this was already true.** The
   entire iOS device/simulator build path already requires `xcodebuild` and
   therefore a Mac (see `CLAUDE.md`: "Apple does not ship a Swift SDK that
   `swift build --triple` can target for iOS") — this proposal doesn't change
   that boundary. Document the pre-mint-and-commit workaround (mint once on a
   Mac, commit the `.mobileprovision`, point CI's `--provisioning-profile` at
   it) in `docs/ios-setup.md`'s "Known limitations" section, matching the
   existing pattern used for other macOS-only functionality in that file.
