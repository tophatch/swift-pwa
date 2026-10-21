import Foundation

/// Switching between the app icons declared in `pwa.json`'s `alternate_icons`,
/// where the platform lets the person choose one: iOS / iPadOS
/// (`setAlternateIconName`) and Android (one launcher `<activity-alias>` per
/// icon). Every other platform has no supported way to make a choice stick —
/// see `docs/proposals/app-icon-appearances.md` for the macOS measurements —
/// so its backend supplies none and the commands report `supported: false`.
///
/// Names are the `name` of each `alternate_icons` entry; `nil` is the primary
/// icon.
public protocol AppIcons: Sendable {
    /// The icon in use and the alternates the app can switch to.
    func state() async throws -> AppIconState

    /// Show `name`'s icon, or the primary when `nil`. Only called with a name
    /// that ``state()`` listed.
    ///
    /// On iOS this returns once the person dismisses the system's
    /// confirmation alert, which iOS always shows; the switch has already
    /// happened by then.
    func select(_ name: String?) async throws
}

/// What `app.icon.list` replies with.
public struct AppIconState: Sendable, Codable, Equatable {
    /// The alternate in use, or `nil` for the primary icon.
    public var current: String?
    /// The alternates declared in `pwa.json`, by name. Empty where switching
    /// isn't supported, since there is nothing the page could do with them.
    public var alternates: [String]
    /// Whether this platform lets the person choose. A page leaves its icon
    /// setting out when this is `false`, rather than showing one that does
    /// nothing.
    public var supported: Bool

    public init(current: String?, alternates: [String], supported: Bool) {
        self.current = current
        self.alternates = alternates
        self.supported = supported
    }

    /// The answer on a platform without alternate icons.
    public static let unsupported = AppIconState(current: nil, alternates: [], supported: false)

    private enum CodingKeys: String, CodingKey { case current, alternates, supported }

    /// `current` is written as `null` for the primary icon rather than left
    /// out, so the page reads `null` — the value it passes back to
    /// `app.icon.set` — and not `undefined`.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let current {
            try container.encode(current, forKey: .current)
        } else {
            try container.encodeNil(forKey: .current)
        }
        try container.encode(alternates, forKey: .alternates)
        try container.encode(supported, forKey: .supported)
    }
}

/// `app.icon.set`'s argument.
public struct AppIconSetArgs: Sendable, Codable {
    /// An alternate's name, or `null` for the primary icon.
    public var name: String?

    public init(name: String?) {
        self.name = name
    }
}
