import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent
@testable import SwiftGLR

/// The differential contract: for an unambiguous grammar and any input the GLR engine's canonical
/// S-expression must be byte-identical to the recursive-descent reference, and its tree must round-trip
/// losslessly to the source. This is the acceptance gate the engine is built to satisfy.
@Suite("Differential agreement with the reference engine")
struct DifferentialTests {
    /// The shared 16-input JSON corpus the native and tree-sitter engines already agree on.
    static let corpus: [String] = [
        "true", "false", "null", "42", "-3.14", "1e9",
        #""hello""#,
        "{}", "[]",
        #"{ "a": 1 }"#,
        #"[1, 2, 3]"#,
        #"[true, false, null]"#,
        #"{ "name": "Ada", "age": 42 }"#,
        #"{ "nested": { "x": [1, 2], "y": "z" } }"#,
        "  [ 1 , 2 ]  ",
        #"{"a":{"b":{"c":[1,[2,[3]]]}}}"#,
    ]

    @Test("UTF-8 GLR equals UTF-8 recursive descent on the corpus", arguments: corpus)
    func utf8Differential(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        #expect(glr.sExpression() == rd.sExpression(), "input \(input)")
        #expect(glr.tree.green.reconstructedText == input)
        #expect(!glr.hasErrors)
    }

    @Test("Scalar GLR equals scalar recursive descent on the corpus", arguments: corpus)
    func scalarDifferential(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let glr = try ScalarGLRParser(grammar: grammar).parse(Source(input))
        let rd = try ScalarParser(grammar: grammar).parse(Source(input))
        #expect(glr.sExpression() == rd.sExpression(), "input \(input)")
        #expect(glr.tree.green.reconstructedText == input)
    }

    @Test("Grapheme GLR equals grapheme recursive descent on the corpus", arguments: corpus)
    func graphemeDifferential(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let glr = try GraphemeGLRParser(grammar: grammar).parse(Source(input))
        let rd = try GraphemeParser(grammar: grammar).parse(Source(input))
        #expect(glr.sExpression() == rd.sExpression(), "input \(input)")
        #expect(glr.tree.green.reconstructedText == input)
    }

    @Test(
        "All three GLR granularities agree with one another",
        arguments: [#"{ "a": 1 }"#, #"["é", "🇦🇺", true]"#, #"{"key": "naïve café"}"#])
    func granularitiesAgree(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let utf8 = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let scalar = try ScalarGLRParser(grammar: grammar).parse(Source(input))
        let grapheme = try GraphemeGLRParser(grammar: grammar).parse(Source(input))
        #expect(utf8.sExpression() == scalar.sExpression())
        #expect(scalar.sExpression() == grapheme.sExpression())
        #expect(utf8.tree.green.reconstructedText == input)
        #expect(scalar.tree.green.reconstructedText == input)
        #expect(grapheme.tree.green.reconstructedText == input)
    }

    @Test(
        "GLR and recursive descent recover identically on malformed input",
        arguments: ["true false", "@@@", "", "   ", "  \n  ", "[1,", #"{"a":}"#, "garbage"])
    func errorDifferential(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        #expect(glr.tree.green.reconstructedText == input)
        #expect(rd.tree.green.reconstructedText == input)
        #expect(glr.hasErrors == rd.hasErrors)
    }
}
