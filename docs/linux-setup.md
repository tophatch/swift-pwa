# swift-pwa on Linux (GTK3 + WebKitGTK 4.1)

Tested target: Ubuntu 24.04 LTS. Should also work on 22.04 (the
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
git clone https://github.com/<you>/swift-pwa
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

## Known issues to expect on first Linux run

The Linux backend in v0.1 is hand-rolled against the WebKitGTK 4.1 C
API. The Swift portion compiles cleanly, but **two GTK details aren't
wired end-to-end yet** because they need a Linux box to debug:

1. **`script-message-received` signal handler.** The Apple side gets JS→Swift
   messages via `WKScriptMessageHandler`. On GTK the analogue is a GObject
   signal that needs a C trampoline to call back into Swift. The
   placeholder is [`WebKitGTKAdapter._ingest(jsonString:)`](../Sources/SwiftPWAGTK/WebKitGTKAdapter.swift)
   — wire it up via `g_signal_connect_data` to receive JS messages.
2. **`evaluateJavaScript` async result.** Currently fire-and-forget; the
   GAsyncResult callback chain isn't threaded through. Outbound frames
   work (`__deliver` is fire-and-forget too), but `evaluate(js:)` returning
   a value to Swift waits on this.

If you hit linker errors around `webkit_*` symbols, the most common cause
is `pkg-config --libs webkit2gtk-4.1` returning empty — confirm with:

```bash
pkg-config --libs webkit2gtk-4.1
```

If the output is empty, your `libwebkit2gtk-4.1-dev` install is broken.
Reinstall.

## Reporting issues

When filing a Linux issue, include:

```bash
swift --version
lsb_release -a
pkg-config --modversion gtk+-3.0 webkit2gtk-4.1
```
