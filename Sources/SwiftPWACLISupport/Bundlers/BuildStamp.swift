import ArgumentParser
import Foundation

/// A note left in an output directory recording what was last bundled there, so
/// a later build for a *different* platform can refuse instead of clobbering.
///
/// The failure it exists to prevent is silent at the moment of damage and
/// misleading later: every Apple bundler writes `<output>/<name>.app`, so a
/// `deploy --target ios` over a previous `build --target macos` left an iOS
/// bundle under a macOS-looking name, and double-clicking it gave Finder's "not
/// supported on this Mac" — which reads as a signing or architecture problem.
/// Per-target default output directories (`build/macos`, `build/ios`, …) mean
/// this can't happen by accident; the stamp catches the case where someone
/// points `--output` at a directory by hand.
struct BuildStamp: Codable, Equatable {
    /// `BuildTarget.rawValue`.
    let target: String
    /// iOS only: `"simulator"` or `"device"` — a simulator bundle installed to a
    /// device fails just as opaquely as the wrong platform entirely.
    var destination: String?
    var name: String
    var configuration: String
    var cliVersion: String

    static let filename = ".swift-pwa-build.json"

    /// Human-readable "macOS" / "iOS (simulator)" for error messages.
    var label: String {
        let platform = BuildTarget(rawValue: target)?.displayName ?? target
        guard let destination else { return platform }
        return "\(platform) (\(destination))"
    }

    static func read(from directory: URL) -> BuildStamp? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(filename)) else {
            return nil
        }
        return try? JSONDecoder().decode(BuildStamp.self, from: data)
    }

    func write(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.filename))
    }

    /// Throw if `directory` already holds a bundle built for something else.
    ///
    /// Two probes, because the stamp only exists on directories a current
    /// swift-pwa wrote: the stamp when it's there, otherwise the shape of any
    /// `.app` present (macOS bundles have `Contents/`, iOS bundles are flat) —
    /// which is exactly the collision that was reported.
    static func checkCompatible(directory: URL, with stamp: BuildStamp) throws {
        if let existing = read(from: directory) {
            guard existing.target != stamp.target || existing.destination != stamp.destination else {
                return
            }
            let suggestion = BuildTarget(rawValue: stamp.target)?
                .outputSubdirectory(simulator: stamp.destination == "simulator") ?? stamp.target
            throw ValidationError("""
            \(directory.path) holds a \(existing.label) build (of \(existing.name)); this build \
            targets \(stamp.label). Overwriting it would leave the new bundle under the old \
            platform's name, which then fails to launch for reasons that point somewhere else \
            entirely. Pass --output <dir> to keep them apart — the default already does: \
            build/\(suggestion).
            """)
        }
        // No stamp: an older build, or a directory that isn't ours. The only
        // ambiguity worth catching structurally is Apple's, where both targets
        // write `<name>.app`.
        let app = directory.appendingPathComponent("\(stamp.name).app")
        guard FileManager.default.fileExists(atPath: app.path),
              stamp.target == BuildTarget.macos.rawValue || stamp.target == BuildTarget.ios.rawValue
        else { return }
        let isMacBundle = FileManager.default.fileExists(
            atPath: app.appendingPathComponent("Contents").path
        )
        let wantsMacBundle = stamp.target == BuildTarget.macos.rawValue
        guard isMacBundle != wantsMacBundle else { return }
        throw ValidationError("""
        \(app.path) is a\(isMacBundle ? " macOS" : "n iOS") .app; this build targets \(stamp.label), \
        which writes the same filename. Pass --output <dir> to keep them apart, or delete the \
        existing bundle.
        """)
    }
}

extension BuildTarget {
    var displayName: String {
        switch self {
        case .macos: "macOS"
        case .ios: "iOS"
        case .linux: "Linux"
        case .windows: "Windows"
        case .android: "Android"
        }
    }

    /// Where this target's artifacts go under the default `build/` root. Keeping
    /// the two Apple targets — and the two iOS destinations — in separate
    /// directories is what stops them overwriting each other's `<name>.app`.
    func outputSubdirectory(simulator: Bool) -> String {
        switch self {
        case .ios: simulator ? "ios-simulator" : "ios"
        default: rawValue
        }
    }
}
