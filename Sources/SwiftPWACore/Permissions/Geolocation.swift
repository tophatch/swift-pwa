import Foundation

/// Device location, as a native capability rather than a web API.
///
/// The web `navigator.geolocation` works on four of the five backends once the
/// permission gate is answered — but **not on macOS**, where WKWebView exposes
/// no public way for an embedder to grant it. A capability that works on four
/// platforms teaches adopters to branch on `os`, which is the tax this project
/// exists to remove, so location gets a plugin on all five and the docs point
/// at it rather than at the web API.
///
/// Leaving the web API newly functional on the other four is fine; it just
/// isn't the documented cross-platform path.
public protocol GeolocationProvider: AnyObject, Sendable {
    /// One fix, as soon as one is available or the request times out.
    func current(_ request: GeoRequest) async throws -> GeoFix

    /// A stream of fixes as the device moves. The stream ends when the
    /// subscriber unsubscribes; a provider that can't watch may emit one fix
    /// and finish.
    func watch(_ request: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error>
}

/// How hard to work for a fix.
///
/// Two values rather than a metre budget: every platform expresses this as a
/// coarse hint (`kCLLocationAccuracyBest` vs `…HundredMeters`,
/// `PRIORITY_HIGH_ACCURACY` vs `…BALANCED_POWER_ACCURACY`,
/// `PositionAccuracy.high` vs `.default`), and a number would imply a promise
/// none of them make.
public enum GeoAccuracy: String, Sendable, Codable, CaseIterable {
    /// GPS-class where available. Slower and more power-hungry.
    case high
    /// Network / coarse positioning. The default, because it's what most apps
    /// actually need and it's what a user is most likely to consent to.
    case balanced
}

public struct GeoRequest: Sendable, Codable, Equatable {
    public var accuracy: GeoAccuracy
    /// Give up after this long. Nil uses the provider's own default.
    public var timeoutSeconds: Double?
    /// A cached fix younger than this is acceptable. Nil means "don't reuse
    /// one" on providers that can tell the difference.
    public var maximumAgeSeconds: Double?

    public init(
        accuracy: GeoAccuracy = .balanced,
        timeoutSeconds: Double? = nil,
        maximumAgeSeconds: Double? = nil
    ) {
        self.accuracy = accuracy
        self.timeoutSeconds = timeoutSeconds
        self.maximumAgeSeconds = maximumAgeSeconds
    }

    /// Hand-written so **every field is optional on the wire**. Swift's
    /// synthesized `Decodable` ignores property defaults, so `accuracy` would
    /// otherwise be required — and `invoke('geo.current')` with no arguments,
    /// which is the most natural way to ask for a location, would fail
    /// `E_DECODE` instead of returning a fix.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accuracy = try container.decodeIfPresent(GeoAccuracy.self, forKey: .accuracy) ?? .balanced
        timeoutSeconds = try container.decodeIfPresent(Double.self, forKey: .timeoutSeconds)
        maximumAgeSeconds = try container.decodeIfPresent(Double.self, forKey: .maximumAgeSeconds)
    }
}

/// One position.
///
/// Field names and units mirror the web platform's `GeolocationCoordinates`
/// (degrees, metres, metres per second, degrees clockwise from true north) so
/// an adopter moving off `navigator.geolocation` doesn't have to relearn the
/// shape — the only difference is `timestamp`, which is seconds here rather
/// than JS milliseconds, matching every other time value the bridge carries.
public struct GeoFix: Sendable, Codable, Equatable {
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy in metres, at 95% confidence — the same definition
    /// the web API uses. Never negative; a provider that won't say reports its
    /// worst plausible value rather than 0, which would claim perfection.
    public var accuracy: Double
    public var altitude: Double?
    public var altitudeAccuracy: Double?
    /// Degrees clockwise from true north, when moving.
    public var heading: Double?
    /// Metres per second.
    public var speed: Double?
    /// Seconds since 1970.
    public var timestamp: Double

    public init(
        latitude: Double,
        longitude: Double,
        accuracy: Double,
        altitude: Double? = nil,
        altitudeAccuracy: Double? = nil,
        heading: Double? = nil,
        speed: Double? = nil,
        timestamp: Double
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.altitude = altitude
        self.altitudeAccuracy = altitudeAccuracy
        self.heading = heading
        self.speed = speed
        self.timestamp = timestamp
    }
}

/// Why a fix didn't happen.
///
/// The three are kept apart for the same reason the permission denials are: an
/// app shows a different thing for each, and collapsing them is what makes a
/// location feature feel broken.
public enum GeoError: Error, Sendable, Equatable {
    /// The app never declared `geolocation`, the user refused, or the app
    /// vetoed it. Recoverable by consent, not by waiting.
    case denied(String)
    /// **This machine, right now** — no GeoClue provider, location services
    /// switched off, no hardware, airplane mode. Never "this OS": an app should
    /// tell the user what to switch on, not that the feature doesn't exist here.
    case unavailable(String)
    /// Nothing arrived in time. Distinct from `unavailable` because retrying is
    /// reasonable — a cold GPS fix indoors legitimately takes a while.
    case timedOut(String)

    public var bridgeError: BridgeError {
        switch self {
        case let .denied(message): BridgeError(code: "E_GEO_DENIED", message: message)
        case let .unavailable(message): BridgeError(code: "E_GEO_UNAVAILABLE", message: message)
        case let .timedOut(message): BridgeError(code: "E_GEO_TIMEOUT", message: message)
        }
    }
}

/// The provider installed where a platform has no implementation yet. Answers
/// `unavailable` with a sentence saying so, rather than hanging or trapping.
public final class NoneGeolocationProvider: GeolocationProvider {
    private let reason: String

    public init(reason: String = "this build has no geolocation provider installed") {
        self.reason = reason
    }

    public func current(_: GeoRequest) async throws -> GeoFix {
        throw GeoError.unavailable(reason)
    }

    public func watch(_: GeoRequest) -> AsyncThrowingStream<GeoFix, any Error> {
        AsyncThrowingStream { $0.finish(throwing: GeoError.unavailable(reason).bridgeError) }
    }
}
