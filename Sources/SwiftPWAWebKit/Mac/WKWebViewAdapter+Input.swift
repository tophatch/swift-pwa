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
            window.sendEvent(event)
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
            // `characters` is what gets inserted. An explicit `text` wins; a
            // single-character `key` is itself; a named key ("Enter",
            // "ArrowLeft") inserts nothing, since its effect comes from the key
            // code rather than a character.
            let characters = key.text ?? (key.key.count == 1 ? key.key : "")
            guard let event = NSEvent.keyEvent(
                with: key.phase == .down ? .keyDown : .keyUp,
                location: .zero,
                modifierFlags: Self.flags(key.modifiers),
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: Self.virtualKeyCode(key: key.key, code: key.code)
            ) else {
                throw BridgeError(code: BridgeError.handler, message: "couldn't build a key event")
            }
            window.sendEvent(event)
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
            window.sendEvent(event)
        }

        // MARK: - Conversions

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
            let named: [String: UInt16] = [
                "Enter": 36, "Return": 36, "Tab": 48, " ": 49, "Space": 49,
                "Backspace": 51, "Delete": 51, "Escape": 53,
                "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126
            ]
            if let match = named[key] { return match }
            if let code, let match = named[code] { return match }

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
