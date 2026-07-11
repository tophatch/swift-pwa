@testable import SwiftPWAStableDiffusion
import Testing

/// Tests the byte-level BPE tokenizer against a small, real-shaped
/// vocabulary built the same way CLIP builds its own (byte→unicode base
/// symbols, their `</w>` variants, then merged tokens) — so the
/// byte-encoding, merge machinery, and id lookup are exercised without
/// shipping the ~half-MB real vocabulary. Ids are arbitrary but consistent;
/// the assertions are on structure and relative behavior, not specific ids.
struct CLIPTokenizerTests {
    /// Build a tokenizer whose vocab contains every byte→unicode symbol, its
    /// `</w>` variant, and the joined form of each supplied merge — mirroring
    /// CLIP's own vocab construction. Returns the vocab too, so assertions
    /// can name the expected symbol rather than hard-coding an id.
    private func makeTokenizer(merges: [(String, String)] = []) -> (CLIPTokenizer, [String: Int]) {
        let symbols = Array(Set(CLIPTokenizer.bytesToUnicode().values))
        var vocab: [String: Int] = [:]
        var id = 0
        for symbol in symbols { vocab[String(symbol)] = id; id += 1 }
        for symbol in symbols { vocab[String(symbol) + "</w>"] = id; id += 1 }
        for merge in merges { vocab[merge.0 + merge.1] = id; id += 1 }
        vocab["<|startoftext|>"] = 49406
        vocab["<|endoftext|>"] = 49407
        return (CLIPTokenizer(vocab: vocab, merges: merges), vocab)
    }

    @Test func bytesToUnicodeIsA256WayBijection() {
        let map = CLIPTokenizer.bytesToUnicode()
        #expect(map.count == 256)
        #expect(Set(map.values).count == 256) // all distinct code points
    }

    @Test func encodesWithBosEosAndPadsToMaxLength() throws {
        let (tokenizer, vocab) = makeTokenizer()
        let ids = tokenizer.encode("hi")
        #expect(ids.count == tokenizer.maxLength)
        #expect(ids.first == tokenizer.bosToken)
        // "hi" → symbols ["h", "i</w>"] (no merges): bos, h, i</w>, eos, pad…
        #expect(try ids[1] == Int32(#require(vocab["h"])))
        #expect(try ids[2] == Int32(#require(vocab["i</w>"])))
        #expect(ids[3] == tokenizer.eosToken)
        #expect(ids[4] == tokenizer.padToken) // padded with the pad token
        #expect(ids.dropFirst(4).allSatisfy { $0 == tokenizer.padToken })
    }

    @Test func appliesBPEMerge() throws {
        // A merge rule on the </w>-suffixed word collapses "h" + "i</w>".
        let (tokenizer, vocab) = makeTokenizer(merges: [("h", "i</w>")])
        let ids = tokenizer.encode("hi")
        #expect(ids[0] == tokenizer.bosToken)
        #expect(try ids[1] == Int32(#require(vocab["hi</w>"])))
        #expect(ids[2] == tokenizer.eosToken)
    }

    @Test func lowercasesAndCollapsesWhitespace() {
        let (tokenizer, _) = makeTokenizer()
        #expect(tokenizer.encode("  HI  ") == tokenizer.encode("hi"))
        #expect(tokenizer.encode("hi\n\tthere") == tokenizer.encode("hi there"))
    }

    @Test func isDeterministic() {
        let (tokenizer, _) = makeTokenizer()
        #expect(tokenizer.encode("hello world") == tokenizer.encode("hello world"))
    }

    @Test func truncatesLongPromptsKeepingBosAndEos() {
        let (tokenizer, _) = makeTokenizer()
        // 100 words → 100 tokens + bos + eos = 102 > 77 → truncated.
        let long = Array(repeating: "a", count: 100).joined(separator: " ")
        let ids = tokenizer.encode(long)
        #expect(ids.count == tokenizer.maxLength)
        #expect(ids.first == tokenizer.bosToken)
        #expect(ids.last == tokenizer.eosToken) // trailing eos preserved on truncation
    }

    @Test func parseMergesDropsHeaderAndBlankLines() {
        let merges = CLIPTokenizer.parseMerges("#version: 0.2\nh i</w>\n\na b\n")
        #expect(merges.count == 2)
        #expect(merges[0] == ("h", "i</w>"))
        #expect(merges[1] == ("a", "b"))
    }
}
