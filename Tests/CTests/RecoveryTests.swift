import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// Error-recovery coverage for the structural C grammar.
///
/// Malformed inputs must be flagged with an error yet still round-trip losslessly: the engines never
/// discard input, so the consumed text is always reconstructable even when the parse fails. A small set of
/// malformed inputs is additionally checked for agreement on the error flag across all three engines.
@Suite("C error recovery")
struct CRecoveryTests {
    /// Malformed C inputs that must be flagged as errors while still round-tripping.
    static let malformed: [String] = [
        "int x =",
        "int x = ;",
        "int f(void) {",
        "int f(void) { return }",
        "if (x) {}",
        "int = 1;",
        "int x = 1",
        "int f(void) { return 1 + ; }",
        "@@@",
        "int 3 = x;",
        "void f() { for (;) {} }",
        "int x = (int);",
        "}",
    ]

    @Test("Malformed input is flagged with an error yet round-trips losslessly", arguments: malformed)
    func recoversAndRoundTrips(_ input: String) throws {
        let result = try UTF8Parser(grammar: CGrammar.translationUnit()).parse(Source(input))
        #expect(result.hasErrors, "should flag an error: \(input.debugDescription)")
        #expect(result.tree.green.reconstructedText == input, "should round-trip: \(input.debugDescription)")
    }

    @Test(
        "All three engines recover malformed input, ALL(*) byte-identically to the reference",
        arguments: ["int x =", "int f(void) {", "@@@", "int = 1;"])
    func threeEngineRecoveryAgreement(_ input: String) throws {
        let grammar = CGrammar.translationUnit()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))

        // Every engine flags the error and round-trips the input losslessly. ALL(*) recovery additionally
        // reconstructs the reference engine's longest-valid-prefix tree exactly, so it joins the differential
        // contract on malformed input as it already does on well-formed input. GLR recovers losslessly but
        // along its own forest, so only its error flag and round-trip are pinned here.
        #expect(rd.hasErrors)
        #expect(glr.hasErrors == rd.hasErrors, "GLR error flag for: \(input.debugDescription)")
        #expect(allstar.hasErrors == rd.hasErrors, "ALL(*) error flag for: \(input.debugDescription)")
        #expect(allstar.sExpression() == rd.sExpression(), "ALL(*) vs RD on: \(input.debugDescription)")
        #expect(rd.tree.green.reconstructedText == input)
        #expect(glr.tree.green.reconstructedText == input)
        #expect(allstar.tree.green.reconstructedText == input, "ALL(*) round-trip for: \(input.debugDescription)")
    }

    @Test("A valid prefix followed by garbage round-trips the whole input")
    func validPrefixThenGarbage() throws {
        let input = "int x = 1; @@@ garbage"
        let result = try UTF8Parser(grammar: CGrammar.translationUnit()).parse(Source(input))
        #expect(result.hasErrors)
        #expect(result.tree.green.reconstructedText == input)
    }
}
