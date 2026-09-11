#if os(macOS) || os(iOS)
    import Foundation
    import SwiftPWACore

    #if os(macOS)
        import AppKit
    #else
        import UIKit
    #endif

    /// A `WindowBackgroundColor` pair has to follow the system appearance while
    /// the app runs, not just at launch: on iOS this colour is the rubber-band
    /// overscroll area, so it is on screen during every bounce. Both AppKit and
    /// UIKit resolve a dynamic colour themselves whenever the appearance
    /// changes, so the pair is handed to the platform rather than tracked here.
    ///
    /// `RGBColor` is spelled out: AppKit re-exports Carbon's QuickDraw struct of
    /// the same name, so the bare name is ambiguous in this module.
    extension WindowBackgroundColor {
        #if os(macOS)
            /// `nil` when either half isn't valid hex.
            func nsColor() -> NSColor? {
                guard let light = rgb(dark: false), let dark = rgb(dark: true) else { return nil }
                guard isPair else { return Self.native(light) }
                return NSColor(name: nil) { appearance in
                    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                        ? Self.native(dark)
                        : Self.native(light)
                }
            }

            private static func native(_ rgb: SwiftPWACore.RGBColor) -> NSColor {
                NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            }
        #else
            /// `nil` when either half isn't valid hex.
            func uiColor() -> UIColor? {
                guard let light = rgb(dark: false), let dark = rgb(dark: true) else { return nil }
                guard isPair else { return Self.native(light) }
                return UIColor { traits in
                    traits.userInterfaceStyle == .dark ? Self.native(dark) : Self.native(light)
                }
            }

            private static func native(_ rgb: SwiftPWACore.RGBColor) -> UIColor {
                UIColor(red: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
            }
        #endif
    }
#endif
