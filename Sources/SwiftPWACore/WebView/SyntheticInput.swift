import Foundation

/// Synthetic input delivered **into the app's own event queue** — the app
/// driver's `input.*` verbs.
///
/// The point is what it *isn't*: an OS-wide HID injection. `CGEvent.post` and
/// `SendInput` move the real cursor, need the app frontmost, require an
/// Accessibility grant on macOS, and make the machine unusable while a run is
/// in progress. Posting into the app's own queue instead means a backgrounded
/// window can be driven while you keep working, and the events still travel the
/// real path — hit testing, focus, default actions — which is exactly what a
/// DOM event dispatched from `eval` can't do (those arrive `isTrusted: false`
/// and skip default behaviour).
///
/// The pointer case is modelled on the DOM's `PointerEvent`, not on a mouse:
/// stylus and touch are first-class input paths with their own semantics
/// (pressure, tilt, palm rejection), not a mouse with extra fields, and a wire
/// format that says "mouse" would have to be broken later to admit them.
/// Backends honour what they can and ``InputCapabilities`` reports the rest
/// honestly — a request for something a backend can't express is refused rather
/// than silently downgraded to a mouse click.
public enum SyntheticInput: Sendable {
    case pointer(PointerInput)
    case key(KeyInput)
    case wheel(WheelInput)
}

/// What a backend's synthetic input can actually express.
///
/// Load-bearing rather than a nicety, and finer-grained than a single flag:
/// every desktop backend that can synthesize input at all can do a mouse click,
/// but pressure and tilt are a different matter, and a stylus test that silently
/// ran as a mouse click would pass while proving nothing.
public struct InputCapabilities: Sendable, Equatable {
    public var pointer: Bool
    public var key: Bool
    public var wheel: Bool
    /// The pointer types this backend can genuinely produce — i.e. the values a
    /// page would actually observe in `PointerEvent.pointerType`.
    public var pointerTypes: [PointerType]
    /// Whether ``PointerInput/pressure`` reaches the page.
    public var pressure: Bool
    /// Whether ``PointerInput/tiltX`` / ``PointerInput/tiltY`` reach the page.
    public var tilt: Bool

    public init(
        pointer: Bool = false,
        key: Bool = false,
        wheel: Bool = false,
        pointerTypes: [PointerType] = [],
        pressure: Bool = false,
        tilt: Bool = false
    ) {
        self.pointer = pointer
        self.key = key
        self.wheel = wheel
        self.pointerTypes = pointerTypes
        self.pressure = pressure
        self.tilt = tilt
    }

    /// A backend with no synthetic input at all — the default, and the honest
    /// answer for WebView2 (its `SendPointerInput` needs a composition
    /// controller we don't create) and GTK4 (which removed event synthesis).
    public static let none = InputCapabilities()

    /// Whether this backend can produce `type`.
    public func supports(_ type: PointerType) -> Bool {
        pointerTypes.contains(type)
    }

    public var supportsAnyInput: Bool {
        pointer || key || wheel
    }
}

/// Modifier keys held during a synthetic event. Named for the DOM's event
/// properties rather than any one platform's spelling.
public struct InputModifiers: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = InputModifiers(rawValue: 1 << 0)
    public static let control = InputModifiers(rawValue: 1 << 1)
    /// `Option` on Apple, `Alt` elsewhere.
    public static let alt = InputModifiers(rawValue: 1 << 2)
    /// `Command` on Apple, `Super`/`Win` elsewhere.
    public static let meta = InputModifiers(rawValue: 1 << 3)

    /// Parse the driver's wire form: `["shift", "meta"]`. Unknown names are
    /// ignored rather than failing the call — a client from a newer protocol
    /// version shouldn't break an older app outright.
    public init(names: [String]) {
        var result = InputModifiers()
        for name in names {
            switch name.lowercased() {
            case "shift": result.insert(.shift)
            case "control", "ctrl": result.insert(.control)
            case "alt", "option": result.insert(.alt)
            case "meta", "command", "cmd": result.insert(.meta)
            default: continue
            }
        }
        self = result
    }
}

/// The DOM `PointerEvent.pointerType` values.
public enum PointerType: String, Sendable, CaseIterable {
    case mouse, pen, touch
}

