#if os(macOS) && SWIFT_PWA_DRIVER

    import AppKit
    import WebKit

    /// The webview used in **driver builds** on macOS, differing from a plain
    /// `WKWebView` in exactly one way: it accepts first mouse.
    ///
    /// Without this the driver's `input.pointer` verbs silently do nothing
    /// whenever the app isn't the active one. AppKit's click-through rule is
    /// that a `mouseDown` landing in a window that isn't key is consumed as
    /// "click to activate" rather than delivered, unless the view under it
    /// returns `true` from `acceptsFirstMouse(for:)` — and `WKWebView` returns
    /// `false`. The event is built correctly, `sendEvent` accepts it, and the
    /// page never sees it: no error anywhere, which is what made this hard to
    /// spot. (`window.focus` doesn't help either: making a window key inside an
    /// application that isn't active doesn't give it the focus.)
    ///
    /// That behaviour is the whole point of the driver — a run you can leave
    /// going while you keep working — so a driven build opts into click-through.
    ///
    /// **Scoped to driver builds on purpose.** Accepting first mouse is a real
    /// change to how an app feels: a click into an unfocused window would both
    /// raise the app *and* reach the page, where the platform default is to
    /// only raise it. That's the adopter's design decision, not swift-pwa's, so
    /// a shipped build keeps AppKit's default.
    ///
    /// The cost is that debug and release differ in one input behaviour. It's
    /// the narrower risk of the two — a click-through difference is visible the
    /// moment anyone tries it by hand, whereas silently changing every app's
    /// window behaviour would not be.
    final class DriverWebView: WKWebView {
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
            true
        }
    }

#endif
