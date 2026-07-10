import Foundation

/// Failures constructing a `CLIPTokenizer` from its on-disk vocabulary.
public enum CLIPTokenizerError: Error, Equatable {
    case vocabLoadFailed(String)
    case mergesLoadFailed(String)
}

/// The byte-level BPE tokenizer a Stable-Diffusion text encoder (CLIP)
/// expects — the piece that turns a prompt into the `input_ids` tensor the
/// `text_encoder` ONNX graph consumes. Pure and deterministic: it needs
/// **only** the tokenizer's `vocab.json` + `merges.txt` (a few hundred KB,
/// no model weights), so it is fully implemented and unit-tested in this
/// increment, ahead of the real-weights pass that finalizes the graph
/// plumbing (see `docs/proposals/stable-diffusion.md`).
///
/// This is a faithful port of the CLIP tokenizer used by 🤗
/// `transformers`' `CLIPTokenizer` / OpenAI's `SimpleTokenizer`:
///
/// 1. **Whitespace clean + lowercase** the text (a light clean — collapse
///    runs of whitespace and trim; the upstream `ftfy` mojibake fix is a
///    nicety, not correctness-critical for typed prompts, and is omitted).
/// 2. **Regex pre-tokenize** into words / single digits / punctuation runs
///    (contractions like `'s` split off), the CLIP pattern.
/// 3. **Byte→unicode map** each pre-token's UTF-8 bytes to printable code
///    points (the GPT-2/CLIP `bytes_to_unicode` table) so any byte is a
///    vocab symbol.
/// 4. **BPE merge** using `merges.txt` rank order, with the word-final
///    symbol carrying the `</w>` end-of-word marker.
/// 5. **Map to ids** via `vocab.json`, wrap with the start/end-of-text
///    tokens, and pad/truncate to `maxLength` (77) with the pad token.
///
/// Stateless and `Sendable` — no BPE cache (prompts are short; correctness
/// and value-type simplicity over a micro-optimization), so it can be held
/// by the `StableDiffusionBackend` actor and used freely.
public struct CLIPTokenizer: Sendable {
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

    /// `<|startoftext|>` id (CLIP default 49406), prepended to every sequence.
    public let bosToken: Int32
    /// `<|endoftext|>` id (CLIP default 49407), appended to every sequence.
    public let eosToken: Int32
    /// Padding id (CLIP pads with `<|endoftext|>`, so default 49407).
    public let padToken: Int32
    /// Fixed sequence length the text encoder expects (CLIP default 77).
    public let maxLength: Int

    /// Build from an in-memory vocabulary + merge list. The primary use is
    /// the file-loading initializer below; this one keeps the type testable
    /// without shipping the ~half-MB real vocabulary.
    ///
    /// - `vocab`: token string → id (the contents of `vocab.json`).
    /// - `merges`: ordered BPE merge rules (each a `(first, second)` symbol
    ///   pair, in priority order — the contents of `merges.txt` minus its
    ///   header line).
    public init(
        vocab: [String: Int],
        merges: [(String, String)],
        bosToken: Int32 = 49406,
        eosToken: Int32 = 49407,
        padToken: Int32 = 49407,
        maxLength: Int = 77
    ) {
        encoder = vocab
        var ranks: [Pair: Int] = [:]
        ranks.reserveCapacity(merges.count)
        for (index, merge) in merges.enumerated() {
            ranks[Pair(merge.0, merge.1)] = index
        }
        bpeRanks = ranks
        byteEncoder = Self.bytesToUnicode()
        self.bosToken = bosToken
        self.eosToken = eosToken
        self.padToken = padToken
        self.maxLength = maxLength
    }

