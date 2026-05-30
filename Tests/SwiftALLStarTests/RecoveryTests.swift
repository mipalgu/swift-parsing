import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent

@testable import SwiftALLStar

@Suite("Losslessness")
struct LosslessnessTests {
    @Test("Reconstructed text equals input", arguments: [
        #"{ "a": 1 }"#, "  [1,2,3]  ", "{}", "\n\ttrue\n",
        #"{"nested": {"x": [true, false, null]}}"#, "   ", "garbage",
    ])
    func roundTrip(_ input: String) throws {
        #expect(try parseAllStar(input).tree.green.reconstructedText == input)
    }
}

@Suite("Error recovery")
struct ErrorRecoveryTests {
    @Test("Trailing junk becomes an ERROR node")
    func trailingJunk() throws {
        let result = try parseAllStar("true false")
        #expect(result.hasErrors)
        #expect(result.sExpression().hasPrefix("(document (true)"))
        #expect(result.sExpression().contains("(ERROR"))
        #expect(result.tree.green.reconstructedText == "true false")
    }

    @Test("Completely unparseable input yields a MISSING node")
    func totallyInvalid() throws {
        let result = try parseAllStar("@@@")
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
        #expect(result.tree.green.reconstructedText == "@@@")
    }

    @Test("Empty input recovers")
    func empty() throws {
        let result = try parseAllStar("")
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
        #expect(result.tree.green.reconstructedText == "")
    }

    @Test("Whitespace-only input recovers and is lossless")
    func whitespace() throws {
        let result = try parseAllStar("   \n  ")
        #expect(result.hasErrors)
        #expect(result.tree.green.reconstructedText == "   \n  ")
    }

    @Test("Diagnostics carry a source span")
    func diagnosticSpans() throws {
        let diagnostics = try parseAllStar("true false").diagnostics
        #expect(!diagnostics.isEmpty)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].span.start >= 0)
    }

    @Test("Recovery output matches the reference engine on malformed input", arguments: [
        "true false", "@@@", "", "   \n  ",
    ])
    func recoveryMatchesReference(_ input: String) throws {
        #expect(try parseAllStar(input).sExpression() == parseReference(input).sExpression())
    }

    @Test("A reference to an undefined rule recovers via MISSING")
    func danglingReference() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: ["s": .reference("nope")])
        let result = try ALLStarUTF8Parser(grammar: grammar).parse(Source("x"))
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
    }
}
