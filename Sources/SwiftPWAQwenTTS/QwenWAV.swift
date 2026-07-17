import Foundation

/// Minimal WAV (RIFF) encoding for the vocoder's float PCM output. 16-bit
/// signed PCM, mono — the compact, universally-playable container for TTS
/// output. Pure and deterministic, so it is unit-testable without a model.
public enum QwenWAV {
    /// Encode mono float samples in `[-1, 1]` at `sampleRate` to a 16-bit PCM
    /// WAV `Data`. Samples are clamped and rounded to `Int16`.
    public static func encode(samples: [Float], sampleRate: Int) -> Data {
        let channels = 1
        let bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataSize = samples.count * bitsPerSample / 8

        var data = Data(capacity: 44 + dataSize)
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func ascii(_ s: String) { data.append(contentsOf: s.utf8) }

        ascii("RIFF")
        u32(UInt32(36 + dataSize))
        ascii("WAVE")
        ascii("fmt ")
        u32(16) // PCM fmt chunk size
        u16(1) // audio format = PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        ascii("data")
        u32(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            // Symmetric scale by 32767 (avoids -32768 asymmetry / clipping wrap).
            let value = Int16((clamped * 32767).rounded())
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}
