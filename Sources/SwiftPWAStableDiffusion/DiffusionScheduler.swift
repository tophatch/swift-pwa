import Foundation

/// A denoising scheduler the txt2img loop drives, abstracted so a backend can
/// pick the sampler its checkpoint was distilled for — `EulerDiscreteScheduler`
/// (SD-Turbo / plain SD-1.x/2.x) or `LCMScheduler` (Latent Consistency Models,
/// the few-step OpenRAIL-M tier). Both are pure-Swift, weight-free, and
/// confirmed numerically against diffusers.
///
/// The loop calls, per inference step: `scaleModelInput` (before the UNet),
/// then `step` (after). Schedulers that inject fresh noise between steps
/// (`usesStepNoise` — LCM's multi-step sampling) receive it via `step`'s
/// `noise` argument; the noise-free samplers (Euler) ignore it.
public protocol DiffusionScheduler: Sendable {
    /// The (descending) training timesteps to run inference at, chosen by
    /// `setTimesteps`.
    var timesteps: [Int] { get }
    /// The initial-latent scale — the seeded Gaussian noise is multiplied by
    /// this before the loop. Euler: the max sigma; LCM: 1.
    var initNoiseSigma: Double { get }
    /// Whether `step` consumes `noise` on non-final steps (LCM's stochastic
    /// multi-step sampling). `false` for Euler — the loop can skip generating
    /// per-step noise entirely.
    var usesStepNoise: Bool { get }

    /// Select the inference timesteps for `steps` denoising steps.
    mutating func setTimesteps(_ steps: Int)
    /// Scale the latent before it enters the UNet at inference step `stepIndex`.
    func scaleModelInput(_ sample: [Float], stepIndex: Int) -> [Float]
    /// Advance `sample` using the UNet's `modelOutput` at inference step
    /// `stepIndex` to the next (lower) noise level. `noise` is standard-normal
    /// noise for the schedulers that need it on non-final steps (LCM); pass
    /// `nil` otherwise.
    func step(modelOutput: [Float], stepIndex: Int, sample: [Float], noise: [Float]?) throws -> [Float]
}

/// The sampler a checkpoint uses — the scheduler registry. `StableDiffusionSpec`
/// carries one, and `makeScheduler` builds the matching `DiffusionScheduler`.
public enum SchedulerKind: String, Sendable, Equatable {
    /// `EulerDiscreteScheduler` — SD-Turbo and plain SD-1.x/2.x.
    case euler
    /// `LCMScheduler` — Latent Consistency Models (few-step, guidance baked
    /// into a `timestep_cond` embedding).
    case lcm
}

/// Build the `DiffusionScheduler` a spec's `scheduler.kind` selects.
func makeScheduler(_ config: StableDiffusionModelSpec.SchedulerConfig) -> any DiffusionScheduler {
    switch config.kind {
    case .euler: EulerDiscreteScheduler(config: config)
    case .lcm: LCMScheduler(config: config)
    }
}
