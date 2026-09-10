import Foundation

/// What the app does when its last window closes.
///
/// **This is a macOS question**, and it only became one when the Window menu
/// gave the app a working ⌘W. macOS is the one platform here where an app can
/// outlive its windows: the menu bar stays, the process keeps running, and a
/// user who closed the only window has an app they can see and cannot reach.
/// Linux and Windows exit when the last window closes — their own convention,
/// and no such state exists there — so the other backends ignore this. On iOS
/// and Android the system owns the lifecycle outright.
///
/// The default, ``reopen``, is what a Mac user expects from Finder, Safari or
/// Mail: the app stays running and activating it — a Dock click, ⌘Tab, opening
/// it again — brings the window back.
public enum LastWindowClosedPolicy: String, Sendable, Codable, CaseIterable {
    /// Stay running and reopen the window when the app is next activated.
    /// The macOS default, and the only one of these with no way to strand the
    /// user: whatever they do to get back to the app produces a window.
    ///
    /// The window comes back from the ``WindowConfig`` it was created with, so
    /// it is the same window the app asked for — including a remembered size
    /// and position when ``WindowConfig/rememberState`` is on. Page state is
    /// not preserved: the reopened window loads the app fresh, exactly as a
    /// relaunch would.
    case reopen

    /// Stay running with no window, and don't reopen one. For an app whose
    /// real surface is the menu bar — a tray app, or one holding a background
    /// job — where a window is incidental and closing it is not a request to
    /// come back.
    ///
    /// The app is still reachable through its status item or ⌘Q; if it has
    /// neither, prefer ``reopen`` or ``quit``, since this is the combination
    /// that leaves a user stuck.
    case keepRunning = "keep-running"

    /// Terminate once the last window closes, the way a single-window utility
    /// does. Matches what Linux and Windows already do, so it is the setting
    /// that makes the desktop behave alike everywhere.
    case quit
}
