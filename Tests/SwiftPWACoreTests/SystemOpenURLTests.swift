import _SwiftPWATestSupport
import Foundation
@testable import SwiftPWACore
import Testing

/// Records what it was asked to open, so the tests can assert that a refusal
/// never reaches the OS — the same stance `GeoPluginTests` takes about the
/// hardware.
private final class StubURLOpener: URLOpener, @unchecked Sendable {
    private let lock = NSLock()
    private var _opened: [URL] = []
    private let answer: Bool

    init(answer: Bool = true) {
        self.answer = answer
    }

    var opened: [URL] {
        lock.withLock { _opened }
    }

    func open(_ url: URL) async -> Bool {
        lock.withLock { _opened.append(url) }
        return answer
    }
}

@Suite("system.openURL")
@MainActor
struct SystemOpenURLTests {
    private func makeApp(
        opener: (any URLOpener)?, declare: [String] = []
    ) -> MockAppContext {
        let app = MockAppContext()
        app.externalURLs.declare(schemes: declare)
        app.use(SystemPlugin(DefaultMemoryProvider(), urlOpener: opener))
        return app
    }

    private func openURL(_ app: MockAppContext, _ payload: String) async -> InvocationResult {
        let invocation = Invocation(id: 1, command: "system.openURL", payload: Data(payload.utf8))
        return await app.registry.dispatch(
            CommandContext(invocation: invocation, caller: .agent, appContext: app)
        )
    }

    @Test("an https URL reaches the opener and reports that it opened")
    func opensHTTPS() async throws {
        let opener = StubURLOpener()
        let app = makeApp(opener: opener)
        let result = await openURL(app, #"{"url":"https://example.com/docs"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok, got \(result)"); return }
        #expect(try JSONDecoder().decode(SystemOpenURLResult.self, from: data).opened)
        #expect(opener.opened.map(\.absoluteString) == ["https://example.com/docs"])
    }

    /// `opened: false` is information, not a failure: a page offering a deep
    /// link into an app the user may not have installed needs to be able to
    /// tell, and a thrown error would make that indistinguishable from a
    /// misconfiguration.
    @Test("no registered handler comes back as opened: false rather than an error")
    func noHandlerIsNotAnError() async throws {
        let app = makeApp(opener: StubURLOpener(answer: false), declare: ["things"])
        let result = await openURL(app, #"{"url":"things:///add"}"#)
        guard case let .ok(data) = result else { Issue.record("expected ok, got \(result)"); return }
        #expect(try JSONDecoder().decode(SystemOpenURLResult.self, from: data).opened == false)
    }

    @Test("an undeclared scheme is refused before the OS is asked")
    func undeclaredSchemeRefused() async {
        let opener = StubURLOpener()
        let app = makeApp(opener: opener)
        let result = await openURL(app, #"{"url":"things:///add"}"#)
        guard case let .failure(error) = result else { Issue.record("expected a failure"); return }
        #expect(error.code == BridgeError.urlScheme)
        // The message has to name the fix — the page only sees a code.
        #expect(error.message.contains("external_urls.schemes"))
        #expect(opener.opened.isEmpty)
    }

    @Test("the app's own bundle origin can't be handed to the OS")
    func bundleOriginRefused() async {
        let opener = StubURLOpener()
        let app = makeApp(opener: opener)
        let result = await openURL(app, #"{"url":"pwa://localhost/index.html"}"#)
        guard case let .failure(error) = result else { Issue.record("expected a failure"); return }
        #expect(error.code == BridgeError.url)
        #expect(opener.opened.isEmpty)
    }

    @Test("a string that isn't a URL fails as one, not as a decode error")
    func nonURLRefused() async {
        let app = makeApp(opener: StubURLOpener())
        let result = await openURL(app, #"{"url":"not a url"}"#)
        guard case let .failure(error) = result else { Issue.record("expected a failure"); return }
        #expect(error.code == BridgeError.url)
    }

    /// The command is registered on every backend so a page can feature-detect
    /// on the error code rather than on the platform.
    @Test("a backend with no opener reports E_UNIMPLEMENTED, not silence")
    func withoutOpener() async {
        let app = makeApp(opener: nil)
        let result = await openURL(app, #"{"url":"https://example.com"}"#)
        guard case let .failure(error) = result else { Issue.record("expected a failure"); return }
        #expect(error.code == BridgeError.unimplemented)
    }
}
