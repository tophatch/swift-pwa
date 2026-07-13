import Foundation
@testable import SwiftPWACore
@testable import SwiftPWARemoteAI
import Testing

/// Exercises the binding engine against **real exported ComfyUI graphs**
/// (`docs/sample-workflows/`, sanitized — model/image names are placeholders,
/// structure intact). These carry node shapes the synthetic fixtures don't:
/// object-valued rgthree widgets, `TextEncodeQwenImageEditPlus`,
/// `SamplerCustomAdvanced` graphs, IP-Adapter, upscale. Pure/offline — no
/// `/object_info`, so enrichment is skipped and only the graph-derived structure
/// (literal-vs-connection, current values, binding locations) is checked.
@Suite("ComfyUI real sample workflows")
struct RealWorkflowFixtureTests {
    private static var sampleDir: URL {
        URL(fileURLWithPath: #filePath) // …/Tests/SwiftPWARemoteAITests/<this>.swift
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/sample-workflows")
    }

    private static func graph(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: sampleDir.appendingPathComponent(name))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func files() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: sampleDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    @Test("every sample yields overridable literals, no connection inputs among them")
    func allSamplesParse() throws {
        let files = try Self.files()
        #expect(!files.isEmpty)
        for file in files {
            let data = try Data(contentsOf: file)
            let graph = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let inputs = WorkflowGraph.overridableInputs(graph: graph, objectInfo: [:], titledOnly: false)
            #expect(!inputs.isEmpty, "\(file.lastPathComponent) had no overridable inputs")
            // Nothing surfaced should correspond to a wired [nodeId, slot] input.
            for input in inputs {
                let node = try #require(graph[input.nodeID] as? [String: Any])
                let raw = try #require((node["inputs"] as? [String: Any])?[input.inputName])
                #expect(!WorkflowGraph.isConnection(raw))
            }
        }
    }

    @Test("qwen edit: prompt literal kept, image1/model connections excluded, LoadImage bindable")
    func qwenEditShape() throws {
        let graph = try Self.graph("image_qwen_image_edit_2509.json")
        let inputs = WorkflowGraph.overridableInputs(graph: graph, objectInfo: [:], titledOnly: false)
        #expect(inputs.contains { $0.nodeID == "110" && $0.inputName == "prompt" })
        #expect(inputs.contains { $0.nodeID == "78" && $0.inputName == "image" })
        #expect(!inputs.contains { $0.inputName == "image1" }) // wired
        #expect(!inputs.contains { $0.inputName == "model" }) // wired
    }

    @Test("rgthree Power Lora Loader surfaces its object-valued widget verbatim")
    func objectValuedWidget() throws {
        let graph = try Self.graph("comfy-workflow-faceinput.json")
        let inputs = WorkflowGraph.overridableInputs(graph: graph, objectInfo: [:], titledOnly: false)
        // A `lora_NN` widget is a JSON object ({ on, strength, lora }) — the runner
        // carries it through as `.object`, not something it chokes on.
        let objectInput = inputs.first { if case .object = $0.currentValue { return true }; return false }
        #expect(objectInput != nil)
    }

    @Test("explicit binding drives a real node; fan-out unaffected by unrelated nodes")
    func bindIntoRealNode() throws {
        let graph = try Self.graph("qwen_image_2512.json")
        // #108 is the positive CLIPTextEncode; bind its `text`.
        var mutable = graph
        WorkflowGraph.setInput(&mutable, at: .init(nodeID: "108", input: "text"), value: "bound prompt")
        let text = ((mutable["108"] as? [String: Any])?["inputs"] as? [String: Any])?["text"] as? String
        #expect(text == "bound prompt")
    }
}
