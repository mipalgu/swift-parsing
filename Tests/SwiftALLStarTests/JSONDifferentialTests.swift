import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent

@testable import SwiftALLStar

@Suite("Valid JSON S-expressions")
struct ValidJSONTests {
    @Test("Object with string key and number value")
    func object() throws {
        let result = try parseAllStar(#"{ "a": 1 }"#)
        #expect(!result.hasErrors)
        #expect(result.sExpression()
            == "(document (object (pair key: (string (string_content)) value: (number))))")
    }

    @Test("Array of values")
    func array() throws {
        let result = try parseAllStar(#"[1, "x", true, null]"#)
        #expect(!result.hasErrors)
        #expect(result.sExpression()
            == "(document (array (number) (string (string_content)) (true) (null)))")
    }

    @Test("Empty object and array")
    func empties() throws {
        #expect(try parseAllStar("{}").sExpression() == "(document (object))")
        #expect(try parseAllStar("[]").sExpression() == "(document (array))")
    }

    @Test("Nested structure")
    func nested() throws {
        let result = try parseAllStar(#"{"o": {"a": [1, 2]}}"#)
        #expect(result.sExpression() == """
            (document (object (pair key: (string (string_content)) \
            value: (object (pair key: (string (string_content)) \
            value: (array (number) (number)))))))
            """)
    }

    @Test("Bare literals")
    func bareLiterals() throws {
        #expect(try parseAllStar("true").sExpression() == "(document (true))")
        #expect(try parseAllStar("false").sExpression() == "(document (false))")
        #expect(try parseAllStar("null").sExpression() == "(document (null))")
    }

    @Test("Numbers: negatives, decimals and exponents", arguments: ["0", "-1", "3.14", "-2.5e10", "1E+9", "10"])
    func numbers(_ literal: String) throws {
        let result = try parseAllStar(literal)
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(document (number))")
    }
}

@Suite("Cross-engine differential")
struct DifferentialTests {
    /// Every corpus input must produce a byte-identical S-expression to the recursive-descent reference,
    /// and must round-trip losslessly to its source text.
    @Test("ALL(*) agrees with the reference and round-trips", arguments: Corpus.json)
    func agreesWithReference(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let reference = try UTF8Parser(grammar: grammar).parse(Source(input))
        let allStar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))
        #expect(allStar.sExpression() == reference.sExpression())
        #expect(allStar.tree.green.reconstructedText == input)
    }
}
