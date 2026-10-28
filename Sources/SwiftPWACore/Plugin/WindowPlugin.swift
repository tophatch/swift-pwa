import Foundation

/// Built-in plugin that exposes the `window.*` command set to JS.
///
/// Lives in Core so all backends share one implementation; backends only
/// need to provide `Window` protocol conformance.
///
/// Eats its own dogfood — uses the same `Plugin` registration path that
/// future tray / notification / clipboard plugins will use.
public struct WindowPlugin: Plugin {
    public static let pluginName = "window"
    public init() {}

    public func register(into registry: CommandRegistry, app: any AppContext) {
        // Capture as a weak-ish escape: AppContext is @MainActor, an
        // AnyObject existential, so closures hold a strong ref. The
        // plugin is intended to live for the full app lifetime.
        let app = app

        registry.register("window.id", typed: { (_: EmptyArgs, ctx) -> WindowIDResult in
            guard let id = ctx.originWindow else {
                throw BridgeError(code: BridgeError.notFound, message: "no origin window")
            }
            return WindowIDResult(id: id.raw)
        })

        registry.register("window.list", typed: { (_: EmptyArgs, _) async -> WindowListResult in
            let ids = await MainThread.run { app.windows.keys.map(\.raw) }
            return WindowListResult(ids: ids)
        })

        registry.register("window.setTitle", typed: { (args: SetTitleArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.setTitle(args.title) }
            return EmptyResult()
        })

        registry.register("window.title", typed: { (args: TargetOnlyArgs, ctx) async throws -> StringResult in
            try await onWindow(args.id, ctx: ctx, app: app) { StringResult(value: $0.title()) }
        })

        registry.register("window.setSize", typed: { (args: SetSizeArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) {
                $0.setSize(Size(width: args.width, height: args.height), animated: args.animated ?? false)
            }
            return EmptyResult()
        })

        registry.register("window.size", typed: { (args: TargetOnlyArgs, ctx) async throws -> Size in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.size() }
        })

        registry.register(
            "window.setPosition",
            typed: { (args: SetPositionArgs, ctx) async throws -> EmptyResult in
                try await onWindow(args.id, ctx: ctx, app: app) { $0.setPosition(Point(x: args.x, y: args.y)) }
                return EmptyResult()
            }
        )

