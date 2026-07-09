import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("WindowStateStore")
@MainActor
struct WindowStateStoreTests {
    /// A fresh store rooted at a unique temp directory, plus that directory.
    private func makeStore() -> (WindowStateStore, URL) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swift-pwa-wss-\(UUID().uuidString)", isDirectory: true)
        return (WindowStateStore(directory: dir), dir)
    }

    private func config(
        rememberState: Bool,
        stateKey: String = "main",
        size: Size = Size(width: 800, height: 600)
    ) -> WindowConfig {
        WindowConfig(
            title: "T",
            size: size,
            content: .remote(URL(string: "about:blank")!),
            rememberState: rememberState,
            stateKey: stateKey
        )
    }

    @Test("restore is a no-op when rememberState is off")
    func restoreOff() {
        let (store, _) = makeStore()
        store.recordSize(Size(width: 1200, height: 900), for: "main")
        let restored = store.restore(config(rememberState: false))
        #expect(restored.size == Size(width: 800, height: 600))
        #expect(restored.origin == nil)
    }

    @Test("restore is a no-op when nothing has been stored")
    func restoreEmpty() {
        let (store, _) = makeStore()
        let restored = store.restore(config(rememberState: true))
        #expect(restored.size == Size(width: 800, height: 600))
        #expect(restored.origin == nil)
    }

    @Test("restore applies stored size and position")
    func restoreSizeAndPosition() {
        let (store, _) = makeStore()
        store.recordSize(Size(width: 1280, height: 720), for: "main")
        store.recordPosition(Point(x: 42, y: 17), for: "main")
        let restored = store.restore(config(rememberState: true))
        #expect(restored.size == Size(width: 1280, height: 720))
        #expect(restored.origin == Point(x: 42, y: 17))
    }

    @Test("recordSize ignores non-positive dimensions")
    func ignoresZeroSize() {
        let (store, _) = makeStore()
        store.recordSize(.zero, for: "main")
        #expect(store.state(for: "main") == nil)
    }

    @Test("recordPosition without a prior size is dropped")
    func positionWithoutSizeDropped() {
        let (store, _) = makeStore()
        store.recordPosition(Point(x: 10, y: 10), for: "main")
        #expect(store.state(for: "main") == nil)
    }

    @Test("state is keyed independently per window")
    func perKey() {
        let (store, _) = makeStore()
        store.recordSize(Size(width: 100, height: 100), for: "a")
        store.recordSize(Size(width: 200, height: 200), for: "b")
        #expect(store.state(for: "a")?.width == 100)
        #expect(store.state(for: "b")?.width == 200)
    }

    @Test("flushed state round-trips through a new store on disk")
    func persistsToDisk() {
        let (store, dir) = makeStore()
        store.recordSize(Size(width: 1024, height: 768), for: "main")
        store.recordPosition(Point(x: 5, y: 6), for: "main")
        store.flushNow()

        let reopened = WindowStateStore(directory: dir)
        let restored = reopened.restore(config(rememberState: true))
        #expect(restored.size == Size(width: 1024, height: 768))
        #expect(restored.origin == Point(x: 5, y: 6))
    }

    @Test("track seeds size and records window resize/move events")
    func trackRecordsEvents() async {
        let (store, dir) = makeStore()
        let win = MockWindow(size: Size(width: 640, height: 480))
        store.track(win, config: config(rememberState: true, size: Size(width: 640, height: 480)))
        // Seeded synchronously.
        #expect(store.state(for: "main")?.width == 640)

        win.emit(.didResize(Size(width: 1000, height: 700)))
        win.emit(.didMove(Point(x: 30, y: 40)))
        // The event-stream consumer runs on the cooperative pool, so poll until
        // it has folded in the last-emitted event rather than assuming a fixed
        // delay — a fixed sleep raced the consumer under CI load and flushed
        // before `.didMove` landed (x/y still nil). Waiting for y == 40 implies
        // the earlier `.didResize` was processed too (the stream is in-order).
        for _ in 0 ..< 200 where store.state(for: "main")?.y != 40 {
            try? await Task.sleep(nanoseconds: 10_000_000) // up to ~2s
        }

        store.flushNow()
        let reopened = WindowStateStore(directory: dir)
        #expect(reopened.state(for: "main")?.width == 1000)
        #expect(reopened.state(for: "main")?.height == 700)
        #expect(reopened.state(for: "main")?.x == 30)
        #expect(reopened.state(for: "main")?.y == 40)
    }

    @Test("track is a no-op when rememberState is off")
    func trackOff() async {
        let (store, _) = makeStore()
        let win = MockWindow(size: Size(width: 640, height: 480))
        store.track(win, config: config(rememberState: false))
        win.emit(.didResize(Size(width: 1000, height: 700)))
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.state(for: "main") == nil)
    }
}
