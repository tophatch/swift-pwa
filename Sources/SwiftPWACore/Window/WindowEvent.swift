import Foundation

/// Lifecycle / state-change events emitted by a `Window`.
public enum WindowEvent: Sendable, Equatable, Codable {
    case willClose
    case didClose
    case didResize(Size)
    case didMove(Point)
    case didFocus
    case didBlur
    case didEnterFullscreen
    case didExitFullscreen
    case didMinimize
    case didDeminiaturize

    private enum CodingKeys: String, CodingKey {
        case type, size, point
    }

    private enum Tag: String, Codable {
        case willClose, didClose, didResize, didMove, didFocus, didBlur,
             didEnterFullscreen, didExitFullscreen, didMinimize, didDeminiaturize
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try c.decode(Tag.self, forKey: .type)
        switch tag {
        case .willClose: self = .willClose
        case .didClose: self = .didClose
        case .didResize: self = .didResize(try c.decode(Size.self, forKey: .size))
        case .didMove: self = .didMove(try c.decode(Point.self, forKey: .point))
        case .didFocus: self = .didFocus
        case .didBlur: self = .didBlur
        case .didEnterFullscreen: self = .didEnterFullscreen
        case .didExitFullscreen: self = .didExitFullscreen
        case .didMinimize: self = .didMinimize
        case .didDeminiaturize: self = .didDeminiaturize
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .willClose: try c.encode(Tag.willClose, forKey: .type)
        case .didClose: try c.encode(Tag.didClose, forKey: .type)
        case .didResize(let size):
            try c.encode(Tag.didResize, forKey: .type)
            try c.encode(size, forKey: .size)
        case .didMove(let point):
            try c.encode(Tag.didMove, forKey: .type)
            try c.encode(point, forKey: .point)
        case .didFocus: try c.encode(Tag.didFocus, forKey: .type)
        case .didBlur: try c.encode(Tag.didBlur, forKey: .type)
        case .didEnterFullscreen: try c.encode(Tag.didEnterFullscreen, forKey: .type)
        case .didExitFullscreen: try c.encode(Tag.didExitFullscreen, forKey: .type)
        case .didMinimize: try c.encode(Tag.didMinimize, forKey: .type)
        case .didDeminiaturize: try c.encode(Tag.didDeminiaturize, forKey: .type)
        }
    }
}
