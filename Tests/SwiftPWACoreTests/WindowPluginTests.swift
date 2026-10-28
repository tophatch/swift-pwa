import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

@Suite("WindowPlugin")
@MainActor
struct WindowPluginTests {
    private func makeApp() async -> (MockAppContext, MockWindow) {
        let app = MockAppContext()
        app.use(WindowPlugin())
        let win = try! app.createWindow(WindowConfig(
            title: "T",
            size: Size(width: 200, height: 100),
            content: .remote(URL(string: "about:blank")!)
        )) as! MockWindow
        return (app, win)
    }

    @Test("window.setTitle mutates the resolved window")
    func setTitle() async throws {
        let (app, win) = await makeApp()
        let payload = try JSONEncoder().encode(SetTitleArgs(id: nil, title: "renamed"))
        let inv = Invocation(id: 1, command: "window.setTitle", payload: payload)
        let ctx = CommandContext(invocation: inv, caller: .page(win.id), appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case .ok = result else { Issue.record("expected ok"); return }
        await MainActor.run {
            #expect(win.title() == "renamed")
            #expect(win.receivedActions == [.setTitle("renamed")])
        }
    }

    @Test("window.setSize records both setSize action and didResize event")
    func setSize() async throws {
        let (app, win) = await makeApp()
        let payload = try JSONEncoder().encode(SetSizeArgs(
            id: nil, width: 1024, height: 768, animated: false
        ))
        let inv = Invocation(id: 1, command: "window.setSize", payload: payload)
        let ctx = CommandContext(invocation: inv, caller: .page(win.id), appContext: app)
        _ = await app.registry.dispatch(ctx)
        await MainActor.run {
            #expect(win.size() == Size(width: 1024, height: 768))
        }
    }

    // MARK: - window.snapshot (#255)

    /// Just enough PNG for ``PNGDimensions`` — signature, chunk length, `IHDR`
    /// tag and the two big-endian dimensions. The plugin reads the header and
    /// base64s the rest without decoding, so a real image would only make the
    /// test slower.
    private func pngHeader(width: UInt32, height: UInt32, trailing: Int = 0) -> Data {
        var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        data.append(contentsOf: Array("IHDR".utf8))
        data.append(contentsOf: withUnsafeBytes(of: width.bigEndian, Array.init))
        data.append(contentsOf: withUnsafeBytes(of: height.bigEndian, Array.init))
        data.append(Data(repeating: 0, count: trailing))
        return data
    }

    private func dispatch(
        _ command: String, on app: MockAppContext, from win: MockWindow, payload: String = "{}"
    ) async -> InvocationResult {
        let inv = Invocation(id: 1, command: command, payload: Data(payload.utf8))
        return await app.registry.dispatch(
            CommandContext(invocation: inv, caller: .page(win.id), appContext: app)
        )
    }

    @Test("window.snapshot hands back the pixels, with the size the page needs")
    func snapshot() async throws {
        let (app, win) = await makeApp()
        let png = pngHeader(width: 1600, height: 1000, trailing: 32)
        (win.webView as! MockWebView).stubbedSnapshot = png

        let result = await dispatch("window.snapshot", on: app, from: win)
        guard case let .ok(data) = result else { Issue.record("expected ok, got \(result)"); return }
        let shot = try JSONDecoder().decode(WindowSnapshot.self, from: data)
        // Device pixels, not the window's CSS size: the whole point is that a
        // page can size a canvas without guessing at devicePixelRatio.
        #expect(shot.width == 1600)
        #expect(shot.height == 1000)
        #expect(shot.bytes == png.count)
        #expect(Data(base64Encoded: shot.pngBase64) == png)
    }

    @Test("a whole-window snapshot asks the backend for no region and doesn't read the viewport")
    func snapshotWholeWindow() async throws {
        let (app, win) = await makeApp()
        let webView = try #require(win.webView as? MockWebView)
        webView.stubbedSnapshot = pngHeader(width: 4, height: 4)
        _ = await dispatch("window.snapshot", on: app, from: win)
        #expect(webView.snapshotRegions == [nil])
        #expect(webView.evaluatedScripts.isEmpty)
    }

    /// The backend gets a region it can crop to without deciding anything:
    /// inside the viewport and on whole CSS pixels, so the picture is
    /// `width * devicePixelRatio` wide on every engine.
    @Test("rect reaches the backend clipped to the viewport, on whole pixels")
    func snapshotRect() async throws {
        let (app, win) = await makeApp()
        let webView = try #require(win.webView as? MockWebView)
        webView.stubbedSnapshot = pngHeader(width: 4, height: 4)
        webView.evaluationResults = ["[800,600]", "[800,600]"]

        _ = await dispatch(
            "window.snapshot",
            on: app,
            from: win,
            payload: #"{"rect":{"x":10.4,"y":20.6,"width":100.2,"height":50}}"#
        )
        // Off the right and bottom edges, and before the origin.
        _ = await dispatch(
            "window.snapshot",
            on: app,
            from: win,
            payload: #"{"rect":{"x":-20,"y":550,"width":900,"height":100}}"#
        )
        let viewport = Size(width: 800, height: 600)
        #expect(webView.snapshotRegions == [
            SnapshotRegion(rect: Rect(x: 10, y: 20, width: 101, height: 51), viewport: viewport),
            SnapshotRegion(rect: Rect(x: 0, y: 550, width: 800, height: 50), viewport: viewport)
        ])
    }

    /// How a backend places the region: as a share of its own viewport, so a
    /// page zoomed out to fit wide content (Android does that) still crops
    /// where the page meant.
    @Test("a region scales into a viewport measured in another unit")
    func snapshotRegionScales() {
        let region = SnapshotRegion(
            rect: Rect(x: 100, y: 50, width: 200, height: 100),
            viewport: Size(width: 800, height: 400)
        )
        #expect(region.scaled(toWidth: 1600, height: 800) == Rect(x: 200, y: 100, width: 400, height: 200))
    }

    @Test("a rect outside the viewport, or with no area, fails as a bad argument")
    func snapshotRectRefused() async throws {
        let (app, win) = await makeApp()
        let webView = try #require(win.webView as? MockWebView)
        webView.stubbedSnapshot = pngHeader(width: 4, height: 4)
        webView.evaluationResults = ["[800,600]"]

        for payload in [
            #"{"rect":{"x":900,"y":0,"width":50,"height":50}}"#,
            #"{"rect":{"x":0,"y":0,"width":0,"height":50}}"#,
            #"{"rect":{"x":0,"y":0,"width":-5,"height":50}}"#
        ] {
            let result = await dispatch("window.snapshot", on: app, from: win, payload: payload)
            guard case let .failure(err) = result else { Issue.record("expected failure for \(payload)"); continue }
            #expect(err.code == BridgeError.decode)
        }
        #expect(webView.snapshotRegions.isEmpty)
    }

    /// A backend with no snapshot has to say so as a clean error, not as a
    /// broken image — an app is meant to ask `window.canSnapshot` first and
    /// offer the feature or not.
    @Test("a backend that can't snapshot reports E_UNIMPLEMENTED")
    func snapshotUnsupported() async {
        let (app, win) = await makeApp()
        let result = await dispatch("window.snapshot", on: app, from: win)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.unimplemented)
    }

    /// Reading a size out of bytes that aren't a PNG would hand the page two
    /// plausible numbers and a canvas full of nothing.
    @Test("bytes that aren't a PNG fail rather than reporting a made-up size")
    func snapshotNotAPNG() async {
        let (app, win) = await makeApp()
        (win.webView as! MockWebView).stubbedSnapshot = Data("GIF89a not a png at all!!".utf8)
        let result = await dispatch("window.snapshot", on: app, from: win)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.handler)
    }

    @Test("window.canSnapshot answers before anything is rendered")
    func canSnapshot() async throws {
        let (app, win) = await makeApp()
        var result = await dispatch("window.canSnapshot", on: app, from: win)
        guard case let .ok(before) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(BoolResult.self, from: before).value == false)

        (win.webView as! MockWebView).stubbedSnapshot = pngHeader(width: 2, height: 2)
        result = await dispatch("window.canSnapshot", on: app, from: win)
        guard case let .ok(after) = result else { Issue.record("expected ok"); return }
        #expect(try JSONDecoder().decode(BoolResult.self, from: after).value == true)
    }

    @Test("window.id without origin returns notFound")
    func windowIDNoOrigin() async {
        let (app, _) = await makeApp()
        let inv = Invocation(id: 1, command: "window.id", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, caller: .agent, appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .failure(err) = result else { Issue.record("expected failure"); return }
        #expect(err.code == BridgeError.notFound)
    }

    @Test("window.subscribe streams events emitted by the window")
    func subscribe() async throws {
        let (app, win) = await makeApp()
        let inv = Invocation(id: 1, command: "window.subscribe", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, caller: .page(win.id), appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .stream(stream) = result else { Issue.record("expected stream"); return }

        var iterator = stream.makeAsyncIterator()
        await MainActor.run { win.emit(.didFocus) }
        let chunk = try await iterator.next()
        let event = try JSONDecoder().decode(WindowEvent.self, from: #require(chunk))
        #expect(event == .didFocus)

        await MainActor.run { win.emit(.didBlur) }
        let chunk2 = try await iterator.next()
        let event2 = try JSONDecoder().decode(WindowEvent.self, from: #require(chunk2))
        #expect(event2 == .didBlur)
    }

    @Test("window.list returns all live window ids")
    func list() async throws {
        let (app, win) = await makeApp()
        let win2 = try app.createWindow(WindowConfig(
            title: "T2",
            size: Size(width: 100, height: 100),
            content: .remote(#require(URL(string: "about:blank")))
        ))
        let inv = Invocation(id: 1, command: "window.list", payload: Data("{}".utf8))
        let ctx = CommandContext(invocation: inv, caller: .page(win.id), appContext: app)
        let result = await app.registry.dispatch(ctx)
        guard case let .ok(data) = result else { Issue.record("expected ok"); return }
        let out = try JSONDecoder().decode(WindowListResult.self, from: data)
        #expect(Set(out.ids) == [win.id.raw, win2.id.raw])
    }
}
