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

    public func register(into registry: CommandRegistry, app: any AppContext) async {
        // Capture as a weak-ish escape: AppContext is @MainActor, an
        // AnyObject existential, so closures hold a strong ref. The
        // plugin is intended to live for the full app lifetime.
        let app = app

        await registry.register("window.id", typed: { (_: EmptyArgs, ctx) -> WindowIDResult in
            guard let id = ctx.originWindow else {
                throw BridgeError(code: BridgeError.notFound, message: "no origin window")
            }
            return WindowIDResult(id: id.raw)
        })

        await registry.register("window.list", typed: { (_: EmptyArgs, _) async -> WindowListResult in
            let ids = await MainActor.run { app.windows.keys.map(\.raw) }
            return WindowListResult(ids: ids)
        })

        await registry.register("window.setTitle", typed: { (args: SetTitleArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.setTitle(args.title) }
            return EmptyResult()
        })

        await registry.register("window.title", typed: { (args: TargetOnlyArgs, ctx) async throws -> StringResult in
            try await onWindow(args.id, ctx: ctx, app: app) { StringResult(value: $0.title()) }
        })

        await registry.register("window.setSize", typed: { (args: SetSizeArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) {
                $0.setSize(Size(width: args.width, height: args.height), animated: args.animated ?? false)
            }
            return EmptyResult()
        })

        await registry.register("window.size", typed: { (args: TargetOnlyArgs, ctx) async throws -> Size in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.size() }
        })

        await registry.register(
            "window.setPosition",
            typed: { (args: SetPositionArgs, ctx) async throws -> EmptyResult in
                try await onWindow(args.id, ctx: ctx, app: app) { $0.setPosition(Point(x: args.x, y: args.y)) }
                return EmptyResult()
            }
        )

        await registry.register("window.position", typed: { (args: TargetOnlyArgs, ctx) async throws -> Point in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.position() }
        })

        await registry.register("window.focus", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.focus() }
            return EmptyResult()
        })

        await registry.register("window.minimize", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.minimize() }
            return EmptyResult()
        })

        await registry.register("window.maximize", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.maximize() }
            return EmptyResult()
        })

        await registry.register(
            "window.setFullscreen",
            typed: { (args: SetFullscreenArgs, ctx) async throws -> EmptyResult in
                try await onWindow(args.id, ctx: ctx, app: app) { $0.setFullscreen(args.on) }
                return EmptyResult()
            }
        )

        await registry.register(
            "window.isFullscreen",
            typed: { (args: TargetOnlyArgs, ctx) async throws -> BoolResult in
                try await onWindow(args.id, ctx: ctx, app: app) { BoolResult(value: $0.isFullscreen()) }
            }
        )

        await registry.register("window.close", typed: { (args: TargetOnlyArgs, ctx) async throws -> EmptyResult in
            try await onWindow(args.id, ctx: ctx, app: app) { $0.close() }
            return EmptyResult()
        })

        await registry.registerStream(
            "window.subscribe",
            typed: { (args: TargetOnlyArgs, ctx) -> AsyncThrowingStream<WindowEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task { @MainActor in
                        let target: WindowID? = args.id.map(WindowID.init(raw:)) ?? ctx.originWindow
                        guard let target, let win = app.window(target) else {
                            continuation.finish(throwing: BridgeError(
                                code: BridgeError.notFound,
                                message: "no such window"
                            ))
                            return
                        }
                        let stream = win.eventStream()
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

// MARK: - helpers

@MainActor
private func resolveWindow(_ id: String?, ctx: CommandContext, app: any AppContext) -> (any Window)? {
    let target: WindowID? = id.map(WindowID.init(raw:)) ?? ctx.originWindow
    guard let target else { return nil }
    return app.window(target)
}

/// Hop to MainActor and run `body` against the resolved window. Throws
/// `.notFound` if the id (or implicit origin) doesn't match any window.
private func onWindow<T: Sendable>(
    _ id: String?,
    ctx: CommandContext,
    app: any AppContext,
    _ body: @MainActor @Sendable (any Window) throws -> T
) async throws -> T {
    try await MainActor.run {
        guard let win = resolveWindow(id, ctx: ctx, app: app) else {
            throw BridgeError(code: BridgeError.notFound, message: "no such window")
        }
        return try body(win)
    }
}
