## swift-pwa on Windows (Win32 + WebView2)

The Windows backend wraps `WKWebView`'s closest cousin — Microsoft Edge
WebView2 — through a small C++ COM shim, plus Win32 for window
management, clipboard, tray, and balloon notifications. Swift on
Windows handles the rest via `import WinSDK`.

> **Status (v0.2):** builds clean on Windows 11 ARM64 with Swift 6.3.1
> (verified against Visual Studio 2026 + WebView2 SDK 1.0.3912.50 +
> WIL 1.0.260126.7). x64 should also build by the same recipe but
> hasn't been re-verified on the latest commits. Runtime behavior
> (windows actually appearing, the JS↔Swift bridge round-tripping,
> clipboard / tray / balloon plumbing) hasn't been smoke-tested yet
> — please file issues with the failure mode rather than working
> around them locally. Richer toast XML (replace-by-id, action
> buttons) and MSIX packaging wait on the swift-winrt rollout in v0.3.

## 1. Toolchain

| Component                              | Install                                                                                         |
|----------------------------------------|-------------------------------------------------------------------------------------------------|
| Swift 6.0+ for Windows                 | <https://www.swift.org/install/windows/> (the official Windows installer or `winget`)           |
| Visual Studio Build Tools              | "Desktop development with C++" workload — supplies `cl.exe`, MSVC libs, the Windows 10/11 SDK   |
| WebView2 SDK                           | NuGet package `Microsoft.Web.WebView2` (≥ 1.0.2210)                                             |
| Windows Implementation Libraries (WIL) | NuGet package `Microsoft.Windows.ImplementationLibrary` — `<wil/com.h>` is used by the COM shim |
| WebView2 Runtime                       | <https://developer.microsoft.com/microsoft-edge/webview2/> (preinstalled on Windows 11)         |

The Swift installer wires `import WinSDK` to the Visual Studio /
Windows SDK headers; you don't need any extra plumbing for Win32.

## 2. WebView2 SDK + WIL on the build path

`Sources/CWebView2Shim/swiftpwa_webview2.cpp` includes `<WebView2.h>`
and `<wil/com.h>`, and links `WebView2LoaderStatic.lib`:

- `<WebView2.h>` and the static loader come from the
  `Microsoft.Web.WebView2` NuGet package, which ships per-arch
  loaders under `build/native/{x86,x64,arm64}/WebView2LoaderStatic.lib`.
- `<wil/com.h>` comes from `Microsoft.Windows.ImplementationLibrary`
  (header-only).

```powershell
# In your project root, fetch both NuGet packages:
nuget install Microsoft.Web.WebView2 -OutputDirectory packages -ExcludeVersion
nuget install Microsoft.Windows.ImplementationLibrary -OutputDirectory packages -ExcludeVersion
```

Then enter a Visual Studio Developer Shell with the right architecture
*before* setting INCLUDE/LIB and building. The default PowerShell
session inherits the system `LIB`, which on a fresh box may point at
x86 MSVC libs and produce confusing link-time errors like
`msvcrt.lib(chkstk.obj): machine type x86 conflicts with arm64`.

```powershell
# x64 host:
& "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64

# arm64 host:
& "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch arm64 -HostArch arm64
```

(Adjust the path for VS 2022 / a non-Community edition.)

```powershell
# Pick the arch matching your Swift toolchain. PROCESSOR_ARCHITECTURE
# is "AMD64" on x64 and "ARM64" on Windows-on-ARM.
$arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$env:INCLUDE = "$pwd\packages\Microsoft.Web.WebView2\build\native\include;" +
               "$pwd\packages\Microsoft.Windows.ImplementationLibrary\include;" +
               "$env:INCLUDE"
$env:LIB     = "$pwd\packages\Microsoft.Web.WebView2\build\native\$arch;$env:LIB"

swift build -c release
```

The static loader (`WebView2LoaderStatic.lib`) is what `Package.swift`
asks for — that means apps don't need to ship `WebView2Loader.dll`
alongside the executable. The WebView2 Runtime itself still has to be
installed; `WindowsAppRuntime` checks for it on startup and prints an
install hint if it's missing.