    /// Load the tokenizer from a CLIP `vocab.json` (a JSON object of token →
    /// id) and `merges.txt` (a header line, then one `"a b"` merge per line).
    public init(
        vocabURL: URL,
        mergesURL: URL,
        bosToken: Int32 = 49406,
        eosToken: Int32 = 49407,
        padToken: Int32 = 49407,
        maxLength: Int = 77
    ) throws {
        let vocab: [String: Int]
        do {
            let data = try Data(contentsOf: vocabURL)
            vocab = try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            throw CLIPTokenizerError.vocabLoadFailed("\(vocabURL.lastPathComponent): \(error)")
        }

        let merges: [(String, String)]
        do {
            let text = try String(contentsOf: mergesURL, encoding: .utf8)
            merges = Self.parseMerges(text)
        } catch {
            throw CLIPTokenizerError.mergesLoadFailed("\(mergesURL.lastPathComponent): \(error)")
        }

        self.init(
            vocab: vocab, merges: merges,
            bosToken: bosToken, eosToken: eosToken, padToken: padToken, maxLength: maxLength
        )
    }

    /// Parse a `merges.txt` body: drop a leading `#version:` header (if
    /// present) and any blank lines, split each remaining line on whitespace
    /// into its two symbols.
    static func parseMerges(_ text: String) -> [(String, String)] {
        var merges: [(String, String)] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if index == 0, line.hasPrefix("#") { continue } // "#version: 0.2"
            let parts = line.split(separator: " ")
            if parts.count == 2 { merges.append((String(parts[0]), String(parts[1]))) }
        }
        return merges
    }

    // MARK: - Encoding

    /// Tokenize `text` into the fixed-length `input_ids` the text encoder
    /// consumes: `[bos, …token ids…, eos]` padded with `padToken` (or
    /// truncated, keeping `bos` and a trailing `eos`) to exactly `maxLength`.
    public func encode(_ text: String) -> [Int32] {
        var ids: [Int32] = [bosToken]
        let cleaned = Self.whitespaceClean(text).lowercased()
        for token in Self.regexTokenize(cleaned) {
            // Byte→unicode: every UTF-8 byte becomes a printable symbol that
            // exists in the vocabulary, so nothing is ever out-of-vocab.
            let mapped = String(Array(token.utf8).map { byteEncoder[$0] ?? "?" })
            for piece in bpe(mapped) {
                if let id = encoder[piece] { ids.append(Int32(id)) }
            }
        }
        ids.append(eosToken)

        if ids.count > maxLength {
            ids = Array(ids.prefix(maxLength - 1)) + [eosToken]
        } else if ids.count < maxLength {
            ids += Array(repeating: padToken, count: maxLength - ids.count)
        }
        return ids
    }

    /// BPE-merge one byte-encoded pre-token into its final list of vocab
    /// symbols. The last symbol carries `</w>`; merges are applied greedily
    /// in ascending rank until no known pair remains.
    private func bpe(_ token: String) -> [String] {
        var word = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"
        if word.count == 1 { return word }

        var pairs = Self.pairs(in: word)
        while true {
            var bestRank = Int.max
            var best: Pair?
            for pair in pairs {
                if let rank = bpeRanks[pair], rank < bestRank {
                    bestRank = rank
                    best = pair
                }
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

    // MARK: - Text normalization

    /// Collapse runs of whitespace to a single space and trim — CLIP's
    /// `whitespace_clean`.
    static func whitespaceClean(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The CLIP pre-tokenization pattern: contractions, letter runs, single
    /// digits, and punctuation runs. Case-insensitive (the text is already
    /// lowercased; the flag matches upstream).
    private static let pattern =
        "'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"

    private static let regex = try? NSRegularExpression(
        pattern: pattern, options: [.caseInsensitive]
    )

    private static func regexTokenize(_ text: String) -> [String] {
        guard let regex else { return text.isEmpty ? [] : [text] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.map { ns.substring(with: $0.range) }
    }

    // MARK: - Byte↔unicode table

    /// The reversible byte→unicode map (GPT-2/CLIP `bytes_to_unicode`): every
    /// one of the 256 byte values maps to a distinct printable code point, so
    /// arbitrary UTF-8 becomes vocabulary symbols with no unknown token.
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
