# swift-pwa on Windows (Win32 + WebView2)

The Windows backend wraps `WKWebView`'s closest cousin — Microsoft Edge
WebView2 — through a small C++ COM shim, plus Win32 for window
management, clipboard, tray, and balloon notifications. Swift on
Windows handles the rest via `import WinSDK`.

> **Status:** verified end-to-end against `Examples/HelloPWA` on
> Windows 11 ARM64 (Swift 6.3.1, Visual Studio 2026, WebView2 SDK
> 1.0.3912.50, WIL 1.0.260126.7); x64 builds clean on every commit
> via the `windows-2022` CI runner. Window lifecycle, JS↔Swift
> bridge, clipboard, tray, WinRT toast notifications, Per-Monitor V2
> DPI scaling, and the `Ctrl+Alt+J` DevTools shortcut are all in scope.
> MSIX packaging and the opt-in Evergreen Bootstrapper land in the
> CLI bundler. Richer toast XML (action buttons, scheduled toasts)
> waits on a follow-up.

## 1. Toolchain

| Component                              | Install                                                                                         |
|----------------------------------------|-------------------------------------------------------------------------------------------------|
| Swift 6.0+ for Windows                 | <https://www.swift.org/install/windows/> — or `winget install --id Swift.Toolchain`             |
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

### Per-session prerequisites

`Launch-VsDevShell.ps1` is **per PowerShell session** — every fresh
window needs the VS Developer environment loaded again before
`swift build` will resolve the MSVC toolchain. (Reproducing what
`vsdevcmd.bat` does ourselves is fragile, so we leave it to VS.)

**Auto-loading it.** PowerShell's profile (`$PROFILE`) is the .zshrc
analogue and will run on every shell launch, but most VS users *don't*
auto-load `Launch-VsDevShell.ps1` globally and you probably shouldn't
either:

- VsDevShell mutates ~50 env vars. MSVC's `link.exe` jumps to the
  front of `$env:Path`, shadowing GNU `link` and any other tools
  with colliding names.
- It locks the session to one arch (x64 *or* arm64) and one VS
  install — switching means a fresh shell anyway, defeating the
  point.
- It adds 1–3s to every PowerShell startup, including non-dev
  sessions.

The cleaner per-context options:

- **Windows Terminal profile** — add a "VS Dev" profile in *Settings
  → Profiles → Add new* with `commandline` set to:

  ```text
  powershell.exe -NoExit -Command "& 'C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1' -Arch amd64 -HostArch amd64"
  ```

  Default profile stays clean; you pick the dev tab when you need it.

- **VS Code workspace terminal** — drop a `.vscode/settings.json` in
  your swift-pwa-using project that overrides
  `terminal.integrated.profiles.windows` and
  `terminal.integrated.defaultProfile.windows`:

  ```json
  {
    "terminal.integrated.profiles.windows": {
      "VS Dev PowerShell": {
        "path": "powershell.exe",
        "args": ["-NoExit", "-Command",
          "& 'C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\Common7\\Tools\\Launch-VsDevShell.ps1' -Arch amd64 -HostArch amd64"]
      }
    },
    "terminal.integrated.defaultProfile.windows": "VS Dev PowerShell"
  }
  ```

  Per-workspace, no global pollution.

- **Project-local script** — save the loader + (optional) NuGet
  exports as `vendor\Set-SwiftPwaEnv.ps1` and dot-source it (`. .\vendor\Set-SwiftPwaEnv.ps1`)
  whenever you open a fresh shell on the project. Lowest blast
  radius, slight per-session friction.

If you do go the `$PROFILE` route anyway, gate it on the working
directory so non-dev sessions stay clean:

```powershell
# In $PROFILE
if ((Get-Location).Path -like "*\swift-pwa*") {
    & "C:\Program Files\Microsoft Visual Studio\18\Community\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64
}
```

The WebView2 + WIL `INCLUDE` / `LIB` exports were also a per-session
chore in v0.2; in v0.3 the bundler auto-detects the swift-pwa repo's
`packages/` folder and prepends the matching directories to
`INCLUDE` / `LIB` before launching `swift build`. Walk order, from
the project being bundled:

  1. `<projectRoot>/packages/...` — running inside the swift-pwa repo
  2. `<projectRoot>/../packages/...` — running from a sibling
     directory like `Examples/HelloPWA`
  3. `<projectRoot>/../../packages/...`
  4. `<projectRoot>/.build/checkouts/swift-pwa/packages/...` — when
     swift-pwa is pulled as a git dependency

