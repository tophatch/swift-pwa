import Foundation
import SwiftPWA

/// CritterFacts' own vocabulary, offered to an AI agent.
///
/// This is the shape the agent surface is *for*. An agent calling
/// `critter_fact({ critter: "otter" })` is a different thing from an agent
/// clicking at pixel (412, 260) and hoping: the call is typed, the list is
/// finite and chosen by the author, and it survives a redesign of the page.
///
/// It's also the "expose the function, never the key" rule in practice. The
/// fact comes from a model — on-device here, but a cloud one would be the same
/// shape — and the agent never sees a credential, only the verb. Whatever
/// needs the key, the app does.
///
/// Declaring these exposes nothing on its own. The user still has to turn
/// access on from the demo's Agent-access card, per session.
enum CritterAgentSurface {
    /// Kept in Swift rather than read from the page: these are what the *app*
    /// knows about, and an agent asking "what can I ask about" should get the
    /// same answer whichever window is open.
    static let critters = [
        "otter", "octopus", "pangolin", "axolotl", "capybara",
        "narwhal", "tardigrade", "puffin", "wombat"
    ]

    static let tools = [
        AgentTool(
            command: "critter.list",
            description: "The critters this app knows facts about.",
            readOnly: true,
            idempotent: true
        ),
        AgentTool(
            command: "critter.fact",
            description: "One surprising fact about a critter, written by the on-device model.",
            readOnly: true
        )
    ]

    /// Register the commands behind the tools. `backend` is whatever text model
    /// this build has; without one the fact command fails honestly rather than
    /// inventing something.
    @MainActor
    static func register(into registry: CommandRegistry, backend: (any AIBackend)?) {
        registry.register("critter.list", typed: { (_: EmptyArgs, _) async throws -> CritterListResult in
            CritterListResult(critters: critters)
        })

        registry.register("critter.fact", typed: { (args: CritterFactArgs, _) async throws -> CritterFactResult in
            let critter = args.critter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard critters.contains(critter) else {
                throw BridgeError(
                    code: "E_UNKNOWN_CRITTER",
                    message: "I don't know about '\(args.critter)'. Try one of: \(critters.joined(separator: ", "))."
                )
            }
            guard let backend else {
                throw BridgeError(
                    code: "E_NO_MODEL",
                    message: "This build has no on-device text model, so there's nothing to write a fact with."
                )
            }
            let result = try await backend.generate(AIGenerateRequest(
                system: "You write one surprising, true, single-sentence fact about an animal. No preamble.",
                prompt: "Tell me a surprising fact about the \(critter).",
                maxTokens: 80
            ))
            return CritterFactResult(
                critter: critter,
                fact: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
                model: result.backend
            )
        })
    }
}

struct CritterListResult: Codable, Sendable {
    let critters: [String]
}

struct CritterFactArgs: Codable, Sendable {
    let critter: String
}

struct CritterFactResult: Codable, Sendable {
    let critter: String
    let fact: String
    /// Which backend wrote it — the same provenance the page shows.
    let model: String
}
