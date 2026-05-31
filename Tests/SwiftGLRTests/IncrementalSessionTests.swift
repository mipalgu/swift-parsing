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

    // MARK: - Shared assertion

    /// Asserts that the session and an independent full parse of `text` agree on the whole tree.
    ///
    /// This is the single governing property, factored out so the UTF-8, scalar, grapheme and multi-edit
    /// fuzzers all check exactly the same four things: the green tree is structurally equivalent, the
    /// s-expression matches, the tree round-trips losslessly to `text`, and the error flag agrees.
    ///
    /// - Parameters:
    ///   - session: The incremental session after a reparse.
    ///   - full: A fresh full parse of the same text.
    ///   - text: The current source text the session was reparsed to.
    ///   - context: A human-readable description used in the failure message.
    private func expectSessionMatchesFull(
        _ session: IncrementalGLRParser<some ParserInput>, _ full: ParseResult, text: String,
        context: @autoclosure () -> String
    ) {
        let where_ = context()
        #expect(
            session.result.tree.green.isEquivalent(to: full.tree.green),
            "incremental tree diverged from a full parse at \(where_)")
        #expect(
            session.result.sExpression() == full.sExpression(),
            "incremental sExpression diverged from a full parse at \(where_)")
        #expect(
            session.result.tree.green.reconstructedText == text,
            "incremental tree did not round-trip at \(where_)")
        #expect(
            session.result.hasErrors == full.hasErrors,
            "incremental error flag diverged at \(where_)")
    }

    // MARK: - Non-UTF-8 granularities (multi-byte content)

    /// Applies one random whole-element edit to a document held as an array of equatable substrings.
    ///
    /// Holding the document as an array of whole text elements (Characters for the grapheme view, or single
    /// scalar strings for the scalar view) and only ever inserting, deleting or replacing whole elements
    /// guarantees every intermediate text is valid UTF-8 and every edit lands on a character boundary, which
    /// is the precondition the multi-byte ``glrIndex`` walk relies on. Each ``TextEdit`` is expressed in
    /// UTF-8 byte coordinates, computed from the UTF-8 byte widths of the elements before the edit point so
    /// the offsets line up with the lossless tree exactly as a real editor would report them.
    ///
    /// - Parameters:
    ///   - elements: The document as whole text elements, mutated in place.
    ///   - rng: The deterministic generator.
    ///   - alphabet: The whole elements an insertion or replacement may introduce (each possibly multi-byte).
    /// - Returns: The new text and the edit describing the change in UTF-8 byte coordinates.
    static func applyRandomElementEdit(
        _ elements: inout [String], using rng: inout SplitMix64, alphabet: [String]
    ) -> (text: String, edit: TextEdit) {
        // The byte offset where element `i` begins, summing the UTF-8 widths of all earlier elements.
        func byteOffset(of index: Int) -> Int {
            var offset = 0
            for position in 0..<index { offset += elements[position].utf8.count }
            return offset
        }

        let count = elements.count
        let kind = count == 0 ? 0 : Int.random(in: 0...2, using: &rng)
        let start = count == 0 ? 0 : Int.random(in: 0...count, using: &rng)
        switch kind {
        case 1 where start < count:  // delete a short run of whole elements
            let end = min(count, start + 1 + Int.random(in: 0...2, using: &rng))
            let startByte = byteOffset(of: start)
            let oldEndByte = byteOffset(of: end)
            elements.removeSubrange(start..<end)
            return (
                elements.joined(),
                TextEdit(startByte: startByte, oldEndByte: oldEndByte, newEndByte: startByte)
            )
        case 2 where start < count:  // replace a short run of whole elements
            let end = min(count, start + 1 + Int.random(in: 0...2, using: &rng))
            let inserted = (0...Int.random(in: 0...2, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)!
            }
            let startByte = byteOffset(of: start)
            let oldEndByte = byteOffset(of: end)
            let insertedBytes = inserted.reduce(0) { $0 + $1.utf8.count }
            elements.replaceSubrange(start..<end, with: inserted)
            return (
                elements.joined(),
                TextEdit(
                    startByte: startByte, oldEndByte: oldEndByte,
                    newEndByte: startByte + insertedBytes)
            )
        default:  // insert whole elements
            let inserted = (0...Int.random(in: 0...3, using: &rng)).map { _ in
                alphabet.randomElement(using: &rng)!
            }
            let startByte = byteOffset(of: start)
            let insertedBytes = inserted.reduce(0) { $0 + $1.utf8.count }
            elements.insert(contentsOf: inserted, at: start)
            return (
                elements.joined(),
                TextEdit(
                    startByte: startByte, oldEndByte: startByte,
                    newEndByte: startByte + insertedBytes)
            )
        }
    }

    /// Splits a string into the whole text elements the element-wise fuzzer edits.
    ///
    /// Grapheme granularity edits whole extended grapheme clusters; scalar granularity edits whole Unicode
    /// scalars. Either way each returned element is a non-empty, boundary-aligned slice of `text`, so editing
    /// whole elements always keeps the text valid UTF-8.
    ///
    /// - Parameters:
    ///   - text: The text to split.
    ///   - byScalar: Whether to split into single Unicode scalars rather than grapheme clusters.
    /// - Returns: The whole text elements, in order.
    static func textElements(of text: String, byScalar: Bool) -> [String] {
        if byScalar {
            return text.unicodeScalars.map { String($0) }
        }
        return text.map { String($0) }
    }

    /// Runs an element-wise chained-edit fuzz over one engine, asserting incremental equals full at each step.
    ///
    /// The engine is supplied by the caller so the same property runs unchanged for every granularity: the
    /// helper is generic over the engine's input view, and the only granularity-specific choice is whether
    /// the document is split into scalars or grapheme clusters. The alphabet and seed deliberately carry
    /// multi-byte content (accented Latin, a CJK character and an emoji) so the multi-byte ``glrIndex`` walk
    /// and the byte-coordinate edit accounting are exercised.
    ///
    /// - Parameters:
    ///   - engine: The granularity-specialised engine under test.
    ///   - source: The starting document text.
    ///   - alphabet: The whole elements an edit may introduce, including multi-byte content.
    ///   - byScalar: Whether the document is edited by whole scalars rather than whole grapheme clusters.
    ///   - rngSeed: The deterministic seed.
    ///   - edits: The number of chained edits to apply.
    private func fuzzElements<Input: ParserInput>(
        engine: GLREngine<Input>, seed source: String, alphabet: [String], byScalar: Bool,
        rngSeed: UInt64, edits: Int
    ) {
        var rng = SplitMix64(seed: rngSeed)
        var current = source
        var session = engine.incrementalParse(Source(current))

        #expect(session.result.sExpression() == engine.parse(Source(current)).sExpression())

        var elements = Self.textElements(of: current, byScalar: byScalar)
        for step in 0..<edits {
            let (new, edit) = Self.applyRandomElementEdit(
                &elements, using: &rng, alphabet: alphabet)
            session = session.reparse(Source(new), edits: [edit])
            let full = engine.parse(Source(new))
            expectSessionMatchesFull(
                session, full, text: new,
                context:
                    "seed \(rngSeed) step \(step): \(current.debugDescription) -> \(new.debugDescription)")
            current = new
        }
    }

    /// Multi-byte text elements shared by the scalar and grapheme fuzzers, drawn into JSON string bodies.
    ///
    /// The set deliberately mixes single-byte ASCII, two-byte accented Latin, a three-byte CJK character and
    /// a four-byte emoji so a single edit can change the UTF-8 byte length of the document by one, two, three
    /// or four bytes per element. The emoji is a single scalar (no combining sequence) so it is one element
    /// under both the scalar and grapheme splits, keeping the two fuzzers comparable.
    static let jsonMultiByteAlphabet: [String] = [
        "a", "b", "1", " ", "\u{e9}", "\u{f1}", "\u{fc}", "\u{4e2d}", "\u{6587}", "\u{1f389}", "x", "0",
    ]

    /// Multi-byte text elements for the Lua fuzzer, kept to identifier-safe and operator characters.
    static let luaMultiByteAlphabet: [String] = [
        "a", "b", "x", "1", " ", "=", "+", "\u{e9}", "\u{fc}", "\u{4e2d}", "\u{1f389}", "\n",
    ]

    @Test(
        "Scalar-granularity chained edits with multi-byte JSON content stay byte-identical to a full parse",
        arguments: 0..<4)
    func jsonScalarMultiByteFuzz(_ seed: Int) throws {
        let engine = try ScalarGLRParser(grammar: JSONGrammar.grammar())
        fuzzElements(
            engine: engine,
            seed: #"{"name": "caf\#u{e9}", "tags": ["\#u{4e2d}\#u{6587}", "\#u{1f389}"], "n": 12}"#,
            alphabet: Self.jsonMultiByteAlphabet, byScalar: true,
            rngSeed: UInt64(seed) &* 0x51ED_2701 &+ 11, edits: 30)
    }

    @Test(
        "Grapheme-granularity chained edits with multi-byte JSON content stay byte-identical to a full parse",
        arguments: 0..<3)
    func jsonGraphemeMultiByteFuzz(_ seed: Int) throws {
        let engine = try GraphemeGLRParser(grammar: JSONGrammar.grammar())
        fuzzElements(
            engine: engine,
            seed: #"{"name": "caf\#u{e9}", "tags": ["\#u{4e2d}\#u{6587}", "\#u{1f389}"], "n": 12}"#,
            alphabet: Self.jsonMultiByteAlphabet, byScalar: false,
            rngSeed: UInt64(seed) &* 0x9E37_BEEF &+ 13, edits: 25)
    }

    @Test(
        "Scalar-granularity chained edits with multi-byte Lua content stay byte-identical to a full parse",
        arguments: 0..<4)
    func luaScalarMultiByteFuzz(_ seed: Int) throws {
        let engine = try ScalarGLRParser(grammar: LuaGrammar.chunk())
        fuzzElements(
            engine: engine,
            seed: "local a = \"caf\u{e9}\"\nlocal b = \"\u{4e2d}\u{6587}\"\nlocal c = a\n",
            alphabet: Self.luaMultiByteAlphabet, byScalar: true,
            rngSeed: UInt64(seed) &* 0x1234_5677 &+ 17, edits: 30)
    }

    @Test(
        "Grapheme-granularity chained edits with multi-byte Lua content stay byte-identical to a full parse",
        arguments: 0..<3)
    func luaGraphemeMultiByteFuzz(_ seed: Int) throws {
        let engine = try GraphemeGLRParser(grammar: LuaGrammar.chunk())
        fuzzElements(
            engine: engine,
            seed: "local a = \"caf\u{e9}\"\nlocal b = \"\u{4e2d}\u{6587}\"\nlocal c = a\n",
            alphabet: Self.luaMultiByteAlphabet, byScalar: false,
            rngSeed: UInt64(seed) &* 0xDEAD_C0DE &+ 19, edits: 22)
    }

    @Test("Grapheme-granularity chained edits with multi-byte C content stay byte-identical to a full parse")
    func cGraphemeMultiByteFuzz() throws {
        // The C case is kept light: a single short chain confirms the multi-byte index walk holds for the
        // grapheme view on this grammar too, without dominating the suite's run time.
        let engine = try GraphemeGLRParser(grammar: CGrammar.translationUnit())
        fuzzElements(
            engine: engine,
            seed: "int main(void) {\n  int x = 1;\n  return x;\n}\n",
            alphabet: ["a", "x", "1", " ", "+", ";", "\u{4e2d}", "\u{1f389}", "\n"], byScalar: false,
            rngSeed: 0x00C0_FFEE, edits: 18)
    }

    // MARK: - Multi-edit reparse (several disjoint edits per reparse call)

    /// Applies 2 to 4 non-overlapping edits to an ASCII byte buffer in one batch, returning the new text and
    /// all the edits to pass to a single ``IncrementalGLRParser/reparse(_:edits:)`` call.
    ///
    /// The edits are chosen as disjoint regions and then applied to the buffer in descending start order so
    /// earlier offsets stay valid while later ones are rewritten. Crucially each ``TextEdit`` is constructed
    /// in the original-text byte coordinates of its own region, before any sibling edit shifts the buffer:
    /// because the regions are disjoint, the minimum start offset across the batch is the true first changed
    /// byte, which is exactly what the engine derives the reuse boundary from.
    ///
    /// - Parameters:
    ///   - bytes: The current text as a UTF-8 byte buffer, mutated in place.
    ///   - rng: The deterministic generator.
    ///   - alphabet: The bytes an insertion or replacement may introduce.
    /// - Returns: The new text and the batch of disjoint edits in original-text byte coordinates.
    static func applyRandomMultiEdit(
        _ bytes: inout [UInt8], using rng: inout SplitMix64, alphabet: [UInt8]
    ) -> (text: String, edits: [TextEdit]) {
        let count = bytes.count
        // With too little text to carve disjoint regions, fall back to a single edit.
        if count < 8 {
            let (text, edit) = applyRandomEdit(&bytes, using: &rng, alphabet: alphabet)
            return (text, [edit])
        }

        let editCount = Int.random(in: 2...4, using: &rng)
        // Partition the buffer into `editCount` slots and place one edit region inside each, so the regions
        // are guaranteed disjoint regardless of how the random offsets fall.
        let slot = count / editCount
        var planned: [(start: Int, end: Int, inserted: [UInt8])] = []
        for index in 0..<editCount {
            let slotStart = index * slot
            let slotEnd = (index == editCount - 1) ? count : (index + 1) * slot
            guard slotEnd > slotStart else { continue }
            let start = Int.random(in: slotStart..<slotEnd, using: &rng)
            // Each region stays strictly within its slot, so no two regions can touch or overlap.
            let maxRun = max(0, slotEnd - start - 1)
            let kind = Int.random(in: 0...2, using: &rng)
            let runLength: Int
            switch kind {
            case 0: runLength = 0  // insert
            default: runLength = maxRun == 0 ? 0 : min(maxRun, 1 + Int.random(in: 0...2, using: &rng))
            }
            let end = start + runLength
            // An insert (run length zero) or a replace introduces fresh bytes; a delete introduces none.
            let inserted: [UInt8]
            if kind == 1 && runLength > 0 {
                inserted = []  // delete
            } else {
                inserted = (0...Int.random(in: 0...2, using: &rng)).map { _ in
                    alphabet.randomElement(using: &rng)!
                }
            }
            planned.append((start: start, end: end, inserted: inserted))
        }

        // Build the edits in original coordinates, then apply to the buffer in descending start order.
        let edits = planned.map {
            TextEdit(
                startByte: $0.start, oldEndByte: $0.end, newEndByte: $0.start + $0.inserted.count)
        }
        for region in planned.sorted(by: { $0.start > $1.start }) {
            bytes.replaceSubrange(region.start..<region.end, with: region.inserted)
        }
        return (String(decoding: bytes, as: UTF8.self), edits)
    }

    /// Runs a chained multi-edit fuzz over one grammar, passing 2 to 4 disjoint edits per reparse call.
    private func fuzzMultiEdit(
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
            let (new, batch) = Self.applyRandomMultiEdit(&buffer, using: &rng, alphabet: alphabetBytes)
            session = session.reparse(Source(new), edits: batch)
            let full = engine.parse(Source(new))
            expectSessionMatchesFull(
                session, full, text: new,
                context:
                    "seed \(rngSeed) step \(step) (\(batch.count) edits): \(current.debugDescription) -> \(new.debugDescription)")
            current = new
        }
    }

    @Test(
        "Batched disjoint edits on JSON keep the session byte-identical to a full parse",
        arguments: 0..<5)
    func jsonMultiEditFuzz(_ seed: Int) throws {
        try fuzzMultiEdit(
            grammar: JSONGrammar.grammar(),
            seed: #"{"a": 1, "b": [true, false, null], "c": {"d": 2.5}, "e": [0, 1, 2, 3]}"#,
            alphabet: #"{}[]:,"abcd0123.- tfnaeulrs"#,
            rngSeed: UInt64(seed) &* 0x2C9E_7D01 &+ 23, edits: 35)
    }

    @Test(
        "Batched disjoint edits on Lua keep the session byte-identical to a full parse",
        arguments: 0..<5)
    func luaMultiEditFuzz(_ seed: Int) throws {
        try fuzzMultiEdit(
            grammar: LuaGrammar.chunk(),
            seed:
                "local a = 1\nlocal b = 2\nfunction f(x) return x + 1 end\nif a then b = 3 end\nlocal c = a + b\n",
            alphabet: "abcdefxy =0123\n()+-*localfunctionifthenendreturlocal",
            rngSeed: UInt64(seed) &* 0x7F4A_7C15 &+ 29, edits: 35)
    }
}
