import Foundation

/// A parsed RGB colour, components in `0...1`. Platform-agnostic so Core
/// can carry a `window.background_color` without importing UIKit / AppKit /
/// GTK; each backend converts it to its native colour type.
///
/// Parses `#RGB`, `#RRGGBB` (and the same without the leading `#`). Alpha
/// is always fully opaque — a window background is a solid fill.
public struct RGBColor: Sendable, Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Parse a hex string. Returns `nil` for anything that isn't 3- or
    /// 6-digit hex (with an optional leading `#`).
    public init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        let hexDigits: String
        switch s.count {
        case 3: // #RGB → #RRGGBB
            hexDigits = s.map { "\($0)\($0)" }.joined()
        case 6:
            hexDigits = s
        default:
            return nil
        }
        guard let value = UInt32(hexDigits, radix: 16) else { return nil }
        red = Double((value >> 16) & 0xFF) / 255.0
        green = Double((value >> 8) & 0xFF) / 255.0
        blue = Double(value & 0xFF) / 255.0
    }

    /// 0–255 component bytes (for backends that want integer channels).
    public var bytes: (r: UInt8, g: UInt8, b: UInt8) {
        (UInt8((red * 255).rounded()), UInt8((green * 255).rounded()), UInt8((blue * 255).rounded()))
    }
}
