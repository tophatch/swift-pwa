import Foundation
@testable import SwiftPWAQwenTTS
import Testing

/// The NPY reader, the sampler, and the WAV encoder — pure pieces, tested
/// without any model weights.
struct QwenSupportTests {
    // MARK: - NPY

    /// Write a tiny float32 C-order `.npy` (matching NumPy's v1.0 layout) and
    /// confirm the reader parses the shape/dtype and reads rows correctly.
    @Test func numpyReadsFloat32Rows() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qwen-npy-\(UInt64(bitPattern: Int64(1))).npy")
        // 2 rows × 3 cols: [[1,2,3],[4,5,6]].
        var data = Data([0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59, 1, 0]) // magic + v1.0
        let header = "{'descr': '<f4', 'fortran_order': False, 'shape': (2, 3), }"
        // Pad the header so (10 + headerLen) is a multiple of 64 (NumPy does
        // this; the reader doesn't require it, but stay faithful).
        var headerBytes = Array(header.utf8)
        let total = 10 + headerBytes.count + 1
        let pad = (64 - total % 64) % 64
        headerBytes += Array(repeating: 0x20, count: pad) + [0x0A]
        data.append(UInt8(headerBytes.count & 0xFF)); data.append(UInt8((headerBytes.count >> 8) & 0xFF))
        data.append(contentsOf: headerBytes)
        for v in [Float(1), 2, 3, 4, 5, 6] {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        try data.write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let array = try QwenNumpyArray(url: dir)
        #expect(array.shape == [2, 3])
        #expect(array.rows == 2)
        #expect(array.columns == 3)
        #expect(array.row(0) == [1, 2, 3])
        #expect(array.row(1) == [4, 5, 6])
        #expect(array.flat() == [1, 2, 3, 4, 5, 6])
    }

    // MARK: - Sampler

    @Test func greedyG0PicksArgmaxRespectingSuppressAndMinTokens() {
        var rng = QwenSeededGenerator(seed: 1)
        // talkerVocab 6, cpVocab 3 → suppress indices [3,6) except eos.
        // Logits favor index 4 (suppressed) then index 1 (valid).
        let logits: [Float] = [0.1, 5.0, 0.2, 9.0, 8.0, 0.3]
        let eos = 5
        // Index 3,4 suppressed (not eos); index 1 is the top valid → argmax 1.
        let g = QwenSampler.sampleG0(
            logits: logits, previous: [], step: 5,
            talkerVocab: 6, cpVocab: 3, eos: eos,
            temperature: 0.9, topK: 50, repetitionPenalty: 1.05, minNewTokens: 2,
            greedy: true, rng: &rng
        )
        #expect(g == 1)
    }

    @Test func minNewTokensForbidsEosEarly() {
        var rng = QwenSeededGenerator(seed: 1)
        // eos (index 5) has the highest logit, but step < minNewTokens forbids it.
        let logits: [Float] = [1, 2, 0, -9, -9, 100]
        let g = QwenSampler.sampleG0(
            logits: logits, previous: [], step: 0,
            talkerVocab: 6, cpVocab: 3, eos: 5,
            temperature: 0.9, topK: 50, repetitionPenalty: 1.05, minNewTokens: 2,
            greedy: true, rng: &rng
        )
        #expect(g != 5)
        #expect(g == 1) // top valid non-eos, non-suppressed
    }

    @Test func seededSamplingIsDeterministic() {
        let logits: [Float] = (0 ..< 100).map { Float($0).truncatingRemainder(dividingBy: 7) }
        func draw(seed: UInt64) -> [Int] {
            var rng = QwenSeededGenerator(seed: seed)
            return (0 ..< 20).map { _ in
                QwenSampler.sampleCP(logits: logits, temperature: 0.9, topK: 10, rng: &rng)
            }
        }
        #expect(draw(seed: 42) == draw(seed: 42))
        #expect(draw(seed: 42) != draw(seed: 7)) // different seed → different stream
    }

    // MARK: - WAV

    @Test func wavHeaderIsWellFormed() {
        let wav = QwenWAV.encode(samples: [0, 0.5, -0.5, 1, -1], sampleRate: 24000)
        #expect(wav.count == 44 + 5 * 2) // header + 5 int16 samples
        #expect(wav.prefix(4) == Data("RIFF".utf8))
        #expect(wav[8 ..< 12] == Data("WAVE".utf8))
        #expect(wav[36 ..< 40] == Data("data".utf8))
        // Sample rate at bytes 24..<28, little-endian.
        let sr = wav[24 ..< 28].withUnsafeBytes { $0.load(as: UInt32.self) }
        #expect(UInt32(littleEndian: sr) == 24000)
    }
}
