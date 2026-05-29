import Testing

import ParsingCore
import ParsingDSL
@testable import RecursiveDescent

/// Parses JSON with the recursive-descent engine and returns the result.
private func parseJSON(_ text: String) throws -> ParseResult {
    let engine = try RecursiveDescentEngine(grammar: JSONGrammar.grammar())
    return engine.parse(Source(text))
}

@Suite("Scanner")
struct ScannerTests {
    let patterns = try! PatternSet(grammar: JSONGrammar.grammar())

    private func scanner(_ text: String) -> Scanner {
        Scanner(source: Source(text), patterns: patterns)
    }

    @Test("Matches a literal at the cursor and advances by UTF-8 bytes")
    func literalMatch() {
        let s = scanner("{}")
        #expect(s.match(.literal("{")) == "{")
        #expect(s.byteOffset == 1)
        #expect(s.match(.literal("{")) == nil) // next char is '}', no match
        #expect(s.match(.literal("}")) == "}")
        #expect(s.isAtEnd)
    }

    @Test("Matches a regex terminal (number) greedily")
    func regexMatch() {
        let s = scanner("-12.5e3 rest")
        #expect(s.match(.regex(#"-?(0|[1-9][0-9]*)([.][0-9]+)?([eE][+-]?[0-9]+)?"#)) == "-12.5e3")
    }

    @Test("Consumes trivia and reports the remainder")
    func trivia() {
        let s = scanner("   {")
        #expect(s.consumeTrivia() == "   ")
        #expect(s.rest == "{")
        #expect(s.consumeTrivia() == "") // no trivia at '{'
    }

    @Test("Marks support backtracking")
    func backtracking() {
        let s = scanner("true")
        let mark = s.mark()
        #expect(s.match(.literal("true")) == "true")
        #expect(s.isAtEnd)
        s.reset(to: mark)
        #expect(!s.isAtEnd)
        #expect(s.match(.literal("false")) == nil)
        #expect(s.match(.literal("true")) == "true")
    }

    @Test("UTF-8 multibyte content advances the byte offset correctly")
    func multibyte() {
        let s = scanner(#"é"#)
        #expect(s.match(.regex(#"[^"]+"#)) == "é")
        #expect(s.byteOffset == 2) // 'é' is two UTF-8 bytes
    }

    @Test("A regex that matches empty yields no token")
    func emptyRegexMatch() throws {
        // A grammar whose only terminal can match the empty string.
        let g = Grammar(name: "g", startRule: "s",
                        rules: ["s": .token(name: "opt", pattern: .regex("a*"), isNamed: false)])
        let patterns = try PatternSet(grammar: g)
        let s = Scanner(source: Source("bbb"), patterns: patterns)
        #expect(s.match(.regex("a*")) == nil) // empty match must not consume or produce a token
        #expect(s.byteOffset == 0)
    }
}

@Suite("RecursiveDescent engine: grammar generality")
struct GeneralityTests {
    /// Parses with a hand-built grammar (bypassing the JSON-specific DSL) to exercise rule forms
    /// that JSON does not use: one-or-more repetition, multi-child fields, precedence, and a
    /// reference to an undefined rule.
    @Test("repeat1, multi-child field and precedence parse and stay lossless")
    func richGrammar() throws {
        let rules: [String: Rule] = [
            "s": .sequence([
                .field("pair", .sequence([.literal("a"), .literal("b")])), // field wrapping two children
                .repeatOneOrMore(.literal("c")),                            // one-or-more
                .precedence(level: 1, associativity: .left, .literal("d")), // precedence wrapper
            ]),
        ]
        let g = Grammar(name: "g", startRule: "s", rules: rules, extras: [.regex("[ ]+")])
        let engine = try RecursiveDescentEngine(grammar: g)
        let result = engine.parse(Source("abccd"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "abccd")
    }

    @Test("repeat1 with no match recovers via ERROR")
    func repeatOneOrMoreNoMatch() throws {
        let g = Grammar(name: "g", startRule: "s",
                        rules: ["s": .repeatOneOrMore(.literal("c"))], extras: [.regex("[ ]+")])
        let engine = try RecursiveDescentEngine(grammar: g)
        let result = engine.parse(Source("x"))
        #expect(result.hasErrors)
        #expect(result.tree.green.reconstructedText == "x")
    }

    @Test("Zero-width repetition terminates instead of looping forever")
    func zeroWidthRepeat() throws {
        // `repeat0(optional("x"))` matches empty on every iteration; the engine must break out.
        let g = Grammar(name: "g", startRule: "s",
                        rules: ["s": .repeatZeroOrMore(.optional(.literal("x")))], extras: [.regex("[ ]+")])
        let engine = try RecursiveDescentEngine(grammar: g)
        let result = engine.parse(Source(""))
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(s)")
    }

    @Test("Reference to an undefined rule recovers via MISSING")
    func danglingReference() throws {
        let g = Grammar(name: "d", startRule: "s",
                        rules: ["s": .reference("missing")], extras: [.regex("[ ]+")])
        let engine = try RecursiveDescentEngine(grammar: g)
        let result = engine.parse(Source("x"))
        #expect(result.hasErrors)
        #expect(result.sExpression().contains("(MISSING value)"))
        #expect(result.tree.green.reconstructedText == "x")
    }
}

@Suite("RecursiveDescent engine: valid JSON")
struct ValidJSONTests {
    @Test("Engine identity and capabilities")
    func metadata() {
        #expect(RecursiveDescentEngine.identifier == "rd")
        #expect(RecursiveDescentEngine.capabilities.contains(.lossless))
        #expect(RecursiveDescentEngine.capabilities.contains(.errorRecovering))
    }

