# Swift API

## Hello, world

```swift
import SwiftPWA

@main
struct HelloApp {
    static func main() async throws {
        let runtime = try SwiftPWA.runtime()
        try runtime.run { ctx in
            _ = try ctx.createWindow(.init(
                title: "Hello",
                size: .init(width: 1024, height: 768),
                content: .bundled(
                    Bundle.main.bundleURL.appendingPathComponent("web/index.html")
                )
            ))
        }
    }
}
```

`SwiftPWA.runtime()` returns the platform-appropriate `AppRuntime` —
`MacAppRuntime`, `IOSAppRuntime`, `GTKAppRuntime`, or
`WindowsAppRuntime`. The umbrella module re-exports the platform
backend through `@_exported import`, so the call site doesn't change.

## Registering custom commands

```swift
struct GreetArgs: Codable, Sendable { let name: String }

try runtime.run { ctx in
    await ctx.registry.register("my.greet") { (args: GreetArgs, _) in
        "hello, \(args.name)"
    }

    // Streaming command — every yield becomes an `event` frame on JS;
    // returning ends the stream.
    await ctx.registry.registerStream("my.tick") { (_: EmptyArgs, ctx) in
        AsyncThrowingStream<Int, any Error> { continuation in
            Task {
                for i in 0 ..< 10 {
                    try? await Task.sleep(for: .seconds(1))
                    continuation.yield(i)
                }
                continuation.finish()
            }
        }
    }
}
```

`Args` and the return type must be `Codable + Sendable`. The bridge
runtime serializes them through `JSONEncoder` / `JSONDecoder`, so any
JSON-compatible shape works.

## Built-in plugins

`WindowPlugin` and `ClipboardPlugin` are auto-installed on every
backend — apps don't need to opt in. Everything else is à la carte so
apps that don't need a tray / file dialogs / biometrics don't pay the
binary or runtime cost.

```swift
try runtime.run { ctx in
    ctx.use(DialogPlugin(SystemDialog()))
    ctx.use(FsPlugin(SystemFs()))
    ctx.use(BiometricAuthPlugin(SystemBiometricAuth()))
    ctx.use(TrayPlugin(SystemTray()))
    ctx.use(NotificationsPlugin(SystemNotifications()))
    ctx.use(UpdaterPlugin(AppleUpdater(
        endpoint: URL(string: "https://updates.example.com/{{target}}/{{current_version}}")!,
        publicKey: "BASE64-OF-32-RAW-ED25519-BYTES" // nil on iOS
    )))

    _ = try ctx.createWindow(...)
}
```

The constructor for each plugin takes a `System*` adapter — the
platform-specific implementation provided by the umbrella module.
Tests substitute `_SwiftPWATestSupport.Mock*` instead, which the same
plugin shape accepts without changes.

## Multi-window

```swift
let main = try ctx.createWindow(.init(title: "Main", ...))
let inspector = try ctx.createWindow(.init(title: "Inspector",
    size: .init(width: 480, height: 720),
    content: .bundled(...inspector.html)))

ctx.windows         // → [main, inspector]
inspector.focus()
inspector.close()
```

`ctx.createWindow` is supported on macOS / Linux / Windows. iOS is
UIScene-aware: a single scene is polished, multi-scene scaffolded.
The cross-platform `Window` protocol documents per-method support;
unsupported operations log a one-shot warning rather than throwing.

## Window events

```swift
let main = try ctx.createWindow(...)

await main.subscribe { event in
    switch event {
    case .didFocus:        /* ... */
    case .didBlur:         /* ... */
    case .didResize(let s):/* s is in DIPs */
    case .didMove(let p):
    case .didMinimize, .didDeminiaturize:
    case .didEnterFullscreen, .didExitFullscreen:
    case .willClose:       /* ... */
    }
}
```

WM-driven focus / minimize / fullscreen events on Linux are currently
only emitted when the corresponding programmatic method is called —
user-driven changes (alt-tab, click another window) don't yet reach
subscribers on either GTK backend. See
[docs/linux-setup.md](linux-setup.md#known-limitations-on-linux).

## Concurrency model

Two non-obvious points worth pinning:

1. **`CommandRegistry` is a class with `NSLock`-guarded state, not an
   actor.** Registration is *synchronous* on purpose so user
   `configure` closures can run on a thread that isn't pumping Swift's
   MainActor executor — typically the main thread before `gtk_main()`
   enters its loop on Linux.
2. **`BridgeRuntime` is *not* `@MainActor`.** Backends are responsible
   for hopping to the platform UI thread internally via
   `MainThread.run`, which routes through a per-backend dispatch hook
   installed at startup (`DispatchQueue.main` on Apple, `g_idle_add`
   on GTK, a hidden `HWND_MESSAGE` window on Windows). Use this rather
   than `await MainActor.run` in any code path that may execute under
   `gtk_main()` or a Win32 message pump — the libdispatch main queue
   isn't drained by either, and a `Task { @MainActor in ... }` will
   never fire.

These are the same tripwires `Examples/HelloPWA` is built against; if
you find yourself fighting a "the call hangs" symptom, the answer is
almost always to route through `MainThread.run`.
