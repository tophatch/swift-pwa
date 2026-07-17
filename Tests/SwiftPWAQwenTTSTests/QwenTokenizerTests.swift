import Foundation
@testable import SwiftPWAQwenTTS
import Testing

/// The Qwen2 byte-level BPE tokenizer, tested with a small synthetic vocabulary
/// built the same way Qwen builds its own (byte→unicode symbols, no `</w>`).
/// Ids are arbitrary but consistent. A separate opt-in test verifies against
/// the real vocabulary when a model directory is provided.
struct QwenTokenizerTests {
    /// Build a tokenizer whose vocab contains every byte→unicode symbol plus
    /// the given merges, and the two chat-control special tokens.
    private func makeTokenizer(merges: [(String, String)] = []) -> (QwenTokenizer, [String: Int]) {
        var vocab: [String: Int] = [:]
        var id = 0
        for symbol in QwenTokenizer.bytesToUnicode().values.sorted() { vocab[String(symbol)] = id; id += 1 }
        for merge in merges { vocab[merge.0 + merge.1] = id; id += 1 }
        return (
            QwenTokenizer(vocab: vocab, merges: merges, specialTokens: ["<|im_start|>": 900, "<|im_end|>": 901]),
            vocab
        )
    }

    @Test func bytesToUnicodeIsA256WayBijection() {
        let map = QwenTokenizer.bytesToUnicode()
        #expect(map.count == 256)
        #expect(Set(map.values).count == 256)
    }

    @Test func encodesBytesWithoutWordEndMarker() throws {
        let (tokenizer, vocab) = makeTokenizer()
        // "hi" → byte symbols ["h", "i"] (no merges, no </w>).
        let ids = tokenizer.encode("hi")
        #expect(try ids[0] == #require(vocab["h"]))
        #expect(try ids[1] == #require(vocab["i"]))
        #expect(ids.count == 2)
    }

    @Test func leadingSpaceBecomesGSymbol() throws {
        let (tokenizer, vocab) = makeTokenizer()
        // " a" pre-tokenizes to " a"; byte 32 → "Ġ", so symbols ["Ġ", "a"].
        let ids = tokenizer.encode(" a")
        let gSymbol = try #require(QwenTokenizer.bytesToUnicode()[32])
        #expect(try ids[0] == #require(vocab[String(gSymbol)]))
        #expect(try ids[1] == #require(vocab["a"]))
    }

    @Test func appliesBPEMerge() throws {
        // With a merge ("h","i"), "hi" collapses to one symbol "hi".
        let (tokenizer, vocab) = makeTokenizer(merges: [("h", "i")])
        let ids = tokenizer.encode("hi")
        #expect(ids.count == 1)
        #expect(try ids[0] == #require(vocab["hi"]))
    }

    @Test func splitsSpecialTokensAtomically() {
        let (tokenizer, _) = makeTokenizer()
        let ids = tokenizer.encode("<|im_start|>a<|im_end|>")
        #expect(ids.first == 900)
        #expect(ids.last == 901)
        // Exactly one text token ("a") between the two specials.
        #expect(ids.count == 3)
    }

    @Test func isDeterministic() {
        let (tokenizer, _) = makeTokenizer(merges: [("h", "i")])
        #expect(tokenizer.encode("hi there") == tokenizer.encode("hi there"))
    }

    @Test func parseMergesDropsHeaderAndBlankLines() {
        let merges = QwenTokenizer.parseMerges("#version: 0.2\nh i\n\na b\n")
        #expect(merges.count == 2)
        #expect(merges[0] == ("h", "i"))
        #expect(merges[1] == ("a", "b"))
    }

    /// Opt-in: verify against the REAL Qwen3-TTS vocab. Set
    /// `QWEN_TTS_MODEL_DIR` to a directory containing `tokenizer/vocab.json` +
    /// `tokenizer/merges.txt` and `embeddings/config.json`. Confirms the chat
    /// template tokenizes to the exact reference ids.
    @Test func matchesReferenceTokenizationWhenModelPresent() throws {
        guard let dir = ProcessInfo.processInfo.environment["QWEN_TTS_MODEL_DIR"] else { return }
        let root = URL(fileURLWithPath: dir)
        let tokenizer = try QwenTokenizer(
            vocabURL: root.appendingPathComponent("tokenizer/vocab.json"),
            mergesURL: root.appendingPathComponent("tokenizer/merges.txt")
        )
        // "Hello from Swift P W A." → the reference ids captured on the box.
        #expect(tokenizer.encode("Hello from Swift P W A.") == [9707, 504, 23670, 393, 467, 362, 13])
        let template = "<|im_start|>assistant\nHello from Swift P W A.<|im_end|>\n<|im_start|>assistant\n"
        #expect(tokenizer.encode(template)
            == [151_644, 77091, 198, 9707, 504, 23670, 393, 467, 362, 13, 151_645, 198, 151_644, 77091, 198])
    }
}
