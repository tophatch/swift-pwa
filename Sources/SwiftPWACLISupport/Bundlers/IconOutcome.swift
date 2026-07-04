import Foundation

/// The result of a bundler's app-icon step. Every target funnels its icon
/// handling through this one type so the build prints a single consistent,
/// concise line — replacing the previous mix of silence (macOS / Windows /
/// Android) and stray `note:`s (iOS / Linux). The caller reports it via
/// `IconOutcome.report(_:)`, which prints exactly one `swift-pwa:` line.
enum IconOutcome: Equatable {
    /// Bundled a real icon from `source` (path as written in pwa.json).
    /// `detail` is an optional per-platform note — e.g. "7 sizes" when the
    /// source PNG was expanded into a multi-size container (macOS `.icns`),
    /// or `nil` when it was copied as-is (Linux / Windows / Android).
    case bundled(source: String, detail: String?)
    /// No `icon` field in pwa.json — the platform default is used.
    case noneSet
    /// `icon` is set but isn't a PNG. `placeholder` is true when a stand-in
    /// icon was written so the packager doesn't fail, false when the step
    /// simply skipped (leaving the platform default).
    case notPNG(source: String, placeholder: Bool)
    /// `icon` is set but the file doesn't exist on disk.
    case notFound(source: String, placeholder: Bool)
    /// The icon toolchain failed (e.g. `actool` / `iconutil` missing or
    /// erroring). The build itself is unaffected.
    case toolFailed(source: String, reason: String)

    /// The message body, without the leading `swift-pwa:` prefix.
    var line: String {
        switch self {
        case let .bundled(source, detail):
            return detail.map { "app icon ← \(source) (\($0))" } ?? "app icon ← \(source)"
        case .noneSet:
            return "no icon set in pwa.json — using the platform default"
        case let .notPNG(source, placeholder):
            let tail = placeholder ? "using a placeholder" : "using the platform default"
            return "icon '\(source)' isn't a PNG — \(tail) (convert to PNG for a real app icon)"
        case let .notFound(source, placeholder):
            let tail = placeholder ? "using a placeholder" : "using the platform default"
            return "icon '\(source)' not found — \(tail)"
        case let .toolFailed(source, reason):
            return "app icon from '\(source)' skipped (\(reason)); the build is otherwise fine"
        }
    }

    /// Print the one icon line for a build. Kept in one place so the format
    /// stays identical across every bundler.
    static func report(_ outcome: IconOutcome) {
        print("swift-pwa: \(outcome.line)")
    }
}
