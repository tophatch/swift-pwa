#if os(macOS)
    import AppKit

    /// What macOS actually sends for a named DOM key — the table behind
    /// `drive type --key ArrowRight`.
    ///
    /// A plain namespace at file scope rather than a member of
    /// `WKWebViewAdapter`: it's pure data with no isolation of its own, and
    /// nesting it inside an actor-isolated type made it main-actor-isolated on
    /// some toolchains and not others (Swift 6.1.2 rejected what 6.3.3 allowed),
    /// which is a silly reason for a test not to compile.
    enum SyntheticKeyMap {
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

        package static func named(_ name: String) -> NamedKey? {
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
    }
#endif
