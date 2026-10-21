#if os(iOS)
    import Foundation
    import SwiftPWACore
    import UIKit

    /// ``AppIcons`` on iOS: `UIApplication`'s alternate icons. The bundler
    /// compiles each `alternate_icons` entry under its own name and registers
    /// it in `CFBundleIcons` → `CFBundleAlternateIcons`, which is where the
    /// list comes from — so it matches the build, not the source manifest.
    struct IOSAppIcons: AppIcons {
        func state() async throws -> AppIconState {
            let alternates = Self.declaredAlternates()
            return await MainThread.run {
                AppIconState(
                    current: UIApplication.shared.alternateIconName,
                    alternates: alternates,
                    supported: UIApplication.shared.supportsAlternateIcons
                )
            }
        }

        /// iOS confirms the change with an alert of its own and calls back
        /// once the person dismisses it; the icon has changed by then. The
        /// change also lands if the app is closed with the alert still up.
        func select(_ name: String?) async throws {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                Task {
                    await MainThread.run {
                        UIApplication.shared.setAlternateIconName(name) { error in
                            if let error {
                                continuation.resume(throwing: BridgeError(
                                    code: BridgeError.handler,
                                    message: "app.icon.set: \(error.localizedDescription)"
                                ))
                            } else {
                                continuation.resume()
                            }
                        }
                    }
                }
            }
        }

        /// The alternates the bundle registers, sorted by name: the
        /// dictionary has no order, and a stable one keeps a settings screen
        /// from reshuffling between launches.
        static func declaredAlternates(in info: [String: Any]? = Bundle.main.infoDictionary) -> [String] {
            let icons = info?["CFBundleIcons"] as? [String: Any]
            let alternates = icons?["CFBundleAlternateIcons"] as? [String: Any]
            return (alternates?.keys).map { $0.sorted() } ?? []
        }
    }
#endif
