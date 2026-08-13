#if os(macOS)
    import AppKit
    import Foundation
    import SwiftPWACore

    /// Synthetic input for the macOS backend — the app driver's `input.*` verbs.
    ///
    /// Events are constructed and handed to the app's **own** `NSWindow` via
    /// `sendEvent(_:)`. Nothing goes near `CGEvent.post` / the HID tap, so the
    /// real cursor never moves, the app needn't be frontmost, and no
    /// Accessibility grant is involved — which is what makes a driven run
    /// survivable while you keep using the machine.
    ///
    /// iOS deliberately gets none of this: UIKit has no public event-synthesis
    /// API, so `supportsInput` stays `false` there and `capabilities` says so.
    extension WKWebViewAdapter {
        /// **Mouse only, and that's not a shortcut.** AppKit exposes no public
        /// constructor for a tablet-pointer event: `NSEvent.mouseEvent` is the
        /// only synthesizable pointer event, tilt has no settable field on it,
        /// and WebKit reports `pointerType: "mouse"` for whatever comes through
        /// it. A `pen` request is therefore refused rather than delivered as a
        /// click that would make a stylus test pass without testing a stylus.
        ///
        /// Pressure *is* real — `NSEvent.mouseEvent` takes it — but WebKit
        /// clamps a non-tablet event's `PointerEvent.pressure` to the spec's
        /// 0.5/0, so the page never observes the value. Reported as `false`.
        public nonisolated var inputCapabilities: InputCapabilities {
            InputCapabilities(
                pointer: true,
                key: true,
                wheel: true,
                pointerTypes: [.mouse],
                pressure: false,
                tilt: false
            )
        }

        public nonisolated func send(_ input: SyntheticInput) async throws {
            try await sendOnMain(input)
        }

        @MainActor
        private func sendOnMain(_ input: SyntheticInput) throws {
            guard let window = webView.window else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "the webview isn't in a window yet"
                )
            }
            switch input {
            case let .pointer(pointer): try sendPointer(pointer, to: window)
            case let .key(key): try sendKey(key, to: window)
            case let .wheel(wheel): try sendWheel(wheel, to: window)
            }
        }

        // MARK: - Pointer

        @MainActor
        private func sendPointer(_ pointer: PointerInput, to window: NSWindow) throws {
            // `barrel` and `eraser` are stylus buttons; AppKit has no
            // synthesizable equivalent, and `inputCapabilities` already refuses
            // a pen pointer, so treat the barrel as its DOM equivalent (a
            // secondary click) and refuse the eraser outright.
            let type: NSEvent.EventType = switch (pointer.phase, pointer.button) {
            case (.move, _): .mouseMoved
            case (.down, .left): .leftMouseDown
            case (.up, .left): .leftMouseUp
            case (.down, .right), (.down, .barrel): .rightMouseDown
            case (.up, .right), (.up, .barrel): .rightMouseUp
            case (.down, .middle): .otherMouseDown
            case (.up, .middle): .otherMouseUp
            case (_, .eraser):
                throw BridgeError(
                    code: BridgeError.unimplemented,
                    message: "macOS can't synthesize a stylus eraser event"
                )
            }

            guard let event = NSEvent.mouseEvent(
                with: type,
                location: windowPoint(x: pointer.x, y: pointer.y),
                modifierFlags: Self.flags(pointer.modifiers),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: pointer.clickCount,
                pressure: Float(pointer.pressure ?? (pointer.phase == .down ? 1 : 0))
            ) else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "couldn't build a \(type) mouse event"
                )
            }
            send(event, to: window)
        }

        // MARK: - Keyboard

        @MainActor
        private func sendKey(_ key: KeyInput, to window: NSWindow) throws {
            // A key event only reaches the page through the responder chain, and
            // the chain starts at the window's first responder. Make the webview
            // it — `makeFirstResponder` doesn't steal focus from another app the
            // way `makeKey` + `NSApp.activate` would.
            if window.firstResponder !== webView {
                window.makeFirstResponder(webView)
            }
            // `characters` decides what the page sees as `event.key`, and an
            // **empty** string is not "no character" — WebKit reads it as a dead
            // key and the page gets `key: "Dead"`. Every named key used to land
            // that way (arrows, Enter, Tab, Escape, Backspace), so anything
            // switching on `e.key` — which is nearly everything — couldn't be
            // driven at all, while `code` and `keyCode` looked perfectly right.
            // Reported by an adopter whose reader ignored every arrow key.
            //
            // A named key therefore carries the character macOS itself sends for
            // it: a control character for Enter / Tab / Escape / Backspace, and
            // for the navigation and function keys one of AppKit's private-use
            // code points (`NSLeftArrowFunctionKey` = U+F702 and friends).
            let named = Self.namedKey(key.key) ?? key.code.flatMap(Self.namedKey)
            let characters = key.text ?? named?.characters ?? (key.key.count == 1 ? key.key : "")
            // Real navigation/function-key events carry these flags; WebKit and
            // page code can both read them, so match what a keyboard produces.
            var modifierFlags = Self.flags(key.modifiers)
            if let named { modifierFlags.formUnion(named.flags) }
            guard let event = NSEvent.keyEvent(
                with: key.phase == .down ? .keyDown : .keyUp,
                location: .zero,
                modifierFlags: modifierFlags,
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: named?.virtualKeyCode ?? Self.virtualKeyCode(key: key.key, code: key.code)
            ) else {
                throw BridgeError(code: BridgeError.handler, message: "couldn't build a key event")
            }
            send(event, to: window)
        }

        // MARK: - Wheel

        @MainActor
        private func sendWheel(_ wheel: WheelInput, to window: NSWindow) throws {
            // `NSEvent` has no public scroll-wheel constructor, so go through a
            // `CGEvent` and wrap it. Note this *creates* an event; it never
            // calls `CGEvent.post`, which is the part that would need an
            // Accessibility grant and would hit the whole system.
            //
            // Sign: AppKit's scrolling deltas are the inverse of the DOM's, so a
            // positive `deltaY` (DOM: content moves down) becomes a negative
            // wheel value here.
            guard let scroll = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 2,
                wheel1: Int32(-wheel.deltaY.rounded()),
                wheel2: Int32(-wheel.deltaX.rounded()),
                wheel3: 0
            ) else {
                throw BridgeError(code: BridgeError.handler, message: "couldn't build a scroll event")
            }
            scroll.flags = Self.cgFlags(wheel.modifiers)
            // `NSEvent(cgEvent:)` derives its window from the event location,
            // which is in *screen* coordinates with a flipped origin.
            let inWindow = windowPoint(x: wheel.x, y: wheel.y)
            let onScreen = window.convertPoint(toScreen: inWindow)
            let flippedY = (NSScreen.screens.first?.frame.height ?? onScreen.y) - onScreen.y
            scroll.location = CGPoint(x: onScreen.x, y: flippedY)

            guard let event = NSEvent(cgEvent: scroll) else {
                throw BridgeError(code: BridgeError.handler, message: "couldn't wrap the scroll event")
            }
            send(event, to: window)
        }

        // MARK: - Delivery

        /// Hand the event to the app's own window, first registering it so the
        /// system alert beep can be suppressed if nothing ends up handling it.
        ///
        /// Registration rather than a scope around `sendEvent`: WebKit decides a
        /// key event's fate asynchronously and re-sends the unhandled ones on a
        /// later turn of the main loop, so there is no synchronous window to
        /// bracket. See `DriverWindow`.
        @MainActor
        private func send(_ event: NSEvent, to window: NSWindow) {
            #if SWIFT_PWA_DRIVER
                DriverWindow.willInject(event)
            #endif
            window.sendEvent(event)
        }

        // MARK: - Conversions

        /// What macOS actually sends for a named DOM key: the virtual key code,
        /// the `characters` payload, and the modifier flags a real event carries.
        ///
        /// The `characters` column is the load-bearing one — see `sendKey`. The
        /// private-use code points are AppKit's (`NSUpArrowFunctionKey` etc.);
        /// they're spelled numerically because the AppKit constants are `Int`s
        /// and this table is `Character`s.
        package struct NamedKey {
            package let virtualKeyCode: UInt16
            package let characters: String
            package var flags: NSEvent.ModifierFlags = []
        }

        package static func namedKey(_ name: String) -> NamedKey? {
            // `.function` marks the private-use function keys; arrows add
            // `.numericPad`, which is what a real arrow-key event reports.
            let arrow: NSEvent.ModifierFlags = [.function, .numericPad]
            let fn: NSEvent.ModifierFlags = [.function]
            let table: [String: NamedKey] = [
                // Navigation.
                "ArrowUp": .init(virtualKeyCode: 126, characters: "\u{F700}", flags: arrow),
                "ArrowDown": .init(virtualKeyCode: 125, characters: "\u{F701}", flags: arrow),
                "ArrowLeft": .init(virtualKeyCode: 123, characters: "\u{F702}", flags: arrow),
                "ArrowRight": .init(virtualKeyCode: 124, characters: "\u{F703}", flags: arrow),
                "Home": .init(virtualKeyCode: 115, characters: "\u{F729}", flags: fn),
                "End": .init(virtualKeyCode: 119, characters: "\u{F72B}", flags: fn),
                "PageUp": .init(virtualKeyCode: 116, characters: "\u{F72C}", flags: fn),
                "PageDown": .init(virtualKeyCode: 121, characters: "\u{F72D}", flags: fn),
                // Editing. Note macOS's "delete" key is the DOM's Backspace and
                // sends U+007F; the DOM's forward Delete is a separate key.
                "Enter": .init(virtualKeyCode: 36, characters: "\r"),
                "Return": .init(virtualKeyCode: 36, characters: "\r"),
                "NumpadEnter": .init(virtualKeyCode: 76, characters: "\u{3}", flags: fn),
                "Tab": .init(virtualKeyCode: 48, characters: "\t"),
                "Escape": .init(virtualKeyCode: 53, characters: "\u{1B}"),
                "Backspace": .init(virtualKeyCode: 51, characters: "\u{7F}"),
                "Delete": .init(virtualKeyCode: 117, characters: "\u{F728}", flags: fn),
                "Insert": .init(virtualKeyCode: 114, characters: "\u{F727}", flags: fn),
                "Space": .init(virtualKeyCode: 49, characters: " "),
                " ": .init(virtualKeyCode: 49, characters: " ")
            ]
            if let match = table[name] { return match }
            // F1–F12: consecutive private-use code points, non-consecutive key codes.
            let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
            if name.first == "F", let number = Int(name.dropFirst()), (1 ... 12).contains(number) {
                return NamedKey(
                    virtualKeyCode: functionKeyCodes[number - 1],
                    characters: String(UnicodeScalar(0xF704 + number - 1)!),
                    flags: fn
                )
            }
            return nil
        }

        /// Page-space (CSS pixels from the webview's top-left, y down) to
        /// window-space (points from the window's bottom-left, y up).
        @MainActor
        private func windowPoint(x: Double, y: Double) -> NSPoint {
            let inView = webView.isFlipped
                ? NSPoint(x: x, y: y)
                : NSPoint(x: x, y: webView.bounds.height - y)
            return webView.convert(inView, to: nil)
        }

        private static func flags(_ modifiers: InputModifiers) -> NSEvent.ModifierFlags {
            var flags = NSEvent.ModifierFlags()
            if modifiers.contains(.shift) { flags.insert(.shift) }
            if modifiers.contains(.control) { flags.insert(.control) }
            if modifiers.contains(.alt) { flags.insert(.option) }
            if modifiers.contains(.meta) { flags.insert(.command) }
            return flags
        }

        private static func cgFlags(_ modifiers: InputModifiers) -> CGEventFlags {
            var flags = CGEventFlags()
            if modifiers.contains(.shift) { flags.insert(.maskShift) }
            if modifiers.contains(.control) { flags.insert(.maskControl) }
            if modifiers.contains(.alt) { flags.insert(.maskAlternate) }
            if modifiers.contains(.meta) { flags.insert(.maskCommand) }
            return flags
        }

        /// DOM `key` / `code` to a macOS virtual key code.
        ///
        /// Covers the keys a driver actually sends — letters, digits, and the
        /// navigation / editing keys. Anything unmapped gets `0`, which still
        /// delivers the event's *characters* (so typing text works) but won't
        /// trigger behaviour keyed on the physical key.
        private static func virtualKeyCode(key: String, code: String?) -> UInt16 {
            // Named keys are handled by `namedKey(_:)`, which also carries the
            // `characters` they must send; this is the character-key fallback.
            if let named = namedKey(key) ?? code.flatMap(namedKey) { return named.virtualKeyCode }

            let letters = "asdfhgzxcv" // 0...9 in macOS virtual-key order
            let lowercased = key.lowercased()
            if lowercased.count == 1, let index = letters.firstIndex(of: Character(lowercased)) {
                return UInt16(letters.distance(from: letters.startIndex, to: index))
            }
            let others: [Character: UInt16] = [
                "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
                "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24,
                "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31,
                "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39,
                "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
                ".": 47, "`": 50
            ]
            if lowercased.count == 1, let match = others[Character(lowercased)] { return match }
            return 0
        }
    }
#endif