(If you'd rather pull the SDK via vcpkg, `vcpkg install
microsoft-web-webview2:x64-windows` — or `:arm64-windows` — resolves
the same headers and loader. WIL is also available as
`vcpkg install wil`. Make sure the vcpkg-installed `lib/` dir is on
`LIB`.)

### Per-session, not per-checkout

The `Launch-VsDevShell.ps1` + `INCLUDE` / `LIB` setup is **per
PowerShell session**, not stamped into the checkout. Every fresh
window needs the dance again — including any project that depends on
swift-pwa as a path or git dependency, since the WebView2 + WIL
headers are needed to compile `CWebView2Shim` transitively.

When building a downstream project (e.g. `Examples/HelloPWA`), point
`INCLUDE` / `LIB` at the swift-pwa root's `packages/` folder rather
than the downstream project's `$pwd`:

```powershell
# Reuse the swift-pwa repo's NuGet packages from any sibling project:
$arch     = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "x64" }
$swiftpwa = "C:\path\to\swift-pwa"  # absolute path to the swift-pwa checkout
$env:INCLUDE = "$swiftpwa\packages\Microsoft.Web.WebView2\build\native\include;" +
               "$swiftpwa\packages\Microsoft.Windows.ImplementationLibrary\include;" +
               "$env:INCLUDE"
$env:LIB     = "$swiftpwa\packages\Microsoft.Web.WebView2\build\native\$arch;$env:LIB"
```

Symptoms of forgetting:

| Missing                    | Failure mode                                                                         |
|----------------------------|--------------------------------------------------------------------------------------|
| `Launch-VsDevShell.ps1`    | `lld-link: error: could not open 'msvcrt.lib'` — even at the manifest-compile stage. |
| `INCLUDE` (WebView2 / WIL) | `CWebView2Shim`: `'WebView2.h' file not found` or `'wil/com.h' file not found`.      |
| `LIB`                      | `lld-link: error: could not open 'WebView2LoaderStatic.lib'`.                        |

Saving the four lines as a `vendor\Set-SwiftPwaEnv.ps1` you dot-source
at the start of each session (`. .\vendor\Set-SwiftPwaEnv.ps1`) takes
the friction out.

### Windows on ARM

The backend is architecture-clean — no inline asm, no x86 intrinsics,
the C++ shim is just COM + Win32 + header-only WRL/WIL — so it builds
for `aarch64-pc-windows-msvc` the same way it does for x64.

| Host           | Swift toolchain                           | WebView2 lib path                               |
|----------------|-------------------------------------------|-------------------------------------------------|
| Windows x64    | `swift-6.x.y-RELEASE-windows10.exe`       | `build/native/x64/WebView2LoaderStatic.lib`     |
| Windows on ARM | `swift-6.x.y-RELEASE-windows10-arm64.exe` | `build/native/arm64/WebView2LoaderStatic.lib`   |

Caveats specific to ARM:

- **Build natively on the ARM box.** Swift-for-Windows's cross-compile
  story (x64 host → arm64 target, or vice versa) is still rough at the
  SDK-layout layer. Running `swift build` on an ARM64 install of
  Windows is the path that "just works" today.
- **The portable bundle is host-arch.** `swift run swift-pwa build
  --target windows` produces a folder containing whatever
  `swift build -c release` emitted on the calling machine — there's
  no `--arch arm64` flag yet. To ship both, build twice on the
  matching hosts (or via two CI runners) and label the output
  folders `MyApp-arm64/` and `MyApp-x64/`.
- **WebView2 Runtime is preinstalled** on Windows 11 ARM and on
  Windows 10 ARM since the 21H2 update. Older ARM boxes (the
  original Surface Pro X on 1809/1903) are the only realistic
  install-prompt scenario; the runtime detection in
  `WindowsAppRuntime` covers it.

## 3. Build & run

```powershell
swift build                                            # debug
swift build -c release                                 # ship build
swift run swift-pwa init MyApp                         # scaffold a project
swift run swift-pwa build --target windows             # → build\MyApp\MyApp.exe (+ web/, pwa.json)
```

The bundler produces a portable folder. Drop it on any Windows 10 21H2+
or Windows 11 box that has the WebView2 Runtime, and double-click
`MyApp.exe`. There's no MSIX / Appx packaging in v0.2 — that lands in
v0.3 alongside swift-winrt and toast notifications.

## 4. Architecture sketch

```
+-----------------------------+        +---------------------------+
| WindowsAppRuntime           |        | CWebView2Shim (C++)       |
|  - OleInitialize            |        |  - CreateCoreWebView2Env  |
|  - install MainThread hook  |  --->  |  - CreateController       |
|  - GetMessageW / Dispatch   |        |  - WebMessageReceived     |
+-------------+---------------+        |  - ExecuteScript          |
              |                        |  - WebResourceRequested   |
              v                        +---------------------------+