    @Test("Object with string key and number value")
    func object() throws {
        let result = try parseJSON(#"{ "a": 1 }"#)
        #expect(!result.hasErrors)
        #expect(result.sExpression()
            == "(document (object (pair key: (string (string_content)) value: (number))))")
    }

    @Test("Nested array of values")
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
        #expect(!result.hasErrors)
        #expect(result.sExpression() == """
            (document (object (pair key: (string (string_content)) \
            value: (object (pair key: (string (string_content)) \
            value: (array (number) (number)))))))
            """)
    }

    @Test("Bare literals parse as documents")
    func bareLiterals() throws {
        #expect(try parseJSON("true").sExpression() == "(document (true))")
        #expect(try parseJSON("false").sExpression() == "(document (false))")
        #expect(try parseJSON("null").sExpression() == "(document (null))")
        #expect(try parseJSON("42").sExpression() == "(document (number))")
    }

    @Test("Numbers: negatives, decimals and exponents", arguments: [
        "0", "-1", "3.14", "-2.5e10", "1E+9", "10",
    ])
    func numbers(_ literal: String) throws {
        let result = try parseJSON(literal)
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(document (number))")
    }
}

@Suite("RecursiveDescent engine: losslessness")
struct LosslessnessTests {
    @Test("Reconstructed text equals input", arguments: [
        #"{ "a": 1 }"#,
        "  [1,2,3]  ",
        "{}",
        "\n\ttrue\n",
        #"{"nested": {"x": [true, false, null]}}"#,
        "   ", // whitespace only
        "garbage",
    ])
    func roundTrip(_ input: String) throws {
        let result = try parseJSON(input)
        #expect(result.tree.green.reconstructedText == input)
    }
}

@Suite("RecursiveDescent engine: error recovery")
struct ErrorRecoveryTests {
    @Test("Trailing junk becomes an ERROR node, tree stays complete")
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

    @Test("Empty input recovers without crashing")
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
        let result = try parseJSON("true false")
        #expect(!result.diagnostics.isEmpty)
        let diag = result.diagnostics[0]
        #expect(diag.severity == .error)
        #expect(diag.span.start >= 0)
    }
}
