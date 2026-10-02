#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit

    /// Pairs an incoming `UIScene` with an `IOSWindow`. The first scene to
    /// connect runs configure (the first time there's a real `UIWindow`) and
    /// takes the first window it creates; a later scene takes the window that
    /// asked for it, or a new one if the system opened it (see
    /// ``IOSAppContext/attachWindow(to:options:)``).
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
                context.prepareLaunch(restoring: session)
                do {
                    try configure(context)
                } catch {
                    FileHandle.standardError.writeQuietly(Data("swift-pwa: configure threw: \(error)\n".utf8))
                }
                // Opt-in dev/test control socket — see `AppDriver`. Only the
                // first scene starts it; a second one would fail to bind.
                AppDriver.startIfRequested(context, backend: "ios")
                context.finishLaunching(in: windowScene)
            } else {
                context.attachWindow(to: windowScene, options: connectionOptions)
            }

            // Cold-launch open: a file that launched the app arrives here, not
            // via `scene(_:openURLContexts:)`. Emitted retained, so the WebView
            // receives it once it subscribes.
            emitOpen(connectionOptions.urlContexts)
        }

        /// The scene came to the foreground. Surfaced as the window's
        /// `didFocus`, which is what the desktop backends emit when their
        /// window becomes active — so an app that re-reads state on becoming
        /// active writes it once and is right on every platform (#214). On iOS
        /// this matters more than on a desktop: an app that was backgrounded
        /// was *suspended*, so anything it was watching stopped being watched.
        public func sceneDidBecomeActive(_ scene: UIScene) {
            window(for: scene)?.emit(.didFocus)
        }

        /// Leaving the foreground — the moment an app re-locks, stops a
        /// recording, or saves. `willResignActive` rather than
        /// `didEnterBackground` so the work is queued while the process is
        /// still scheduled, and because it also covers the states short of
        /// backgrounding (a system alert, the app switcher).
        public func sceneWillResignActive(_ scene: UIScene) {
            window(for: scene)?.emit(.didBlur)
        }

        /// The last moment the page is sure to be recorded before the system
        /// can reclaim the scene or end the app.
        public func sceneDidEnterBackground(_ scene: UIScene) {
            window(for: scene)?.recordPage(in: scene.session)
        }

        public func sceneDidDisconnect(_ scene: UIScene) {
            guard let window = window(for: scene) else { return }
            window.recordPage(in: scene.session)
            window.sceneDidDisconnect()
        }

        /// The `IOSWindow` showing in `scene`, if it has one attached yet:
        /// lifecycle callbacks can arrive for a scene whose window is still
        /// pending.
        private func window(for scene: UIScene) -> IOSWindow? {
            IOSAppRuntime.shared.context.windows.values
                .compactMap { $0 as? IOSWindow }
                .first { $0.uiWindow?.windowScene === scene }
        }

        /// Warm-launch open: the app is already running and the OS hands it a
        /// document / URL to open.
        public func scene(_: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
            emitOpen(URLContexts)
        }

        /// Forward the URLs in `contexts` to JS: file URLs over ``OpenFile``
        /// (activating and retaining the sandbox grant for each), everything
        /// else — a deep link in a scheme the app registered in
        /// `CFBundleURLTypes` — over ``OpenURL``. Two channels, because a path
        /// to read and a URL to route are different payloads.
        private func emitOpen(_ contexts: Set<UIOpenURLContext>) {
            let urls = contexts.map(\.url)
            let fileURLs = urls.filter(\.isFileURL)
            for url in fileURLs where url.startAccessingSecurityScopedResource() {
                scopedURLs.append(url)
            }
            let events = IOSAppRuntime.shared.context.events
            OpenFile.emit(fileURLs.map(\.path), on: events)
            OpenURL.emit(urls.filter { !$0.isFileURL }.map(\.absoluteString), on: events)
        }
    }
#endif
