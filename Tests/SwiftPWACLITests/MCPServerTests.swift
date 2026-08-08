import ArgumentParser
import Foundation
@testable import SwiftPWACLISupport
import SwiftPWACore
import Testing

/// The MCP surface that can be checked without a socket or a running app: the
/// tool catalogue's shape and protocol-version negotiation. The wire behaviour
/// (handshake, content blocks, error mapping) is exercised against a real
/// server process — see `docs/app-driver.md`.
@Suite("MCP server")
struct MCPServerTests {
    // MARK: - Version negotiation

    @Test("a version we speak is echoed back, as the spec requires")
    func echoesSupportedVersion() {
        for version in MCPServer.supportedProtocolVersions {
            #expect(MCPServer.negotiate(protocolVersion: version) == version)
        }
    }

    @Test("a version we don't speak negotiates down to our latest")
    func fallsBackToPreferred() {
        #expect(MCPServer.negotiate(protocolVersion: "1.0.0") == MCPServer.preferredProtocolVersion)
        #expect(MCPServer.negotiate(protocolVersion: nil) == MCPServer.preferredProtocolVersion)
    }

    @Test("the preferred version is one we actually support")
    func preferredIsSupported() {
        #expect(MCPServer.supportedProtocolVersions.contains(MCPServer.preferredProtocolVersion))
    }

    // MARK: - Tool catalogue

    @Test("tool names are unique and namespaced")
    func namesAreDistinct() {
        let names = MCPTools.all.map(\.name)
        #expect(Set(names).count == names.count)
        // An agent host merges tools from every connected server, so a bare
        // `click` would be ambiguous the moment a second server offers one.
        #expect(names.allSatisfy { $0.hasPrefix("app_") })
    }

    @Test("every tool carries the fields a client needs to call it")
    func descriptorsAreComplete() {
        for tool in MCPTools.all {
            let descriptor = tool.descriptor
            #expect(descriptor["name"] == .string(tool.name))
            guard case let .string(description)? = descriptor["description"], !description.isEmpty else {
                Issue.record("\(tool.name) has no description")
                continue
            }
            #expect(descriptor["inputSchema"]?["type"] == .string("object"))
            #expect(descriptor["inputSchema"]?["properties"] != nil)
        }
    }

    @Test("required arguments are declared, and name real properties")
    func requiredArgumentsExist() {
        for tool in MCPTools.all {
            guard case let .array(required)? = tool.inputSchema["required"] else { continue }
            guard case let .object(properties)? = tool.inputSchema["properties"] else {
                Issue.record("\(tool.name) declares required args but no properties")
                continue
            }
            for entry in required {
                guard case let .string(name) = entry else { continue }
                #expect(properties[name] != nil, "\(tool.name) requires '\(name)', which isn't a property")
            }
        }
    }

    @Test("every declared property has a type and a description")
    func propertiesAreDocumented() {
        for tool in MCPTools.all {
            guard case let .object(properties)? = tool.inputSchema["properties"] else { continue }
            for (name, schema) in properties {
                #expect(schema["type"] != nil, "\(tool.name).\(name) has no type")
                // The description is what an agent reads to decide whether the
                // argument applies — an undocumented one is effectively unusable.
                #expect(schema["description"] != nil, "\(tool.name).\(name) has no description")
            }
        }
    }

    @Test("the catalogue covers both observing and acting")
    func coversTheVerbSet() {
        let names = Set(MCPTools.all.map(\.name))
        for expected in [
            "app_screenshot", "app_eval", "app_windows", "app_capabilities",
            "app_click", "app_type", "app_press_key", "app_scroll"
        ] {
            #expect(names.contains(expected), "missing \(expected)")
        }
    }

    // MARK: - Agent mode

    @Test("an app tool's descriptor carries what a host needs to call it")
    func agentToolDescriptor() {
        let tool = AgentMCPTool(
            name: "book_open",
            description: "Open a book by id.",
            inputSchema: .object(["type": .string("object")]),
            annotations: .object(["readOnlyHint": .bool(true)])
        )
        let descriptor = tool.descriptor
        #expect(descriptor["name"] == .string("book_open"))
        #expect(descriptor["description"] == .string("Open a book by id."))
        #expect(descriptor["inputSchema"]?["type"] == .string("object"))
        // Passed through untouched: they're the app author's claim about their
        // own commands, and a host uses them to decide what to confirm.
        #expect(descriptor["annotations"]?["readOnlyHint"] == .bool(true))
    }

    @Test("a tool with no annotations doesn't get an empty annotations object")
    func annotationsAreOmittedWhenAbsent() {
        let tool = AgentMCPTool(name: "x", description: "y", inputSchema: .object([:]), annotations: nil)
        #expect(tool.descriptor["annotations"] == nil)
    }

    @Test("the two modes tell an agent different things about what it's holding")
    func instructionsDifferByMode() {
        // The driver can do anything to a debug build; the agent surface is an
        // allowlist someone switched on. An agent shouldn't have to guess which.
        #expect(MCPServer.agentInstructions.contains("own commands"))
        #expect(MCPServer.agentInstructions.contains("revoked"))
        #expect(MCPServer.driverInstructions.contains("screenshot"))
        #expect(MCPServer.agentInstructions != MCPServer.driverInstructions)
    }

    @Test("agent mode refuses to run without something to attach to")
    func agentModeNeedsAttach() async throws {
        // It serves a *running* app, so there's nothing sensible to do without
        // a port — and launching one would produce a second copy with its agent
        // surface switched off.
        var command = try MCP.parse(["--agent"])
        await #expect(throws: ValidationError.self) { try await command.run() }
    }

    @Test("driver mode is still happy without --attach: it launches the app itself")
    func driverModeDoesNotRequireAttach() throws {
        // Guards the check above from over-reaching — it must be specific to
        // --agent, not a blanket requirement.
        let command = try MCP.parse([])
        #expect(command.agent == false)
        #expect(command.options.attach == nil)
    }

    // MARK: - Screenshot scaling

    @Test("a PNG wider than the limit is scaled down, preserving aspect ratio")
    func scalesLargeScreenshots() throws {
        let source = try #require(Self.solidPNG(width: 800, height: 600))
        let scaled = try #require(PNGScaler.fit(source, maxWidth: 200))
        let size = try #require(Self.pngSize(scaled))
        #expect(size.width == 200)
        #expect(size.height == 150) // 4:3 preserved
    }

    @Test("a PNG already within the limit is left alone")
    func leavesSmallScreenshots() throws {
        let source = try #require(Self.solidPNG(width: 120, height: 90))
        // nil means "nothing to do" — the caller sends the original rather
        // than a needlessly re-encoded copy.
        #expect(PNGScaler.fit(source, maxWidth: 640) == nil)
    }

    // MARK: - Fixtures

    /// A minimal real PNG, produced by the same encoder the scaler uses.
    private static func solidPNG(width: Int, height: Int) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 0x30
            pixels[index + 1] = 0x60
            pixels[index + 2] = 0x90
            pixels[index + 3] = 0xFF
        }
        return PNGScaler.encode(rgba: pixels, width: width, height: height)
    }

    /// Width and height straight out of the IHDR chunk.
    private static func pngSize(_ png: Data) -> (width: Int, height: Int)? {
        guard png.count >= 24 else { return nil }
        let bytes = [UInt8](png)
        func be32(_ offset: Int) -> Int {
            (Int(bytes[offset]) << 24) | (Int(bytes[offset + 1]) << 16)
                | (Int(bytes[offset + 2]) << 8) | Int(bytes[offset + 3])
        }
        return (be32(16), be32(20))
    }
}
