@testable import SwiftPWAStableDiffusion
import Testing

/// Checks the Euler scheduler against the numbers the real diffusers
/// `EulerDiscreteScheduler` produced for SD-Turbo (dumped during the
/// real-weights pass — see docs/proposals/stable-diffusion.md).
struct EulerDiscreteSchedulerTests {
    private let config = StableDiffusionModelSpec.SchedulerConfig() // SD-Turbo defaults

    @Test func trainSigmaTableMatchesDiffusers() {
        let sched = EulerDiscreteScheduler(config: config)
        #expect(sched.trainSigmas.count == 1000)
        #expect(abs(sched.trainSigmas[0] - 0.029167) < 1e-4) // sigma[0]
        #expect(abs(sched.trainSigmas[999] - 14.6146) < 1e-3) // sigma_max
    }

    @Test func singleStepMatchesSDTurbo() {
        var sched = EulerDiscreteScheduler(config: config)
        sched.setTimesteps(1)
        #expect(sched.timesteps == [999]) // trailing spacing, not linspace's [0]
        #expect(sched.sigmas.count == 2)
        #expect(abs(sched.sigmas[0] - 14.6146) < 1e-3)
        #expect(sched.sigmas[1] == 0)
        #expect(abs(sched.initNoiseSigma - 14.6146) < 1e-3)
    }

    @Test func fourStepsAreDescendingTrailing() {
        var sched = EulerDiscreteScheduler(config: config)
        sched.setTimesteps(4)
        #expect(sched.timesteps == [999, 749, 499, 249]) // trailing: round(arange(1000,0,-250))-1
        #expect(sched.sigmas.count == 5)
        #expect(sched.sigmas.last == 0)
    }

    @Test func epsilonSingleStepReducesToPredOriginal() throws {
        // For one step (sigmaNext = 0), prev = sample - sigma·noise.
        var sched = EulerDiscreteScheduler(config: config)
        sched.setTimesteps(1)
        let sigma = Float(sched.sigmas[0])
        let sample: [Float] = [2, -1, 0.5]
        let noise: [Float] = [1, 1, -2]
        let prev = try sched.step(modelOutput: noise, stepIndex: 0, sample: sample)
        for i in 0 ..< 3 {
            #expect(abs(prev[i] - (sample[i] - sigma * noise[i])) < 1e-3)
        }
    }

    @Test func nonEpsilonPredictionThrows() {
        var cfg = config
        cfg.predictionType = "v_prediction"
        var sched = EulerDiscreteScheduler(config: cfg)
        sched.setTimesteps(1)
        #expect(throws: EulerDiscreteScheduler.SchedulerError.self) {
            try sched.step(modelOutput: [0], stepIndex: 0, sample: [0])
        }
    }
}