        registry.register("window.position", typed: { (args: TargetOnlyArgs, ctx) async throws -> Point in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.position() }
        })

        registry.register("window.focus", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.focus() }
            return EmptyResult()
        })

        registry.register("window.minimize", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.minimize() }
            return EmptyResult()
        })

        registry.register("window.maximize", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.maximize() }
            return EmptyResult()
        })

        registry.register(
            "window.setFullscreen",
            typed: { (args: SetFullscreenArgs, ctx) async throws -> EmptyResult in
                try await onWindow(args.id, ctx: ctx, app: app) { $0.setFullscreen(args.on) }
                return EmptyResult()
            }
        )

        registry.register(
            "window.isFullscreen",
            typed: { (args: TargetOnlyArgs, ctx) async throws -> BoolResult in
                try await onWindow(args.id, ctx: ctx, app: app) { BoolResult(value: $0.isFullscreen()) }
            }
        )

        registry.register("window.close", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.close() }
            return EmptyResult()
        })

        // A picture of what this window is showing, for the page that is
        // showing it. The web has no API that rasterises a DOM subtree — the
        // libraries that fill the gap re-implement the renderer in JavaScript,
        // which is slow and blind to shadow-root CSS and `@font-face` — and the
        // engine already holds the pixels. An app animating its own content (a
        // page curl, a shared-element transition) needs exactly this.
        //
        // The snapshot is of the *webview*, not the screen: it works while the
        // window is occluded or backgrounded, and it needs no screen-recording
        // grant. Take it **before** mutating the DOM you want pictured — the
        // backends flush pending layout first, so a snapshot taken after the
        // mutation shows the new state, not the old one.
        //
        // `rect` asks for one region, in CSS pixels relative to the viewport.
        // On Windows and Android a whole window took 240-400 ms, nearly all of
        // it encoding three to four megapixels, so a smaller picture is what
        // makes the call fast enough to animate there.
        registry.register("window.snapshot", typed: { (args: SnapshotArgs, ctx) async throws -> WindowSnapshot in
            // Out of the UI thread before encoding: `PWAWebView` is
            // deliberately not main-actor isolated (each backend hops
            // internally), so a full-window PNG doesn't hold up the frame the
            // caller is about to animate.
            let webView = try await onWindow(args.id, ctx: ctx, app: app) { $0.webView }
            guard webView.supportsSnapshot else {
                throw BridgeError(
                    code: BridgeError.unimplemented,
                    message: "this backend can't snapshot its webview contents — check window.canSnapshot"
                )
            }
            var region: SnapshotRegion?
            if let rect = args.rect {
                region = try await SnapshotRegion.clip(rect, toViewportOf: webView)
            }
            let png = try await webView.captureSnapshot(region: region)
            guard let size = PNGDimensions.read(png) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "the backend's snapshot wasn't a PNG we could read a size out of"
                )
            }
            return WindowSnapshot(
                pngBase64: png.base64EncodedString(),
                width: size.width,
                height: size.height,
                bytes: png.count
            )
        })

        // Asked separately rather than discovered by catching an error, so an
        // app can offer the feature or not instead of rendering a snapshot to
        // find out whether it can.
        registry.register("window.canSnapshot", typed: { (args: TargetOnlyArgs, ctx) async throws -> BoolResult in
            try await onWindow(args.id, ctx: ctx, app: app) { BoolResult(value: $0.webView.supportsSnapshot) }
        })

        registry.registerStream(
            "window.subscribe",
            typed: { (args: TargetOnlyArgs, ctx) -> AsyncThrowingStream<WindowEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        // Resolve the target window on the UI thread.
                        let target: WindowID? = args.id.map(WindowID.init(raw:)) ?? ctx.originWindow
                        guard let target else {
                            continuation.finish(throwing: BridgeError(
                                code: BridgeError.notFound,
                                message: "no such window"
                            ))
                            return
                        }
                        let stream: AsyncStream<WindowEvent>? = await MainThread.run {
                            app.window(target)?.eventStream()
                        }
                        guard let stream else {
                            continuation.finish(throwing: BridgeError(
                                code: BridgeError.notFound,
                                message: "no such window"
                            ))
                            return
                        }
                        for await event in stream {
                            if Task.isCancelled { break }
                            continuation.yield(event)
                        }
                        continuation.finish()
                    }
                    continuation.onTermination = { _ in task.cancel() }
                }
            }
        )
    }
}

// MARK: - Argument / result types

public struct TargetOnlyArgs: Sendable, Codable {
    public var id: String?
    public init(id: String? = nil) { self.id = id }
}

public struct SnapshotArgs: Sendable, Codable {
    public var id: String?
    /// One region of the viewport, in CSS pixels — the coordinates
    /// `getBoundingClientRect()` returns. `nil` pictures the whole webview.
    public var rect: Rect?

    public init(id: String? = nil, rect: Rect? = nil) {
        self.id = id
        self.rect = rect
    }
}

/// Part of the viewport to snapshot: `rect` in CSS pixels — the coordinates
/// `getBoundingClientRect()` returns — inside a viewport of `viewport` CSS
/// pixels, clipped to it and on whole pixels.
///
/// The viewport travels with the rect so a backend can place it as a share of
/// its own viewport (`rect.x / viewport.width` of the way across) without
/// knowing the page's zoom. Android zooms a page out when its content
/// overflows, and then a CSS pixel is no longer `devicePixelRatio` device
/// pixels; an engine's idea of the zoom and the page's can disagree, but the
/// viewport the page reports and the one the backend draws are the same box.
public struct SnapshotRegion: Sendable, Hashable {
    public var rect: Rect
    public var viewport: Size

    public init(rect: Rect, viewport: Size) {
        self.rect = rect
        self.viewport = viewport
    }

    /// `rect` scaled into a viewport that is `width` x `height` in some other
    /// unit — a backend's points or device pixels.
    public func scaled(toWidth width: Double, height: Double) -> Rect {
        let sx = width / viewport.width
        let sy = height / viewport.height
        return Rect(x: rect.x * sx, y: rect.y * sy, width: rect.width * sx, height: rect.height * sy)
    }

