#if os(Linux)
    import CGtk4Shim
    import CWebKitGTK6Shim
    import Foundation
    import SwiftPWACore

    /// Synthetic input for the GTK4 backend — the app driver's `input.*` verbs.
    ///
    /// **This one is different from every other backend, and the capability
    /// report says so.** Everywhere else the driver pushes events into the
    /// app's own queue, which is what lets a backgrounded window be driven
    /// while the machine stays usable. GTK4 offers no such route: `GdkEvent`
    /// became opaque with no public constructors and `gtk_main_do_event` was
    /// removed, so `gdk_display_put_event` survives with nothing to hand it.
    /// WebKitGTK exposes no injection API of its own either.
    ///
    /// What is left is XTEST, the X server's test extension — the same
    /// mechanism `xdotool` uses. Events enter at the *server*, so:
    ///
    /// * the window must hold **input focus**, and
    /// * the real pointer really moves, and
    /// * it reaches X11 and XWayland clients only — a native Wayland session
    ///   can't be driven at all.
    ///
    /// That is a worse guarantee than the other backends give, which is exactly
    /// why ``InputCapabilities/delivery`` exists rather than a bare `true`. It
    /// is still worth having: under Xvfb there is no input device, nothing
    /// competes for focus, and this is the only way the GTK4 backend's keyboard
    /// behaviour can be checked by anything other than a person.
    extension WebKitGTKAdapter {
        public var inputCapabilities: InputCapabilities {
            // Answered by asking, not by assuming: the same binary reports no
            // input on a Wayland session and full input under Xvfb, and a build
            // on a box without libXtst reports none anywhere. A backend that
            // claimed otherwise would produce tests that pass by not running.
            guard canSynthesizeInput else { return .none }
            return InputCapabilities(
                pointer: true,
                key: true,
                wheel: true,
                pointerTypes: [.mouse],
                pressure: false,
                tilt: false,
                delivery: .displayServer
            )
        }

        public func send(_ input: SyntheticInput) async throws {
            let raw = UInt(bitPattern: viewWidget)
            let lifetime = lifetime
            try await MainThread.run {
                guard lifetime.isAlive,
                      let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: raw)
                else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "the web view went away before the event was delivered"
                    )
                }
                switch input {
                case let .pointer(pointer): try Self.sendPointer(pointer, to: widget)
                case let .key(key): try Self.sendKey(key, to: widget)
                case let .wheel(wheel): try Self.sendWheel(wheel, to: widget)
                }
            }
        }

        private static func sendPointer(
            _ pointer: PointerInput,
            to widget: UnsafeMutablePointer<GtkWidget>
        ) throws {
            let button: Int32 = switch pointer.button {
            case .left: 1
            case .middle: 2
            case .right, .barrel: 3
            case .eraser:
                throw BridgeError(
                    code: BridgeError.unimplemented,
                    message: "X11 has no stylus eraser button to fake"
                )
            }
            let phase: Int32 = switch pointer.phase {
            case .down: 0
            case .up: 1
            case .move: 2
            }
            // No button mask to carry, unlike GTK3: XTEST presses the real
            // button, so the server already knows what's held and a drag is a
            // drag without being told.
            guard swiftpwa_x11_send_pointer(widget, phase, pointer.x, pointer.y, button) != 0 else {
                throw Self.unavailable
            }
        }

        private static func sendKey(_ key: KeyInput, to widget: UnsafeMutablePointer<GtkWidget>) throws {
            let keyval = GDKKeyval.forDOMKey(key.key)
            guard keyval != 0 else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "no GDK keyval for key '\(key.key)'"
                )
            }
            guard swiftpwa_x11_send_key(
                widget, key.phase == .down ? 0 : 1, keyval, state(key.modifiers)
            ) != 0 else {
                // Distinct from "no keyval": the name resolved, but the active
                // keymap has no physical key carrying it. A caller driving a
                // layout-dependent key needs to know which of the two it hit.
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "'\(key.key)' isn't on the active X keymap, or XTEST is unavailable"
                )
            }
        }

        private static func sendWheel(
            _ wheel: WheelInput,
            to widget: UnsafeMutablePointer<GtkWidget>
        ) throws {
            // X11 has no scroll axis — buttons 4/5 are vertical, 6/7
            // horizontal — so a pixel delta has to become whole notches. 53 px
            // is WebKitGTK's own per-notch step; a fractional remainder is
            // dropped rather than rounded up, so a small scroll does nothing
            // instead of jumping a full line.
            let notch = 53.0
            for (delta, negative, positive) in [
                (wheel.deltaY, Int32(4), Int32(5)),
                (wheel.deltaX, Int32(6), Int32(7))
            ] {
                let clicks = Int32(abs(delta) / notch)
                guard clicks > 0 else { continue }
                let button = delta < 0 ? negative : positive
                guard swiftpwa_x11_send_scroll(widget, wheel.x, wheel.y, button, clicks) != 0 else {
                    throw Self.unavailable
                }
            }
        }

        private static var unavailable: BridgeError {
            BridgeError(
                code: BridgeError.unimplemented,
                message: """
                synthetic input needs XTEST, which this session doesn't offer — \
                a native Wayland session or a box without libXtst. Check \
                `drive info` (input.delivery) before driving input here.
                """
            )
        }

        /// `InputModifiers` to a `GdkModifierType` mask. The shim turns these
        /// back into real modifier key presses, because XTEST has no state
        /// field — the server derives it from what's physically down.
        private static func state(_ modifiers: InputModifiers) -> UInt32 {
            var mask: UInt32 = 0
            if modifiers.contains(.shift) { mask |= GDK_SHIFT_MASK.rawValue }
            if modifiers.contains(.control) { mask |= GDK_CONTROL_MASK.rawValue }
            if modifiers.contains(.alt) { mask |= GDK_ALT_MASK.rawValue }
            if modifiers.contains(.meta) { mask |= GDK_SUPER_MASK.rawValue }
            return mask
        }
    }

    /// DOM `KeyboardEvent.key` to a GDK keyval, which is also an X keysym for
    /// everything here — the two numbering schemes are the same by design.
    ///
    /// Shared shape with the GTK3 backend rather than shared code: the two
    /// targets never appear in one build, so a common file would have to live
    /// in Core and drag GDK's headers with it.
    enum GDKKeyval {
        /// GDK spells several of these differently from the DOM.
        private static let gdkNames: [String: String] = [
            "Enter": "Return", "Escape": "Escape", "Tab": "Tab",
            "Backspace": "BackSpace", "Delete": "Delete", " ": "space",
            "ArrowLeft": "Left", "ArrowRight": "Right",
            "ArrowUp": "Up", "ArrowDown": "Down",
            "Home": "Home", "End": "End", "PageUp": "Page_Up", "PageDown": "Page_Down"
        ]

        static func forDOMKey(_ key: String) -> UInt32 {
            if let name = gdkNames[key] {
                return name.withCString { swiftpwa_gtk4_keyval_from_name($0) }
            }
            if key.count == 1, let scalar = key.unicodeScalars.first {
                return swiftpwa_gtk4_keyval_from_unicode(scalar.value)
            }
            // A name we don't know: GDK's own table has "F1", "Insert" and
            // plenty more, so try it verbatim before giving up.
            return key.withCString { swiftpwa_gtk4_keyval_from_name($0) }
        }
    }
#endif
