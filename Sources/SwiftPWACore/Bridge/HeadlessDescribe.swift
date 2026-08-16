import Foundation

/// Headless command-catalog dump — the codegen (roadmap #6) counterpart to the
/// `__bridge.describe` command, for use *without* a running window/webview.
///
/// When the environment variable ``environmentVariable`` (`SWIFT_PWA_DESCRIBE`)
/// is set to a file path, a backend's `run(configure:)` calls
/// ``dumpIfRequested(_:)`` *before* any UI bootstrap. That builds a headless
/// ``HeadlessAppContext`` (the same built-in plugins a real backend installs,
/// but with a no-op window factory), runs the app's own `configure` closure so
/// every plugin — including dynamically-named ones — registers, serializes
/// `registry.descriptors()` to the path as a `[CommandDescriptor]` JSON array,
/// and **exits before creating any window**. `swift-pwa codegen` drives this to
/// read the catalog straight from the built app, replacing the manual "capture
/// `__bridge.describe` in the devtools console" step.
///
/// Because it runs the real `configure` closure, the app must be **pure up to
/// registration** for a headless dump to be safe: `createWindow` returns a
/// no-op window and `serveDirectory`/`emit` are inert, but any *other* side
/// effect in `configure` (starting a download, spawning a process) still runs.
/// Guard such work behind ``isDumping`` if it must not run during codegen.
public enum HeadlessDescribe {
    /// The env var a backend checks. Set it to a writable file path to request a
    /// dump; matches the `SWIFT_PWA_GTK4` / `SWIFT_PWA_LINUX_GUI` env-flag
    /// convention. Unset (the normal case) ⇒ ``dumpIfRequested(_:)`` is a no-op.
    public static let environmentVariable = "SWIFT_PWA_DESCRIBE"

    /// Appended to the requested path for the compiled `AgentPlugin` tool list,
    /// written only when the app installs one. `swift-pwa build` reads it to
    /// check the binary's agent surface against `pwa.json`'s declaration.
    public static let agentCatalogSuffix = ".agent.json"

    /// Appended to the requested path for the app's declared web permissions,
    /// written only when it declares any. `swift-pwa build` reads it to check
    /// the runtime ceiling (`ctx.permissions.declare`) against `pwa.json`'s
    /// `permissions.web`, which is what drives the platform artifacts — the two
    /// have to agree or an app ships a manifest entry it will refuse to use, or
    /// asks for a device the artifact never declared.
    public static let permissionsCatalogSuffix = ".permissions.json"

    /// The requested output path, or `nil` when no dump was requested. Apps can
    /// read this in `configure` to skip side-effectful work during codegen.
    public static var requestedPath: String? {
        guard let path = ProcessInfo.processInfo.environment[environmentVariable],
              !path.isEmpty
        else { return nil }
        return path
    }

    /// `true` while a headless catalog dump is being produced — i.e. when
    /// ``requestedPath`` is set. Sugar so an app can branch in `configure`:
    /// `if HeadlessDescribe.isDumping { return }` after its `use(...)` calls to
    /// skip window creation / background work.
    public static var isDumping: Bool {
        requestedPath != nil
    }

    /// If ``environmentVariable`` names a path, dump the command catalog there
    /// and **terminate the process** — otherwise return so the caller proceeds
    /// with a normal launch. A backend calls this at the very top of
    /// `run(configure:)`, before any platform bootstrap.
    @MainActor
    public static func dumpIfRequested(
        _ configure: @MainActor @Sendable (any AppContext) throws -> Void
    ) {
        guard let path = requestedPath else { return }

        let context = HeadlessAppContext()
        do {
            try configure(context)
        } catch {
            // Registration failing is a hard error for codegen — we can't emit a
            // partial catalog and pretend it's complete.
            fail("configure threw during headless describe: \(error)")
        }

        let descriptors = context.registry.descriptors()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(descriptors)
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            fail("couldn't write catalog to \(path): \(error)")
        }

        // The compiled agent surface goes to a sibling path rather than into
        // the catalog: the catalog's shape is `__bridge.describe`'s and is
        // consumed by pre-captured files and generated clients, so widening it
        // would break readers for something only the build cares about.
        if let agent = context.installedAgentTools {
            do {
                let data = try encoder.encode(agent)
                try data.write(to: URL(fileURLWithPath: path + agentCatalogSuffix))
            } catch {
                fail("couldn't write the agent surface to \(path + agentCatalogSuffix): \(error)")
            }
        }

        // Same reasoning as the agent surface above: a sibling file, so the
        // catalog's shape stays `__bridge.describe`'s.
        let declared = context.permissions.declaredPermissions
        if !declared.isEmpty {
            do {
                let data = try encoder.encode(declared.map(\.rawValue).sorted())
                try data.write(to: URL(fileURLWithPath: path + permissionsCatalogSuffix))
            } catch {
                fail("couldn't write declared permissions to \(path + permissionsCatalogSuffix): \(error)")
            }
        }

