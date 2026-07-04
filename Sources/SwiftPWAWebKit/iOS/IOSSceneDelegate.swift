#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit

    /// Pairs an incoming `UIScene` with one of the `IOSWindow`s created
    /// from the user's configure closure. The first scene to connect
    /// triggers configure (since it's the first time we have a real
    /// `UIWindow`), subsequent scenes pull the next pending window.
    @MainActor
    public final class SwiftPWASceneDelegate: UIResponder, UIWindowSceneDelegate {
        public var window: UIWindow?
        /// Retains opened security-scoped URLs so the grant stays active for
        /// the scene's lifetime (the web app reads them via `fs.readBinary`
        /// after an async bridge round-trip). See the macOS counterpart.
        private var scopedURLs: [URL] = []

        public func scene(
            _ scene: UIScene,
            willConnectTo session: UISceneSession,
            options connectionOptions: UIScene.ConnectionOptions
        ) {
            guard let windowScene = scene as? UIWindowScene else { return }
            let runtime = IOSAppRuntime.shared
            let context = runtime.context

            // First-scene boot: run the user's configure closure.
            if let configure = runtime.pendingConfigure {
                runtime.pendingConfigure = nil
                try? configure(context)
            }
            attachNextPendingWindow(to: windowScene)

            // Cold-launch open: a file that launched the app arrives here, not
            // via `scene(_:openURLContexts:)`. Emitted retained, so the WebView
            // receives it once it subscribes.
            emitOpen(connectionOptions.urlContexts)
        }

        /// Warm-launch open: the app is already running and the OS hands it a
        /// document / URL to open.
        public func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
            emitOpen(URLContexts)
        }

        /// Forward the file URLs in `contexts` to JS over the ``OpenFile``
        /// channel, activating (and retaining) the sandbox grant for each.
        private func emitOpen(_ contexts: Set<UIOpenURLContext>) {
            let fileURLs = contexts.map(\.url).filter(\.isFileURL)
            guard !fileURLs.isEmpty else { return }
            for url in fileURLs where url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
            OpenFile.emit(fileURLs.map(\.path), on: IOSAppRuntime.shared.context.events)
        }

        private func attachNextPendingWindow(to windowScene: UIWindowScene) {
            let context = IOSAppRuntime.shared.context
            // Pick the first IOSWindow with no UIWindow attached.
            let candidate = context.windows.values
                .compactMap { $0 as? IOSWindow }
                .first(where: { $0.uiWindow == nil })
            guard let pending = candidate else { return }
            let uiWindow = UIWindow(windowScene: windowScene)
            uiWindow.rootViewController = pending.viewController
            pending.uiWindow = uiWindow
            uiWindow.makeKeyAndVisible()
        }
    }
#endif
