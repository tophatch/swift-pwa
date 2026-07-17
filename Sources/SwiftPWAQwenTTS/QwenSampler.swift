import Foundation

/// A small deterministic RNG (SplitMix64) so a given `seed` reproduces the same
/// sampled utterance. Not cryptographic — a fast, well-distributed generator
/// for multinomial token sampling. (`Foundation`'s `SystemRandomNumberGenerator`
/// isn't seedable, and reproducing NumPy's PCG64 stream isn't required: the
/// pipeline only needs *a* faithful, reproducible sampler.)
public struct QwenSeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A uniform double in `[0, 1)`.
    public mutating func uniform() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0) // 2^53
    }
}

/// The talker (codebook-0) and code-predictor (codebooks 1-15) samplers,
/// faithful to the reference's HuggingFace generation stack. Pure functions
/// over a logits vector + an RNG, so they are trivially unit-testable.
public enum QwenSampler {
    /// Sample the talker's codebook-0 token from its `logits` (length =
    /// `talkerVocab`). Applies, in HF order: repetition penalty (once per
    /// **unique** previously-emitted token), suppression of the reserved range
    /// `[cpVocab, talkerVocab)` except `eos`, a min-new-tokens floor (eos
    /// forbidden for the first `minNewTokens` steps), temperature, top-k, then a
    /// multinomial draw. With `greedy`, returns the argmax after the processors
    /// (deterministic — used for reference comparison / tests).
    public static func sampleG0(
        logits: [Float],
        previous: Set<Int>,
        step: Int,
        talkerVocab: Int,
        cpVocab: Int,
        eos: Int,
        temperature: Double,
        topK: Int,
        repetitionPenalty: Double,
        minNewTokens: Int,
        greedy: Bool = false,
        rng: inout QwenSeededGenerator
    ) -> Int {
        var p = logits.map { Double($0) }
        let eosLogit = p[eos] // pre-penalty; eos is never in `previous`
        let pen = repetitionPenalty
        for token in previous where token < p.count {
            p[token] = p[token] > 0 ? p[token] / pen : p[token] * pen
        }
        // Suppress the reserved tail, then restore eos to its original logit.
        for i in cpVocab ..< min(talkerVocab, p.count) { p[i] = -.infinity }
        if eos < p.count { p[eos] = eosLogit }
        if step < minNewTokens, eos < p.count { p[eos] = -.infinity }
        return finish(&p, temperature: temperature, topK: topK, greedy: greedy, rng: &rng)
    }

    /// Sample a code-predictor codebook token from its `logits` (length =
    /// `cpVocab`). Temperature + top-k + multinomial only — no repetition
    /// penalty, suppression, or min-length (the reference's subtalker path).
    public static func sampleCP(
        logits: [Float],
        temperature: Double,
        topK: Int,
        greedy: Bool = false,
        rng: inout QwenSeededGenerator
    ) -> Int {
        var p = logits.map { Double($0) }
        return finish(&p, temperature: temperature, topK: topK, greedy: greedy, rng: &rng)
    }

    /// Shared tail: temperature → top-k → softmax → multinomial (or argmax when
    /// `greedy`). Operates in place on `p` (already-processed logits).
    private static func finish(
        _ p: inout [Double], temperature: Double, topK: Int, greedy: Bool, rng: inout QwenSeededGenerator
    ) -> Int {
        if greedy { return argmax(p) }
        if temperature > 0, temperature != 1 { for i in p.indices { p[i] /= temperature } }
        keepTopK(&p, k: topK)
        // Softmax over the (mostly -inf) vector, then a cumulative multinomial draw.
        let maxLogit = p.max() ?? 0
        var expSum = 0.0
        var exps = [Double](repeating: 0, count: p.count)
        for i in p.indices where p[i].isFinite {
            let e = Foundation.exp(p[i] - maxLogit)
            exps[i] = e
            expSum += e
        }
        guard expSum > 0 else { return argmax(p) }
        let target = rng.uniform() * expSum
        var acc = 0.0
        for i in exps.indices {
            acc += exps[i]
            if acc >= target { return i }
        }
        return argmax(exps)
    }

    /// Mask everything outside the `k` highest values to `-inf` (top-k filter).
    private static func keepTopK(_ p: inout [Double], k: Int) {
        guard k > 0, k < p.count else { return }
        // The k-th largest value is the threshold; keep values >= it.
        let sorted = p.enumerated().sorted { $0.element > $1.element }
        let threshold = sorted[k - 1].element
        for i in p.indices where p[i] < threshold { p[i] = -.infinity }
    }

    private static func argmax(_ p: [Double]) -> Int {
        var best = 0
        var bestValue = -Double.infinity
        for i in p.indices where p[i] > bestValue { bestValue = p[i]; best = i }
        return best
    }
}
