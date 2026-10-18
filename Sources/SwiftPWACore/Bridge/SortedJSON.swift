import Foundation

/// A handler's bytes were not one well-formed JSON value, so they were not put
/// on the wire.
public enum SortedJSONError: Error, Equatable, Sendable, CustomStringConvertible {
    /// Not JSON, or a string that isn't UTF-8. `offset` is the byte where
    /// reading stopped.
    case malformed(offset: Int)
    /// Nested deeper than ``SortedJSON/maxDepth``.
    case tooDeep

    public var description: String {
        switch self {
        case let .malformed(offset): "payload is not well-formed JSON (stopped at byte \(offset))"
        case .tooDeep: "payload nests deeper than \(SortedJSON.maxDepth) levels"
        }
    }
}

/// Copies one JSON value with every object's keys in byte order and no
/// whitespace between tokens, checking that it is well-formed on the way.
///
/// This is what pins key order on the wire (see `Envelope.encode`). It works on
/// the bytes rather than parsing into `Any` and writing them out again with
/// `JSONSerialization`, because off Apple that round trip is what a large reply
/// cost: on swift-corelibs-foundation a 14 MB reply took 7.8 s to re-serialize,
/// most of it sorting keys through `NSString` comparison, against 57 ms here.
///
/// Keys sort by their bytes as written, which for unescaped keys is Unicode
/// code-point order and matches `JSONEncoder`'s `.sortedKeys`. Strings and
/// numbers are copied as written, not normalized: this pins the order the
/// fields arrive in, not every spelling of a value.
enum SortedJSON {
    /// Deeper nesting is refused rather than risking the thread's stack, which
    /// on Android is a fraction of a desktop thread's.
    static let maxDepth = 512

    /// Appends the sorted copy of `data` to `out`. On a throw, `out` ends in a
    /// partial copy and should be discarded.
    static func append(_ data: Data, to out: inout [UInt8]) throws {
        try data.withUnsafeBytes { raw in
            var writer = Writer(input: raw.bindMemory(to: UInt8.self))
            // Handed over rather than copied, so appending never duplicates
            // what is already in `out`.
            swap(&writer.out, &out)
            defer { swap(&writer.out, &out) }
            writer.out.reserveCapacity(writer.out.count + writer.input.count)
            writer.skipWhitespace()
            try writer.value(depth: 0)
            writer.skipWhitespace()
            guard writer.pos == writer.input.count else { throw writer.malformed() }
        }
    }

    private struct Member {
        let keyStart: Int
        let keyEnd: Int
        let outStart: Int
        let outEnd: Int
    }

    private struct Writer {
        let input: UnsafeBufferPointer<UInt8>
        var pos = 0
        var out: [UInt8] = []

        init(input: UnsafeBufferPointer<UInt8>) {
            self.input = input
        }

        func malformed() -> SortedJSONError {
            .malformed(offset: pos)
        }

        mutating func skipWhitespace() {
            while pos < input.count {
                switch input[pos] {
                case 0x20, 0x09, 0x0A, 0x0D: pos += 1
                default: return
                }
            }
        }

        mutating func value(depth: Int) throws {
            guard pos < input.count else { throw malformed() }
            switch input[pos] {
            case UInt8(ascii: "{"): try object(depth: depth + 1)
            case UInt8(ascii: "["): try array(depth: depth + 1)
            case UInt8(ascii: "\""): try string()
            case UInt8(ascii: "t"): try literal("true")
            case UInt8(ascii: "f"): try literal("false")
            case UInt8(ascii: "n"): try literal("null")
            default: try number()
            }
        }

        mutating func literal(_ word: StaticString) throws {
            let count = word.utf8CodeUnitCount
            guard pos + count <= input.count else { throw malformed() }
            for i in 0 ..< count where input[pos + i] != word.utf8Start[i] {
                throw malformed()
            }
            out.append(contentsOf: UnsafeBufferPointer(start: word.utf8Start, count: count))
            pos += count
        }

        mutating func number() throws {
            let start = pos
            if pos < input.count, input[pos] == UInt8(ascii: "-") { pos += 1 }
            guard pos < input.count else { throw malformed() }
            if input[pos] == UInt8(ascii: "0") {
                pos += 1
            } else {
                guard digits() > 0 else { throw malformed() }
            }
            if pos < input.count, input[pos] == UInt8(ascii: ".") {
                pos += 1
                guard digits() > 0 else { throw malformed() }
            }
            if pos < input.count, input[pos] | 0x20 == UInt8(ascii: "e") {
                pos += 1
                if pos < input.count, input[pos] == UInt8(ascii: "+") || input[pos] == UInt8(ascii: "-") {
                    pos += 1
                }
                guard digits() > 0 else { throw malformed() }
            }
            out.append(contentsOf: UnsafeBufferPointer(rebasing: input[start ..< pos]))
        }

        mutating func digits() -> Int {
            let start = pos
            while pos < input.count, input[pos] >= UInt8(ascii: "0"), input[pos] <= UInt8(ascii: "9") {
                pos += 1
            }
            return pos - start
        }

