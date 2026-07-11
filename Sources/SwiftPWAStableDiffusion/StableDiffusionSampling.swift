import Foundation

/// Pure, deterministic sampling helpers for the diffusion loop — the
/// weight-free arithmetic pieces of the pipeline (seeded latent
/// initialization and timestep selection). Split out from
/// `StableDiffusionBackend` so they compile and unit-test without an ONNX
/// Runtime linked, and are reusable by other diffusion backends.
///
/// > The exact scheduler `step()` update (sigmas, the noise→sample math) is
/// > confirmed on the real-weights pass and lives in the backend; this
/// > covers only the parts that are deterministic regardless of the model:
/// > the seeded Gaussian init and the descending timestep schedule.
public enum StableDiffusionSampling {
    /// A small, deterministic, cross-platform PRNG (SplitMix64) — used so a
    /// given `seed` reproduces the same initial latent on every platform,
    /// independent of any system RNG. Not cryptographic; it only needs to be
    /// well-distributed and reproducible.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// A uniform double in `[0, 1)`.
        mutating func nextUnitDouble() -> Double {
            // Top 53 bits → [0,1), the standard construction.
            Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
    }

    /// `count` standard-normal samples from `seed`, via Box–Muller over the
    /// deterministic PRNG. This is the initial latent noise (before scaling
    /// by the scheduler's `init_noise_sigma`).
    public static func seededLatents(count: Int, seed: UInt64) -> [Float] {
        guard count > 0 else { return [] }
        var rng = SplitMix64(seed: seed)
        var out = [Float](repeating: 0, count: count)
        var index = 0
        while index < count {
            // Box–Muller yields two independent normals per pair of uniforms.
            let u1 = max(Double.leastNormalMagnitude, rng.nextUnitDouble())
            let u2 = rng.nextUnitDouble()
            let radius = (-2.0 * Foundation.log(u1)).squareRoot()
            let angle = 2.0 * Double.pi * u2
            out[index] = Float(radius * Foundation.cos(angle))
            index += 1
            if index < count {
                out[index] = Float(radius * Foundation.sin(angle))
                index += 1
            }
        }
        return out
    }

    /// The LCM **guidance-scale embedding** (`timestep_cond`) — an LCM UNet
    /// takes the guidance scale as a conditioning input rather than running a
    /// separate unconditional pass. This ports diffusers'
    /// `get_guidance_scale_embedding` (the VDM sinusoidal embedding): with
    /// `w = (guidanceScale - 1) · 1000`, the first half is `sin(w · freqᵢ)` and
    /// the second half `cos(w · freqᵢ)`, where `freqᵢ = exp(-i · ln(10000) /
    /// (halfDim - 1))`. `embeddingDim` is the UNet's `time_cond_proj_dim`
    /// (256 for `LCM_Dreamshaper_v7`). Returns a flat `[embeddingDim]` vector.
    public static func guidanceScaleEmbedding(guidanceScale: Double, embeddingDim: Int) -> [Float] {
        let w = (guidanceScale - 1.0) * 1000.0
        let halfDim = embeddingDim / 2
        guard halfDim > 1 else { return [Float](repeating: 0, count: embeddingDim) }
        let scale = Foundation.log(10000.0) / Double(halfDim - 1)
        var out = [Float](repeating: 0, count: embeddingDim)
        for i in 0 ..< halfDim {
            let arg = w * Foundation.exp(Double(i) * -scale)
            out[i] = Float(Foundation.sin(arg))
            out[halfDim + i] = Float(Foundation.cos(arg))
        }
        // Odd embedding dims zero-pad the last slot (diffusers parity).
        return out
    }

    /// The descending training-timestep schedule for `steps` inference
    /// steps, evenly spaced over `[0, numTrainTimesteps)` (the diffusers
    /// convention: `round(linspace(numTrainTimesteps-1, 0, steps))`). A
    /// single step (SD-Turbo) yields the last training timestep.
    public static func timesteps(steps: Int, numTrainTimesteps: Int = 1000) -> [Int] {
        let n = max(1, steps)
        let last = Double(numTrainTimesteps - 1)
        if n == 1 { return [Int(last.rounded())] }
        let stride = last / Double(n - 1)
        return (0 ..< n).map { Int((last - Double($0) * stride).rounded()) }
    }
}
