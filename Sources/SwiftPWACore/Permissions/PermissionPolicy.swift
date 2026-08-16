import Foundation

/// A permission a *page* asks for through an ordinary web API —
/// `getUserMedia`, `navigator.geolocation`, `Notification.requestPermission`.
///
/// Deliberately the page's vocabulary rather than any platform's. One page
/// request maps to several OS permissions on Android (`geolocation` needs both
/// `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION`), reaches a different
/// seam on every backend, and has no OS counterpart at all on Linux. What the
/// five have in common is what the page asked for, so that's what this models.
public enum WebPermission: String, Sendable, Codable, CaseIterable {
    case camera
    case microphone
    case geolocation
    case notifications
}

/// Why the runtime refused a permission request before the platform ever saw it.
///
/// A refusal the *user* made is not in here: it comes back from the OS prompt
/// and is a runtime state the user can change. Keeping the two distinguishable
/// is the point — collapsing them is how the current behaviour became so
/// misleading, with a page told "the user denied this" about a question nobody
/// was ever asked.
public enum PermissionDenial: String, Sendable, Equatable {
    /// The app never declared this permission. A build-time fix, and the one
    /// refusal that is the app's own doing rather than the user's.
    case undeclared
    /// The app refused it itself, from its own in-app privacy controls.
    case vetoed
}

public enum PermissionDecision: Sendable, Equatable {
    /// Let the request through. On a platform whose OS asks the user, this
    /// means "forward to the system prompt" — the runtime never invents
    /// consent UI of its own, it only decides whether asking is allowed.
    case allow
    case deny(PermissionDenial)
}

