import Foundation

/// A window's native background colour: either one colour, or a light/dark
/// pair the backend resolves against the system appearance.
///
/// The pair exists because this colour is not only a launch colour. On iOS it
/// paints the scroll view's rubber-band area, so it is on screen during every
/// overscroll — a dark-themed app painted with one light value flashes white on
/// each bounce, and a light-themed app painted dark flashes black. `#RGB` and
/// `#RRGGBB` are both accepted (see ``RGBColor``).
///
/// A string literal still spells a single colour, so
/// `WindowConfig(… backgroundColor: "#0C0D0E")` keeps working; use
/// ``WindowBackgroundColor/init(_:)`` for a `String` held in a variable.
public enum WindowBackgroundColor: Sendable, Equatable, ExpressibleByStringLiteral {
    /// One colour, used in both appearances.
    case single(String)
    /// Two colours, picked by the system appearance at paint time.
    case dayNight(light: String, dark: String)

    public init(stringLiteral value: String) { self = .single(value) }

    /// One colour for both appearances.
    public init(_ hex: String) { self = .single(hex) }

    /// A light/dark pair.
    public init(light: String, dark: String) { self = .dayNight(light: light, dark: dark) }

    /// The light-appearance colour (the single colour when not a pair).
    public var light: String {
        switch self {
        case let .single(hex): hex
        case let .dayNight(light, _): light
        }
    }

    /// The dark-appearance colour (the single colour when not a pair).
    public var dark: String {
        switch self {
        case let .single(hex): hex
        case let .dayNight(_, dark): dark
        }
    }

    /// Whether this carries two distinct values, i.e. whether a backend has to
    /// track the system appearance at all.
    public var isPair: Bool {
        if case .dayNight = self { true } else { false }
    }

    /// The hex for one appearance.
    public func hex(dark: Bool) -> String { dark ? self.dark : light }

    /// The parsed colour for one appearance, or `nil` if that half isn't
    /// valid hex. Backends treat `nil` as "no background configured" rather
    /// than substituting a colour the app never asked for.
    public func rgb(dark: Bool) -> RGBColor? { RGBColor(hex: hex(dark: dark)) }
}
