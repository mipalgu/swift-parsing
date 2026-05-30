import Testing

import ParsingCore
import ParsingDSL
@testable import SwiftGLR

/// Parses JSON with the UTF-8 GLR engine and returns the result.
private func parseJSON(_ text: String) throws -> ParseResult {
    let engine = try UTF8GLRParser(grammar: JSONGrammar.grammar())
    return engine.parse(Source(text))
}

@Suite("GLR engine metadata")
struct MetadataTests {
    @Test("Identifiers are derived per granularity")
    func identifiers() {
        #expect(UTF8GLRParser.identifier == "glr-utf8")
        #expect(ScalarGLRParser.identifier == "glr-scalar")
        #expect(GraphemeGLRParser.identifier == "glr-grapheme")
    }

    @Test("Capabilities include lossless, error recovery and ambiguity")
    func capabilities() {
        #expect(UTF8GLRParser.capabilities.contains(.lossless))
        #expect(UTF8GLRParser.capabilities.contains(.errorRecovering))
        #expect(UTF8GLRParser.capabilities.contains(.ambiguous))
    }

    @Test("An undefined start rule is rejected at construction")
    func undefinedStart() {
        let grammar = Grammar(name: "g", startRule: "missing", rules: ["s": .literal("a")])
        #expect(throws: GrammarError.undefinedStartRule("missing")) {
            _ = try UTF8GLRParser(grammar: grammar)
        }
    }
}

@Suite("GLR valid JSON")
struct ValidJSONTests {
    @Test("Object with string key and number value")
    func object() throws {
        let result = try parseJSON(#"{ "a": 1 }"#)
        #expect(!result.hasErrors)
        #expect(result.sExpression()
            == "(document (object (pair key: (string (string_content)) value: (number))))")
    }

    @Test("Array of values")
    func array() throws {
        let result = try parseJSON(#"[1, "x", true, null]"#)
        #expect(!result.hasErrors)
        #expect(result.sExpression()
            == "(document (array (number) (string (string_content)) (true) (null)))")
    }

    @Test("Empty object and array")
    func empties() throws {
        #expect(try parseJSON("{}").sExpression() == "(document (object))")
        #expect(try parseJSON("[]").sExpression() == "(document (array))")
    }

    @Test("Nested structure")
    func nested() throws {
        let result = try parseJSON(#"{"o": {"a": [1, 2]}}"#)
        #expect(result.sExpression() == """
            (document (object (pair key: (string (string_content)) \
            value: (object (pair key: (string (string_content)) \
            value: (array (number) (number)))))))
            """)
    }

    @Test("Bare literals")
    func bareLiterals() throws {
        #expect(try parseJSON("true").sExpression() == "(document (true))")
        #expect(try parseJSON("false").sExpression() == "(document (false))")
        #expect(try parseJSON("null").sExpression() == "(document (null))")
    }

    @Test(
        "Numbers: negatives, decimals and exponents",
        arguments: ["0", "-1", "3.14", "-2.5e10", "1E+9", "10"])
    func numbers(_ literal: String) throws {
        let result = try parseJSON(literal)
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(document (number))")
    }
}

@Suite("GLR losslessness")
struct LosslessnessTests {
    @Test(
        "Reconstructed text equals input",
        arguments: [
            #"{ "a": 1 }"#, "  [1,2,3]  ", "{}", "\n\ttrue\n",
            #"{"nested": {"x": [true, false, null]}}"#, "   ", "garbage",
        ])
    func roundTrip(_ input: String) throws {
        #expect(try parseJSON(input).tree.green.reconstructedText == input)
    }
}

@Suite("GLR error recovery")
struct ErrorRecoveryTests {
    @Test("Trailing junk becomes an ERROR node")
    func trailingJunk() throws {
        let result = try parseJSON("true false")
        #expect(result.hasErrors)
        #expect(result.sExpression().hasPrefix("(document (true)"))
        #expect(result.sExpression().contains("(ERROR"))
        #expect(result.tree.green.reconstructedText == "true false")
    }

    @Test("Completely unparseable input yields a MISSING node")
    func totallyInvalid() throws {
        let result = try parseJSON("@@@")
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
        #expect(result.tree.green.reconstructedText == "@@@")
    }

    @Test("Empty input recovers")
    func empty() throws {
        let result = try parseJSON("")
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
        #expect(result.tree.green.reconstructedText == "")
    }

    @Test("Whitespace-only input recovers and is lossless")
    func whitespace() throws {
        let result = try parseJSON("   \n  ")
        #expect(result.hasErrors)
        #expect(result.tree.green.reconstructedText == "   \n  ")
    }

    @Test("Diagnostics carry a source span")
    func diagnosticSpans() throws {
        let diagnostics = try parseJSON("true false").diagnostics
        #expect(!diagnostics.isEmpty)
        #expect(diagnostics[0].severity == .error)
        #expect(diagnostics[0].span.start >= 0)
    }
}

@Suite("GLR matcher interpretation")
struct MatcherTests {
    private func parse(_ grammar: Grammar, _ text: String) throws -> ParseResult {
        try UTF8GLRParser(grammar: grammar).parse(Source(text))
    }

    @Test("Ranges, builtins, alternation, repetition and anyElement")
    func richMatchers() throws {
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: [
                "s": .sequence([
                    .token(name: "letter", matcher: Match.range("a", "z"), isNamed: true),
                    .token(name: "digits", matcher: Match.oneOrMore(Match.digit), isNamed: true),
                    .token(name: "bounded", matcher: .repeated(min: 2, max: 3, Match.lit("!")), isNamed: true),
                    .token(name: "notbang", matcher: Match.not(Match.lit("!")), isNamed: true),
                    .token(name: "anything", matcher: Match.any, isNamed: true),
                    .token(name: "kw", matcher: Match.oneOf(Match.lit("yes"), Match.lit("no")), isNamed: true),
                ])
            ])
        let result = try parse(grammar, "a12!!xZyes")
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(s (letter) (digits) (bounded) (notbang) (anything) (kw))")
        #expect(result.tree.green.reconstructedText == "a12!!xZyes")
    }

    @Test("hexDigit and letter built-in classes")
    func hexAndLetter() throws {
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: [
                "s": .sequence([
                    .token(name: "hex", matcher: Match.oneOrMore(Match.hexDigit), isNamed: true),
                    .token(name: "word", matcher: Match.oneOrMore(Match.letter), isNamed: true),
                ])
            ], extras: [])
        let result = try parse(grammar, "1aF3Zebra")
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(s (hex) (word))")
    }

    @Test("repeat1 with no match recovers")
    func repeatOneOrMoreNoMatch() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: ["s": .repeatOneOrMore(.literal("c"))])
        let result = try parse(grammar, "x")
        #expect(result.hasErrors)
        #expect(result.tree.green.reconstructedText == "x")
    }

    @Test("Multi-child field, precedence and zero-width repetition")
    func structuralForms() throws {
        let grammar = Grammar(
            name: "g", startRule: "s",
            rules: [
                "s": .sequence([
                    .field("pair", .sequence([.literal("a"), .literal("b")])),
                    .precedence(level: 1, associativity: .left, .literal("c")),
                    .repeatZeroOrMore(.optional(.literal("x"))),
                ])
            ])
        let result = try parse(grammar, "abc")
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "abc")
    }

    @Test("Reference to an undefined rule recovers via MISSING")
    func danglingReference() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: ["s": .reference("nope")])
        let result = try parse(grammar, "x")
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
    }
}
