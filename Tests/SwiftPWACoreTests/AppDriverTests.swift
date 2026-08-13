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
            // MockWebView leaves the input defaults in place — the same answer
            // a backend with no event synthesis gives.
            #expect(result?["input"]?["pointer"] == .bool(false))
            #expect(result?["input"]?["pointerTypes"] == .array([]))
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

        /// A window the compositor isn't showing has its `requestAnimationFrame`
        /// throttled, so a page that draws in a rAF callback appears to do
        /// nothing and a screenshot captures the stale state cleanly — an adopter
        /// lost an hour to that twice. `window.list` reports it so the CLI can
        /// warn; `unknown` is a real answer on backends with no occlusion query.
        @Test("window.list reports whether each window is actually on screen")
        @MainActor
        func windowListReportsVisibility() async throws {
            let shown = MockWindow(id: WindowID(raw: "aaa"), title: "Shown")
            shown.mockVisibility = .visible
            let covered = MockWindow(id: WindowID(raw: "bbb"), title: "Covered")
            covered.mockVisibility = .hidden
            let unknown = MockWindow(id: WindowID(raw: "ccc"), title: "Unknown")
            let (session, _) = makeSession(windows: [shown, covered, unknown])

            let result = try await send(session, cmd: "window.list")["result"]
            guard case let .array(entries)? = result, entries.count == 3 else {
                Issue.record("expected three windows")
                return
            }
            #expect(entries[0]["visibility"] == .string("visible"))
            #expect(entries[1]["visibility"] == .string("hidden"))
            #expect(entries[2]["visibility"] == .string("unknown"))
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

        // MARK: - Input

        /// A backend that can click but is honest about not being a stylus —
        /// which is every desktop backend that can synthesize input at all.
        private static let mouseOnly = InputCapabilities(
            pointer: true, key: true, wheel: true,
            pointerTypes: [.mouse], pressure: false, tilt: false
        )

        @MainActor
        private func makeInputSession(
            _ capabilities: InputCapabilities
        ) -> (DriverSession, MockWebView) {
            let webView = MockWebView()
            webView.stubbedInputCapabilities = capabilities
            let (session, _) = makeSession(windows: [MockWindow(webView: webView)])
            return (session, webView)
        }

        @Test("capabilities reports input structurally, not as one bool")
        @MainActor
        func inputCapabilitiesShape() async throws {
            let (session, _) = makeInputSession(Self.mouseOnly)
            let input = try await send(session, cmd: "capabilities")["result"]?["input"]
            #expect(input?["pointer"] == .bool(true))
            #expect(input?["tilt"] == .bool(false))
            #expect(input?["pointerTypes"] == .array([.string("mouse")]))
        }

        @Test("a pointer press reaches the backend with its coordinates intact")
        @MainActor
        func pointerPress() async throws {
            let (session, webView) = makeInputSession(Self.mouseOnly)
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: [
                    "type": .string("down"), "x": .number(12), "y": .number(34),
                    "clickCount": .number(2), "modifiers": .array([.string("shift")])
                ]
            )
            #expect(response["ok"] == .bool(true))
            guard case let .pointer(pointer)? = webView.receivedInput.first else {
                Issue.record("expected a pointer event")
                return
            }
            #expect(pointer.phase == .down)
            #expect(pointer.x == 12)
            #expect(pointer.y == 34)
            #expect(pointer.clickCount == 2)
            #expect(pointer.modifiers.contains(.shift))
            #expect(pointer.pointerType == .mouse)
        }

        @Test("a stylus request is refused where a page would only see a mouse")
        @MainActor
        func refusesUnsupportedPointerType() async throws {
            let (session, webView) = makeInputSession(Self.mouseOnly)
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: [
                    "type": .string("down"), "x": .number(1), "y": .number(1),
                    "pointerType": .string("pen")
                ]
            )
            // Refused, not silently downgraded — a stylus test that ran as a
            // mouse click would pass while proving nothing.
            #expect(response["error"]?["code"] == .string("E_DRIVER_UNSUPPORTED"))
            #expect(webView.receivedInput.isEmpty)
        }

        @Test("tilt is refused where it can't reach the page")
        @MainActor
        func refusesTilt() async throws {
            let (session, webView) = makeInputSession(Self.mouseOnly)
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: [
                    "type": .string("down"), "x": .number(1), "y": .number(1),
                    "tiltX": .number(30)
                ]
            )
            #expect(response["error"]?["code"] == .string("E_DRIVER_UNSUPPORTED"))
            #expect(webView.receivedInput.isEmpty)
        }

        @Test("a stylus-capable backend accepts pressure and tilt")
        @MainActor
        func acceptsStylusWhereSupported() async throws {
            let (session, webView) = makeInputSession(InputCapabilities(
                pointer: true, key: true, wheel: true,
                pointerTypes: [.mouse, .pen], pressure: true, tilt: true
            ))
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: [
                    "type": .string("down"), "x": .number(5), "y": .number(6),
                    "pointerType": .string("pen"), "pressure": .number(0.7),
                    "tiltX": .number(-20), "tiltY": .number(15)
                ]
            )
            #expect(response["ok"] == .bool(true))
            guard case let .pointer(pointer)? = webView.receivedInput.first else {
                Issue.record("expected a pointer event")
                return
            }
            #expect(pointer.pointerType == .pen)
            #expect(pointer.pressure == 0.7)
            #expect(pointer.tiltX == -20)
            #expect(pointer.tiltY == 15)
        }

        @Test("an out-of-range pressure is a bad request, not a clamp")
        @MainActor
        func rejectsOutOfRangePressure() async throws {
            let (session, _) = makeInputSession(InputCapabilities(
                pointer: true, pointerTypes: [.mouse], pressure: true
            ))
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: [
                    "type": .string("down"), "x": .number(1), "y": .number(1),
                    "pressure": .number(4)
                ]
            )
            #expect(response["error"]?["code"] == .string("E_DRIVER_REQUEST"))
        }

        @Test("a backend with no input at all points the caller at eval")
        @MainActor
        func noInputSupport() async throws {
            let (session, _) = makeInputSession(.none)
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: ["type": .string("down"), "x": .number(1), "y": .number(1)]
            )
            #expect(response["error"]?["code"] == .string("E_DRIVER_UNSUPPORTED"))
            if case let .string(message)? = response["error"]?["message"] {
                #expect(message.contains("eval"))
            }
        }

        @Test("wheel deltas carry through with the DOM sign convention")
        @MainActor
        func wheel() async throws {
            let (session, webView) = makeInputSession(Self.mouseOnly)
            let response = try await send(
                session,
                cmd: "input.wheel",
                payload: [
                    "x": .number(100), "y": .number(200),
                    "deltaY": .number(-120), "deltaX": .number(15)
                ]
            )
            #expect(response["ok"] == .bool(true))
            guard case let .wheel(wheel)? = webView.receivedInput.first else {
                Issue.record("expected a wheel event")
                return
            }
            #expect(wheel.deltaY == -120)
            #expect(wheel.deltaX == 15)
            #expect(wheel.x == 100)
        }

        @Test("a key event carries key, code and inserted text")
        @MainActor
        func key() async throws {
            let (session, webView) = makeInputSession(Self.mouseOnly)
            let response = try await send(
                session,
                cmd: "input.key",
                payload: [
                    "type": .string("down"), "key": .string("a"),
                    "code": .string("KeyA"), "text": .string("a")
                ]
            )
            #expect(response["ok"] == .bool(true))
            guard case let .key(key)? = webView.receivedInput.first else {
                Issue.record("expected a key event")
                return
            }
            #expect(key.key == "a")
            #expect(key.code == "KeyA")
            #expect(key.text == "a")
        }

        @Test("an unknown pointer phase is rejected before reaching the backend")
        @MainActor
        func rejectsUnknownPhase() async throws {
            let (session, webView) = makeInputSession(Self.mouseOnly)
            let response = try await send(
                session,
                cmd: "input.pointer",
                payload: ["type": .string("hover"), "x": .number(1), "y": .number(1)]
            )
            #expect(response["error"]?["code"] == .string("E_DRIVER_REQUEST"))
            #expect(webView.receivedInput.isEmpty)
        }
    }

#endif
