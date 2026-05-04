import Foundation
import SwiftPWACore

/// In-memory `Notifications` for unit tests. State is `@MainActor`-
/// isolated so it satisfies `Sendable` without locks; the protocol
/// itself isn't `@MainActor` so tests still exercise the actor hop.
@MainActor
public final class MockNotifications: Notifications {
    public enum Action: Sendable, Equatable {
        case requestAuthorization
        case send(NotificationRequest)
    }

    public private(set) var actions: [Action] = []
    public private(set) var sent: [NotificationRequest] = []
    public var authorizationGranted: Bool = true
    public var nextID: () -> String = { UUID().uuidString }

    public init() {}

    public func requestAuthorization() async throws -> Bool {
        actions.append(.requestAuthorization)
        return authorizationGranted
    }

    public func send(_ request: NotificationRequest) async throws -> String {
        actions.append(.send(request))
        sent.append(request)
        return nextID()
    }
}
