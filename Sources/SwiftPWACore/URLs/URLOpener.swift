import Foundation

/// Hands a URL to the operating system — the default browser for `https`, the
/// mail client for `mailto`, whichever app registered a custom scheme.
///
/// Injected into ``SystemPlugin`` and each backend's navigation policy, like
/// ``MemoryProvider`` / `ProcessRunner`, because the call is a UI-framework one
/// on three of the five platforms (`NSWorkspace`, `UIApplication`,
/// `Intent.ACTION_VIEW`) and Core can't reach those. A backend that supplies
/// none gets a `system.openURL` that refuses with `E_UNIMPLEMENTED` rather than
/// one that appears to work.
public protocol URLOpener: Sendable {
    /// Ask the OS to open `url`. Returns `false` if it declined — no
    /// registered handler, or the platform refused — which is a real answer
    /// rather than an error: a page offering a deep link to an app the user
    /// may not have installed wants to know, and it isn't a failure of the
    /// runtime.
    ///
    /// Whether the app may open this URL at all is ``ExternalURLPolicy``'s
    /// decision, made before this is called; an opener never consults it.
    func open(_ url: URL) async -> Bool
}
