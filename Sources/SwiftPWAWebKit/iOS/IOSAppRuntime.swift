#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit
    import WebKit

    /// iOS runtime. Bootstraps `UIApplication` with a UIScene-aware
    /// delegate; the configure closure runs as soon as the first scene
    /// is connected, so it has a real `UIWindow` to attach to.
    ///
    /// **Status**: scaffolded but the per-scene window plumbing is
    /// minimal. Multi-scene iPad multitasking will land in a follow-up
    /// once we have a real iOS test target running in CI.
    @MainActor
    public final class IOSAppRuntime {
        public static let shared = IOSAppRuntime()
        public let context = IOSAppContext()

        /// Configure block stashed until the first scene is ready.
        public var pendingConfigure: ((any AppContext) throws -> Void)?

        private init() {}

        public func bootstrap(
            configure: @escaping @MainActor @Sendable (any AppContext) throws -> Void
        ) {
            // Install MainThread hook eagerly so anything scheduled
            // before the first scene connects still hops correctly.
            MainThread.setHook { body in
                if Thread.isMainThread {
                    body()
                } else {
                    DispatchQueue.main.async { body() }
                }
            }
            pendingConfigure = configure
        }

        public func runForever() -> Never {
            UIApplicationMain(
                CommandLine.argc,
                CommandLine.unsafeArgv,
                nil,
                NSStringFromClass(SwiftPWAAppDelegate.self)
            )
            // UIApplicationMain never returns.
            fatalError("UIApplicationMain returned")
        }
    }

    @MainActor
    public final class IOSAppContext: AppContext {
        public let registry = CommandRegistry()
        public private(set) var windows: [WindowID: any Window] = [:]
        private var installedPlugins: Set<String> = []

        public init() {
            use(WindowPlugin())
        }

        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            // iOS windows are tied to a scene; we instantiate a
            // detached IOSWindow now and the SceneDelegate attaches
            // it to a UIWindow when a scene connects.
            let win = try IOSWindow(config: config, app: self)
            windows[win.id] = win
            return win
        }

        public func use(_ plugin: any Plugin) {
            let name = type(of: plugin).pluginName
            guard installedPlugins.insert(name).inserted else { return }
            plugin.register(into: registry, app: self)
        }

        public func window(_ id: WindowID) -> (any Window)? { windows[id] }

        public func quit(exitCode: Int32) {
            // iOS apps cannot programmatically terminate cleanly. Quit
            // is a no-op; users should rely on system-driven lifecycle.
            _ = exitCode
        }

        func windowDidClose(_ id: WindowID) { windows.removeValue(forKey: id) }
    }

    public final class SwiftPWAAppDelegate: UIResponder, UIApplicationDelegate {
        public func application(
            _ application: UIApplication,
            didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
        ) -> Bool {
            true
        }

        public func application(
            _ application: UIApplication,
            configurationForConnecting connectingSceneSession: UISceneSession,
            options: UIScene.ConnectionOptions
        ) -> UISceneConfiguration {
            let config = UISceneConfiguration(name: "swift-pwa", sessionRole: connectingSceneSession.role)
            config.delegateClass = SwiftPWASceneDelegate.self
            return config
        }
    }
#endif