+-----------------------------+
| Win32Window                 |  + SystemClipboard (Win32 CB API)
|  - CreateWindowExW          |  + SystemTray (Shell_NotifyIconW)
|  - WM_SIZE → fitTo(client)  |  + SystemNotifications (NIF_INFO)
|  - WebView2Adapter          |
+-----------------------------+
```

A few load-bearing details:

- **MainThread hook is a hidden message-only window.** Same reason
  Linux's hook routes through `g_idle_add`: Swift's MainActor
  executor is backed by libdispatch's main queue, which `GetMessageW`
  doesn't pump. `MainThread.run` posts `WM_APP+1` carrying a heap-boxed
  closure to the dispatcher window; its WndProc unboxes and fires.
- **`pwa://`-style content uses a virtual host, not a custom scheme.**
  WebView2 enforces same-origin checks on custom schemes that would
  break ESM imports and `fetch`, so for bundled content we map
  `https://swift-pwa.local/` to the bundle directory via
  `SetVirtualHostNameToFolderMapping` and navigate there. The C shim
  also exposes `WebResourceRequested`-style interception for callers
  who really want a custom scheme; `WebView2Adapter` doesn't use it
  but the surface is there.
- **Notifications piggy-back on the tray icon.** `Shell_NotifyIconW`
  with `NIF_INFO` shows up as a toast on Windows 10 / 11. This is
  intentionally a shortcut — it avoids depending on swift-winrt and
  `Windows.UI.Notifications.ToastNotificationManager` for v0.2. The
  tradeoff is no replace-by-id, no action buttons, no Action Center
  persistence without an AppUserModelID. v0.3 swaps in the WinRT path.
- **Tray uses `Shell_NotifyIconW`, not the StatusNotifierItem spec.**
  Windows has no SNI; Microsoft has not migrated the notification
  area to a modern API. Right-click pops a `TrackPopupMenu`; left-click
  emits `TrayEvent.click` only when no menu is currently set, mirroring
  the macOS `NSStatusItem` behavior.

## Known limitations (Windows-specific)

- **Untested on hardware.** The v0.2 cut compiles cross-platform-clean
  but hasn't been verified on a real Windows install yet. Expect
  surprises in the WebView2 controller-creation timing, the message
  pump's interaction with the controller-ready callback, or the
  tray's left-click semantics. File issues.
- **WebView2 Runtime install is on the user.** We don't bundle the
  Evergreen Bootstrapper. `WindowsAppRuntime` detects a missing
  runtime via `GetAvailableCoreWebView2BrowserVersionString` and
  prints the download URL, then exits. v0.3 will add an opt-in
  bootstrapper download to the bundler.
- **Notification ids are synthesized UUIDs.** `Shell_NotifyIconW`
  doesn't return identifiers for balloon tips, so callers using
  `notifications.send(...)` get a generated UUID for log correlation
  only. The v0.3 WinRT path returns real WinRT notification ids.
- **`Window.position()` returns physical pixels, not DIPs.** We don't
  do any DPI-awareness mapping yet; on a 200% display the values are
  raw pixel coords. v0.3 will add a `SetProcessDpiAwarenessContext`
  call at startup and convert to DIPs at the API boundary.
