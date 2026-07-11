@testable import SwiftPWAStableDiffusion
import Testing

struct StableDiffusionSamplingTests {
    @Test func seededLatentsAreDeterministicAndSeedSensitive() {
        let a = StableDiffusionSampling.seededLatents(count: 64, seed: 42)
        let b = StableDiffusionSampling.seededLatents(count: 64, seed: 42)
        let c = StableDiffusionSampling.seededLatents(count: 64, seed: 43)
        #expect(a.count == 64)
        #expect(a == b) // same seed → identical noise on every platform
        #expect(a != c) // different seed → different noise
    }

    @Test func seededLatentsRespectCountIncludingOdd() {
        // Box–Muller emits normals in pairs; an odd count must still be exact.
        #expect(StableDiffusionSampling.seededLatents(count: 0, seed: 1).isEmpty)
        #expect(StableDiffusionSampling.seededLatents(count: 1, seed: 1).count == 1)
        #expect(StableDiffusionSampling.seededLatents(count: 7, seed: 1).count == 7)
    }

    @Test func seededLatentsAreRoughlyStandardNormal() {
        let samples = StableDiffusionSampling.seededLatents(count: 20000, seed: 7)
        let mean = samples.reduce(0, +) / Float(samples.count)
        let variance = samples.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(samples.count)
        #expect(abs(mean) < 0.05) // ~0
        #expect(abs(variance - 1) < 0.1) // ~1
    }

    @Test func timestepsAreDescendingOverTheTrainRange() {
        #expect(StableDiffusionSampling.timesteps(steps: 1, numTrainTimesteps: 1000) == [999])

        let four = StableDiffusionSampling.timesteps(steps: 4, numTrainTimesteps: 1000)
        #expect(four.count == 4)
        #expect(four.first == 999)
        #expect(four.last == 0)
        #expect(zip(four, four.dropFirst()).allSatisfy { $0 > $1 }) // strictly descending
    }
}
