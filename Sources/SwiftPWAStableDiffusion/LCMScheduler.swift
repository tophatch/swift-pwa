import Foundation

/// A pure-Swift port of diffusers' `LCMScheduler` — the sampler a **Latent
/// Consistency Model** (LCM) is distilled for. Weight-free and deterministic
/// (the only stochastic part is the per-step noise, which the loop supplies).
/// Confirmed numerically against diffusers 0.39 on `LCM_Dreamshaper_v7`
/// (SD-1.5 base): for `setTimesteps(4)` it reproduces `timesteps == [999, 759,
/// 499, 259]` and `initNoiseSigma == 1`, and `scaleModelInput` is the identity.
///
/// Unlike Euler, LCM is a **consistency model**: each step predicts the clean
/// latent `x₀` directly (through a boundary-condition scaling), then — except
/// on the last step — re-noises it to the next timestep for another refinement
/// pass. Guidance is *not* applied here via a negative-prompt branch; it rides
/// in as a `timestep_cond` embedding fed to the UNet (see
/// `StableDiffusionSampling.guidanceScaleEmbedding`). Only the `epsilon`
/// prediction type is implemented (LCM_Dreamshaper); others throw.
public struct LCMScheduler: DiffusionScheduler, Sendable {
    public enum SchedulerError: Error, Equatable {
        case unsupported(String)
    }

    private let config: StableDiffusionModelSpec.SchedulerConfig
    /// ᾱ_t (`alphas_cumprod`) for each training timestep — `cumprod(1 - betas)`.
    private let alphasCumprod: [Double]

    public private(set) var timesteps: [Int] = []
    public let initNoiseSigma: Double = 1
    public let usesStepNoise = true

    public init(config: StableDiffusionModelSpec.SchedulerConfig) {
        self.config = config
        let n = config.numTrainTimesteps

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
        var cum = [Double](repeating: 0, count: n)
        for i in 0 ..< n {
            cumprod *= (1.0 - betas[i])
            cum[i] = cumprod
        }
        alphasCumprod = cum
    }

    /// Select the `steps` LCM inference timesteps. diffusers builds the LCM
    /// "origin" schedule — `[k-1, 2k-1, …, origSteps·k-1]` with
    /// `k = numTrainTimesteps / origSteps` — reverses it, and takes
    /// `floor(linspace(0, origSteps, steps, endpoint=false))` of it.
    public mutating func setTimesteps(_ steps: Int) {
        let n = max(1, steps)
        let train = config.numTrainTimesteps
        let orig = max(1, config.originalInferenceSteps)
        let k = max(1, train / orig)
        // Origin schedule ascending, then reversed (descending).
        let originDescending = (1 ... orig).map { ($0 * k) - 1 }.reversed().map(\.self)
        var ts: [Int] = []
        for i in 0 ..< n {
            // np.linspace(0, orig, num=n, endpoint=False)[i] = i * orig / n, floored.
            let idx = Int((Double(orig) * Double(i) / Double(n)).rounded(.down))
            ts.append(originDescending[min(originDescending.count - 1, idx)])
        }
        timesteps = ts
    }

    /// LCM does not scale the UNet input — identity.
    public func scaleModelInput(_ sample: [Float], stepIndex _: Int) -> [Float] { sample }

    /// One LCM step: predict `x₀`, apply the consistency boundary scaling to
    /// get `denoised`, then (unless this is the last step) re-noise it to the
    /// next timestep with the supplied `noise`. The final step returns
    /// `denoised` — that's the latent the VAE decodes.
    public func step(modelOutput: [Float], stepIndex: Int, sample: [Float], noise: [Float]?) throws -> [Float] {
        guard config.predictionType == "epsilon" else {
            throw SchedulerError.unsupported("prediction type \"\(config.predictionType)\"")
        }
        let t = timesteps[stepIndex]
        let isLast = stepIndex == timesteps.count - 1
        let prevT = isLast ? t : timesteps[stepIndex + 1]

        let aT = alphasCumprod[t]
        let aPrev = alphasCumprod[prevT]
        let sqrtAT = aT.squareRoot(), sqrtBT = (1 - aT).squareRoot()
        let sqrtAlphaPrev = aPrev.squareRoot(), sqrtBetaPrev = (1 - aPrev).squareRoot()

        // Consistency-function boundary conditions (sigma_data 0.5, timestep
        // scaling 10 — diffusers defaults).
        let scaled = Double(t) * config.timestepScaling
        let sd2 = config.sigmaData * config.sigmaData
        let cSkip = sd2 / (scaled * scaled + sd2)
        let cOut = scaled / (scaled * scaled + sd2).squareRoot()

        if !isLast, (noise?.count ?? 0) != sample.count {
            throw SchedulerError.unsupported("LCM multi-step needs per-step noise of the latent's length")
        }

        var out = [Float](repeating: 0, count: sample.count)
        for i in 0 ..< sample.count {
            let s = Double(sample[i])
            let eps = Double(modelOutput[i])
            // epsilon → predicted clean latent x₀.
            let x0 = (s - sqrtBT * eps) / sqrtAT
            let denoised = cOut * x0 + cSkip * s
            if isLast {
                out[i] = Float(denoised)
            } else {
                let z = Double(noise![i])
                out[i] = Float(sqrtAlphaPrev * denoised + sqrtBetaPrev * z)
            }
        }
        return out
    }
}
