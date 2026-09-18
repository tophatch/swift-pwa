import Foundation

/// A device capability an app has to ask for before it can use.
///
/// Deliberately the *app's* vocabulary rather than any platform's. One request
/// maps to several OS permissions on Android (`geolocation` needs both
/// `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION`; `bluetooth` needs
/// `BLUETOOTH_SCAN` and `BLUETOOTH_CONNECT`), reaches a different seam on every
/// backend, and has no OS counterpart at all on Linux. What the five platforms
/// have in common is what was asked for, so that's what this models.
///
/// Most of these arrive through an ordinary web API — `getUserMedia`,
/// `navigator.geolocation`, `Notification.requestPermission` — and the runtime
/// answers on the page's behalf at each backend's permission seam.
/// ``bluetooth`` is the exception: no webview here exposes Web Bluetooth, so it
/// is only ever reached through `ble.*`. It sits in the same policy anyway
/// because everything downstream of the decision is identical — one veto, one
/// undeclared diagnostic, one build-time cross-check.
public enum DevicePermission: String, Sendable, Codable, CaseIterable {
    case camera
    case microphone
    case geolocation
    case notifications
    /// Talking to Bluetooth LE peripherals through `ble.*`. Declared under
    /// `permissions.device` in `pwa.json`, not `permissions.web`.
    case bluetooth
    /// Reading and writing the user's own files **by path** — the whole of
    /// shared storage, not a folder they handed over through a picker.
    ///
    /// Declared under `permissions.device` in `pwa.json`, like ``bluetooth``,
    /// because no web API asks for it: the File System Access API's directory
    /// picker is the web's answer, and what this models is the app that walks
    /// folders it was given a *path* to — a library whose books are the user's
    /// own directories, a sidecar file written beside the original.
    ///
    /// It is the one permission here whose answer differs by platform rather
    /// than by device: ambient on Linux and Windows, ambient-with-a-prompt on
    /// macOS, an explicit hand-off to Settings on Android (API 30+), and not
    /// available at all on iOS. ``PermissionPolicy/status(_:)`` is how an app
    /// finds out which of those it is on, before it offers the user a button
    /// that can't work.
    case allFiles
}

/// The name this enum shipped under in 0.10.0, when everything in it came from
/// a web API.
@available(*, deprecated, renamed: "DevicePermission")
public typealias WebPermission = DevicePermission

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

/// Where a permission stands with the OS *right now*, as opposed to whether
/// the app is allowed to ask (``PermissionDecision``).
///
/// Three states rather than a `Bool` because "no" splits in two, and an app
/// that can't tell them apart shows the wrong UI. ``denied`` is worth a button;
/// ``unavailable`` never becomes ``granted`` on this device, and offering to
/// ask would be offering something that does nothing.
public enum PermissionState: String, Sendable, Codable, Equatable, CaseIterable {
    /// The app can use the capability now.
    case granted
    /// Not granted, but asking is possible — ``PermissionPolicy/request(_:)``
    /// will reach a prompt or a Settings hand-off.
    case denied
    /// Nothing to ask. The app never declared it, the app has vetoed it, the
    /// platform has no such grant to give (All-files access on iOS), or the OS
    /// version predates it. The app needs its other route — a document picker,
    /// its own storage — and the decision is a build-time one, not a button.
    ///
    /// A permission a store refuses to approve lands here too: an app shipped
    /// without the declaration reads `unavailable` at runtime rather than
    /// offering a hand-off that Settings would show nothing for.
    case unavailable
}

/// The platform seam behind ``PermissionPolicy/status(_:)`` and
/// ``PermissionPolicy/request(_:)``. One per backend that has something to
/// ask; installed by its `AppContext`, never by an app.
///
/// Only consulted for a permission that has cleared the declaration and the
/// veto, so an implementation answers about the OS alone.
public protocol DevicePermissionAuthority: Sendable {
    /// Where `permission` stands with the OS, without asking the user
    /// anything. Return nil for a permission this backend has no opinion on,
    /// which falls back to ``PermissionState/granted`` — the honest answer
    /// where nothing stands between a declared app and the capability.
    func state(of permission: DevicePermission) async -> PermissionState?

    /// Ask, and answer with where things stand once the user is done. Returns
    /// nil for a permission this backend can't ask about.
    ///
    /// May take as long as the user does: on Android All-files access is a
    /// trip to a Settings screen and back.
    func request(_ permission: DevicePermission) async -> PermissionState?
}

public enum PermissionDecision: Sendable, Equatable {
    /// Let the request through. On a platform whose OS asks the user, this
    /// means "forward to the system prompt" — the runtime never invents
    /// consent UI of its own, it only decides whether asking is allowed.
    case allow
    case deny(PermissionDenial)
}

