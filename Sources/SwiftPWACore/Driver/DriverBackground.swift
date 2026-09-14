import Foundation

/// A **driven run that stays off the screen** — `SWIFT_PWA_DRIVE_BACKGROUND=1`,
/// or `swift-pwa drive --background`.
///
/// The problem it solves is a suite, not a verb. An adopter's e2e run launches
/// one app per test file — 37 of them — and every launch comes to the front and
/// takes focus, so a full run is minutes during which the machine can't be used
/// for anything else. The driver's whole premise is that a run needn't own the
/// machine (input goes into the app's own event queue, screenshots come from
/// WebKit's own compositor), and the window coming forward was the last thing
/// contradicting it.
///
/// **Why the obvious workaround doesn't work, and what does.** A suite can't
/// just hide the window: WebKit stops servicing `requestAnimationFrame` for a
/// window the compositor isn't showing, so a page that draws in a rAF callback
/// silently does nothing and neither fails — it reads as the app being broken.
/// Measured on macOS 26.6.2, frames/second in a rAF loop with a
/// `takeSnapshot` pixel check as proof the page really drew:
///
/// | Window                        | Default | Occlusion detection off |
/// | ----------------------------- | ------- | ----------------------- |
/// | On screen, never key          | 63      | 63                      |
/// | Covered by another window     | 0–17    | 63                      |
/// | Parked fully off screen       | 0       | 63                      |
/// | `orderOut` — not in the list  | 0       | 0                       |
///
/// So the shape is a window **ordered in and parked off screen**, with
/// `-[WKWebView _setWindowOcclusionDetectionEnabled:]` off — and an app that
/// never activates, since key and active turn out to be irrelevant to the frame
/// rate (a window that is never key, in an app that never activates, runs at
/// full rate). The two problems read as one and are not.
///
/// **Off by default, and driver-only.** ``isRequested`` answers `false` unless
/// the driver is compiled in at all, so the env var can't reshape a shipped
/// app's window behaviour even if something sets it.
public enum DriverBackground {
    /// The env var a backend checks. Set to `1` / `true` / `yes` to ask for a
    /// backgrounded run. Unset — the normal case — an app launches, activates
    /// and shows its window exactly as it always has.
    public static let environmentVariable = "SWIFT_PWA_DRIVE_BACKGROUND"

    /// Whether a backgrounded run was asked for *and* this build can honour it.
    ///
    /// Read at every decision point rather than cached at startup: it's an
    /// environment read, and the alternative is a stored flag that has to be
    /// initialized before the first window — which is exactly the ordering bug
    /// this has to avoid.
    public static var isRequested: Bool {
        #if SWIFT_PWA_DRIVER
            guard let raw = ProcessInfo.processInfo.environment[environmentVariable] else { return false }
            guard !isUnsupported else { return false }
            return ["1", "true", "yes"].contains(raw.trimmingCharacters(in: .whitespaces).lowercased())
        #else
            return false
        #endif
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var honoured = false
    private nonisolated(unsafe) static var unsupported = false

    /// Called by a backend that finds it *can't* keep the page rendering off
    /// screen — on Apple that means the occlusion-detection SPI has gone.
    ///
    /// From here on ``isRequested`` answers `false`, so the run falls back to a
    /// visible window rather than an invisible one whose page never paints.
    /// The degradation has to be this way round: a visible run is an annoyance,
    /// and a silent one is every rAF-dependent test timing out for a reason
    /// nothing on screen explains.
    public static func markUnsupported() {
        lock.lock(); defer { lock.unlock() }
        unsupported = true
    }

    /// Whether the mode was asked for but can't be delivered on this OS.
    public static var isUnsupported: Bool {
        lock.lock(); defer { lock.unlock() }
        return unsupported
    }

    /// Called by a backend that has actually applied the mode, so the driver's
    /// `capabilities` verb can report it.
    ///
    /// The distinction is the point: a backend that doesn't implement
    /// backgrounding would otherwise ignore the env var in silence, and a
    /// harness would be told nothing while every launch kept stealing focus.
    /// ``isActive`` says whether the request landed.
    public static func markHonoured() {
        lock.lock(); defer { lock.unlock() }
        honoured = true
    }

    /// Whether this app is actually running backgrounded — requested, and a
    /// backend applied it.
    public static var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return honoured && !unsupported
    }

    /// Where a backgrounded window is parked: far outside the union of any
    /// plausible display arrangement, in the negative quadrant so it can't
    /// collide with a screen someone attaches mid-run.
    ///
    /// It has to be a real on-screen-ordered window at *some* coordinates —
    /// `orderOut` stops the frames as surely as occlusion does (measured), so
    /// "not visible" and "not in the window list" are different states and only
    /// the first one works.
    public static let parkedOrigin = Point(x: -32000, y: -32000)
}