/// Which button the event carries. `barrel` is the stylus side switch, which
/// the DOM surfaces as button 2 (the same as a right-click) — named for what it
/// physically is so a caller isn't left translating.
public enum PointerButton: String, Sendable {
    case left, right, middle, barrel, eraser

    /// The DOM `MouseEvent.button` number.
    public var domButton: Int {
        switch self {
        case .left: 0
        case .middle: 1
        case .right, .barrel: 2
        case .eraser: 5
        }
    }
}

public struct PointerInput: Sendable {
    public enum Phase: String, Sendable {
        case down, up, move
    }

    public var phase: Phase
    public var pointerType: PointerType
    /// **Window-local CSS pixels**, measured from the webview's top-left with y
    /// increasing downward — i.e. the coordinate space the page itself uses.
    ///
    /// Deliberately not screen coordinates: screen space plus a moving window
    /// plus a title-bar offset plus a device-pixel ratio is four chances to be
    /// wrong, and the hand-rolled harness this replaces was wrong on three.
    /// Each backend converts to its own space.
    public var x: Double
    public var y: Double
    public var button: PointerButton
    /// 1 for a single click, 2 for a double-click, and so on. Carried through
    /// so a double-click selects a word rather than reading as two clicks.
    public var clickCount: Int
    /// Normalized 0...1. `nil` means "whatever the platform's default is for
    /// this phase" — for a mouse the DOM specifies 0.5 while a button is down
    /// and 0 otherwise, so a caller who doesn't care shouldn't have to say so.
    public var pressure: Double?
    /// Stylus tilt in degrees, -90...90, as `PointerEvent.tiltX` / `tiltY`.
    public var tiltX: Double?
    public var tiltY: Double?
    public var modifiers: InputModifiers

    public init(
        phase: Phase,
        x: Double,
        y: Double,
        pointerType: PointerType = .mouse,
        button: PointerButton = .left,
        clickCount: Int = 1,
        pressure: Double? = nil,
        tiltX: Double? = nil,
        tiltY: Double? = nil,
        modifiers: InputModifiers = []
    ) {
        self.phase = phase
        self.pointerType = pointerType
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.modifiers = modifiers
    }

    /// Whether this event asks for anything beyond a plain positional press —
    /// used by backends to refuse rather than silently flatten a stylus event
    /// into a mouse click.
    public var needsStylusFidelity: Bool {
        tiltX != nil || tiltY != nil
    }
}

public struct KeyInput: Sendable {
    public enum Phase: String, Sendable {
        case down, up
    }

    public var phase: Phase
    /// The DOM `KeyboardEvent.key` value — `"a"`, `"Enter"`, `"ArrowLeft"`.
    public var key: String
    /// The DOM `KeyboardEvent.code` value — `"KeyA"`, `"Enter"`. Optional
    /// because a caller typing text usually knows the character, not the
    /// physical key; backends fall back to deriving one from ``key``.
    public var code: String?
    /// Text this keystroke inserts, when it differs from ``key`` (a dead-key
    /// composition, a pasted run). `nil` means "use `key` if it's a single
    /// character, otherwise insert nothing".
    public var text: String?
    public var modifiers: InputModifiers

    public init(
        phase: Phase,
        key: String,
        code: String? = nil,
        text: String? = nil,
        modifiers: InputModifiers = []
    ) {
        self.phase = phase
        self.key = key
        self.code = code
        self.text = text
        self.modifiers = modifiers
    }
}

public struct WheelInput: Sendable {
    /// Window-local CSS pixels, as ``PointerInput/x`` — scrolling is
    /// position-dependent when the page has nested scrollers.
    public var x: Double
    public var y: Double
    /// Scroll distance in CSS pixels. Positive `deltaY` scrolls the content
    /// **down** (the DOM's sign convention), whatever the platform's native
    /// direction or "natural scrolling" setting.
    public var deltaX: Double
    public var deltaY: Double
    public var modifiers: InputModifiers

    public init(
        x: Double,
        y: Double,
        deltaX: Double = 0,
        deltaY: Double = 0,
        modifiers: InputModifiers = []
    ) {
        self.x = x
        self.y = y
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
    }
}
