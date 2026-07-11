import Foundation

/// A pure-Swift port of diffusers' `EulerDiscreteScheduler` — the sampler
/// SD-Turbo (and SD-1.x/2.x) uses. Weight-free and deterministic: it derives
/// the noise-level (`sigma`) schedule from the model's beta constants and
/// steps the latent through the denoising loop. Confirmed numerically against
/// the real diffusers scheduler on SD-Turbo (see
/// `docs/proposals/stable-diffusion.md`): for `setTimesteps(1)` it reproduces
/// `timesteps == [999]`, `sigmas == [14.6146, 0]`, `initNoiseSigma ==
/// 14.6146`.
///
/// Only the `epsilon` prediction type is implemented (SD-Turbo / SD-1.x);
/// `step` throws `.unsupported` for others. All three timestep spacings
/// (`trailing` — SD-Turbo's default — `linspace`, `leading`) are supported.
public struct EulerDiscreteScheduler: Sendable {
    public enum SchedulerError: Error, Equatable {
        case unsupported(String)
    }

    private let config: StableDiffusionModelSpec.SchedulerConfig
    /// `sigma` for each of the `numTrainTimesteps` training steps: the ONNX
    /// export's noise levels, `sqrt((1 - ᾱ_t) / ᾱ_t)`.
    public let trainSigmas: [Double]

    /// Populated by `setTimesteps`.
    /// The (descending) training timesteps to run inference at.
    public private(set) var timesteps: [Int] = []
    /// The per-step sigmas, with a trailing `0` appended (length
    /// `timesteps.count + 1`), indexed by inference step.
    public private(set) var sigmas: [Double] = []
    /// The initial-latent scale — the seeded Gaussian noise is multiplied by
    /// this before the loop.
    public private(set) var initNoiseSigma: Double = 1

    public init(config: StableDiffusionModelSpec.SchedulerConfig) {
        self.config = config
        let n = config.numTrainTimesteps

        // betas → alphas → ᾱ (cumulative product) → sigmas.
        var betas = [Double](repeating: 0, count: n)
        if config.betaSchedule == "scaled_linear" {
            let lo = config.betaStart.squareRoot(), hi = config.betaEnd.squareRoot()
            for i in 0 ..< n {
                let t = n > 1 ? Double(i) / Double(n - 1) : 0
                let v = lo + (hi - lo) * t
                betas[i] = v * v
            }
        } else { // "linear"
            for i in 0 ..< n {
                let t = n > 1 ? Double(i) / Double(n - 1) : 0
                betas[i] = config.betaStart + (config.betaEnd - config.betaStart) * t
            }
        }
        var cumprod = 1.0
        var sigmas = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            cumprod *= (1.0 - betas[i])
            sigmas[i] = ((1.0 - cumprod) / cumprod).squareRoot()
        }
        trainSigmas = sigmas
    }

    /// Select the inference timesteps + sigmas for `steps` denoising steps.
    public mutating func setTimesteps(_ steps: Int) {
        let n = max(1, steps)
        let train = config.numTrainTimesteps
        var ts: [Int] = []

        switch config.timestepSpacing {
        case "linspace":
            let last = Double(train - 1)
            for i in 0 ..< n {
                let v = n > 1 ? last - Double(i) * (last / Double(n - 1)) : last
                ts.append(Int(v.rounded()))
            }
        case "leading":
            let ratio = train / n
            for i in stride(from: n - 1, through: 0, by: -1) {
                ts.append(i * ratio + config.stepsOffset)
            }
        default: // "trailing" (SD-Turbo)
            let ratio = Double(train) / Double(n)
            var v = Double(train)
            while v > 0.5 { // arange(train, 0, -ratio)
                ts.append(Int(v.rounded()) - 1)
                v -= ratio
            }
        }

        // Sigma per timestep (linear interp over the integer train grid; the
        // timesteps are integers here, so this is an exact table lookup).
        var stepSigmas = ts.map { interpolatedSigma(at: Double($0)) }
        // diffusers appends a terminal sigma of 0.
        let maxSigma = stepSigmas.max() ?? 0
        stepSigmas.append(0)

        timesteps = ts
        sigmas = stepSigmas
        // trailing / linspace scale by max sigma; leading by sqrt(max²+1).
        initNoiseSigma = config.timestepSpacing == "leading" ? (maxSigma * maxSigma + 1).squareRoot() : maxSigma
    }

    /// Scale the latent before it enters the UNet at inference step
    /// `stepIndex`: `sample / sqrt(sigma² + 1)`.
    public func scaleModelInput(_ sample: [Float], stepIndex: Int) -> [Float] {
        let sigma = sigmas[stepIndex]
        let scale = Float(1.0 / (sigma * sigma + 1.0).squareRoot())
        return sample.map { $0 * scale }
    }

    /// One Euler step: advance `sample` using the UNet's `modelOutput` (the
    /// predicted noise, for `epsilon`) at inference step `stepIndex`, to the
    /// next (lower) noise level. Returns the new latent.
    public func step(modelOutput: [Float], stepIndex: Int, sample: [Float]) throws -> [Float] {
        guard config.predictionType == "epsilon" else {
            throw SchedulerError.unsupported("prediction type \"\(config.predictionType)\"")
        }
        let sigma = sigmas[stepIndex]
        let sigmaNext = sigmas[stepIndex + 1]
        // epsilon: pred_original = sample - sigma·noise; derivative =
        // (sample - pred_original)/sigma = noise; prev = sample +
        // derivative·(sigmaNext - sigma). So prev = sample + noise·(sigmaNext - sigma).
        let dt = Float(sigmaNext - sigma)
        return zip(sample, modelOutput).map { $0 + $1 * dt }
    }

    /// Linear interpolation into `trainSigmas` at a (possibly fractional)
    /// training-timestep index.
    private func interpolatedSigma(at t: Double) -> Double {
        let clamped = max(0, min(Double(trainSigmas.count - 1), t))
        let lo = Int(clamped.rounded(.down)), hi = min(trainSigmas.count - 1, lo + 1)
        let frac = clamped - Double(lo)
        return trainSigmas[lo] + (trainSigmas[hi] - trainSigmas[lo]) * frac
    }
}
