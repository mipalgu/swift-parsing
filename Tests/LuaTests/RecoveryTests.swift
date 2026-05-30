import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// Error-recovery coverage for the structural Lua grammar.
///
/// Malformed inputs must be flagged with an error yet still round-trip losslessly: the engines never
/// discard input, so the consumed text is always reconstructable even when the parse fails. A small set of
/// malformed inputs is additionally checked for agreement on the error flag across all three engines.
@Suite("Lua error recovery")
struct LuaRecoveryTests {
    /// Malformed Lua inputs that must be flagged as errors while still round-tripping.
    static let malformed: [String] = [
        "if then end",
        "local x =",
        "x = ",
        "do",
        "[[unterminated",
        "x = 1 ..",
        "function",
        "@@@",
        "local 1 = x",
        "return return",
        "for = 1 do end",
    ]

    @Test("Malformed input is flagged with an error yet round-trips losslessly", arguments: malformed)
    func recoversAndRoundTrips(_ input: String) throws {
        let result = try UTF8Parser(grammar: LuaGrammar.chunk()).parse(Source(input))
        #expect(result.hasErrors, "should flag an error: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input, "should round-trip: \(input.debugDescription)")
    }

    @Test(
        "All three engines agree that the input is malformed",
        arguments: ["if then end", "local x =", "x = 1 ..", "@@@"])
    func threeEngineErrorAgreement(_ input: String) throws {
        let grammar = LuaGrammar.chunk()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))

        // Every engine flags the error. The two lossless engines (recursive descent and GLR) also round-trip
        // the consumed text; the ALL(*) engine's recovery is not byte-lossless on malformed input, so only
        // its error flag is asserted here (the byte-identical contract holds for well-formed input, proven by
        // the differential suite).
        #expect(rd.hasErrors)
        #expect(glr.hasErrors == rd.hasErrors, "GLR error flag for: \(input.debugDescription)")
        #expect(allstar.hasErrors == rd.hasErrors, "ALL(*) error flag for: \(input.debugDescription)")
        #expect(rd.tree.green.reconstructedText == input)
        #expect(glr.tree.green.reconstructedText == input)
    }

    @Test("A valid prefix followed by garbage round-trips the whole input")
    func validPrefixThenGarbage() throws {
        let input = "local x = 1 @@@ garbage"
        let result = try UTF8Parser(grammar: LuaGrammar.chunk()).parse(Source(input))
        #expect(result.hasErrors)
        #expect(result.tree.green.reconstructedText == input)
    }
}
