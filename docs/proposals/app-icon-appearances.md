# Proposal: app icon appearances and alternate icons

Status: **de-risking** (#314), 2026-10-21. All five platforms in one change.
All four probes are measured on real hardware, including the macOS
alternates options. See
[De-risking](#de-risking-before-any-cli-code).

## The problem

An app ships one 1024×1024 PNG, and every appearance shows that one picture.
iOS 18 and macOS 26 both draw a dark and a tinted icon when the app supplies
them, and fall back to the light art when it doesn't. iOS (and, with caveats,
Android) also let the person choose an alternate icon in the app's settings.
A consumer has artwork ready for both features (#314).

Neither feature has a web API. Appearances are build-time only, so they belong
in `pwa.json`. Picking an icon happens at runtime, so it needs a bridge command.

## Proposed manifest

`icon` accepts either a path, as it does today, or an object with one path per
appearance. The per-target `icon` overrides accept the same two forms.

```json
"icon": { "light": "../public/icon.png", "dark": "../public/icon-dark.png", "tinted": "../public/icon-tinted.png" },
"alternate_icons": [
  { "name": "sketch", "icon": { "light": "../public/sketch.png", "dark": "../public/sketch-dark.png", "tinted": "../public/sketch-tinted.png" } }
]
```

- **One `icon` key in two forms, rather than the issue's separate
  `icon_appearances`.** `ios.icon` and `macos.icon` already exist because the
  two platforms want different art (iOS masks the icon; a pre-26 Mac doesn't).
  A separate key would need to be repeated under every target to stay
  overridable. One key in two forms keeps "which art for this target" in one
  place.
- **`dark` and `tinted` are optional.** A platform that has no use for a
  variant ignores it, and a variant that isn't supplied falls back to the
  system's own treatment of the light art, as it does today.
- **Appearance art is full-bleed on every platform.** iOS, macOS 26+ and
  Android's adaptive icons all apply their own mask. See the macOS row for why
  pre-masked Mac art stops being needed on this route.
- **`name` is the stable id** that the page stores and passes back. It must be
  a valid asset-catalog name and Android resource suffix, i.e. `[a-z0-9_]+`,
  and the build checks that.

## Proposed bridge

```js
const { current, alternates, supported } = await __SWIFT_PWA__.invoke('app.icon.list');
// current: null (the primary) or an alternate's name; alternates: ['sketch']
await __SWIFT_PWA__.invoke('app.icon.set', { name: 'sketch' }); // null restores the primary
```

The same calls are available from Swift as an `AppContext` requirement. Its
default implementation reports `supported: false`, so existing backends
compile unchanged. Three-segment names follow `ai.vision.*`.

- **`supported: false` lets the page leave the setting out** rather than show a
  control that does nothing. `alternates` is listed even when switching isn't
  supported, so the page can still describe what exists.
- **`set` on an unsupported platform is an error (`E_UNSUPPORTED`)**, not a
  silent no-op. A page that skipped the `supported` check should find out.

## Per platform

| Platform | Appearances | Alternates | Evidence |
| --- | --- | --- | --- |
| iOS / iPadOS | `actool` appearance variants in the `AppIcon` set | `actool --alternate-app-icon <name>`, plus `setAlternateIconName` at runtime | **Build measured** (Xcode 27.1): dark + tinted renditions for both the primary and an alternate; `CFBundleAlternateIcons` written into both `CFBundleIcons` and `CFBundleIcons~ipad`. Runtime switch and home-screen dark/tinted **work** on an iPhone (R1). |
| macOS | A generated Icon Composer `.icon`, one layer per appearance | No supported persistent switch; see below | **Measured**: the asset-catalog route compiles but **drops dark and tinted without a warning** (one rendition). A generated `.icon` keeps all three; rendered under the system's `RegularDark` icon theme it draws the dark art in the system mask, while a plain `.icns` control stays light. Tinted confirmed too (R2). |
| Android | Themed icon = an adaptive icon's `<monochrome>` layer | One `<activity-alias>` per icon, switched with `setComponentEnabledSetting` | **Measured on One UI** (R3): aliases switch in ~2 s without killing the app; the themed icon draws from `<monochrome>`. |
| Windows | MSIX theme-qualified logo assets (`altform-unplated` / `altform-lightunplated`) could carry light/dark taskbar art | None | **Measured** (R4): with a `resources.pri`, the taskbar shows `altform-unplated` in dark mode and `altform-lightunplated` in light mode. |
| Linux | None: the icon theme spec has no per-app dark variant | None | — |

### macOS: why a generated `.icon`

`actool` with an `.appiconset` for `macosx` accepts appearance entries in
`Contents.json` and then compiles one rendition. Nothing reports the drop. The
only route that keeps them is an Icon Composer `.icon`. The CLI can write one
from PNGs: one layer per appearance, each shown in only its own appearance via
`hidden-specializations`, with glass, specular, shadow and translucency off so
flat art comes through unaltered.

The same compile also emits a fallback `AppIcon.icns` for macOS before 26. It
is **already masked** (transparent corners, the standard margin) from the
full-bleed art. So on this route a Mac app needs no pre-masked `macos.icon`
for macOS 15 either. Its largest rendition is 256 px, against 1024 from today's
`sips` pipeline, which is the cost.

The route is used only when `dark` or `tinted` is set. An app with a single
string `icon` keeps today's `.icns` pipeline exactly, so pre-masked Mac art
someone already ships doesn't get a second mask.

### macOS alternates: measured

macOS has no alternate-icon API. The macOS 27 SDK's AppKit headers have
nothing for it (only UIKit does), and `actool --alternate-app-icon` for
`macosx` compiles the alternate's renditions into the car but writes no
alternate-icon keys into `Info.plist`. The icon shows in two places fed from
different sources:

| Surface | Source |
| --- | --- |
| Finder, Launchpad/Apps, Spotlight, Get Info, a quit app's Dock tile | The bundle's icon, via LaunchServices |
| A running app's Dock tile, ⌘-Tab, the About panel | `NSApp.applicationIconImage` |

The options, each probed on macOS 27 with a control:

1. **`supported: false`.** The page leaves the setting out.
2. **Set `NSApp.applicationIconImage` at each launch.** **Measured:** the
   alternate `.icon`, loaded by name from the app's own catalog, draws its
   flat *light* art under every appearance and every system icon theme. The
   control, an ordinary image set with a dark variant in the same catalog,
   draws light under `aqua` and dark under `darkAqua`, so the lookup itself
   does follow appearance. A runtime switch therefore shows the light art in
   dark and tinted mode. It also leaves Finder, Launchpad and Spotlight on the
   primary, and the tile reverts once the app quits (from the API's design;
   the Dock wasn't captured).
3. **An `NSDockTilePlugIn`.** Not probed. It's a second compiled product that
   only extends (2)'s Dock tile past quit, and it draws a flat image too.
4. **`NSWorkspace.setIcon(_:forFile:)` on the app's own bundle.**
   **Measured:** it succeeds from inside the app and writes `Icon\r` into the
   bundle root. `codesign --verify --strict` then fails ("resource fork,
   Finder information, or similar detritus not allowed"), although the
   un-quarantined app still relaunches. The custom icon is one flat image in
   light, dark *and* tinted (the system doesn't even tint it). `setIcon(nil)`
   removes the file and restores both the signature and the appearances.
   Unmeasured: whether Gatekeeper refuses a notarized Developer ID app in that
   state (the probe's Apple Development signature is rejected by `spctl`
   before and after, so it can't tell). Also inferred, not measured: the
   choice is lost whenever an update replaces the bundle, so the app would
   re-break its own seal at every launch to restore it, and App Store
   installs are root-owned, so the write would fail there.

So every option that does something loses dark and tinted, which is what this
issue adds, and covers only some of the places the icon appears.
Recommendation: **`supported: false`**, documented in `docs/macos-setup.md`
as a known limitation with the reason.

### Android

- **Alternates:** the generated manifest moves the launcher intent filter from
  the main activity to one `<activity-alias>` per icon, and `set` enables one
  alias and disables the rest with `DONT_KILL_APP`. R3 measured launcher
  delay, process survival and pinned shortcuts.
- **Themed icons** need adaptive icons, which `AndroidSection.icon` doesn't
  model. The light art becomes the foreground, inset so the full-bleed art
  fills the 72 dp safe zone. The `tinted` PNG becomes `<monochrome>` with the
  same inset, because R3 showed that layer uses the same canvas. Android reads only the monochrome layer's **alpha**, so a
  tinted PNG without transparency would come out as a solid tile. The build
  can read the PNG's colour type from its header and warn, with no image
  library.

## Not this round

- **Icon Composer artwork as input** (an adopter's own `.icon` with glass and
  layers). It would be a natural extension of the macOS route, but no consumer
  has asked for it.

## Scope

**Every platform in one change**, per the parity rule. That includes Android
themed icons and the Windows MSIX's light/dark taskbar art. Linux has no
mechanism and reports `supported: false`. Nothing is built until the
de-risking below has answered its questions.

## De-risking, before any CLI code

Each probe answers one question, by hand on a fresh `swift-pwa init` app (the
examples are not the scaffold), with a control that has to succeed.

| # | Question | Method | Control | Status |
| --- | --- | --- | --- | --- |
| R1 | Does `setAlternateIconName` switch an icon compiled by our `actool` call, in a bundle not built by Xcode? Do dark and tinted reach the home screen? | Simulator, then an iPhone: the probe app's asset catalog recompiled with an alternate, a custom command calling the API, home-screen screenshots per appearance | The primary icon shows before switching | **works**: simulator, then an iPhone |
| R2 | Does macOS draw the light and tinted art from the generated `.icon`, and which macOS alternate option holds up? | A second Mac: switch the system icon theme and render; measure the Dock-only switch and an `NSDockTilePlugIn` built with `swiftc` | A `.icns`-only bundle that doesn't follow the theme | **appearances work**; alternates: every workable option loses dark/tinted |
| R3 | Android: how does One UI handle switching `<activity-alias>`es (delay, app killed, pinned shortcut), and does it draw a themed icon from a `<monochrome>` layer? | A Samsung foldable: hand-edited Gradle project from a scaffolded app; switch from inside the app with `DONT_KILL_APP` | The launcher icon before switching; the theming setting off | **both work** on One UI |
| R4 | Windows: does the taskbar pick theme-qualified MSIX logos (`altform-unplated` / `altform-lightunplated`) per light/dark mode? | An x64 Windows 11 machine: hand-built MSIX, toggle the system theme, screenshot the taskbar and Start | An unqualified-only MSIX | **works**: the taskbar follows the theme live |

### What the probes found

**R1, iOS (iPad mini simulator, iOS 27.1, fresh `init` app from the 0.11.8 CLI).**

- The switch works on the bundle our `actool` call compiled, and survives a
  simulator reboot. `alternateIconName` then reports it.
- iOS confirms the change with its own alert, and the alert draws the
  alternate's **dark** rendition when the system is dark. So the system
  resolves our dark art.
- The home screen kept every icon (Apple's included) in its light style. Since
  iOS 18 the home screen's icon style (Light / Dark / Automatic / Tinted) is a
  setting of its own, not the system appearance, and the simulator doesn't
  expose it.
- **On an iPhone (iOS 27, free personal team, re-signed after
  patching):** the home screen's Dark style drew the dark art and its Tinted
  style drew the tinted art (half-black/half-white art kept its split, so it
  wasn't the light art auto-tinted). `set` settled only after the alert's OK,
  and the alternate's own appearances applied.
- **Clear, on the same iPhone, two builds.** (A) The classic `.appiconset`
  with dark and tinted entries: the Clear style kept the tinted art's split,
  so Clear draws from the tinted art. (B) The same art as generated Icon
  Composer `.icon` files, the alternate included, which is how Apple's
  alternate-icons article now builds them: Clear kept the split, the
  alternate switched and showed its own split in Clear, and the Default style
  looked identical to (A).

What this means for the design:

- **`app.icon.set` settles only once the person dismisses that alert.** While
  the alert is up the app's scene isn't active and the page doesn't run (the
  driver's verbs queue, as they do for a backgrounded app). That's fine for a
  settings screen, but nothing should await `set` on a path that needs to
  carry on without the person.
- **The change lands even if the alert is never confirmed.** The probe app was
  terminated with the alert still up, and the alternate was in place after
  reboot. So an e2e check can't wait for `set` to settle (CI can't tap the
  alert). It can fire `set`, relaunch, and assert on `list().current`.

**R2, macOS (macOS 27).** Rendered under each system icon theme
(`AppleIconAppearanceTheme`): RegularLight gives the light art, RegularDark the
dark art. Under TintedLight and TintedDark, tinted art that was half black and
half white came back tinted by luminance with the split intact, so the system
is using our tinted art rather than auto-tinting the light art. The `.icns`
control stays light under the dark theme and gets auto-tinted under the tinted
themes. One instrument trap: `NSWorkspace.icon(forFile:)` follows the system
icon theme, not the drawing appearance or `NSApp.appearance`.

**Clear, measured afterwards on macOS 27:** the Clear light and Clear dark
styles also draw from the **tinted** art. The half-black/half-white split
survived in both, rendered as grays, while the `.icns` control was flattened
to one gray. This matches Icon Composer's model in the HIG (you annotate
"default, dark, and mono" variants, and the system derives Clear and Tinted
from mono), so the manifest needs no separate `clear` key: `tinted` is the
mono art. A second instrument trap: from some point on,
`NSWorkspace.icon(forFile:)` returned the generic *document* icon for any
bundle outside an Applications folder, on two Macs, through a restart, even
for a bundle that had rendered correctly earlier and for a copy of
Calculator. Bundles in `~/Applications` render correctly, so probes go
there.

**R3, Android (a Samsung foldable, One UI, Android 16).**

- `setComponentEnabledSetting` from inside the app takes ~1 ms per switch.
  With `DONT_KILL_APP` the process survives (same pid).
- The drawer showed the new icon, in the same slot, within ~2 s.
- A home-screen icon pinned to the alias being disabled is **swapped in place**
  for the newly enabled alias, and tapping it cold-launches the app.
- With One UI's icon palette on (`colortheme_app_icon`), the adaptive icon drew
  its `<monochrome>` layer tinted. Apps without one stayed in colour.
- The monochrome layer uses the foreground's 108 dp canvas with its 66 dp
  visible window. So the tinted PNG needs the same inset as the light art, or
  it gets cropped.
- Only Samsung's launcher was measured; every Android test device is a Samsung. Pixel
  Launcher and third-party launchers are inferred from the platform docs.

**R4, Windows (x64, Windows 11 26200).**

- A hand-built MSIX installs and `makepri` indexes the qualified candidates
  (`TargetSize-48, AlternateForm-UNPLATED` / `-LIGHTUNPLATED`). So the build
  step is `makepri` beside the `makeappx` the bundler already runs.
- `Add-AppxPackage` over SSH fails with 0x80070005 and has to run in the
  console session.
- **The taskbar follows the theme, live.** Every candidate had its own colour.
  The running app's taskbar button showed the `altform-unplated` art with the
  taskbar dark, switched to `altform-lightunplated` within 3 s of setting
  `SystemUsesLightTheme=1` and broadcasting `ImmersiveColorSet`, and switched
  back when restored. So `dark` maps to `altform-unplated` and `light` to
  `altform-lightunplated`. Windows has no tinted mode.
- Instrument traps: the desktop has to be unlocked, and the capture process
  DPI-aware (otherwise `CopyFromScreen` grabs the top-left logical region and
  misses the taskbar). The shell's `IShellItemImageFactory` on the `AppsFolder`
  item returns the unqualified asset in both themes, so it can't stand in for
  the taskbar.

## Implementation plan (after de-risking)

1. **Manifest:** an `IconArt` type (a string, or `{light, dark, tinted}`) for
   `icon` and every per-target `icon`; `alternate_icons`; validating `name`.
2. **Bridge + Swift:** `app.icon.list` / `app.icon.set`, an `AppContext`
   requirement whose default implementation is unsupported, and typed codegen.
3. **Apple, one generator:** when `dark` or `tinted` is set, write one
   Icon Composer `.icon` per icon (primary and alternates) and compile them
   with the catalog the bundler already builds. Measured to work on iOS
   (Clear included) and macOS (all six styles). If `actool` can't read
   `.icon` (an Xcode older than the documented 26), fall back to the classic
   `.appiconset` on iOS (measured: dark, tinted and Clear work) and to today's
   `.icns` on macOS, reporting why through `IconOutcome`. CI's `macos-15`
   runners default to an older Xcode, so the smoke jobs either select Xcode 26
   or cover the fallback.
4. **iOS runtime:** `setAlternateIconName` in `SwiftPWAWebKit`. **macOS:**
   alternates report `supported: false` (see above).
5. **Android:** an adaptive icon when `tinted` is set; aliases in the generated
   manifest; the switch in the generated Kotlin; a warning for a tinted PNG
   without alpha.
6. **Windows:** the qualified logo set in the MSIX; the portable exe keeps one
   icon.
7. **Linux:** `supported: false`, documented.
8. **Coverage:** manifest and generator unit tests; a drive check per platform
   that runs `app.icon.list` / `set` on a fresh `init` app; CI's bundle-smoke
   jobs build an app that declares appearances and an alternate.
9. **Docs:** the per-platform setup pages, a README matrix row, CHANGELOG.
