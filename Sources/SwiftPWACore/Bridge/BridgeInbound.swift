import Foundation

/// The client→server half of a duplex bridge session (`registerSession`).
///
/// An `AsyncSequence` of typed `Frame`s decoded from the raw JSON payloads a
/// client pushes into an open session via `__SWIFT_PWA__.session(...).push(...)`.
/// A session handler iterates it (`for await frame in inbound`) to receive
/// client frames while yielding its own downstream events.
///
/// - **Decode leniency:** a payload that fails to decode to `Frame` is skipped
///   (and logged once to stderr), matching the typed-args contract — a
///   malformed push doesn't tear down the whole session. Decode skips are *not*
///   counted as drops (see `droppedCount`).
/// - **Bounding:** the underlying stream is bounded by `BridgeRuntime` to
///   `registerSession(maxBufferedFrames:)` (drop-oldest); `postMessage` can't be
///   back-pressured, so a client that floods faster than the handler drains
///   loses the oldest buffered frames. Read `droppedCount` to observe how many —
///   a consumer that can't tolerate loss should ack-gate in its own protocol
///   (yield a downstream event the client waits for before pushing again).
public struct BridgeInbound<Frame: Decodable & Sendable>: AsyncSequence, Sendable {
    public typealias Element = Frame

    private let raw: AsyncStream<Data>
    private let commandName: String
    private let dropCount: @Sendable () -> Int

    init(_ raw: AsyncStream<Data>, command: String, droppedCount: @escaping @Sendable () -> Int) {
        self.raw = raw
        commandName = command
        dropCount = droppedCount
    }

    /// Number of client frames dropped so far because the bounded buffer was
    /// full (drop-oldest). Increases as the client outpaces the handler; safe
    /// to read at any point while consuming.
    public var droppedCount: Int {
        dropCount()
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(base: raw.makeAsyncIterator(), command: commandName)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        var base: AsyncStream<Data>.Iterator
        let command: String

        public mutating func next() async -> Frame? {
            while let data = await base.next() {
                do {
                    return try JSONDecoder().decode(Frame.self, from: data)
                } catch {
                    FileHandle.standardError.write(Data(
                        "[swift-pwa bridge] dropping malformed push frame for \"\(command)\": \(error)\n".utf8
                    ))
                    continue
                }
            }
            return nil
        }
    }
}
