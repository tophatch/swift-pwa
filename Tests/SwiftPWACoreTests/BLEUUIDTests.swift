@testable import SwiftPWACore
import Testing

@Suite("BLE UUIDs")
struct BLEUUIDTests {
    @Test("the short forms are the same UUID as the long one")
    func shortFormsExpand() {
        // `FFE1` *is* `0000FFE1-0000-1000-8000-00805F9B34FB`. Treating them as
        // different strings is what makes a page work on one backend and
        // silently match nothing on the other three.
        let canonical = "0000ffe1-0000-1000-8000-00805f9b34fb"
        #expect(BLEUUID.canonical("ffe1") == canonical)
        #expect(BLEUUID.canonical("FFE1") == canonical)
        #expect(BLEUUID.canonical("0000ffe1") == canonical)
        #expect(BLEUUID.canonical(canonical.uppercased()) == canonical)
        // Windows prints GUIDs in braces.
        #expect(BLEUUID.canonical("{0000FFE1-0000-1000-8000-00805F9B34FB}") == canonical)
        // Un-hyphenated, which several tools emit.
        #expect(BLEUUID.canonical("0000ffe10000100080000080 5f9b34fb".replacingOccurrences(of: " ", with: ""))
            == canonical)
    }

    @Test("a custom 128-bit UUID passes through, lower-cased")
    func customUUIDs() {
        let custom = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
        #expect(BLEUUID.canonical(custom.uppercased()) == custom)
        // …and has no short form: it isn't in the assigned-numbers range.
        #expect(BLEUUID.shortForm(custom) == nil)
        #expect(BLEUUID.shortForm("ffe1") == "ffe1")
    }

    @Test("anything that isn't a UUID is refused rather than matching nothing")
    func rejectsNonUUIDs() {
        // A typo'd UUID is otherwise invisible: the scan just never matches.
        #expect(BLEUUID.canonical("") == nil)
        #expect(BLEUUID.canonical("ffez") == nil)
        #expect(BLEUUID.canonical("ffe") == nil)
        #expect(BLEUUID.canonical("0000ffe1-0000-1000-8000") == nil)
        #expect(BLEUUID.canonical("0000ffe1-0000-1000-8000-00805f9b34fbff") == nil)
        // Right length, wrong grouping.
        #expect(BLEUUID.canonical("0000ffe1-00001-000-8000-00805f9b34fb") == nil)
        #expect(throws: BLEError.self) { try BLEUUID.require("nope") }
    }
}