        // Success. Never fall through to the UI loop.
        exit(0)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.writeQuietly(Data("swift-pwa: \(message)\n".utf8))
        exit(1)
    }
}

// MARK: - Headless AppContext

/// A UI-less ``AppContext`` used only for the ``HeadlessDescribe`` catalog dump.
/// It installs the same built-in plugins every backend's `AppContext.init`
/// does, so the emitted catalog matches a real launch's command set, and its
/// `createWindow` returns an inert window so an app's `configure` closure runs
/// to completion without a display server / webview.
///
/// - Important: the built-in plugin list here **must stay in sync** with the
///   set each backend installs (`WindowPlugin`, `PlatformInfoPlugin`,
///   `SystemPlugin`, `AppPlugin`, `EventsPlugin`, `ClipboardPlugin`). If a
///   backend gains a built-in, add it here too or it won't appear in generated
///   clients. The backend-specific *implementations* (`SystemClipboard`, the
///   Android memory provider) don't matter for codegen — only the command
///   *shapes* the plugins register — so no-op stand-ins are used.
@MainActor
public final class HeadlessAppContext: AppContext {
    public let registry = CommandRegistry()
    public let assetProvider = AssetProvider()
    public let events = EventBus()
    public let permissions = PermissionPolicy()
    public private(set) var windows: [WindowID: any Window] = [:]
    private var installedPlugins: Set<String> = []

    /// The tool list of an installed ``AgentPlugin``, or `nil` if the app
    /// installs none. Captured during `use` rather than read back off the
    /// registry, because the registry holds command *shapes* and the agent
    /// surface is data.
    public private(set) var installedAgentTools: [AgentTool]?

    public init() {
        use(WindowPlugin())
        use(PlatformInfoPlugin())
        use(SystemPlugin())
        use(AppPlugin())
        use(EventsPlugin())
        use(ClipboardPlugin(HeadlessClipboard()))
    }

    @discardableResult
    public func createWindow(_ config: WindowConfig) throws -> any Window {
        let win = HeadlessWindow(id: WindowID(), config: config)
        windows[win.id] = win
        return win
    }

    public func use(_ plugin: any Plugin) {
        let name = type(of: plugin).pluginName
        guard installedPlugins.insert(name).inserted else { return }
        if let agent = plugin as? AgentPlugin {
            installedAgentTools = agent.agentSurface.tools
        }
        plugin.register(into: registry, app: self)
    }

    public func window(_ id: WindowID) -> (any Window)? { windows[id] }

    public func quit(exitCode _: Int32) {}
}

/// Inert ``Window`` returned by ``HeadlessAppContext/createWindow(_:)``. State
/// setters are stored so a `configure` that reads them back doesn't misbehave;
/// nothing is rendered.
@MainActor
final class HeadlessWindow: Window {
    let id: WindowID
    let webView: any PWAWebView = HeadlessWebView()

    private var storedTitle: String
    private var storedSize: Size
    private var storedPosition: Point = .zero
    private var storedFullscreen = false

    init(id: WindowID, config: WindowConfig) {
        self.id = id
        storedTitle = config.title
        storedSize = config.size
    }

    func eventStream() -> AsyncStream<WindowEvent> { AsyncStream { $0.finish() } }

    func setTitle(_ title: String) { storedTitle = title }
    func title() -> String { storedTitle }
    func setSize(_ size: Size, animated _: Bool) { storedSize = size }
    func size() -> Size { storedSize }
    func setPosition(_ point: Point) { storedPosition = point }
    func position() -> Point { storedPosition }
    func focus() {}
    func minimize() {}
    func maximize() {}
    func setFullscreen(_ on: Bool) { storedFullscreen = on }
    func isFullscreen() -> Bool { storedFullscreen }
    func close() {}
}

/// Inert ``PWAWebView`` — the bridge never pumps during a headless dump.
final class HeadlessWebView: PWAWebView {
    func load(_: WindowContent) {}
    func evaluateJavaScript(_: String) async throws -> String? { nil }
    func deliver(_: OutboundFrame) async throws {}
    func inboundFrames() -> AsyncStream<InboundFrame> { AsyncStream { $0.finish() } }
}

/// No-op ``Clipboard`` for the headless context — `ClipboardPlugin` only needs a
/// conformer to register its command *shapes*; nothing is read or written.
private final class HeadlessClipboard: Clipboard {
    func readText() async throws -> String? { nil }
    func writeText(_: String) async throws {}
    func clear() async throws {}
}