        /// Copies a string as written, escapes included, after checking them.
        mutating func string() throws {
            let start = pos
            var nonASCII = false
            pos += 1
            while true {
                guard pos < input.count else { throw malformed() }
                let byte = input[pos]
                if byte == UInt8(ascii: "\"") { break }
                if byte < 0x20 { throw malformed() }
                if byte >= 0x80 { nonASCII = true }
                if byte == UInt8(ascii: "\\") {
                    pos += 1
                    guard pos < input.count else { throw malformed() }
                    switch input[pos] {
                    case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                         UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                        break
                    case UInt8(ascii: "u"):
                        guard pos + 4 < input.count else { throw malformed() }
                        for i in 1 ... 4 where !isHexDigit(input[pos + i]) {
                            throw malformed()
                        }
                        pos += 4
                    default:
                        throw malformed()
                    }
                }
                pos += 1
            }
            let contents = UnsafeBufferPointer(rebasing: input[(start + 1) ..< pos])
            if nonASCII, String(validating: contents, as: UTF8.self) == nil {
                throw SortedJSONError.malformed(offset: start)
            }
            pos += 1
            out.append(contentsOf: UnsafeBufferPointer(rebasing: input[start ..< pos]))
        }

        mutating func array(depth: Int) throws {
            guard depth <= SortedJSON.maxDepth else { throw SortedJSONError.tooDeep }
            out.append(UInt8(ascii: "["))
            pos += 1
            skipWhitespace()
            if pos < input.count, input[pos] == UInt8(ascii: "]") {
                pos += 1
                out.append(UInt8(ascii: "]"))
                return
            }
            while true {
                try value(depth: depth)
                skipWhitespace()
                guard pos < input.count else { throw malformed() }
                if input[pos] == UInt8(ascii: "]") {
                    pos += 1
                    out.append(UInt8(ascii: "]"))
                    return
                }
                guard input[pos] == UInt8(ascii: ",") else { throw malformed() }
                pos += 1
                out.append(UInt8(ascii: ","))
                skipWhitespace()
            }
        }

        /// Writes the members in the order they arrive, then rewrites them
        /// sorted only if they weren't already, since most producers already
        /// sort and that copy is then never made.
        mutating func object(depth: Int) throws {
            guard depth <= SortedJSON.maxDepth else { throw SortedJSONError.tooDeep }
            out.append(UInt8(ascii: "{"))
            pos += 1
            skipWhitespace()
            if pos < input.count, input[pos] == UInt8(ascii: "}") {
                pos += 1
                out.append(UInt8(ascii: "}"))
                return
            }
            let bodyStart = out.count
            var members: [Member] = []
            var inOrder = true
            while true {
                guard pos < input.count, input[pos] == UInt8(ascii: "\"") else { throw malformed() }
                let keyStart = pos + 1
                let outStart = out.count
                try string()
                let keyEnd = pos - 1
                skipWhitespace()
                guard pos < input.count, input[pos] == UInt8(ascii: ":") else { throw malformed() }
                pos += 1
                out.append(UInt8(ascii: ":"))
                skipWhitespace()
                try value(depth: depth)
                let member = Member(keyStart: keyStart, keyEnd: keyEnd, outStart: outStart, outEnd: out.count)
                if inOrder, let last = members.last, precedes(member, last) { inOrder = false }
                members.append(member)
                skipWhitespace()
                guard pos < input.count else { throw malformed() }
                if input[pos] == UInt8(ascii: "}") {
                    pos += 1
                    break
                }
                guard input[pos] == UInt8(ascii: ",") else { throw malformed() }
                pos += 1
                out.append(UInt8(ascii: ","))
                skipWhitespace()
            }
            if !inOrder {
                let written = Array(out[bodyStart...])
                out.removeSubrange(bodyStart...)
                // Stable, so a repeated key keeps the order it was written in.
                let sorted = members.enumerated().sorted { a, b in
                    precedes(a.element, b.element) || (!precedes(b.element, a.element) && a.offset < b.offset)
                }
                for (index, entry) in sorted.enumerated() {
                    if index > 0 { out.append(UInt8(ascii: ",")) }
                    let member = entry.element
                    out.append(contentsOf: written[(member.outStart - bodyStart) ..< (member.outEnd - bodyStart)])
                }
            }
            out.append(UInt8(ascii: "}"))
        }

        func precedes(_ a: Member, _ b: Member) -> Bool {
            UnsafeBufferPointer(rebasing: input[a.keyStart ..< a.keyEnd])
                .lexicographicallyPrecedes(UnsafeBufferPointer(rebasing: input[b.keyStart ..< b.keyEnd]))
        }

        func isHexDigit(_ byte: UInt8) -> Bool {
            (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
                || (byte | 0x20 >= UInt8(ascii: "a") && byte | 0x20 <= UInt8(ascii: "f"))
        }
    }
}
