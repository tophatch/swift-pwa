import Foundation

/// Cross-platform size. Use this in the public API instead of `CGSize`
/// so that the `Window` / `WebView` protocols are identical on Apple
/// and Linux (where `CoreGraphics` is unavailable).
public struct Size: Sendable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = Size(width: 0, height: 0)
}

/// Cross-platform point.
public struct Point: Sendable, Hashable, Codable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point(x: 0, y: 0)
}

#if canImport(CoreGraphics)
    import CoreGraphics

    public extension Size {
        var cgSize: CGSize {
            CGSize(width: width, height: height)
        }
        init(_ cg: CGSize) { self.init(width: Double(cg.width), height: Double(cg.height)) }
    }

    public extension Point {
        var cgPoint: CGPoint {
            CGPoint(x: x, y: y)
        }
        init(_ cg: CGPoint) { self.init(x: Double(cg.x), y: Double(cg.y)) }
    }
#endif