/// The app-wide answer to "may this page use the camera / microphone /
/// location", consulted by every backend at its own permission seam.
///
/// Two ceilings, in order:
///
/// 1. **The declaration** — a build-time ceiling. Undeclared is denied, so no
///    app silently gains a capability the day it upgrades, and the refusal
///    carries a diagnostic naming the fix.
/// 2. **The veto** — a runtime ceiling the app owns, for its own in-app privacy
///    switches ("microphone: off"). It sits *above* the OS prompt: a vetoed
///    permission is refused without asking, so the user isn't prompted for
///    something the app has already ruled out.
///
/// Anything that clears both is forwarded to the platform, which is where the
/// user actually gets asked (iOS, Android and Windows prompt; Linux has no
/// system consent layer for capture, so clearing both gates is the whole
/// decision there).
///
/// **Threading**: lock-guarded rather than actor-isolated, because backends
/// consult it from whatever thread their permission callback fires on — GTK's
/// main loop, a WebView2 callback, a JNI thread — none of which is pumping
/// Swift's MainActor executor. Same reasoning as `CommandRegistry`.
public final class PermissionPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var declared: Set<WebPermission> = []
    private var veto: (@Sendable (WebPermission, String) -> Bool)?
    private var diagnosed: Set<WebPermission> = []

    public init() {}

    /// Declare the permissions this app may ask for. Additive, so separate
    /// features can each declare their own without coordinating.
    ///
    /// Call it from `configure`, before any window exists — a page can request
    /// a permission as soon as it loads.
    ///
    /// > Today this is the only declaration the runtime reads. `pwa.json`'s
    /// > `permissions.web` is what drives the *platform* artifacts (the Android
    /// > manifest entries, the Apple usage descriptions), and a later change
    /// > will cross-check the two at build time and fail on drift — the stance
    /// > `agent.expose` already takes, resolving a manifest claim against the
    /// > live catalog rather than trusting it.
    public func declare(_ permissions: WebPermission...) {
        declare(permissions)
    }

    public func declare(_ permissions: some Sequence<WebPermission>) {
        lock.lock()
        defer { lock.unlock() }
        declared.formUnion(permissions)
    }

    /// Everything declared so far.
    public var declaredPermissions: Set<WebPermission> {
        lock.lock()
        defer { lock.unlock() }
        return declared
    }

    /// Install the app's own refusal hook. Return `true` to refuse the request.
    ///
    /// For app-owned privacy controls, not for re-implementing the OS prompt:
    /// a `false` here means "no objection", not "granted" — the platform still
    /// gets to ask the user.
    ///
    /// Called on whichever thread the backend's permission callback fires on,
    /// so keep it quick and don't assume the main actor. Installing a second
    /// one replaces the first.
    public func setVeto(_ veto: (@Sendable (WebPermission, String) -> Bool)?) {
        lock.lock()
        defer { lock.unlock() }
        self.veto = veto
    }

    /// Decide a single permission for a page at `origin`.
    ///
    /// Logs a one-off diagnostic when it refuses something undeclared: that
    /// refusal reaches the page as `NotAllowedError` / `PERMISSION_DENIED`,
    /// which is indistinguishable from a user saying no, so the only place the
    /// real cause can surface is here. Logged once per permission so a page
    /// that retries in a loop doesn't bury the rest of the output.
    public func decide(_ permission: WebPermission, origin: String) -> PermissionDecision {
        lock.lock()
        let isDeclared = declared.contains(permission)
        // Copied out and called *outside* the lock: it's app code, and app code
        // that calls back into the policy would otherwise deadlock.
        let veto = veto
        lock.unlock()

        guard isDeclared else {
            diagnoseUndeclared(permission, origin: origin)
            return .deny(.undeclared)
        }
        if veto?(permission, origin) == true { return .deny(.vetoed) }
        return .allow
    }

    /// Decide a request that needs *several* permissions at once — the
    /// `getUserMedia({audio: true, video: true})` case, which is one request
    /// the backend can only allow or deny as a whole.
    ///
    /// Refuses unless every one of them clears, and reports the first refusal.
    /// An empty set is refused too: a request we couldn't classify is not one
    /// to wave through.
    public func decide(
        all permissions: Set<WebPermission>, origin: String
    ) -> PermissionDecision {
        guard !permissions.isEmpty else { return .deny(.undeclared) }
        var firstDenial: PermissionDenial?
        // Sorted so the reported denial doesn't depend on Set iteration order,
        // and every permission is evaluated so each gets its own diagnostic.
        for permission in permissions.sorted(by: { $0.rawValue < $1.rawValue }) {
            if case let .deny(reason) = decide(permission, origin: origin) {
                firstDenial = firstDenial ?? reason
            }
        }
        if let firstDenial { return .deny(firstDenial) }
        return .allow
    }

    /// Decide a request that any *one* of several permissions would satisfy —
    /// `enumerateDevices()` asking for device labels, which either capture
    /// permission justifies.
    ///
    /// Silent when it refuses, unlike the other two. An app with no interest in
    /// capture is *expected* to fail this, and a page that calls
    /// `enumerateDevices` on load would otherwise print a diagnostic naming a
    /// permission its author never wanted.
    public func decide(
        any permissions: Set<WebPermission>, origin: String
    ) -> PermissionDecision {
        lock.lock()
        let candidates = declared.intersection(permissions)
        let veto = veto
        lock.unlock()

        for permission in candidates.sorted(by: { $0.rawValue < $1.rawValue })
            where veto?(permission, origin) != true
        {
            return .allow
        }
        return .deny(candidates.isEmpty ? .undeclared : .vetoed)
    }

    private func diagnoseUndeclared(_ permission: WebPermission, origin: String) {
        lock.lock()
        let isFirst = diagnosed.insert(permission).inserted
        lock.unlock()
        guard isFirst else { return }
        // Through the sink rather than straight to stderr: on Android stderr
        // goes to /dev/null, and a message explaining a silent refusal must
        // not itself be silent.
        RuntimeDiagnostics.emit("""
        swift-pwa: refused a '\(permission.rawValue)' permission request from \(origin) \
        because this app has not declared it. Add \
        `ctx.permissions.declare(.\(permission.rawValue))` to your configure closure. \
        The page sees an ordinary denial, which looks exactly like the user saying no.
        """)
    }
}
