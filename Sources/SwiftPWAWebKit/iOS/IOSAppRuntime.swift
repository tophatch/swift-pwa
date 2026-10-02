#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit
    import WebKit

    /// iOS runtime. Bootstraps `UIApplication` with a UIScene-aware
    /// delegate; the configure closure runs as soon as the first scene
    /// is connected, so it has a real `UIWindow` to attach to.
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
            context.observeBackgrounding()
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
        public let assetProvider = AssetProvider()
        public let events = EventBus()
        public let permissions = PermissionPolicy()
        public let externalURLs = ExternalURLPolicy()

        /// The platform pieces a plugin can pick up without the app naming a
        /// backend type (see ``AppContext/urlOpener``).
        public let urlOpener: (any URLOpener)? = AppleURLOpener()
        public let authorizationSession: (any AuthorizationSessionPresenter)? = SystemAuthorizationSession()
        /// Stored to satisfy ``AppContext``; this backend never reads it.
        /// macOS is the only platform where an app outlives its windows —
        /// see ``LastWindowClosedPolicy``.
        public var lastWindowClosed: LastWindowClosedPolicy = .reopen
        public private(set) var windows: [WindowID: any Window] = [:]
        private var installedPlugins: Set<String> = []

        public init() {
            use(WindowPlugin())
            use(PlatformInfoPlugin())
            use(SystemPlugin(urlOpener: AppleURLOpener()))
            use(AppPlugin())
            use(PermissionsPlugin())
            // iOS has no All-files access to grant, and saying so up front is
            // the whole point of the seam.
            permissions.setAuthority(IOSPermissionAuthority())
            use(EventsPlugin())
            use(ClipboardPlugin(SystemClipboard()))
        }

        /// An iOS window is a scene's, and a scene is the system's to make. So
        /// a window starts detached: the one created while the app launches
        /// takes the launching scene, and one created later asks iPadOS for a
        /// scene of its own and is paired with it by id when it connects.
        ///
        /// Without multiple scenes (iPhone, or `ios.multiple_windows` off) a
        /// second window has nowhere to appear, and saying so is better than
        /// handing back a window nobody will ever see.
        @discardableResult
        public func createWindow(_ config: WindowConfig) throws -> any Window {
            guard windows.isEmpty || UIApplication.shared.supportsMultipleScenes else {
                throw BridgeError(
                    code: BridgeError.unimplemented,
                    message: "This app shows one window at a time: a second window needs an iPad "
                        + "and \"multiple_windows\": true in pwa.json's ios section"
                )
            }
            let restoring = launched ? nil : launchRestoreURL
            launchRestoreURL = nil
            let win = try IOSWindow(config: config, app: self, restoring: restoring)
            windows[win.id] = win
            if primaryConfig == nil { primaryConfig = config }
            if launched {
                requestScene(for: win)
            } else {
                windowsAwaitingLaunch.append(win)
            }
            return win
        }

        /// The first window's config. A window the system opens or brings
        /// back is built from it, showing the page it last showed.
        private var primaryConfig: WindowConfig?
        private var launched = false
        private var windowsAwaitingLaunch: [IOSWindow] = []
        /// What the launching scene last showed, when the system is bringing
        /// back a multi-window app's windows; the first window created loads it
        /// instead of its entry.
        private var launchRestoreURL: URL?

        static let windowActivityType = "swift-pwa.window"
        private static let windowIDKey = "windowID"

        /// The launching scene connected and `configure` ran: the first window
        /// it created takes `scene`, and any more ask for scenes of their own.
        func finishLaunching(in scene: UIWindowScene) {
            launched = true
            let waiting = windowsAwaitingLaunch
            windowsAwaitingLaunch = []
            guard let first = waiting.first else { return }
            first.attach(to: scene)
            for window in waiting.dropFirst() {
                requestScene(for: window)
            }
        }

        func prepareLaunch(restoring session: UISceneSession) {
            if UIApplication.shared.supportsMultipleScenes, let url = IOSWindow.lastPage(in: session) {
                launchRestoreURL = url
            }
        }

        /// The window for a scene that connected after launch: the one that
        /// asked for it, or, for a scene the system opened or brought back, a
        /// new window from the app's first config showing what that scene
        /// last showed.
        func attachWindow(to scene: UIWindowScene, options: UIScene.ConnectionOptions) {
            let requested = options.userActivities
                .first { $0.activityType == Self.windowActivityType }?
                .userInfo?[Self.windowIDKey] as? String
            if let requested {
                guard let window = windows[WindowID(raw: requested)] as? IOSWindow, window.uiWindow == nil else {
                    // The window that asked was closed before its scene came.
                    UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
                    return
                }
                window.attach(to: scene)
                return
            }
            guard let primaryConfig else { return }
            do {
                let window = try IOSWindow(
                    config: primaryConfig, app: self, restoring: IOSWindow.lastPage(in: scene.session)
                )
                windows[window.id] = window
                window.attach(to: scene)
            } catch {
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: couldn't make a window for a scene iPadOS opened: \(error)\n".utf8
                ))
            }
        }

        private func requestScene(for window: IOSWindow) {
            let activity = NSUserActivity(activityType: Self.windowActivityType)
            activity.userInfo = [Self.windowIDKey: window.id.raw]
            let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity)
            UIApplication.shared.activateSceneSession(for: request) { [weak window] error in
                FileHandle.standardError.writeQuietly(Data(
                    "swift-pwa: iPadOS didn't open a scene for a new window: \(error)\n".utf8
                ))
                Task { @MainActor in window?.close() }
            }
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

        private var backgroundObserver: (any NSObjectProtocol)?

        /// iOS has no quit: an app that goes to the background is suspended,
        /// and a suspended app can be killed without being told. Going to the
        /// background is therefore the last moment it is sure to run, and gets
        /// a background task long enough for each page to finish what it
        /// posted on going hidden and for the app's `beforeClose` handlers
        /// (reason `.backgrounded`) to run (#281).
        func observeBackgrounding() {
            backgroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushForBackground() }
            }
        }

        private func flushForBackground() {
            let task = BackgroundTask(named: "swift-pwa beforeClose")
            let deadline = ContinuousClock.now + CloseBudget.backgrounded
            let windows = windows.values.compactMap { $0 as? IOSWindow }
            Task { @MainActor in
                await withTaskGroup(of: Void.self) { group in
                    for window in windows {
                        group.addTask { await window.finishPageForBackground(until: deadline) }
                    }
                    group.addTask { await CloseHandlers.shared.run(.backgrounded, until: deadline) }
                }
                task.end()
            }
        }
    }

    /// Time to finish in, should the app be in the background: what a closing
    /// window or a backgrounding app has left to run would otherwise be
    /// suspended mid-flight.
    @MainActor
    final class BackgroundTask {
        private var id = UIBackgroundTaskIdentifier.invalid

        init(named name: String) {
            id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
                MainActor.assumeIsolated { self?.end() }
            }
        }

        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
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