    /// `rect` clipped to the viewport and widened to whole CSS pixels, so a
    /// backend never has to decide what a region hanging off the edge means,
    /// and the picture is `width * devicePixelRatio` wide on every engine.
    static func clip(_ rect: Rect, toViewportOf webView: any PWAWebView) async throws -> SnapshotRegion {
        let values = [rect.x, rect.y, rect.width, rect.height]
        guard values.allSatisfy(\.isFinite), rect.width > 0, rect.height > 0 else {
            throw BridgeError(
                code: BridgeError.decode,
                message: "rect needs finite numbers and a positive width and height"
            )
        }
        let reply = try await webView.evaluateJavaScript("[innerWidth, innerHeight]")
        guard let data = reply?.data(using: .utf8),
              let viewport = try? JSONDecoder().decode([Double].self, from: data), viewport.count == 2
        else {
            throw BridgeError(code: BridgeError.handler, message: "couldn't read the viewport's size")
        }
        return try clip(rect, toViewport: Size(width: viewport[0], height: viewport[1]))
    }

    static func clip(_ rect: Rect, toViewport viewport: Size) throws -> SnapshotRegion {
        let left = max(0, rect.x.rounded(.down))
        let top = max(0, rect.y.rounded(.down))
        let right = min(viewport.width.rounded(.down), (rect.x + rect.width).rounded(.up))
        let bottom = min(viewport.height.rounded(.down), (rect.y + rect.height).rounded(.up))
        guard right > left, bottom > top else {
            throw BridgeError(
                code: BridgeError.decode,
                message: "rect lies outside the \(Int(viewport.width))x\(Int(viewport.height)) viewport"
            )
        }
        return SnapshotRegion(
            rect: Rect(x: left, y: top, width: right - left, height: bottom - top),
            viewport: viewport
        )
    }
}

public struct SetTitleArgs: Sendable, Codable {
    public var id: String?
    public var title: String
}

public struct SetSizeArgs: Sendable, Codable {
    public var id: String?
    public var width: Double
    public var height: Double
    public var animated: Bool?
}

public struct SetPositionArgs: Sendable, Codable {
    public var id: String?
    public var x: Double
    public var y: Double
}

public struct SetFullscreenArgs: Sendable, Codable {
    public var id: String?
    public var on: Bool
}

public struct WindowIDResult: Sendable, Codable, Equatable {
    public var id: String
    public init(id: String) { self.id = id }
}

public struct WindowListResult: Sendable, Codable, Equatable {
    public var ids: [String]
    public init(ids: [String]) { self.ids = ids }
}

public struct StringResult: Sendable, Codable, Equatable {
    public var value: String
    public init(value: String) { self.value = value }
}

public struct BoolResult: Sendable, Codable, Equatable {
    public var value: Bool
    public init(value: Bool) { self.value = value }
}

/// What `window.snapshot` hands back: the picture, and the two numbers a page
/// needs to put it on a canvas without guessing.
///
/// `width` / `height` are **device pixels**, which on a Retina or high-DPI
/// display are not the window's CSS size — divide by `devicePixelRatio` to
/// place it, or draw at the full size for a sharp result. `bytes` is the PNG's
/// own length, before base64, so an app can tell a cheap snapshot from an
/// expensive one without measuring the string.
public struct WindowSnapshot: Sendable, Codable, Equatable {
    public var pngBase64: String
    public var width: Int
    public var height: Int
    public var bytes: Int

    public init(pngBase64: String, width: Int, height: Int, bytes: Int) {
        self.pngBase64 = pngBase64
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

// MARK: - helpers

@MainActor
private func resolveWindow(_ id: String?, ctx: CommandContext, app: any AppContext) -> (any Window)? {
    let target: WindowID? = id.map(WindowID.init(raw:)) ?? ctx.originWindow
    guard let target else { return nil }
    return app.window(target)
}

/// Hop to the UI thread (via `MainThread`) and run `body` against the
/// resolved window. Throws `.notFound` if the id (or implicit origin)
/// doesn't match any window.
///
/// We use `MainThread.run` rather than `MainActor.run` because Swift's
/// MainActor executor isn't pumped by `gtk_main()` on Linux; the GTK
/// backend installs a `g_idle_add`-based dispatch hook so this works
/// uniformly on all platforms.
private func onWindow<T: Sendable>(
    _ id: String?,
    ctx: CommandContext,
    app: any AppContext,
    _ body: @escaping @MainActor @Sendable (any Window) throws -> T
) async throws -> T {
    try await MainThread.run {
        guard let win = resolveWindow(id, ctx: ctx, app: app) else {
            throw BridgeError(code: BridgeError.notFound, message: "no such window")
        }
        return try body(win)
    }
}
