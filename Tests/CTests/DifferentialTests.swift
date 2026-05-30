import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// The three-engine differential contract for the structural C grammar.
///
/// For every structural corpus input the GLR and ALL(*) engines must produce a byte-identical canonical
/// S-expression to the recursive-descent reference engine, and every engine's tree must round-trip
/// losslessly to the source. Multibyte inputs additionally agree across the UTF-8, scalar, and grapheme
/// granularities. This is the headline acceptance gate: it proves the framework parses a real, deeply
/// nested language identically on all three native engines.
@Suite("C three-engine differential")
struct CDifferentialTests {
    @Test("GLR and ALL(*) agree with recursive descent on the structural corpus", arguments: Corpus.structural)
    func threeEngineAgreement(_ input: String) throws {
        let grammar = CGrammar.translationUnit()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))

        #expect(!rd.hasErrors, "reference engine should accept: \(input)")
        #expect(glr.sExpression() == rd.sExpression(), "GLR vs RD on: \(input)")
        #expect(allstar.sExpression() == rd.sExpression(), "ALL(*) vs RD on: \(input)")
        #expect(rd.tree.green.reconstructedText == input)
        #expect(glr.tree.green.reconstructedText == input)
        #expect(allstar.tree.green.reconstructedText == input)
    }

    @Test("All three GLR granularities agree on multibyte inputs", arguments: Corpus.multibyte)
    func granularityAgreement(_ input: String) throws {
        let grammar = CGrammar.translationUnit()
        let utf8 = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let scalar = try ScalarGLRParser(grammar: grammar).parse(Source(input))
        let grapheme = try GraphemeGLRParser(grammar: grammar).parse(Source(input))

        #expect(utf8.sExpression() == scalar.sExpression(), "UTF-8 vs scalar on: \(input)")
        #expect(scalar.sExpression() == grapheme.sExpression(), "scalar vs grapheme on: \(input)")
        #expect(utf8.tree.green.reconstructedText == input)
        #expect(scalar.tree.green.reconstructedText == input)
        #expect(grapheme.tree.green.reconstructedText == input)
    }

    @Test(
        "All three recursive-descent granularities agree with one another on multibyte inputs",
        arguments: Corpus.multibyte)
    func recursiveDescentGranularityAgreement(_ input: String) throws {
        let grammar = CGrammar.translationUnit()
        let utf8 = try UTF8Parser(grammar: grammar).parse(Source(input))
        let scalar = try ScalarParser(grammar: grammar).parse(Source(input))
        let grapheme = try GraphemeParser(grammar: grammar).parse(Source(input))

        #expect(utf8.sExpression() == scalar.sExpression(), "UTF-8 vs scalar on: \(input)")
        #expect(scalar.sExpression() == grapheme.sExpression(), "scalar vs grapheme on: \(input)")
        #expect(utf8.tree.green.reconstructedText == input)
    }
}
