import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// Regression coverage for a `void`-typed pointer parameter such as `void f(void *p)`.
///
/// A bare `void` once headed an ordered choice in the `parameter_list` rule as the explicitly-empty-list
/// marker, ahead of the general parameter-declaration alternative. The greedy recursive-descent engine
/// committed to that bare `void` keyword on the `void` of `void *p`, then failed at the unexpected `*p`,
/// rejecting valid input that the exploratory GLR and ALL(*) engines accepted: a genuine three-engine
/// divergence on in-scope C. The `parameter_list` rule now has a single production, so a lone `void`,
/// `void *p`, and `void **pp` all parse uniformly as parameter declarations and the three engines agree on
/// a byte-identical tree that round-trips losslessly.
@Suite("C void-pointer parameter regression")
struct CVoidPointerParameterTests {
    /// Inputs that previously diverged across the three engines, plus the canonical `(void)` cases that must
    /// keep parsing after the rule simplification.
    static let cases: [String] = [
        "void f(void *p) { }",
        "void f(void **pp) { }",
        "void f(void *const *pp) { }",
        "void g(int x, void *p) { return; }",
        "int main(void) { return 0; }",
    ]

    @Test(
        "A void-pointer parameter parses byte-identically and losslessly on all three engines",
        arguments: cases)
    func threeEngineAgreement(_ input: String) throws {
        let grammar = CGrammar.translationUnit()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))

        #expect(!rd.hasErrors, "recursive descent should accept: \(input)")
        #expect(!glr.hasErrors, "GLR should accept: \(input)")
        #expect(!allstar.hasErrors, "ALL(*) should accept: \(input)")
        #expect(glr.sExpression() == rd.sExpression(), "GLR vs RD on: \(input)")
        #expect(allstar.sExpression() == rd.sExpression(), "ALL(*) vs RD on: \(input)")
        #expect(rd.tree.green.reconstructedText == input)
        #expect(glr.tree.green.reconstructedText == input)
        #expect(allstar.tree.green.reconstructedText == input)
    }
}
