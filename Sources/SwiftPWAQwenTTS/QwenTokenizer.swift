import Foundation

/// Failures constructing a `QwenTokenizer` from its on-disk vocabulary.
public enum QwenTokenizerError: Error, Equatable {
    case vocabLoadFailed(String)
    case mergesLoadFailed(String)
}

/// The Qwen2 byte-level BPE tokenizer the Qwen3-TTS talker expects — the piece
/// that turns the chat-template text into the `input_ids` the pipeline embeds.
/// Pure and deterministic: it needs **only** `vocab.json` + `merges.txt`
/// (a few MB, no model weights), so it is fully implemented and unit-tested.
///
/// A faithful port of 🤗 `transformers`' `Qwen2Tokenizer` (a GPT-2-style
/// byte-level BPE, distinct from `CLIPTokenizer` in three ways that matter):
///
/// 1. **No lowercasing / whitespace-clean.** Whitespace is significant and is
///    carried into the vocabulary via the byte→unicode map (a leading space
///    becomes `Ġ`), so `" from"` and `"from"` are different symbols.
/// 2. **No `</w>` end-of-word marker.** GPT-2/Qwen byte-level BPE encodes word
///    boundaries through that space→`Ġ` mapping, not a suffix marker.
/// 3. **Special tokens are matched atomically first** (`<|im_start|>`,
///    `<|im_end|>`, …) and mapped straight to their ids, ahead of any
///    byte-level/BPE processing — so the chat template's control tokens survive.
///
/// The Qwen2 pre-tokenization regex (contractions, letter runs, **single**
/// digits, punctuation runs, and whitespace groups) is applied to each
/// non-special segment. Emits raw token ids (no auto BOS/EOS) — the caller
/// assembles the chat template.
///
/// Stateless and `Sendable` (no BPE cache; the prompts are short), so the
/// backend actor can hold and use it freely.
public struct QwenTokenizer: Sendable {
    /// A single BPE symbol pair (ordered), the key into the merge-rank table.
    private struct Pair: Hashable {
        let first: String
        let second: String
        init(_ first: String, _ second: String) {
            self.first = first
            self.second = second
        }
    }

    private let encoder: [String: Int]
    private let bpeRanks: [Pair: Int]
    private let byteEncoder: [UInt8: Character]
    /// Special token string → id, matched literally before byte-level BPE.
    /// Sorted longest-first at split time so `<|im_start|>` wins over any
    /// prefix. Defaults to Qwen3-TTS's chat-control tokens.
    private let specialTokens: [String: Int]

    /// Build from an in-memory vocabulary + merge list (keeps the type
    /// testable without shipping the multi-MB real vocabulary).
    ///
    /// - `vocab`: token string → id (the contents of `vocab.json`).
    /// - `merges`: ordered BPE merge rules, in priority order (the contents of
    ///   `merges.txt` minus its header line).
    /// - `specialTokens`: control tokens matched atomically (default: the
    ///   Qwen3-TTS `<|im_start|>` / `<|im_end|>` ids).
    public init(
        vocab: [String: Int],
        merges: [(String, String)],
        specialTokens: [String: Int] = ["<|im_start|>": 151_644, "<|im_end|>": 151_645]
    ) {
        encoder = vocab
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (index, merge) in merges.enumerated() { ranks[Pair(merge.0, merge.1)] = index }
        bpeRanks = ranks
        byteEncoder = Self.bytesToUnicode()
        self.specialTokens = specialTokens
    }

    /// Load from a Qwen2 `vocab.json` (token → id) and `merges.txt` (a header
    /// line, then one `"a b"` merge per line).
    public init(
        vocabURL: URL,
        mergesURL: URL,
        specialTokens: [String: Int] = ["<|im_start|>": 151_644, "<|im_end|>": 151_645]
    ) throws {
        let vocab: [String: Int]
        do {
            let data = try Data(contentsOf: vocabURL)
            vocab = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            throw QwenTokenizerError.vocabLoadFailed("\(vocabURL.lastPathComponent): \(error)")
        }
        let merges: [(String, String)]
        do {
            let text = try String(contentsOf: mergesURL, encoding: .utf8)
            merges = Self.parseMerges(text)
        } catch {
            throw QwenTokenizerError.mergesLoadFailed("\(mergesURL.lastPathComponent): \(error)")
        }
        self.init(vocab: vocab, merges: merges, specialTokens: specialTokens)
    }