If any of those resolves, you'll see:

```text
swift-pwa: prepending swift-pwa NuGet packages to INCLUDE / LIB
  WebView2: …\Microsoft.Web.WebView2\build\native\include
  WIL:      …\Microsoft.Windows.ImplementationLibrary\include
  Loader:   …\Microsoft.Web.WebView2\build\native\x64
```

If you're invoking `swift build` directly (e.g. plain `swift build -c
release` outside the bundler), the auto-detect doesn't run and you
still need the manual exports:

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

| Missing                    | Failure mode                                                                                                                                                          |
|----------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `Launch-VsDevShell.ps1`    | `lld-link: error: could not open 'msvcrt.lib'` — even at the manifest-compile stage.                                                                                  |
| `INCLUDE` (WebView2 / WIL) | `CWebView2Shim`: `'WebView2.h' file not found` or `'wil/com.h' file not found`. Plain `swift build` only — the bundler auto-injects these.                            |
| `LIB`                      | `lld-link: error: could not open 'WebView2LoaderStatic.lib'`. Plain `swift build` only — same auto-inject.                                                            |
| stdlib junction            | `error: unable to load standard library for target 'x86_64-unknown-windows-msvc'`. See [One-time stdlib junction](#one-time-stdlib-junction-swift-asserts-installer). |

### One-time stdlib junction (Swift `+Asserts` installer)

The official Swift Windows installer ships two toolchain trees:
`Toolchains\6.x.y+Asserts` (the default on PATH) and `Platforms\6.x.y\Windows.platform\Developer\SDKs\Windows.sdk`.  
The `+Asserts` tree intentionally omits a `lib\swift\windows` directory — it
expects `swiftc` to resolve the stdlib via `SDKROOT`. However, SwiftPM's
manifest compiler (`swift package`) invokes `swiftc` directly without that
variable, so on a fresh install you get:

```
<unknown>:0: error: unable to load standard library for target 'x86_64-unknown-windows-msvc'
error: 'swift-pwa': Invalid manifest
```

The fix is a one-time directory junction that makes the Platform SDK's stdlib
visible where the toolchain expects it:

```powershell
# Run once after installing Swift (adjust the version number if needed):
$base = "$env:LOCALAPPDATA\Programs\Swift"
New-Item -ItemType Junction `
    -Path  "$base\Toolchains\6.3.1+Asserts\usr\lib\swift\windows" `
    -Target "$base\Platforms\6.3.1\Windows.platform\Developer\SDKs\Windows.sdk\usr\lib\swift\windows"
```

The junction survives reboots and only needs to be recreated if you reinstall
or upgrade Swift. Verify it worked:

```powershell
Test-Path "$env:LOCALAPPDATA\Programs\Swift\Toolchains\6.3.1+Asserts\usr\lib\swift\windows\x86_64\swiftCore.lib"
# → True
```

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

Easiest is to grab the prebuilt CLI from the latest GitHub release
(added to the matrix in v0.3) and put it on your PATH:

```powershell
Invoke-WebRequest `
    -Uri https://github.com/tophatch/swift-pwa/releases/latest/download/swift-pwa-windows-x86_64.exe `
    -OutFile $env:USERPROFILE\bin\swift-pwa.exe
# Make sure $env:USERPROFILE\bin is on $env:Path.