/// The app-wide answer to "may this app use the camera / microphone / location
/// / Bluetooth", consulted by every backend at its own permission seam and by
/// the plugins that reach a capability the webview can't.
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
    private var declared: Set<DevicePermission> = []
    private var veto: (@Sendable (DevicePermission, String) -> Bool)?
    private var diagnosed: Set<DevicePermission> = []
    private var authority: (any DevicePermissionAuthority)?

    public init() {}

    /// Declare the permissions this app may ask for. Additive, so separate
    /// features can each declare their own without coordinating.
    ///
    /// Call it from `configure`, before any window exists — a page can request
    /// a permission as soon as it loads.
    ///
    /// > This is the ceiling the *runtime* reads. `pwa.json`'s `permissions`
    /// > block is what drives the *platform* artifacts (the Android manifest
    /// > entries, the Apple usage descriptions, the MSIX device capabilities),
    /// > and `swift-pwa build` cross-checks the two and fails on drift in
    /// > either direction — the stance `agent.expose` takes, resolving a
    /// > manifest claim against the live catalog rather than trusting it.
    public func declare(_ permissions: DevicePermission...) {
        declare(permissions)
    }

    public func declare(_ permissions: some Sequence<DevicePermission>) {
        lock.lock()
        defer { lock.unlock() }
        declared.formUnion(permissions)
    }

    /// Everything declared so far.
    public var declaredPermissions: Set<DevicePermission> {
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
    public func setVeto(_ veto: (@Sendable (DevicePermission, String) -> Bool)?) {
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
    public func decide(_ permission: DevicePermission, origin: String) -> PermissionDecision {
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
        all permissions: Set<DevicePermission>, origin: String
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
        any permissions: Set<DevicePermission>, origin: String
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

    /// Install the backend's OS seam. Called by each `AppContext`; an app
    /// never calls this.
    public func setAuthority(_ authority: (any DevicePermissionAuthority)?) {
        lock.lock()
        defer { lock.unlock() }
        self.authority = authority
    }

    /// Where `permission` stands with the OS right now — read it before
    /// offering the user a button, so an app doesn't offer one that can't
    /// work.
    ///
    /// Undeclared or vetoed is ``PermissionState/unavailable``: both are the
    /// app's own doing and neither changes by asking. Everything else is the
    /// backend's answer, or ``PermissionState/granted`` where the backend has
    /// none — nothing stands between a declared app and a capability the
    /// platform grants ambiently.
    ///
    /// Asks the user nothing.
    public func status(_ permission: DevicePermission) async -> PermissionState {
        guard let authority = clearedAuthority(for: permission) else { return .unavailable }
        return await authority?.state(of: permission) ?? .granted
    }

    /// Ask for `permission`, and answer with where it stands once the user is
    /// done. Safe to call when already granted — a backend answers from the
    /// current state rather than asking twice.
    ///
    /// Undeclared or vetoed returns ``PermissionState/unavailable`` without
    /// asking anything: a permission the app ruled out is not one to put a
    /// system prompt in front of the user for.
    ///
    /// This is deliberately *not* how the web APIs get their consent —
    /// `getUserMedia` and friends still reach the platform's own prompt
    /// through ``decide(_:origin:)`` at each backend's permission seam. It
    /// exists for a capability no web API asks for.
    public func request(_ permission: DevicePermission) async -> PermissionState {
        guard let authority = clearedAuthority(for: permission) else { return .unavailable }
        return await authority?.request(permission) ?? .granted
    }

    /// The installed authority, or nil when the app's own two ceilings already
    /// settle the question. Double-optional at the call site: the outer nil
    /// means "refused here", the inner one "nothing installed".
    private func clearedAuthority(for permission: DevicePermission) -> (any DevicePermissionAuthority)?? {
        lock.lock()
        let isDeclared = declared.contains(permission)
        let veto = veto
        let authority = authority
        lock.unlock()

        guard isDeclared else {
            // The same one-off diagnostic the web seam emits: a page told
            // `unavailable` can't tell a missing declaration from a platform
            // that has no such grant, and this is the only place the
            // difference can surface.
            diagnoseUndeclared(
                permission, origin: "ctx.permissions",
                consequence: """
                `status` and `request` answer `unavailable` until then, which reads to an app as \
                'this platform cannot do it' — indistinguishable from a device that really can't.
                """
            )
            return .none
        }
        // The veto takes an origin because it was written for a page's
        // request; this one is the app asking on its own behalf.
        if veto?(permission, "ctx.permissions") == true { return .none }
        return .some(authority)
    }

    private func diagnoseUndeclared(
        _ permission: DevicePermission, origin: String, consequence: String? = nil
    ) {
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
        \(consequence ?? "The page sees an ordinary denial, which looks exactly like the user saying no.")
        """)
    }
}
