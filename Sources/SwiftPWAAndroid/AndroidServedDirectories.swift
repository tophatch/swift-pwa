#if os(Android)
    import CSwiftPWAAndroidJNI
    import Foundation
    import SwiftPWACore

    /// Answers `WebViewClient.shouldInterceptRequest` from the app's
    /// ``AssetProvider``, so `ctx.serveDirectory(_:at:)` works on Android.
    ///
    /// It didn't, at all, before #216's release. The `WebViewAssetLoader` is
    /// built in `Activity.onCreate`, before any Swift runs, so the only mounts
    /// that could exist were the ones `pwa.json`'s `build.serve` declared at
    /// build time, rooted inside app storage. That covers a content pack the
    /// app downloads into its own directory and nothing else — an app whose
    /// roots are folders the *user* points it at, wherever those already live,
    /// could not serve a single file to its own page. Copying them into app
    /// storage is a different product.
    ///
    /// The fix inverts the ownership: Kotlin keeps no mount table, and asks
    /// here for every request that reaches the `WebViewClient`. So the table
    /// is Core's, exactly the one the other four backends resolve against —
    /// same longest-prefix match, same per-mount traversal guard, same MIME
    /// table — and a mount added or removed mid-session takes effect on the
    /// next request with nothing to keep in sync.
    ///
    /// Two things make asking-every-time affordable. The call is a JNI upcall
    /// into a lock-guarded path lookup, on a WebView **worker** thread rather
    /// than the UI thread (`shouldInterceptRequest` is documented as such), so
    /// it costs a stat and blocks nothing the user can see. And it answers nil
    /// for everything outside a mount, which on Android is the entire app
    /// bundle: the `AssetProvider` here is created with no `/` root and never
    /// given one, because the bundle is the asset loader's job. An app that
    /// mounts nothing pays one pointer comparison per request.
    enum AndroidServedDirectories {
        /// Retained for the lifetime of the process: the C shim holds the
        /// pointer and the JVM calls back into it on every resource request.
        private nonisolated(unsafe) static var box: Unmanaged<ProviderBox>?

        static func install(provider: AssetProvider) {
            let retained = Unmanaged.passRetained(ProviderBox(provider: provider))
            box?.release()
            box = retained
            swiftpwa_android_set_mount_resolver(
                { url, user in
                    guard let url, let user else { return nil }
                    let box = Unmanaged<ProviderBox>.fromOpaque(user).takeUnretainedValue()
                    // `strdup` because the JNI trampoline frees what it gets:
                    // a Swift `String`'s buffer would not outlive this return.
                    return box.resolve(url: String(cString: url)).map { strdup($0) } ?? nil
                },
                retained.toOpaque()
            )
        }

        /// `@unchecked Sendable`: `AssetProvider` is itself lock-guarded and
        /// documented as safe to resolve against from any thread, which is the
        /// whole reason this seam can be synchronous.
        final class ProviderBox: @unchecked Sendable {
            private let provider: AssetProvider

            init(provider: AssetProvider) { self.provider = provider }

            /// The JSON the Kotlin side reads, or nil when `url` falls under no
            /// mount. Hand-built rather than `JSONEncoder`d: three fields, and
            /// this runs once per resource request.
            func resolve(url: String) -> String? {
                guard let parsed = URL(string: url), let hit = provider.resolve(parsed) else { return nil }
                return """
                {"path":\(jsonString(hit.fileURL.path)),\
                "mime":\(jsonString(hit.mimeType)),\
                "size":\(hit.fileSize)}
                """
            }

            /// A JSON string literal. A file path can hold a quote or a
            /// backslash, and the control-character escape is what stops a
            /// newline in a name from producing JSON Kotlin can't parse.
            private func jsonString(_ value: String) -> String {
                var out = "\""
                for scalar in value.unicodeScalars {
                    switch scalar {
                    case "\"": out += "\\\""
                    case "\\": out += "\\\\"
                    case "\n": out += "\\n"
                    case "\r": out += "\\r"
                    case "\t": out += "\\t"
                    default:
                        if scalar.value < 0x20 {
                            out += String(format: "\\u%04x", scalar.value)
                        } else {
                            out.unicodeScalars.append(scalar)
                        }
                    }
                }
                return out + "\""
            }
        }
    }
#endif
