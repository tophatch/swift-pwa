import Foundation

/// Which frame of a window's content made a bridge call.
///
/// `bridge.js` is injected at document start into **every** frame, not just the
/// main one, so an `<iframe>` of content the page composed in can invoke
/// commands with exactly the same reach as the app's own code. That is the
/// threat `ExternalURLPolicy`'s scheme allowlist is written against, and until
/// this existed nothing above a webview adapter could see the difference: an
/// invoke arrived with a window id and nothing else.
///
/// Deliberately **not** self-reported by the page. `bridge.js` could send
/// `window.top === window` and `location.origin` in the envelope, which is one
/// line and looks like the same answer — but the frame this exists to identify
/// is content we don't trust, and it would simply lie. Only the backend, which
/// sits outside the web content, can answer this.
///
/// ``unknown`` is a real answer, not a placeholder for "not implemented yet":
/// on both GTK backends the UI process genuinely cannot tell. WebKitGTK's
/// `script-message-received` carries only the message value, and `WebKitFrame`
/// is guarded to the *web-process extension* API (`#error "Only
/// <webkit/webkit-web-process-extension.h> can be included directly"`) on both
/// 4.1 and 6.0 — reaching it means shipping a second `.so` that loads inside
/// WebKit's web process. Measured on both boxes rather than assumed.
public enum CallerFrame: Sendable, Equatable {
    /// The window's own top-level document.
    case main
    /// An embedded frame. `origin` is that frame's own origin where the
    /// backend reports one — `nil` where it reports only that this wasn't the
    /// main frame.
    case subframe(origin: WebOrigin?)
    /// This backend can't report which frame a call came from. A policy that
    /// would otherwise narrow its answer has to decide what to do with that,
    /// and say so, rather than silently treating it as either of the above.
    case unknown

    /// Whether this is known to be the window's own top-level document.
    /// `false` for ``unknown`` — a caller asking this question is narrowing a
    /// permission, and "I can't tell" must not widen it.
    public var isKnownMainFrame: Bool {
        self == .main
    }
}

/// An inbound bridge frame together with what the backend knows about where it
/// came from.
///
/// The pair travels together because frame identity is per-*message*: one
/// window's stream carries calls from its main document and from any frame it
/// embeds, interleaved.
public struct InboundMessage: Sendable, Equatable {
    public let frame: InboundFrame
    public let callerFrame: CallerFrame

    public init(frame: InboundFrame, callerFrame: CallerFrame = .unknown) {
        self.frame = frame
        self.callerFrame = callerFrame
    }
}
