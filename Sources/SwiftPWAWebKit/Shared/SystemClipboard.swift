#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// `Clipboard` backed by `NSPasteboard.general` on macOS and
    /// `UIPasteboard.general` on iOS. Reads / writes hop to the UI thread
    /// because both classes are documented as main-thread only.
    public final class SystemClipboard: Clipboard, @unchecked Sendable {
        public init() {}

        public func readText() async throws -> String? {
            await MainThread.run {
                #if os(macOS)
                    NSPasteboard.general.string(forType: .string)
                #else
                    UIPasteboard.general.hasStrings ? UIPasteboard.general.string : nil
                #endif
            }
        }

        public func writeText(_ text: String) async throws {
            _ = await MainThread.run { () -> Bool in
                #if os(macOS)
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(text, forType: .string)
                #else
                    UIPasteboard.general.string = text
                #endif
                return true
            }
        }

        public func clear() async throws {
            _ = await MainThread.run { () -> Bool in
                #if os(macOS)
                    NSPasteboard.general.clearContents()
                #else
                    UIPasteboard.general.items = []
                #endif
                return true
            }
        }
    }
#endif
