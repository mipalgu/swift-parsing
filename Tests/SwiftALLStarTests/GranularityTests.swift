import Testing

import ParsingCore
import ParsingDSL

@testable import SwiftALLStar

@Suite("Input granularity")
struct GranularityTests {
    /// The same JSON produces the same tree at every granularity, including multibyte/composite input.
    @Test("All granularities agree and round-trip", arguments: [
        #"{ "a": 1 }"#,
        #"["é", "🇦🇺", true]"#,
        #"{"key": "naïve café"}"#,
        #"{"o": {"a": [1, 2]}}"#,
    ])
    func granularitiesAgree(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let utf8 = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))
        let scalar = try ALLStarScalarParser(grammar: grammar).parse(Source(input))
        let grapheme = try ALLStarGraphemeParser(grammar: grammar).parse(Source(input))
        #expect(utf8.sExpression() == scalar.sExpression())
        #expect(scalar.sExpression() == grapheme.sExpression())
        #expect(utf8.tree.green.reconstructedText == input)
        #expect(scalar.tree.green.reconstructedText == input)
        #expect(grapheme.tree.green.reconstructedText == input)
    }

    @Test("Every granularity still agrees with the reference engine", arguments: [
        #"["é", "🇦🇺", true]"#,
        #"{"key": "naïve café"}"#,
    ])
    func granularitiesMatchReference(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let reference = try parseReference(input).sExpression()
        #expect(try ALLStarUTF8Parser(grammar: grammar).parse(Source(input)).sExpression() == reference)
        #expect(try ALLStarScalarParser(grammar: grammar).parse(Source(input)).sExpression() == reference)
        #expect(try ALLStarGraphemeParser(grammar: grammar).parse(Source(input)).sExpression() == reference)
    }
}
