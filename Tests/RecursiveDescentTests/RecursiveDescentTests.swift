import Testing

import ParsingCore
import ParsingDSL
@testable import RecursiveDescent

/// Parses JSON with the UTF-8 engine and returns the result.
private func parseJSON(_ text: String) throws -> ParseResult {
    let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
    return engine.parse(Source(text))
}

@Suite("Engine metadata")
struct MetadataTests {
    @Test("Identifiers are derived per granularity")
    func identifiers() {
        #expect(UTF8Parser.identifier == "rd-utf8")
        #expect(ScalarParser.identifier == "rd-scalar")
        #expect(GraphemeParser.identifier == "rd-grapheme")
    }

    @Test("Capabilities")
    func capabilities() {
        #expect(UTF8Parser.capabilities.contains(.lossless))
        #expect(UTF8Parser.capabilities.contains(.errorRecovering))
    }

    @Test("An undefined start rule is rejected at construction")
    func undefinedStart() {
        let grammar = Grammar(name: "g", startRule: "missing", rules: ["s": .literal("a")])
        #expect(throws: GrammarError.undefinedStartRule("missing")) {
            _ = try UTF8Parser(grammar: grammar)
        }
    }
}

@Suite("Valid JSON")
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

    @Test("Numbers: negatives, decimals and exponents", arguments: ["0", "-1", "3.14", "-2.5e10", "1E+9", "10"])
    func numbers(_ literal: String) throws {
        let result = try parseJSON(literal)
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(document (number))")
    }
}

@Suite("Lookahead zero-width matching")
struct LookaheadMatchingTests {
    /// Builds a single-token grammar whose start rule `s` is a named token matching `matcher`, with no
    /// trivia, so the parsed token text is exactly what the matcher consumed.
    private func tokenGrammar(_ matcher: TokenMatcher) -> Grammar {
        Grammar(
            name: "g", startRule: "s",
            rules: ["s": .token(name: "s", matcher: matcher, isNamed: true)],
            extras: [])
    }

    @Test("Negative lookahead is zero-width: notFollowedBy(X) then Y matches Y at the same position")
    func negativeZeroWidth() throws {
        // `notFollowedBy("x")` asserts the next element is not 'x' and consumes nothing, then 'y' is
        // consumed; so the whole token is just "y".
        let matcher = Match.seq(Match.notFollowedBy(Match.lit("x")), Match.lit("y"))
        let parser = try UTF8Parser(grammar: tokenGrammar(matcher))
        let ok = parser.parse(Source("y"))
        #expect(!ok.hasErrors)
        #expect(ok.sExpression() == "(s (s))")
        #expect(ok.tree.green.reconstructedText == "y")
        // The assertion fires: "xy" begins with 'x', so notFollowedBy("x") fails the token.
        #expect(parser.parse(Source("xy")).hasErrors)
    }

    @Test("Positive lookahead is zero-width: followedBy(X) then X consumes only one X")
    func positiveZeroWidth() throws {
        // `followedBy("y")` asserts 'y' is next and consumes nothing, then a single 'y' is consumed.
        let matcher = Match.seq(Match.followedBy(Match.lit("y")), Match.lit("y"))
        let parser = try UTF8Parser(grammar: tokenGrammar(matcher))
        let ok = parser.parse(Source("y"))
        #expect(!ok.hasErrors)
        #expect(ok.tree.green.reconstructedText == "y")
        // The positive assertion fails when 'y' is not next.
        #expect(parser.parse(Source("z")).hasErrors)
    }

    @Test("Negative lookahead succeeds at end of input (nothing follows)")
    func negativeAtEndOfInput() throws {
        // After consuming "a", notFollowedBy(letter) holds at end of input, so "a" matches but "ab" does not.
        let matcher = Match.seq(Match.lit("a"), Match.notFollowedBy(Match.letter))
        let parser = try UTF8Parser(grammar: tokenGrammar(matcher))
        let atEnd = parser.parse(Source("a"))
        #expect(!atEnd.hasErrors)
        #expect(atEnd.tree.green.reconstructedText == "a")
        #expect(parser.parse(Source("ab")).hasErrors)
    }

