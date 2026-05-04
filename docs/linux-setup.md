# swift-pwa on Linux (GTK3 + WebKitGTK 4.1)

Tested target: Ubuntu 24.04 LTS with Swift 6.0.3 (via [Swiftly](https://swiftlang.github.io/swiftly/)).
JS↔Swift bridge round-trip verified end-to-end against `Examples/HelloPWA`
on this configuration. Should also work on 22.04 (the
`libwebkit2gtk-4.1-dev` package is the gating piece).

## 1. Install Swift 6.0+

```bash
# Quickest path — Swiftly (the official toolchain manager).
curl -L https://swiftlang.github.io/swiftly/swiftly-install.sh | bash
. "$HOME/.local/share/swiftly/env.sh"
swiftly install latest
swift --version       # expect 6.0+
```

Or grab a tarball directly from <https://swift.org/download/>.

## 2. System dependencies

```bash
sudo apt-get update
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libgtk-3-dev \
    libwebkit2gtk-4.1-dev \
    libglib2.0-dev \
    xvfb \
    wget \
    file \
    zlib1g-dev   # Swift sometimes needs this on minimal images
```

Sanity-check the GTK + WebKitGTK headers are findable:

```bash
pkg-config --modversion gtk+-3.0           # any 3.x
pkg-config --modversion webkit2gtk-4.1     # any 2.4x
```

If `webkit2gtk-4.1` is missing, your distro is too old; on 22.04 you may
need the [WebKitGTK PPA](https://launchpad.net/~webkit-team/+archive/ubuntu/ppa).

## 3. Optional — AppImage tooling (only needed for `swift-pwa build --target linux`)

```bash
sudo wget -O /usr/local/bin/linuxdeploy \
    https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-x86_64.AppImage
sudo wget -O /usr/local/bin/linuxdeploy-plugin-appimage \
    https://github.com/linuxdeploy/linuxdeploy-plugin-appimage/releases/download/continuous/linuxdeploy-plugin-appimage-x86_64.AppImage
sudo chmod +x /usr/local/bin/linuxdeploy /usr/local/bin/linuxdeploy-plugin-appimage
```

## 4. Clone and build

```bash
git clone https://github.com/tophatch/swift-pwa
cd swift-pwa

# Build everything — Core, GTK backend, CLI, examples.
swift build

# Run unit tests (Core + CLI). Always works headless.
swift test --filter SwiftPWACoreTests
swift test --filter SwiftPWACLITests
```

Expected: 33+ tests pass. The Apple `WKWebViewTests` target won't build
on Linux (it's gated by `#if canImport(WebKit)`), so SwiftPM skips it.

## 5. Run the example

```bash
# Display required for any GUI run.
swift run --package-path Examples/HelloPWA HelloPWA
```

If you're SSH'd in headlessly:

```bash
# Run inside Xvfb so it doesn't need a real display.
Xvfb :99 -screen 0 1280x720x24 &
DISPLAY=:99 swift run --package-path Examples/HelloPWA HelloPWA &
sleep 2
# Take a screenshot to prove it rendered.
DISPLAY=:99 import -window root /tmp/swift-pwa.png
```

## 6. Build an `.AppImage`

```bash
swift build --product swift-pwa
cd Examples/HelloPWA
../../.build/debug/swift-pwa build --target linux
# → build/HelloPWA-x86_64.AppImage
./build/HelloPWA-x86_64.AppImage
```

## Known limitations on Linux

The Linux backend is hand-rolled against the WebKitGTK 4.1 C API.
End-to-end functionality is in place — JS `__SWIFT_PWA__.invoke()` /
`subscribe()` round-trip through the bridge — but a few rough edges
remain:

- **WebKitGTK 6.0 (GTK4) isn't supported yet** — only the 4.1 ABI.
  The C shim assumes `WebKitJavascriptResult` (boxed type) on the
  signal callback; the 6.0 ABI swapped that for `JSCValue` direct.
  Adding 6.0 means a sibling shim target.
- **WM-driven focus / minimize / fullscreen events aren't observed.**
  `WindowEvent.didFocus` / `.didBlur` / `.didMinimize` / `.didDeminiaturize`
  / `.didEnterFullscreen` / `.didExitFullscreen` are only emitted when
  the corresponding `Window.focus()` / `minimize()` / `setFullscreen()`
  method is called programmatically. User-driven state changes (alt-tab,
  click another window, double-click titlebar to maximize) don't reach
  subscribers. The fix is to wire up GTK's `focus-in-event` /
  `focus-out-event` / `window-state-event` signals the same way
  `configure-event` is hooked for resize.
- **AppImage builds need a real PNG icon.** If `pwa.json.icon` is
  absent or non-PNG, the bundler embeds a 1×1 transparent placeholder
  so `linuxdeploy` doesn't hang on its prompt path.
- **Swiftly's bundled toolchain prints noisy warnings** on Ubuntu
  (`libxml2.so.2: no version information available`, `prohibited
  flag(s): -pthread`). Cosmetic; ignore.

If you hit linker errors around `webkit_*` symbols, the most common
cause is `pkg-config --libs webkit2gtk-4.1` returning empty — confirm
with:

```bash
pkg-config --libs webkit2gtk-4.1
```

If the output is empty, your `libwebkit2gtk-4.1-dev` install is broken.
Reinstall.

## Threading model on Linux

Worth knowing if you read the source: Swift's `MainActor` executor on
Linux is libdispatch's main queue, which `gtk_main()` does not pump.
That means `await MainActor.run { … }` from a cooperative-pool task
hangs forever once `gtk_main()` is running. swift-pwa works around
this with a [`MainThread.run`](../Sources/SwiftPWACore/MainThread.swift)
abstraction whose hook the GTK runtime points at `g_idle_add`. If you
write your own commands that need to touch GTK from a non-main thread,
use `MainThread.run` rather than `MainActor.run` and you'll avoid the
deadlock.

## Reporting issues

When filing a Linux issue, include:

```bash
swift --version
lsb_release -a
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1
```
