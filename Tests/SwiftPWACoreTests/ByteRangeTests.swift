@testable import SwiftPWACore
import Testing

@Suite("ByteRange (HTTP Range parsing)")
struct ByteRangeTests {
    @Test("no header serves the full resource")
    func noHeader() {
        #expect(ByteRange.resolve(header: nil, fileSize: 1000) == .full)
    }

    @Test("a non-bytes unit serves full")
    func nonBytesUnit() {
        #expect(ByteRange.resolve(header: "items=0-10", fileSize: 1000) == .full)
    }

    @Test("closed range start-end")
    func closedRange() {
        #expect(ByteRange.resolve(header: "bytes=0-99", fileSize: 1000) == .partial(offset: 0, length: 100))
        #expect(ByteRange.resolve(header: "bytes=200-299", fileSize: 1000) == .partial(offset: 200, length: 100))
    }

    @Test("open-ended range start- goes to EOF")
    func openEnded() {
        #expect(ByteRange.resolve(header: "bytes=100-", fileSize: 1000) == .partial(offset: 100, length: 900))
        #expect(ByteRange.resolve(header: "bytes=999-", fileSize: 1000) == .partial(offset: 999, length: 1))
    }

    @Test("suffix range -N is the last N bytes, clamped to size")
    func suffix() {
        #expect(ByteRange.resolve(header: "bytes=-100", fileSize: 1000) == .partial(offset: 900, length: 100))
        #expect(ByteRange.resolve(header: "bytes=-5000", fileSize: 1000) == .partial(offset: 0, length: 1000))
    }

    @Test("end beyond EOF clamps to the last byte")
    func endClamped() {
        #expect(ByteRange.resolve(header: "bytes=0-5000", fileSize: 1000) == .partial(offset: 0, length: 1000))
    }

    @Test("start at or past EOF is unsatisfiable")
    func startPastEOF() {
        #expect(ByteRange.resolve(header: "bytes=1000-", fileSize: 1000) == .unsatisfiable)
        #expect(ByteRange.resolve(header: "bytes=1500-1600", fileSize: 1000) == .unsatisfiable)
    }

    @Test("end before start is unsatisfiable")
    func endBeforeStart() {
        #expect(ByteRange.resolve(header: "bytes=500-499", fileSize: 1000) == .unsatisfiable)
    }

    @Test("multi-range falls back to full (no multipart body)")
    func multiRange() {
        #expect(ByteRange.resolve(header: "bytes=0-99,200-299", fileSize: 1000) == .full)
    }

    @Test("whitespace and case are tolerated")
    func whitespace() {
        #expect(ByteRange.resolve(header: " BYTES=0-9 ", fileSize: 100) == .partial(offset: 0, length: 10))
    }
}
