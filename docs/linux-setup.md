# swift-pwa on Linux (GTK3 + WebKitGTK 4.1, or GTK4 + WebKitGTK 6.0)

Two parallel Linux backends, selected at build time via the
`SWIFT_PWA_GTK4` environment variable. Both go through the same
`SwiftPWAGTK` Swift module, so downstream code is identical:

| Backend | Build command                  | System dev packages                       | Tested distro          |
|---------|--------------------------------|-------------------------------------------|------------------------|
| GTK3    | `swift build` (default)        | `libgtk-3-dev`, `libwebkit2gtk-4.1-dev`   | Ubuntu 22.04 / 24.04   |
| GTK4    | `SWIFT_PWA_GTK4=1 swift build` | `libgtk-4-dev`, `libwebkitgtk-6.0-dev`    | Ubuntu 24.04+ / 26.04  |

Pick GTK3 if you're shipping to older distros (Ubuntu 22.04 LTS doesn't
have WebKitGTK 6.0 in apt without a PPA). Pick GTK4 for modern distros
and the long-term direction. JS↔Swift bridge round-trip is verified
end-to-end against `Examples/HelloPWA` on both.

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

### GTK3 + WebKitGTK 4.1 (default)

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

Sanity-check the headers are findable:

```bash
pkg-config --modversion gtk+-3.0           # any 3.x
pkg-config --modversion webkit2gtk-4.1     # any 2.4x
```

### GTK4 + WebKitGTK 6.0

```bash
sudo apt-get install -y \
    build-essential \
    pkg-config \
    libgtk-4-dev \
    libwebkitgtk-6.0-dev \
    libglib2.0-dev \
    xvfb \
    wget \
    file \
    zlib1g-dev
```

Sanity-check:

```bash
pkg-config --modversion gtk4               # any 4.x
pkg-config --modversion webkitgtk-6.0      # any 2.4x
```

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

# GTK3 build (default).
swift build

# Or, GTK4 build.
SWIFT_PWA_GTK4=1 swift build

# Run unit tests (Core + CLI). Backend-agnostic; always works headless.
swift test --filter SwiftPWACoreTests
swift test --filter SwiftPWACLITests
```

The `SWIFT_PWA_GTK4` env var swaps which system-library targets are in
the SwiftPM package graph, so `pkg-config` only resolves the deps for
the backend you're actually building. The Apple `WKWebViewTests` target
won't build on Linux (gated by `#if canImport(WebKit)`), so SwiftPM
skips it.

## 5. Run the example

```bash
# Display required for any GUI run.
swift run --package-path Examples/HelloPWA HelloPWA
# or, GTK4:
SWIFT_PWA_GTK4=1 swift run --package-path Examples/HelloPWA HelloPWA
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

The Linux backends are hand-rolled against the GTK / WebKitGTK C APIs.
End-to-end functionality is in place on both — JS `__SWIFT_PWA__.invoke()` /
`subscribe()` round-trip through the bridge — but a few rough edges
remain:

- **`Window.position()` / `setPosition` / `.didMove` are no-ops on the
  GTK4 backend.** GTK4 dropped the position APIs entirely (Wayland
  refuses to give apps their own position; CSD makes the concept
  ambiguous). `position()` returns `.zero`, `setPosition` silently
  no-ops, and `.didMove` events are never emitted on GTK4. The GTK3
  backend supports all three.
- **WM-driven focus / minimize / fullscreen events aren't observed.**
  `WindowEvent.didFocus` / `.didBlur` / `.didMinimize` / `.didDeminiaturize`
  / `.didEnterFullscreen` / `.didExitFullscreen` are only emitted when
  the corresponding `Window.focus()` / `minimize()` / `setFullscreen()`
  method is called programmatically. User-driven state changes (alt-tab,
  click another window, double-click titlebar to maximize) don't reach
  subscribers on either backend. The fix is to wire GTK3's
  `focus-in-event` / `focus-out-event` / `window-state-event`, or
  GTK4's `notify::is-active` / `notify::fullscreened` / `notify::minimized`,
  the same way the resize signals are hooked.
- **AppImage builds need a real PNG icon.** If `pwa.json.icon` is
  absent or non-PNG, the bundler embeds a 1×1 transparent placeholder
  so `linuxdeploy` doesn't hang on its prompt path.
- **Swiftly's bundled toolchain prints noisy warnings** on Ubuntu
  (`libxml2.so.2: no version information available`, `prohibited
  flag(s): -pthread`). Cosmetic; ignore.

If you hit linker errors around `webkit_*` symbols, the most common
cause is `pkg-config --libs <module>` returning empty — confirm with:

```bash
pkg-config --libs webkit2gtk-4.1     # GTK3 backend
pkg-config --libs webkitgtk-6.0      # GTK4 backend
```

If the output is empty, your dev package install is broken. Reinstall.

## Threading model on Linux

Worth knowing if you read the source: Swift's `MainActor` executor on
Linux is libdispatch's main queue, which neither `gtk_main()` (GTK3)
nor a bare `g_main_loop_run` (GTK4) pumps. That means
`await MainActor.run { … }` from a cooperative-pool task hangs forever
once the GTK loop is running. swift-pwa works around this with a
[`MainThread.run`](../Sources/SwiftPWACore/MainThread.swift) abstraction
whose hook both GTK runtimes point at `g_idle_add`. If you write your
own commands that need to touch GTK from a non-main thread, use
`MainThread.run` rather than `MainActor.run` and you'll avoid the
deadlock.

## Reporting issues

When filing a Linux issue, include:

```bash
swift --version
lsb_release -a
echo "SWIFT_PWA_GTK4=${SWIFT_PWA_GTK4:-unset}"
# GTK3:
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1 2>/dev/null
# GTK4:
pkg-config --modversion gtk4 webkitgtk-6.0 2>/dev/null
```