    /// Parse a `merges.txt` body: drop a leading `#version:` header (if
    /// present) and blank lines, split each remaining line into its two symbols.
    static func parseMerges(_ text: String) -> [(String, String)] {
        var merges: [(String, String)] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if index == 0, line.hasPrefix("#") { continue } // "#version: 0.2"
            // A merge symbol can itself contain a space-encoded char, but in
            // merges.txt the two symbols are separated by a single ASCII space
            // and never contain a raw space (spaces are the `Ġ` symbol), so a
            // split on the first space is exact.
            if let sep = line.firstIndex(of: " ") {
                merges.append((String(line[line.startIndex ..< sep]), String(line[line.index(after: sep)...])))
            }
        }
        return merges
    }

    // MARK: - Encoding

    /// Tokenize `text` into raw token ids (no BOS/EOS added). Special tokens
    /// are split out and mapped directly; everything else goes through the
    /// Qwen2 regex → byte-level → BPE → vocab path.
    public func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        for segment in splitOnSpecials(text) {
            switch segment {
            case let .special(id):
                ids.append(id)
            case let .text(chunk):
                for token in Self.regexTokenize(chunk) {
                    let mapped = String(Array(token.utf8).map { byteEncoder[$0] ?? "?" })
                    for piece in bpe(mapped) {
                        if let id = encoder[piece] { ids.append(id) }
                    }
                }
            }
        }
        return ids
    }

    private enum Segment {
        case text(String)
        case special(Int)
    }

    /// Split `text` on the longest-matching special token at each position,
    /// yielding interleaved text and special-id segments. Longest-first so a
    /// token that is a prefix of another can't shadow it.
    private func splitOnSpecials(_ text: String) -> [Segment] {
        guard !specialTokens.isEmpty else { return text.isEmpty ? [] : [.text(text)] }
        let specials = specialTokens.sorted { $0.key.count > $1.key.count }
        var segments: [Segment] = []
        var pending = ""
        var i = text.startIndex
        outer: while i < text.endIndex {
            for (token, id) in specials where text[i...].hasPrefix(token) {
                if !pending.isEmpty { segments.append(.text(pending)); pending = "" }
                segments.append(.special(id))
                i = text.index(i, offsetBy: token.count)
                continue outer
            }
            pending.append(text[i])
            i = text.index(after: i)
        }
        if !pending.isEmpty { segments.append(.text(pending)) }
        return segments
    }

    /// BPE-merge one byte-encoded pre-token into its final vocab symbols.
    /// Greedy in ascending merge rank; **no `</w>`** (Qwen/GPT-2 byte-level).
    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard word.count > 1 else { return word }
        var pairs = Self.pairs(in: word)
        while true {
            var bestRank = Int.max
            var best: Pair?
            for pair in pairs {
                if let rank = bpeRanks[pair], rank < bestRank { bestRank = rank; best = pair }
            }
            guard let bigram = best else { break }
            var newWord: [String] = []
            var i = 0
            while i < word.count {
                if let j = word[i...].firstIndex(of: bigram.first) {
                    newWord.append(contentsOf: word[i ..< j])
                    i = j
                } else {
                    newWord.append(contentsOf: word[i...])
                    break
                }
                if word[i] == bigram.first, i < word.count - 1, word[i + 1] == bigram.second {
                    newWord.append(bigram.first + bigram.second)
                    i += 2
                } else {
                    newWord.append(word[i])
                    i += 1
                }
            }
            word = newWord
            if word.count == 1 { break }
            pairs = Self.pairs(in: word)
        }
        return word
    }

    private static func pairs(in word: [String]) -> Set<Pair> {
        guard word.count > 1 else { return [] }
        var result = Set<Pair>()
        for i in 0 ..< (word.count - 1) { result.insert(Pair(word[i], word[i + 1])) }
        return result
    }

    // MARK: - Pre-tokenization

    /// The Qwen2 pre-tokenization pattern: contractions (case-insensitive),
    /// letter runs (optionally with a leading non-letter/non-digit), **single**
    /// digits, punctuation runs (optionally space-led, trailing newlines),
    /// and whitespace groups. Matches `transformers`' `Qwen2Tokenizer`.
    private static let pattern =
        "(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\\r\\n\\p{L}\\p{N}]?\\p{L}+|\\p{N}| ?[^\\s\\p{L}\\p{N}]+[\\r\\n]*|\\s*[\\r\\n]+|\\s+(?!\\S)|\\s+"

    private static let regex = try? NSRegularExpression(pattern: pattern)

    private static func regexTokenize(_ text: String) -> [String] {
        guard let regex, !text.isEmpty else { return text.isEmpty ? [] : [text] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }
    }

    // MARK: - Byte↔unicode table

    /// The reversible byte→unicode map (GPT-2/Qwen `bytes_to_unicode`): each of
    /// the 256 byte values maps to a distinct printable code point, so
    /// arbitrary UTF-8 becomes vocabulary symbols with no unknown token (and a
    /// space, byte 32, becomes `Ġ`).
    static func bytesToUnicode() -> [UInt8: Character] {
        var byteValues: [Int] = Array(33 ... 126) + Array(161 ... 172) + Array(174 ... 255)
        var codePoints = byteValues
        var next = 0
        for byte in 0 ..< 256 where !byteValues.contains(byte) {
            byteValues.append(byte)
            codePoints.append(256 + next)
            next += 1
        }
        var map: [UInt8: Character] = [:]
        for (byte, code) in zip(byteValues, codePoints) {
            if let scalar = Unicode.Scalar(code) { map[UInt8(byte)] = Character(scalar) }
        }
        return map
    }
}
