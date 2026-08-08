#if SWIFT_PWA_DRIVER

    import _SwiftPWATestSupport
    import Foundation
    @testable import SwiftPWACore
    import Testing

    /// Verb dispatch for the app driver, exercised without binding a port —
    /// `DriverSession` is deliberately socket-free so this can run in the
    /// normal unit suite on every platform.
    @Suite("App driver session")
    struct AppDriverTests {
        private let token = "test-token"

        @MainActor
        private func makeSession(
            windows: [MockWindow] = [],
            backend: String = "macos"
        ) -> (DriverSession, MockAppContext) {
            let context = MockAppContext()
            for window in windows { context.attach(window) }
            return (DriverSession(context: context, token: token, backend: backend), context)
        }

        private func send(
            _ session: DriverSession,
            cmd: String,
            payload: [String: JSONValue]? = nil,
            token: String? = "test-token"
        ) async throws -> JSONValue {
            var frame: [String: JSONValue] = ["id": .number(1), "cmd": .string(cmd)]
            if let token { frame["token"] = .string(token) }
            if let payload { frame["payload"] = .object(payload) }
            let line = try JSONValue.object(frame).encoded()
            return try await JSONValue.decode(session.handle(line: line))
        }

        // MARK: - Gating

        @Test("a frame without the launch token is refused")
        @MainActor
        func rejectsMissingToken() async throws {
            let (session, _) = makeSession(windows: [MockWindow()])
            let response = try await send(session, cmd: "capabilities", token: nil)
            #expect(response["ok"] == .bool(false))
            #expect(response["error"]?["code"] == .string("E_DRIVER_AUTH"))
        }

        @Test("a frame with the wrong token is refused")
        @MainActor
        func rejectsWrongToken() async throws {
            let (session, _) = makeSession(windows: [MockWindow()])
            let response = try await send(session, cmd: "eval", token: "guessed")
            #expect(response["error"]?["code"] == .string("E_DRIVER_AUTH"))
        }

        @Test("a non-JSON line is answered, not dropped")
        @MainActor
        func rejectsGarbage() async throws {
            let (session, _) = makeSession()
            let response = try await JSONValue.decode(session.handle(line: Data("not json".utf8)))
            #expect(response["error"]?["code"] == .string("E_DRIVER_REQUEST"))
        }

        @Test("an unknown verb names itself in the error")
        @MainActor
        func rejectsUnknownCommand() async throws {
            let (session, _) = makeSession()
            let response = try await send(session, cmd: "input.mouse")
            #expect(response["error"]?["code"] == .string("E_DRIVER_COMMAND"))
            if case let .string(message)? = response["error"]?["message"] {
                #expect(message.contains("input.mouse"))
            } else {
                Issue.record("expected a message naming the verb")
            }
        }

        // MARK: - capabilities

        @Test("capabilities reports the backend and its honest verb set")
        @MainActor
        func capabilities() async throws {
            let (session, _) = makeSession(windows: [MockWindow()], backend: "gtk4")
            let result = try await send(session, cmd: "capabilities")["result"]
            #expect(result?["backend"] == .string("gtk4"))
            #expect(result?["protocol"] == .number(1))
            #expect(result?["windows"] == .number(1))
            // Cut 1 ships no native input synthesis anywhere.
            #expect(result?["input"] == .bool(false))
            // MockWebView leaves the protocol default in place, which is the
            // same answer a backend without a snapshot API would give.
            #expect(result?["screenshot"] == .bool(false))
            guard case let .array(verbs)? = result?["verbs"] else {
                Issue.record("expected a verb list")
                return
            }
            #expect(verbs.contains(.string("eval")))
            #expect(verbs.contains(.string("window.setSize")))
        }

        @Test("with no windows open, snapshot support is unknown rather than false")
        @MainActor
        func capabilitiesWithoutWindows() async throws {
            let (session, _) = makeSession()
            let result = try await send(session, cmd: "capabilities")["result"]
            #expect(result?["windows"] == .number(0))
            #expect(result?["screenshot"] == .null)
        }

        // MARK: - window.list

        @Test("window.list reports geometry and is ordered stably")
        @MainActor
        func windowList() async throws {
            let first = MockWindow(id: WindowID(raw: "aaa"), title: "First")
            let second = MockWindow(
                id: WindowID(raw: "bbb"),
                title: "Second",
                size: Size(width: 640, height: 480),
                position: Point(x: 12, y: 34)
            )
            let (session, _) = makeSession(windows: [second, first])

            let result = try await send(session, cmd: "window.list")["result"]
            guard case let .array(entries)? = result, entries.count == 2 else {
                Issue.record("expected two windows")
                return
            }
            // Sorted by id, not by insertion order.
            #expect(entries[0]["id"] == .string("aaa"))
            #expect(entries[1]["title"] == .string("Second"))
            #expect(entries[1]["size"]?["width"] == .number(640))
            #expect(entries[1]["position"]?["y"] == .number(34))
        }

        // MARK: - eval

        @Test("eval runs the snippet in the page and parses the JSON result")
        @MainActor
        func evalParsesResult() async throws {
            let webView = MockWebView()
            webView.evaluationResults = [#"{"title":"CritterFacts"}"#]
            let window = MockWindow(webView: webView)
            let (session, _) = makeSession(windows: [window])

            let response = try await send(
                session, cmd: "eval", payload: ["js": .string("document.title")]
            )
            #expect(response["ok"] == .bool(true))
            #expect(response["result"]?["title"] == .string("CritterFacts"))
            #expect(webView.evaluatedScripts == ["document.title"])
        }

        @Test("a result that isn't JSON comes back as a string rather than failing")
        @MainActor
        func evalToleratesNonJSON() async throws {
            let webView = MockWebView()
            webView.evaluationResults = ["a bare string"]
            let (session, _) = makeSession(windows: [MockWindow(webView: webView)])

            let response = try await send(
                session, cmd: "eval", payload: ["js": .string("x")]
            )
            #expect(response["result"] == .string("a bare string"))
        }

        @Test("eval without a `js` string is rejected before touching a window")
        @MainActor
        func evalNeedsScript() async throws {
            let (session, _) = makeSession(windows: [MockWindow()])
            let response = try await send(session, cmd: "eval", payload: ["js": .string("")])
            #expect(response["error"]?["code"] == .string("E_DRIVER_REQUEST"))
        }

        // MARK: - window resolution

        @Test("a verb with no windows open says so")
        @MainActor
        func noWindows() async throws {
            let (session, _) = makeSession()
            let response = try await send(session, cmd: "eval", payload: ["js": .string("1")])
            #expect(response["error"]?["code"] == .string("E_DRIVER_WINDOW"))
        }

        @Test("two open windows is an error, not a guess")
        @MainActor
        func ambiguousWindow() async throws {
            let (session, _) = makeSession(windows: [MockWindow(), MockWindow()])
            let response = try await send(session, cmd: "eval", payload: ["js": .string("1")])
            #expect(response["error"]?["code"] == .string("E_DRIVER_WINDOW"))
        }

        @Test("naming a window disambiguates")
        @MainActor
        func namedWindow() async throws {
            let webView = MockWebView()
            webView.evaluationResults = ["42"]
            let target = MockWindow(id: WindowID(raw: "target"), webView: webView)
            let (session, _) = makeSession(windows: [MockWindow(id: WindowID(raw: "other")), target])

            let response = try await send(
                session,
                cmd: "eval",
                payload: ["js": .string("1"), "window": .string("target")]
            )
            #expect(response["result"] == .number(42))
        }

        @Test("an unknown window id is refused")
        @MainActor
        func unknownWindow() async throws {
            let (session, _) = makeSession(windows: [MockWindow()])
            let response = try await send(
                session,
                cmd: "eval",
                payload: ["js": .string("1"), "window": .string("nope")]
            )
            #expect(response["error"]?["code"] == .string("E_DRIVER_WINDOW"))
        }

        // MARK: - screenshot

        @Test("screenshot is refused where the backend can't snapshot")
        @MainActor
        func screenshotUnsupported() async throws {
            let (session, _) = makeSession(windows: [MockWindow()], backend: "gtk4")
            let response = try await send(session, cmd: "screenshot")
            #expect(response["error"]?["code"] == .string("E_DRIVER_UNSUPPORTED"))
        }

        // MARK: - geometry

        @Test("window.setSize applies and reports the size the window actually took")
        @MainActor
        func setSize() async throws {
            let window = MockWindow()
            let (session, _) = makeSession(windows: [window])

            let response = try await send(
                session,
                cmd: "window.setSize",
                payload: ["width": .number(1024), "height": .number(768)]
            )
            #expect(response["result"]?["width"] == .number(1024))
            #expect(window.currentSize == Size(width: 1024, height: 768))
            #expect(window.receivedActions.contains(.setSize(Size(width: 1024, height: 768), animated: false)))
        }

        @Test("window.setPosition reads back rather than echoing the request")
        @MainActor
        func setPosition() async throws {
            let window = MockWindow()
            let (session, _) = makeSession(windows: [window])

            let response = try await send(
                session,
                cmd: "window.setPosition",
                payload: ["x": .number(40), "y": .number(50)]
            )
            #expect(response["result"]?["x"] == .number(40))
            #expect(window.currentPosition == Point(x: 40, y: 50))
        }

        @Test("window.setSize without numeric dimensions is rejected")
        @MainActor
        func setSizeNeedsNumbers() async throws {
            let (session, _) = makeSession(windows: [MockWindow()])
            let response = try await send(
                session,
                cmd: "window.setSize",
                payload: ["width": .string("wide"), "height": .number(768)]
            )
            #expect(response["error"]?["code"] == .string("E_DRIVER_REQUEST"))
        }
    }

#endif
