#if os(macOS)
    import AppKit
    @testable import SwiftPWAWebKit
    import Testing

    /// The `characters` payload of a synthesized key event.
    ///
    /// This is the whole bug: a named key used to be sent with `characters: ""`,
    /// and WebKit reads an empty string as a **dead key** — the page got
    /// `key: "Dead"` while `code` and `keyCode` looked perfectly correct, so
    /// nothing that switches on `e.key` (which is nearly everything) could be
    /// driven. Reported by an adopter whose reader ignored every arrow key.
    @Suite("synthetic key characters")
    struct SyntheticKeyTests {
        /// The invariant that would have caught it: a key we claim to know must
        /// carry a character, because "" doesn't mean "no character" to WebKit.
        @Test("every named key carries a non-empty character")
        func neverEmpty() throws {
            let names = [
                "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
                "Home", "End", "PageUp", "PageDown",
                "Enter", "Return", "NumpadEnter", "Tab", "Escape",
                "Backspace", "Delete", "Insert", "Space", " ",
                "F1", "F5", "F12"
            ]
            for name in names {
                let named = try #require(WKWebViewAdapter.namedKey(name), "no mapping for \(name)")
                #expect(!named.characters.isEmpty, "\(name) would arrive as key: \"Dead\"")
            }
        }

        /// Arrows carry AppKit's private-use code points and the flags a real
        /// arrow-key event has; those are what WebKit turns back into `ArrowLeft`.
        @Test("arrows use the private-use function-key code points")
        func arrows() throws {
            let right = try #require(WKWebViewAdapter.namedKey("ArrowRight"))
            #expect(right.characters == "\u{F703}")
            #expect(right.virtualKeyCode == 124)
            #expect(right.flags.contains(.function))
            #expect(right.flags.contains(.numericPad))

            #expect(WKWebViewAdapter.namedKey("ArrowLeft")?.characters == "\u{F702}")
            #expect(WKWebViewAdapter.namedKey("ArrowUp")?.characters == "\u{F700}")
            #expect(WKWebViewAdapter.namedKey("ArrowDown")?.characters == "\u{F701}")
        }

        @Test("the editing keys send their control characters")
        func editingKeys() {
            #expect(WKWebViewAdapter.namedKey("Enter")?.characters == "\r")
            #expect(WKWebViewAdapter.namedKey("Tab")?.characters == "\t")
            #expect(WKWebViewAdapter.namedKey("Escape")?.characters == "\u{1B}")
        }

        /// macOS's "delete" key is the DOM's **Backspace**; the DOM's forward
        /// Delete is a different key with a different code and character. They
        /// used to share one virtual key code, so `--key Delete` deleted
        /// backwards.
        @Test("Backspace and Delete are different keys")
        func backspaceIsNotDelete() throws {
            let backspace = try #require(WKWebViewAdapter.namedKey("Backspace"))
            let forward = try #require(WKWebViewAdapter.namedKey("Delete"))
            #expect(backspace.characters == "\u{7F}")
            #expect(backspace.virtualKeyCode == 51)
            #expect(forward.characters == "\u{F728}")
            #expect(forward.virtualKeyCode == 117)
            #expect(backspace.virtualKeyCode != forward.virtualKeyCode)
        }

        @Test("function keys are generated, not tabulated one by one")
        func functionKeys() {
            #expect(WKWebViewAdapter.namedKey("F1")?.characters == "\u{F704}")
            #expect(WKWebViewAdapter.namedKey("F12")?.characters == "\u{F70F}")
            #expect(WKWebViewAdapter.namedKey("F12")?.virtualKeyCode == 111)
            // Out of range, and not a key name at all.
            #expect(WKWebViewAdapter.namedKey("F13") == nil)
            #expect(WKWebViewAdapter.namedKey("Fnord") == nil)
            #expect(WKWebViewAdapter.namedKey("a") == nil)
        }
    }
#endif
