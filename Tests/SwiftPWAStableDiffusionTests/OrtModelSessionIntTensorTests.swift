import Foundation
import SwiftPWAONNX
import Testing

/// Validates the `OrtModelSession` integer-input path end-to-end against a
/// tiny real ONNX graph (`int_cast_add.onnx`: `Cast(int32)+Cast(int64) →
/// float`), so the int32/int64 support the Stable-Diffusion text encoder
/// (`input_ids` int32) / UNet (`timestep` int64) need is exercised on real
/// ONNX Runtime, not just compiled. Lives here because SD is what motivates
/// the feature; the graph itself is model-agnostic.
struct OrtModelSessionIntTensorTests {
    private func fixtureURL() throws -> URL {
        try #require(Bundle.module.url(forResource: "int_cast_add", withExtension: "onnx", subdirectory: "Fixtures"))
    }

    @Test func runsInt32AndInt64InputsToFloatOutput() throws {
        let runtime = try #require(OrtRuntime.shared, "no ONNX Runtime linked")
        let session = try OrtModelSession(modelPath: fixtureURL().path, runtime: runtime)

        let outputs = try session.run(
            inputs: [
                "a_int32": .int32([1, 2, 3], shape: [3]),
                "b_int64": .int64([10, 20, 30], shape: [3])
            ],
            outputNames: ["sum"]
        )

        let sum = try #require(outputs["sum"])
        #expect(sum.shape == [3])
        #expect(sum.values == [11, 22, 33]) // int32 + int64, cast to float, added
    }
}