swift-pwa init MyApp
cd MyApp
swift-pwa build --target windows                       # → build\MyApp\MyApp.exe (+ web/, pwa.json)
```

Or build the CLI from a swift-pwa checkout (useful when you're
hacking on the bundler itself — same dance as the iOS / macOS docs):

```powershell
swift build                                            # debug
swift build -c release                                 # ship build
swift run swift-pwa init MyApp                         # scaffold a project
swift run swift-pwa build --target windows             # → build\MyApp\MyApp.exe (+ web/, pwa.json)
```

The bundler produces a portable folder. Drop it on any Windows 10 21H2+
or Windows 11 box that has the WebView2 Runtime, and double-click
`MyApp.exe`.

For an MSIX/Appx package instead of a portable folder:

```powershell
swift run swift-pwa build --target windows --package-format msix
swift run swift-pwa build --target windows --package-format msix --sign <thumbprint-or-pfx>
```

The bundler stages the EXE, web bundle, a generated `AppxManifest.xml`,
and a `Square150x150Logo.png` (taken from `pwa.json`'s `icon` if
provided, otherwise a 1×1 placeholder), then drives `makeappx.exe pack`
and — if `--sign` is supplied — `signtool.exe sign`. Both binaries
ship with the Windows SDK; no extra install needed once you've launched
the VS Developer Shell. The signed MSIX installs on any Windows 10
1809+ box; an unsigned MSIX is sideloadable on developer-mode boxes
only.

To embed the WebView2 Evergreen Bootstrapper (~1.7 MB) in either the
portable bundle or the MSIX so the app can self-install the runtime:

```powershell
swift run swift-pwa build --target windows --bootstrap-webview2
```

`WindowsAppRuntime` detects a missing runtime at startup, finds
`MicrosoftEdgeWebview2Setup.exe` next to the EXE, and prompts the user
via a MessageBox before `ShellExecuteEx`-ing it with elevation.

## 4. Architecture sketch

```
+-----------------------------+        +---------------------------+
| WindowsAppRuntime           |        | CWebView2Shim (C++)       |
|  - SetProcessDpiAwareness   |        |  - CreateCoreWebView2Env  |
|  - SetCurrent..AppUserModel |        |  - CreateController       |
|  - swiftpwa_toast_init(..)  |        |  - WebMessageReceived     |
|  - OleInitialize            |  --->  |  - ExecuteScript          |
|  - install MainThread hook  |        |  - WebResourceRequested   |
|  - GetMessageW / Dispatch   |        |  - swiftpwa_toast_send    |
+-------------+---------------+        |    (C++/WinRT, ToastMgr)  |
              |                        +---------------------------+
              v
+-----------------------------+
| Win32Window                 |  + SystemClipboard (Win32 CB API)
|  - CreateWindowExW          |  + SystemTray (Shell_NotifyIconW)
|  - WM_SIZE → fitTo(client)  |  + SystemNotifications (WinRT toast,
|  - WM_DPICHANGED → resize   |    Shell_NotifyIcon balloon fallback)
|  - DIP ↔ physical px        |
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
- **Notifications go through `Windows.UI.Notifications.ToastNotificationManager`.**
  The C++/WinRT shim (`swiftpwa_toast.cpp`) constructs a
  `ToastGeneric` XML payload and `Show()`s it through a notifier
  bound to the process's AUMID. We didn't take a `swift-winrt`
  dependency for this — the WinRT surface area is one notifier, one
  XML payload, one event, so a flat C ABI over the same handful of
  WinRT calls is the simpler path (same rationale as keeping
  WebView2's COM behind `swiftpwa_webview2.cpp`). When the WinRT
  path fails (Server Core without the Desktop Experience, missing
  AUMID, etc.) `SystemNotifications` falls back to a
  `Shell_NotifyIconW` balloon tip so something still shows.
- **Tray uses `Shell_NotifyIconW`, not the StatusNotifierItem spec.**
  Windows has no SNI; Microsoft has not migrated the notification
  area to a modern API. Right-click pops a `TrackPopupMenu`; left-click
  emits `TrayEvent.click` only when no menu is currently set, mirroring
  the macOS `NSStatusItem` behavior.

## Keyboard shortcuts

| Shortcut       | Action                                        |
|----------------|-----------------------------------------------|
| `Ctrl+Q`       | Quit (matches the Linux GTK binding).         |
| `Ctrl+Alt+J`   | Open WebView2 DevTools in a separate window.  |

The DevTools binding is cross-platform: `Cmd+Opt+J` on macOS via
WKWebView's `_showInspector:` SPI and `Ctrl+Alt+J` on Linux via
`webkit_web_inspector_show`.

## Known limitations (Windows-specific)

- **Action Center persistence requires a Start-menu shortcut.** The
  runtime sets a stable AppUserModelID at process start
  (`SwiftPWA.<exe-stem>`) which is enough for toasts to *show*, but
  Windows only keeps them in Action Center across reboots when the
  AUMID also matches a Start-menu `.lnk` registered with the same id.
  The MSIX path takes care of this automatically; portable bundles
  shipping outside an installer don't get persistence.
- **Notification ids are synthesized UUIDs.** The cross-platform
  `Notifications` protocol doesn't currently expose a caller-supplied
  tag, so `swift-pwa` synthesizes a UUID per send. The shim itself
  (`swiftpwa_toast_send`) takes a tag; surfacing it requires a
  protocol-level addition.
- **MSIX builds are x64-only by default.** The generated
  `AppxManifest.xml` declares `ProcessorArchitecture="x64"`. To ship
  ARM64 packages, build on an ARM64 host and edit the manifest (or
  wait for the bundler's `--arch` flag).
