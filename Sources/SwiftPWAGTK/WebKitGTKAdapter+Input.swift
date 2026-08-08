#if os(Linux)
    import CGtk3Shim
    import CWebKitGTK4Shim
    import Foundation
    import SwiftPWACore

    /// Synthetic input for the GTK3 backend — the app driver's `input.*` verbs.
    ///
    /// Events are pushed through `gtk_main_do_event`, GTK's own dispatch entry
    /// point, so they travel the real path (grabs, widget hierarchy, WebKit's
    /// hit testing) without an X test extension or any OS-wide injection — and
    /// so they work under Xvfb, where there's no input device at all.
    ///
    /// The GTK4 backend has no counterpart, and can't: GTK4 made `GdkEvent`
    /// opaque with no public constructors and removed `gtk_main_do_event`.
    extension WebKitGTKAdapter {
        /// Mouse only. GDK can carry a stylus (`GdkDeviceTool`, axes for
        /// pressure and tilt), but only for a device the display server
        /// actually has; a fabricated tool on a display with no tablet is a
        /// different kind of lie from the one this is trying to avoid, so a pen
        /// request is refused instead.
        public var inputCapabilities: InputCapabilities {
            InputCapabilities(
                pointer: true,
                key: true,
                wheel: true,
                pointerTypes: [.mouse],
                pressure: false,
                tilt: false
            )
        }

        public func send(_ input: SyntheticInput) async throws {
            let raw = UInt(bitPattern: viewWidget)
            try await MainThread.run {
                guard let widget = UnsafeMutablePointer<GtkWidget>(bitPattern: raw) else {
                    throw BridgeError(
                        code: BridgeError.handler,
                        message: "the web view went away before the event was delivered"
                    )
                }
                switch input {
                case let .pointer(pointer):
                    try Self.sendPointer(pointer, to: widget)
                case let .key(key):
                    try Self.sendKey(key, to: widget)
                case let .wheel(wheel):
                    swiftpwa_send_scroll_event(
                        widget, wheel.x, wheel.y,
                        wheel.deltaX / Self.pixelsPerScrollUnit,
                        wheel.deltaY / Self.pixelsPerScrollUnit,
                        Self.state(wheel.modifiers)
                    )
                }
            }
        }

        /// CSS pixels scrolled per unit of GDK smooth-scroll delta.
        ///
        /// GDK's smooth deltas aren't pixels — WebKit applies its own line-step
        /// conversion — so `WheelInput`'s documented CSS-pixel contract has to
        /// be divided through by it. **Measured**, not derived from WebKit's
        /// headers: on WebKitGTK 4.1 a delta of 1/2/5/10 scrolled 83/166/415/830
        /// px, i.e. exactly linear at 83. If a WebKit release changes its
        /// line-step arithmetic this constant is what needs re-measuring, and a
        /// scroll of the wrong distance is the symptom.
        private static let pixelsPerScrollUnit = 83.0

        private static func sendPointer(_ pointer: PointerInput, to widget: UnsafeMutablePointer<GtkWidget>) throws {
            let button: Int32 = switch pointer.button {
            case .left: 1
            case .middle: 2
            case .right, .barrel: 3
            case .eraser:
                throw BridgeError(
                    code: BridgeError.unimplemented,
                    message: "GTK can't synthesize a stylus eraser event"
                )
            }
            let phase: Int32 = switch pointer.phase {
            case .down: 0
            case .up: 1
            case .move: 2
            }
            swiftpwa_send_pointer_event(
                widget, phase, pointer.x, pointer.y,
                button, Int32(pointer.clickCount), state(pointer.modifiers)
            )
        }

        private static func sendKey(_ key: KeyInput, to widget: UnsafeMutablePointer<GtkWidget>) throws {
            let keyval = gdkKeyval(for: key.key)
            guard keyval != 0 else {
                throw BridgeError(
                    code: BridgeError.handler,
                    message: "no GDK keyval for key '\(key.key)'"
                )
            }
            swiftpwa_send_key_event(widget, key.phase == .down ? 0 : 1, keyval, state(key.modifiers))
        }

        /// DOM `KeyboardEvent.key` to a GDK keyval.
        ///
        /// Named keys go through GDK's own name table, which spells several of
        /// them differently from the DOM (`Return` vs `Enter`, `Left` vs
        /// `ArrowLeft`); anything else is a character, and GDK maps Unicode
        /// scalars directly.
        private static func gdkKeyval(for key: String) -> UInt32 {
            let gdkNames: [String: String] = [
                "Enter": "Return", "Escape": "Escape", "Tab": "Tab",
                "Backspace": "BackSpace", "Delete": "Delete", " ": "space",
                "ArrowLeft": "Left", "ArrowRight": "Right",
                "ArrowUp": "Up", "ArrowDown": "Down",
                "Home": "Home", "End": "End", "PageUp": "Page_Up", "PageDown": "Page_Down"
            ]
            if let name = gdkNames[key] {
                return name.withCString { swiftpwa_keyval_from_name($0) }
            }
            if key.count == 1, let scalar = key.unicodeScalars.first {
                return swiftpwa_keyval_from_unicode(scalar.value)
            }
            // A multi-character name we don't know: try GDK's table verbatim
            // (it knows "F1", "Insert", and plenty more) before giving up.
            return key.withCString { swiftpwa_keyval_from_name($0) }
        }

        /// `InputModifiers` to a `GdkModifierType` mask.
        private static func state(_ modifiers: InputModifiers) -> UInt32 {
            var mask: UInt32 = 0
            if modifiers.contains(.shift) { mask |= GDK_SHIFT_MASK.rawValue }
            if modifiers.contains(.control) { mask |= GDK_CONTROL_MASK.rawValue }
            if modifiers.contains(.alt) { mask |= GDK_MOD1_MASK.rawValue }
            if modifiers.contains(.meta) { mask |= GDK_META_MASK.rawValue }
            return mask
        }
    }
#endif
