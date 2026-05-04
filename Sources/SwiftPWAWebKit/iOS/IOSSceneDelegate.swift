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
