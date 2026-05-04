import Foundation

/// Optional plugin that exposes the `tray.*` command set to JS.
///
/// Unlike `WindowPlugin` and `ClipboardPlugin`, this plugin is *not*
/// auto-installed: constructing the platform tray (`SystemTray()`)
/// puts a visible icon in the menu bar / system tray, which most apps
/// want to opt into rather than have unconditionally. Users opt in:
///
/// ```swift
/// runtime.run { ctx in
///     ctx.use(TrayPlugin(SystemTray()))
/// }
/// ```
///
/// On platforms without a system tray (iOS, GTK4) `SystemTray()`
/// returns a no-op stub so the same call site works everywhere — the
/// plugin's commands resolve, they just don't display anything.
public struct TrayPlugin: Plugin {
    public static let pluginName = "tray"

    private let tray: any Tray

    public init(_ tray: any Tray) {
        self.tray = tray
    }

    public func register(into registry: CommandRegistry, app _: any AppContext) {
        let tray = tray

        registry.register(
            "tray.setIcon",
            typed: { (args: TraySetIconArgs, _) async throws -> EmptyResult in
                try await MainThread.run {
                    tray.setIcon(path: args.path, template: args.template ?? false)
                }
                return EmptyResult()
            }
        )

        registry.register(
            "tray.setTooltip",
            typed: { (args: TraySetTooltipArgs, _) async throws -> EmptyResult in
                try await MainThread.run { tray.setTooltip(args.text) }
                return EmptyResult()
            }
        )

        registry.register(
            "tray.setMenu",
            typed: { (args: TrayMenu, _) async throws -> EmptyResult in
                try await MainThread.run { tray.setMenu(args) }
                return EmptyResult()
            }
        )

        registry.register(
            "tray.setVisible",
            typed: { (args: TraySetVisibleArgs, _) async throws -> EmptyResult in
                try await MainThread.run { tray.setVisible(args.visible) }
                return EmptyResult()
            }
        )

        registry.registerStream(
            "tray.subscribe",
            typed: { (_: EmptyArgs, _) -> AsyncThrowingStream<TrayEvent, any Error> in
                AsyncThrowingStream { continuation in
                    let task = Task {
                        let stream = await MainThread.run { tray.eventStream() }
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