    @Test("Positive lookahead fails at end of input (nothing follows)")
    func positiveAtEndOfInput() throws {
        // followedBy(any) cannot hold at end of input, so "a" alone fails but "ab" lets "a" match.
        let matcher = Match.seq(Match.lit("a"), Match.followedBy(Match.any))
        let parser = try UTF8Parser(grammar: tokenGrammar(matcher))
        #expect(parser.parse(Source("a")).hasErrors)
        let followed = parser.parse(Source("ab"))
        // "a" is consumed (the positive lookahead saw the following "b" without consuming it); "b"
        // remains as trailing junk, so the token "s" still matched and the parse is lossless.
        #expect(followed.sExpression().hasPrefix("(s (s)"))
        #expect(followed.tree.green.reconstructedText == "ab")
    }

    @Test("Nested lookahead: a positive lookahead guarding a negative lookahead is zero-width")
    func nestedLookahead() throws {
        // followedBy( "a" then notFollowedBy(digit) ) is zero-width, then "a" is consumed: matches "a"
        // and "ax" but not "a1" (the inner negative assertion rejects a following digit).
        let inner = Match.seq(Match.lit("a"), Match.notFollowedBy(Match.digit))
        let matcher = Match.seq(Match.followedBy(inner), Match.lit("a"))
        let parser = try UTF8Parser(grammar: tokenGrammar(matcher))
        #expect(!parser.parse(Source("a")).hasErrors)
        #expect(parser.parse(Source("a")).tree.green.reconstructedText == "a")
        #expect(parser.parse(Source("a1")).hasErrors)
    }
}

@Suite("Input granularity")
struct GranularityTests {
    /// The same JSON produces the same tree at every granularity (UTF-8, scalar, grapheme), including
    /// input containing multi-byte/composite characters.
    @Test("All granularities agree", arguments: [
        #"{ "a": 1 }"#,
        #"["é", "🇦🇺", true]"#,
        #"{"key": "naïve café"}"#,
    ])
    func granularitiesAgree(_ input: String) throws {
        let grammar = JSONGrammar.grammar()
        let utf8 = try UTF8Parser(grammar: grammar).parse(Source(input))
        let scalar = try ScalarParser(grammar: grammar).parse(Source(input))
        let grapheme = try GraphemeParser(grammar: grammar).parse(Source(input))
        #expect(utf8.sExpression() == scalar.sExpression())
        #expect(scalar.sExpression() == grapheme.sExpression())
        // Lossless at every granularity.
        #expect(utf8.tree.green.reconstructedText == input)
        #expect(scalar.tree.green.reconstructedText == input)
        #expect(grapheme.tree.green.reconstructedText == input)
    }
}

@Suite("Losslessness")
struct LosslessnessTests {
    @Test("Reconstructed text equals input", arguments: [
        #"{ "a": 1 }"#, "  [1,2,3]  ", "{}", "\n\ttrue\n",
        #"{"nested": {"x": [true, false, null]}}"#, "   ", "garbage",
    ])
    func roundTrip(_ input: String) throws {
        #expect(try parseJSON(input).tree.green.reconstructedText == input)
    }
}

@Suite("Error recovery")
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

@Suite("Matcher interpretation")
struct MatcherTests {
    private func parse(_ grammar: Grammar, _ text: String) throws -> ParseResult {
        try UTF8Parser(grammar: grammar).parse(Source(text))
    }

    @Test("Ranges, builtins, alternation, repetition and anyElement")
    func richMatchers() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .sequence([
                .token(name: "letter", matcher: Match.range("a", "z"), isNamed: true),
                .token(name: "digits", matcher: Match.oneOrMore(Match.digit), isNamed: true),
                .token(name: "bounded", matcher: .repeated(min: 2, max: 3, Match.lit("!")), isNamed: true),
                .token(name: "notbang", matcher: Match.not(Match.lit("!")), isNamed: true),
                .token(name: "anything", matcher: Match.any, isNamed: true),
                .token(name: "kw", matcher: Match.oneOf(Match.lit("yes"), Match.lit("no")), isNamed: true),
            ]),
        ])
        let result = try parse(grammar, "a12!!xZyes")
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(s (letter) (digits) (bounded) (notbang) (anything) (kw))")
        #expect(result.tree.green.reconstructedText == "a12!!xZyes")
    }

    @Test("hexDigit and letter built-in classes")
    func hexAndLetter() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .sequence([
                .token(name: "hex", matcher: Match.oneOrMore(Match.hexDigit), isNamed: true),
                .token(name: "word", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
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
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .sequence([
                .field("pair", .sequence([.literal("a"), .literal("b")])),
                .precedence(level: 1, associativity: .left, .literal("c")),
                .repeatZeroOrMore(.optional(.literal("x"))),
            ]),
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
