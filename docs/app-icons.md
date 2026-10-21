# App icons: appearances and alternates

An app icon can be one 1024×1024 PNG, or one per appearance, so the system's
dark, clear and tinted icon styles show art you drew instead of a filter over
the light icon. An app can also offer icons the person picks from its
settings. Both come from `pwa.json`; switching goes through `app.icon.*`.

```json
"icon": { "light": "art/icon.png", "dark": "art/icon-dark.png", "tinted": "art/icon-tinted.png" },
"alternate_icons": [
  { "name": "sketch", "icon": { "light": "art/sketch.png", "dark": "art/sketch-dark.png", "tinted": "art/sketch-tinted.png" } }
]
```

```js
const { current, alternates, supported } = await __SWIFT_PWA__.invoke('app.icon.list');
// supported: false → leave the setting out. alternates: ['sketch']. current: null (the primary) or a name.
await __SWIFT_PWA__.invoke('app.icon.set', { name: 'sketch' }); // { name: null } for the primary
```

## The art

- **Full-bleed, unmasked squares.** Every platform that draws appearances
  applies its own mask.
- **`light`** is the default icon, and the one each platform without
  appearances uses. A plain `"icon": "icon.png"` is the same as
  `{ "light": "icon.png" }` and builds exactly as it always has.
- **`dark`** is the icon for the dark style on iOS and macOS, and the logo a
  dark Windows taskbar shows.
- **`tinted`** is grayscale art the system colours. iOS and macOS draw both
  their **Clear** and **Tinted** styles from it (Icon Composer calls it
  "mono"); there is no separate Clear art. Android uses it as the themed
  icon's monochrome layer, which reads **only its alpha**, so give it a
  transparent background. The build warns when it has none.
- `dark` and `tinted` are each optional. An appearance without its own art
  gets the system's treatment of the light icon, as before.
- A per-platform `icon` (`"macos": { "icon": … }`) replaces the top-level one
  outright, appearances included.

An alternate's `name` is the id the page passes to `app.icon.set`: lowercase
letters, digits and `_`, starting with a letter, and not `appicon`. The build
refuses a bad or repeated name. An alternate whose art is missing is left out,
with a line in the build output, rather than offered and switching to nothing.

## Per platform

| | Appearances | Alternates |
| --- | --- | --- |
| iOS / iPadOS | Dark, Clear, Tinted | Yes |
| macOS | Dark, Clear, Tinted (macOS 26+) | No: `supported: false` |
| Android | Themed icon from `tinted` | Yes |
| Windows | Light and dark taskbar logos (MSIX) | No: `supported: false` |
| Linux | None | No: `supported: false` |

### iOS and macOS

With dark or tinted art, the bundler writes an Icon Composer `.icon` document
per icon (one layer per appearance, with no Liquid Glass effects, so the art
arrives as drawn) and compiles it with `actool`. That's the only input macOS
keeps appearances from: an `.appiconset` with dark and tinted entries
compiles for macOS without a warning and keeps the light art alone. iOS
compiles the same document, alternates included.

`.icon` documents need the Xcode 26 `actool`. With an older one the iOS build
falls back to a classic icon set with `luminosity` entries (dark, tinted and
Clear still work), and the macOS build to the light `.icns`; the icon line in
the build output says which happened.

On macOS the compile also renders an `AppIcon.icns` for macOS before 26: it
comes out already masked, at up to 256 px (the plain `.icns` path renders up
to 1024 px).

**Switching on iOS** is `setAlternateIconName`. iOS shows its own alert
confirming the change, and `app.icon.set` resolves when the person dismisses
it. The page doesn't run while the alert is up. The change lands even if the
app is closed with the alert still showing.

**macOS has no alternate icons.** AppKit has no API for it (Apple's HIG lists
alternate icons for iOS, iPadOS, tvOS and visionOS), and each workaround was
measured to lose what this feature adds: the running app's Dock icon
(`NSApp.applicationIconImage`) draws only the alternate's light art, in every
style; and writing a custom icon onto the bundle breaks its code signature and
shows one flat image in every style. So `app.icon.list` reports
`supported: false`.

### Android

`tinted` art makes the launcher icon an adaptive icon: the light art as its
foreground and the tinted art as its monochrome (themed) layer, each inset so
the full-bleed art fills the 72 dp the launcher shows instead of losing a
sixth of each edge to the 108 dp layer. The background colour is
`window.background_color`'s light value (white when unset); it shows only
where a launcher draws beyond that window, such as the parallax shift. Without
`tinted` the launcher icon stays the plain PNG. Android has no dark icon, so
`dark` isn't used.

**Alternates** become one launcher `<activity-alias>` per icon
(`.LauncherDefault` and `.LauncherIcon_<name>`), and the launcher entry moves
from `MainActivity` to them; an app without `alternate_icons` keeps its
manifest unchanged. `app.icon.set` enables one alias and disables the rest
without stopping the app. Measured on One UI: the drawer shows the new icon
within about two seconds, in the same place, and an icon pinned to the home
screen is swapped in place and still opens the app. Other launchers can take
longer.

### Windows

In the **MSIX**, `dark` art adds taskbar logos per taskbar theme: the dark
art as `altform-unplated` (what a dark taskbar shows) and the light art as
`altform-lightunplated`, at the sizes the shell asks for, with a
`resources.pri` built by `makepri.exe` (Windows SDK, beside `makeappx.exe`) so
Windows can choose between them. The taskbar switches when the theme does. If
`makepri` fails, the build keeps the single logo and says why. The portable
`.exe` embeds one icon, from `light`. Windows has no tinted style.

### Linux

The freedesktop icon theme has no per-app dark variant, so the AppImage icon
is `light`.

## From Swift

The same calls are on `AppContext`:

```swift
if let icons = ctx.appIcons {          // nil where the platform has no alternates
    let state = try await icons.state() // current, alternates, supported
    try await icons.select("sketch")    // nil for the primary
}
```

## Checking it

- `Scripts/verify-app-icons.sh` — macOS or Linux on this machine, or the iOS
  Simulator with `--simulator`.
- `Scripts/verify-android-app-icons.sh` — a device over adb.
- `Scripts\verify-app-icons-windows.ps1` — the MSIX taskbar logos, on a
  logged-on Windows desktop.

Each runs a fresh `swift-pwa init` app; `--released` (`-Control` on Windows)
runs the control, where the rows have to fail. How each style looks was
checked by eye and by rendering on devices, with the measurements in
[proposals/app-icon-appearances.md](proposals/app-icon-appearances.md).
