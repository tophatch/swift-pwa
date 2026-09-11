#if os(Linux)
    import CWebKitGTK6Shim
    import Foundation
    import SwiftPWACore

    /// ``URLOpener`` on Linux, via gio's `g_app_info_launch_default_for_uri`
    /// — the browser for `http(s)`, whichever `.desktop` file claims a custom
    /// scheme.
    ///
    /// gio rather than `gtk_show_uri_on_window` / `gtk_uri_launcher`, which
    /// are spelled differently in GTK3 and GTK4 and both want a window: this
    /// is one call that serves both backends and needs no window at all.
    public struct GTKURLOpener: URLOpener {
        public init() {}

        public func open(_ url: URL) async -> Bool {
            #if DEBUG
                // Test hook, debug builds only: the GUI suite runs under Xvfb
                // on a box with a real browser installed, and a launched
                // browser would outlive the run.
                if ProcessInfo.processInfo.environment["SWIFT_PWA_RECORD_OPENS"] != nil {
                    RecordedOpens.record(url)
                    return true
                }
            #endif
            return await MainThread.run {
                url.absoluteString.withCString { swiftpwa_open_uri_external($0) != 0 }
            }
        }
    }

    /// Where ``GTKURLOpener`` logs instead of launching, under
    /// `SWIFT_PWA_RECORD_OPENS` in a debug build. Test-only.
    public enum RecordedOpens {
        private static let lock = NSLock()
        private nonisolated(unsafe) static var urls: [String] = []

        static func record(_ url: URL) {
            lock.lock(); defer { lock.unlock() }
            urls.append(url.absoluteString)
        }

        /// Clears the log, so one test's expectations can't be satisfied by
        /// an earlier test's handoffs.
        public static func reset() {
            lock.lock(); defer { lock.unlock() }
            urls.removeAll()
        }

        public static var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return urls
        }
    }
#endif
