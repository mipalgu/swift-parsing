import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftGLR
import Testing

/// Correctness fuzzer for the incremental GLR parsing session.
///
/// The governing property is non-negotiable: after every edit in a long random chain, an incremental
/// session's tree is byte-for-byte what a full parse of the same text produces, and it still round-trips to
/// the source. The fuzzer applies many random insert, delete and replace edits in sequence across the JSON,
/// Lua and C grammars, feeding each through the chained session and an independent full parse, and asserts
/// they agree at every step. Edits are drawn from a seeded generator so any failure reproduces from its
/// seed. This chained-edit property is what previously caught the lexer-boundary unsoundness the safe-point
/// search now guards against.
@Suite("GLR incremental session")
struct IncrementalSessionTests {
    /// A small deterministic generator so a fuzz failure reproduces from its seed.
    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Applies one random edit to an ASCII byte buffer, returning the new text and the matching ``TextEdit``.
    ///
    /// The buffer is kept ASCII (the seeds and the alphabet are ASCII), so byte-level insert, delete and
    /// replace operations always yield valid UTF-8 and the byte offsets line up with the lossless tree.
    ///
    /// - Parameters:
    ///   - bytes: The current text as a UTF-8 byte buffer, mutated in place.
    ///   - rng: The deterministic generator.
    ///   - alphabet: The bytes an insertion or replacement may introduce.
    /// - Returns: The new text and the edit describing the change.
    static func applyRandomEdit(
        _ bytes: inout [UInt8], using rng: inout SplitMix64, alphabet: [UInt8]
    ) -> (text: String, edit: TextEdit) {
        let count = bytes.count
        let kind = count == 0 ? 0 : Int.random(in: 0...2, using: &rng)
        let start = count == 0 ? 0 : Int.random(in: 0...count, using: &rng)
        switch kind {
        case 1 where start < count:  // delete a short run
            let end = min(count, start + 1 + Int.random(in: 0...2, using: &rng))
            bytes.removeSubrange(start..<end)
            return (
                String(decoding: bytes, as: UTF8.self),
                TextEdit(startByte: start, oldEndByte: end, newEndByte: start)
            )
        case 2 where start < count:  // replace a short run
            let end = min(count, start + 1 + Int.random(in: 0...2, using: &rng))
            let inserted = (0...Int.random(in: 0...2, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)!
            }
            bytes.replaceSubrange(start..<end, with: inserted)
            return (
                String(decoding: bytes, as: UTF8.self),
                TextEdit(startByte: start, oldEndByte: end, newEndByte: start + inserted.count)
            )
        default:  // insert
            let inserted = (0...Int.random(in: 0...3, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)!
            }
            bytes.insert(contentsOf: inserted, at: start)
            return (
                String(decoding: bytes, as: UTF8.self),
                TextEdit(startByte: start, oldEndByte: start, newEndByte: start + inserted.count)
            )
        }
    }

    /// Runs a chained-edit fuzz over one grammar, asserting incremental equals full at every step.
    private func fuzz(
        grammar: Grammar, seed source: String, alphabet: String, rngSeed: UInt64, edits: Int
    ) throws {
        let engine = try UTF8GLRParser(grammar: grammar)
        let alphabetBytes = Array(alphabet.utf8)
        var rng = SplitMix64(seed: rngSeed)
        var current = source
        var session = engine.incrementalParse(Source(current))

        #expect(session.result.sExpression() == engine.parse(Source(current)).sExpression())

        var buffer = Array(current.utf8)
        for step in 0..<edits {
            let (new, edit) = Self.applyRandomEdit(&buffer, using: &rng, alphabet: alphabetBytes)
            session = session.reparse(Source(new), edits: [edit])
            let full = engine.parse(Source(new))
            let context = "seed \(rngSeed) step \(step): \(current.debugDescription) -> \(new.debugDescription)"
            #expect(
                session.result.tree.green.isEquivalent(to: full.tree.green),
                "incremental tree diverged from a full parse at \(context)")
            #expect(
                session.result.sExpression() == full.sExpression(),
                "incremental sExpression diverged from a full parse at \(context)")
            #expect(
                session.result.tree.green.reconstructedText == new,
                "incremental tree did not round-trip at \(context)")
            #expect(
                session.result.hasErrors == full.hasErrors,
                "incremental error flag diverged at \(context)")
            current = new
        }
    }

    @Test(
        "Chained random edits on JSON keep the session byte-identical to a full parse",
        arguments: 0..<6)
    func jsonFuzz(_ seed: Int) throws {
        try fuzz(
            grammar: JSONGrammar.grammar(),
            seed: #"{"a": 1, "b": [true, false, null], "c": {"d": 2.5}}"#,
            alphabet: #"{}[]:,"abcd0123.- tfnaeulrs"#,
            rngSeed: UInt64(seed) &* 0x1_0001 &+ 1, edits: 40)
    }

    @Test(
        "Chained random edits on Lua keep the session byte-identical to a full parse",
        arguments: 0..<6)
    func luaFuzz(_ seed: Int) throws {
        try fuzz(
            grammar: LuaGrammar.chunk(),
            seed: "local a = 1\nlocal b = 2\nfunction f(x) return x + 1 end\nif a then b = 3 end\n",
            alphabet: "abcdefxy =0123\n()+-*localfunctionifthenendreturlocal",
            rngSeed: UInt64(seed) &* 0x9E37 &+ 7, edits: 40)
    }

    @Test(
        "Chained random edits on C keep the session byte-identical to a full parse",
        arguments: 0..<6)
    func cFuzz(_ seed: Int) throws {
        try fuzz(
            grammar: CGrammar.translationUnit(),
            seed: "int main(void) {\n  int x = 1;\n  return x + 2;\n}\n",
            alphabet: "abcxy =0123\n(){}+-*;intreturvoidchar",
            rngSeed: UInt64(seed) &* 0xABCD &+ 3, edits: 40)
    }
}
