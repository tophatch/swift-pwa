@testable import SwiftPWAStableDiffusion
import Testing

/// Checks the LCM scheduler + guidance embedding against the numbers the real
/// diffusers 0.39 `LCMScheduler` / `LatentConsistencyModelPipeline` produced
/// for `LCM_Dreamshaper_v7` (SD-1.5 base) — see docs/proposals/stable-diffusion.md.
struct LCMSchedulerTests {
    /// LCM_Dreamshaper's scheduler config (SD-1.5 betas, LCM kind).
    private let config = StableDiffusionModelSpec.SchedulerConfig(kind: .lcm)

    @Test func fourStepTimestepsMatchDiffusers() {
        var sched = LCMScheduler(config: config)
        sched.setTimesteps(4)
        #expect(sched.timesteps == [999, 759, 499, 259]) // origin schedule, floor(linspace(0,50,4,False))
        #expect(sched.initNoiseSigma == 1) // LCM does not scale the init latent
    }

    @Test func scaleModelInputIsIdentity() {
        var sched = LCMScheduler(config: config)
        sched.setTimesteps(4)
        let x: [Float] = [3, -2, 0.25]
        #expect(sched.scaleModelInput(x, stepIndex: 0) == x)
    }

    @Test func lastStepDenoisedMatchesDiffusers() throws {
        var sched = LCMScheduler(config: config)
        sched.setTimesteps(4)
        // Last step (index 3, t=259): isLast → returns `denoised` (no re-noise).
        let sample: [Float] = [2, -1, 0.5]
        let eps: [Float] = [1, 1, -2]
        let out = try sched.step(modelOutput: eps, stepIndex: 3, sample: sample, noise: nil)
        let expected: [Float] = [1.744363, -1.951252, 2.054696] // diffusers step().denoised
        for i in 0 ..< 3 {
            #expect(abs(out[i] - expected[i]) < 1e-3)
        }
    }

    @Test func nonFinalStepReNoisesAndNeedsNoise() throws {
        var sched = LCMScheduler(config: config)
        sched.setTimesteps(4)
        let sample: [Float] = [0.5, -0.5, 1]
        let eps: [Float] = [0.1, -0.2, 0.3]
        // With zero noise on a non-final step, prev = sqrt(alphaPrev)·denoised.
        let out = try sched.step(modelOutput: eps, stepIndex: 0, sample: sample, noise: [0, 0, 0])
        #expect(out.count == 3)
        // Missing/short noise on a non-final step is an error.
        #expect(throws: LCMScheduler.SchedulerError.self) {
            try sched.step(modelOutput: eps, stepIndex: 0, sample: sample, noise: nil)
        }
    }

    @Test func nonEpsilonPredictionThrows() {
        var cfg = config
        cfg.predictionType = "v_prediction"
        var sched = LCMScheduler(config: cfg)
        sched.setTimesteps(4)
        #expect(throws: LCMScheduler.SchedulerError.self) {
            try sched.step(modelOutput: [0], stepIndex: 3, sample: [0], noise: nil)
        }
    }

    @Test func guidanceScaleEmbeddingMatchesDiffusers() {
        // diffusers get_guidance_scale_embedding(w = guidanceScale - 1, dim=256)
        // for guidanceScale 8 → w=7 → w·1000=7000.
        let emb = StableDiffusionSampling.guidanceScaleEmbedding(guidanceScale: 8.0, embeddingDim: 256)
        #expect(emb.count == 256)
        let expectedFirst4: [Float] = [0.506885, 0.804287, -0.86048, 0.999944] // sin half
        for i in 0 ..< 4 { #expect(abs(emb[i] - expectedFirst4[i]) < 1e-3) }
        // cos half starts at index 128.
        #expect(abs(emb[128] - 0.862013) < 1e-3)
        #expect(abs(emb[129] - 0.594241) < 1e-3)
    }

    @Test func schedulerRegistryPicksLCM() {
        let sched = makeScheduler(StableDiffusionModelSpec.SchedulerConfig(kind: .lcm))
        #expect(sched is LCMScheduler)
        #expect(sched.usesStepNoise)
        let euler = makeScheduler(StableDiffusionModelSpec.SchedulerConfig(kind: .euler))
        #expect(euler is EulerDiscreteScheduler)
        #expect(!euler.usesStepNoise)
    }
}
