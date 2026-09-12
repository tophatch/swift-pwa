#if os(Windows)
    import CWebView2Shim
    import Foundation
    import SwiftPWACore

    /// Synthetic input for the Windows backend — the app driver's `input.*`
    /// verbs, over the Chrome DevTools Protocol.
    ///
    /// WebView2's own `SendPointerInput` lives on
    /// `ICoreWebView2CompositionController`, and swift-pwa creates a *windowed*
    /// controller, so for two releases this backend reported no input at all.
    /// The obvious alternative — `SendInput` / `keybd_event` — would have cost
    /// the property the whole driver is built on: OS-level injection moves the
    /// real cursor, needs the window foreground, and makes the machine unusable
    /// while a run is in progress.
    ///
    /// CDP's `Input` domain is the way out. `CallDevToolsProtocolMethod` is on
    /// the base `ICoreWebView2`, and `Input.dispatchKeyEvent` /
    /// `Input.dispatchMouseEvent` inject at the *browser* level: the page sees
    /// trusted events with hit testing, focus and default actions, nothing goes
    /// near the OS input queue, and a backgrounded window drives correctly.
    /// It is the same mechanism Puppeteer and Playwright drive Chromium with.
    extension WebView2Adapter {
        /// Mouse only, for now. CDP's `dispatchMouseEvent` does take
        /// `pointerType: "pen"` and a `force`, so a stylus path is reachable
        /// here in a way it isn't on AppKit or GDK — but a capability is only
        /// claimed once it's been measured against a real page, since a stylus
        /// test that silently ran as a mouse click would pass while proving
        /// nothing.
        public var inputCapabilities: InputCapabilities {
            InputCapabilities(
                pointer: true,
                key: true,
                wheel: true,
                pointerTypes: [.mouse],
                pressure: false,
                tilt: false,
                // Not the display server: CDP injects inside the browser, so
                // this backend keeps the same "no focus needed, cursor doesn't
                // move" guarantee as macOS and GTK3.
                delivery: .appQueue
            )
        }

        public func send(_ input: SyntheticInput) async throws {
            switch input {
            case let .pointer(pointer):
                try await dispatch("Input.dispatchMouseEvent", Self.pointerParameters(pointer))
            case let .key(key):
                try await dispatch("Input.dispatchKeyEvent", Self.keyParameters(key))
            case let .wheel(wheel):
                try await dispatch("Input.dispatchMouseEvent", Self.wheelParameters(wheel))
            }
        }

        // MARK: - Parameters

        private static func pointerParameters(_ pointer: PointerInput) -> [String: JSONValue] {
            let type = switch pointer.phase {
            case .down: "mousePressed"
            case .up: "mouseReleased"
            case .move: "mouseMoved"
            }
            var parameters: [String: JSONValue] = [
                "type": .string(type),
                "x": .number(pointer.x),
                "y": .number(pointer.y),
                "button": .string(cdpButton(pointer.button)),
                // Which buttons are held *during* the event. A move with this
                // empty is a hover; with it set, a drag. Chromium distinguishes
                // the two here rather than by event type.
                "buttons": .number(Double(buttonsMask(pointer.buttons))),
                "clickCount": .number(Double(pointer.clickCount)),
                "modifiers": .number(Double(modifierMask(pointer.modifiers)))
            ]
            // A move carries no button; saying "left" would make Chromium treat
            // a hover as a drag of the left button.
            if pointer.phase == .move, pointer.buttons.isEmpty {
                parameters["button"] = .string("none")
            }
            return parameters
        }

        private static func wheelParameters(_ wheel: WheelInput) -> [String: JSONValue] {
            [
                "type": .string("mouseWheel"),
                "x": .number(wheel.x),
                "y": .number(wheel.y),
                // CDP takes CSS pixels with the DOM's sign convention, which is
                // the contract `WheelInput` already documents — so unlike GDK,
                // nothing needs scaling here.
                "deltaX": .number(wheel.deltaX),
                "deltaY": .number(wheel.deltaY),
                "button": .string("none"),
                "modifiers": .number(Double(modifierMask(wheel.modifiers)))
            ]
        }

        private static func keyParameters(_ key: KeyInput) -> [String: JSONValue] {
            let text = key.text ?? (key.key.count == 1 ? key.key : nil)
            let modifiers = modifierMask(key.modifiers)
            // A keystroke that inserts nothing is `rawKeyDown`; one that does is
            // `keyDown` carrying the text. Chromium inserts on the strength of
            // `text`, so a shortcut sent as `keyDown` with text would type a
            // character *and* fire the shortcut. Anything with Ctrl or Meta
            // held is a shortcut, whatever character the key would otherwise
            // produce.
            let isShortcut = key.modifiers.contains(.control) || key.modifiers.contains(.meta)
            let inserts = text != nil && !isShortcut
            var parameters: [String: JSONValue] = [
                "type": .string(key.phase == .down ? (inserts ? "keyDown" : "rawKeyDown") : "keyUp"),
                "key": .string(key.key),
                "code": .string(key.code ?? domCode(for: key.key)),
                "windowsVirtualKeyCode": .number(Double(virtualKeyCode(for: key.key))),
                "nativeVirtualKeyCode": .number(Double(virtualKeyCode(for: key.key))),
                "modifiers": .number(Double(modifiers))
            ]
            if inserts, key.phase == .down, let text {
                parameters["text"] = .string(text)
                parameters["unmodifiedText"] = .string(text)
            }
            return parameters
        }

        // MARK: - Mappings

        /// CDP's modifier bitmask. Not the DOM's, and not Win32's.
        private static func modifierMask(_ modifiers: InputModifiers) -> Int {
            var mask = 0
            if modifiers.contains(.alt) { mask |= 1 }
            if modifiers.contains(.control) { mask |= 2 }
            if modifiers.contains(.meta) { mask |= 4 }
            if modifiers.contains(.shift) { mask |= 8 }
            return mask
        }

        private static func cdpButton(_ button: PointerButton) -> String {
            switch button {
            case .left: "left"
            case .middle: "middle"
            case .right, .barrel: "right"
            // Chromium has no eraser button; "back" would be a lie of a
            // different kind, so send left and let the capability report —
            // which claims mouse only — be what a caller branches on.
            case .eraser: "left"
            }
        }

        /// The `buttons` bitmask, which is the DOM's, not `button`'s numbering.
        private static func buttonsMask(_ buttons: Set<PointerButton>) -> Int {
            var mask = 0
            if buttons.contains(.left) { mask |= 1 }
            if buttons.contains(.right) || buttons.contains(.barrel) { mask |= 2 }
            if buttons.contains(.middle) { mask |= 4 }
            return mask
        }

        /// Windows virtual key code for a DOM key value.
        ///
        /// Chromium uses this to decide what a keystroke *means* — an editing
        /// shortcut is matched on the virtual key, not on `key` — so a wrong or
        /// absent code turns Ctrl+Z into a keystroke that arrives in the page
        /// and does nothing.
        private static func virtualKeyCode(for key: String) -> Int {
            if let named = namedVirtualKeys[key] { return named }
            guard key.count == 1, let scalar = key.uppercased().unicodeScalars.first else { return 0 }
            return Int(scalar.value)
        }

        private static let namedVirtualKeys: [String: Int] = [
            "Backspace": 8, "Tab": 9, "Enter": 13, "Escape": 27, " ": 32,
            "PageUp": 33, "PageDown": 34, "End": 35, "Home": 36,
            "ArrowLeft": 37, "ArrowUp": 38, "ArrowRight": 39, "ArrowDown": 40,
            "Insert": 45, "Delete": 46,
            "F1": 112, "F2": 113, "F3": 114, "F4": 115, "F5": 116, "F6": 117,
            "F7": 118, "F8": 119, "F9": 120, "F10": 121, "F11": 122, "F12": 123
        ]

        /// A plausible `KeyboardEvent.code` when the caller didn't give one.
        /// Pages switch on `code` for layout-independent shortcuts, so leaving
        /// it empty is its own bug.
        private static func domCode(for key: String) -> String {
            if namedVirtualKeys[key] != nil || key.hasPrefix("F") {
                return key == " " ? "Space" : key
            }
            guard key.count == 1, let scalar = key.unicodeScalars.first else { return "" }
            if scalar.properties.isAlphabetic { return "Key\(key.uppercased())" }
            if ("0" ... "9").contains(key) { return "Digit\(key)" }
            return ""
        }

        // MARK: - Transport

        /// One CDP call, awaited so a failure surfaces instead of vanishing.
        private func dispatch(_ method: String, _ parameters: [String: JSONValue]) async throws {
            let json = try String(data: JSONValue.object(parameters).encoded(), encoding: .utf8) ?? "{}"
            _ = try await withCheckedThrowingContinuation {
                (cont: CheckedContinuation<String?, any Error>) in
                let box = EvalBox(continuation: cont)
                Task { [self] in
                    await MainThread.run {
                        guard let view = self.driverView else {
                            box.continuation.resume(throwing: BridgeError(
                                code: BridgeError.handler,
                                message: "the webview went away before the event was delivered"
                            ))
                            return
                        }
                        let boxPtr = Unmanaged.passRetained(box).toOpaque()
                        method.withCString(encodedAs: UTF16.self) { wMethod in
                            json.withCString(encodedAs: UTF16.self) { wJSON in
                                swiftpwa_w2_view_call_devtools_protocol(
                                    view, wMethod, wJSON, evalCompleteTrampoline, boxPtr
                                )
                            }
                        }
                    }
                }
            }
        }
    }
#endif
