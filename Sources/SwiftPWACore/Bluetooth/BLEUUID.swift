import Foundation

/// One spelling of a Bluetooth UUID, so the same peripheral doesn't look
/// different on each platform.
///
/// Bluetooth allows 16-bit, 32-bit and 128-bit UUIDs, and every backend picks
/// its own favourite when handing one back: CoreBluetooth returns `"FFE1"` for
/// an assigned 16-bit UUID and an upper-case 128-bit string otherwise, BlueZ
/// and Android always return lower-case 128-bit, WinRT returns a `GUID`. A page
/// written against one of those (`if (event.characteristic === 'ffe1')`) breaks
/// silently on the other three — a mismatch, not an error, so nothing is
/// reported and notifications just never seem to arrive.
///
/// So the wire form is always the **full 128-bit, lower-case** string, on the
/// way out *and* on the way in. Short forms are still accepted as input,
/// because they're how the assigned-numbers documents write them and demanding
/// the long form would be pedantry.
public enum BLEUUID {
    /// The Bluetooth Base UUID that 16- and 32-bit values expand against.
    /// `0000FFE1-0000-1000-8000-00805F9B34FB` *is* `FFE1`, and treating them as
    /// different strings is the whole bug this type exists to prevent.
    private static let baseSuffix = "-0000-1000-8000-00805f9b34fb"

    /// The canonical form of `value`, or nil if it isn't a UUID at all.
    ///
    /// Accepts `ffe1`, `0000ffe1`, `0000ffe1-0000-1000-8000-00805f9b34fb` and
    /// any of them upper-case or wrapped in braces (the shape Windows prints).
    public static func canonical(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "{} \t\n"))
            .lowercased()
        switch trimmed.count {
        case 4, 8:
            guard trimmed.allSatisfy(\.isHexDigit) else { return nil }
            return String(repeating: "0", count: 8 - trimmed.count) + trimmed + baseSuffix
        case 36:
            let groups = trimmed.split(separator: "-", omittingEmptySubsequences: false)
            guard groups.count == 5,
                  groups.map(\.count) == [8, 4, 4, 4, 12],
                  groups.allSatisfy({ $0.allSatisfy(\.isHexDigit) })
            else { return nil }
            return trimmed
        case 32:
            // Un-hyphenated 128-bit, which is how some tools print them.
            guard trimmed.allSatisfy(\.isHexDigit) else { return nil }
            let hex = Array(trimmed)
            let groups = [hex[0 ..< 8], hex[8 ..< 12], hex[12 ..< 16], hex[16 ..< 20], hex[20 ..< 32]]
            return groups.map { String($0) }.joined(separator: "-")
        default:
            return nil
        }
    }

    /// Canonicalize, or fail with a message naming the value — a UUID typo is
    /// otherwise invisible: the scan simply matches nothing.
    public static func require(_ value: String) throws -> String {
        guard let canonical = canonical(value) else {
            throw BLEError.invalidArgument("'\(value)' isn't a Bluetooth UUID (expected 'ffe1' or a full 128-bit UUID)")
        }
        return canonical
    }

    /// The 16-bit short form when `value` is an assigned UUID, else nil.
    ///
    /// For display only. The wire never carries this, because a page that saw
    /// `ffe1` from one peripheral and a 128-bit string from a custom one would
    /// have to handle both.
    public static func shortForm(_ value: String) -> String? {
        guard let canonical = canonical(value), canonical.hasSuffix(baseSuffix) else { return nil }
        let leading = canonical.prefix(8)
        guard leading.hasPrefix("0000") else { return nil }
        return String(leading.dropFirst(4))
    }
}
