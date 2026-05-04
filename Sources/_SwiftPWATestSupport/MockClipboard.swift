import Foundation
import SwiftPWACore

/// In-memory `Clipboard` for unit tests. All operations record into
/// `actions` so tests can assert ordering. State is `@MainActor`-isolated
/// — Sendability of the protocol is satisfied because actor-isolated
/// classes are implicitly `Sendable` when crossing actor boundaries.
@MainActor
public final class MockClipboard: Clipboard {
    public enum Action: Sendable, Equatable {
        case readText
        case writeText(String)
        case clear
    }

    public private(set) var text: String?
    public private(set) var actions: [Action] = []

    public init(text: String? = nil) {
        self.text = text
    }

    public func readText() async throws -> String? {
        actions.append(.readText)
        return text
    }

    public func writeText(_ text: String) async throws {
        actions.append(.writeText(text))
        self.text = text
    }

    public func clear() async throws {
        actions.append(.clear)
        text = nil
    }
}
