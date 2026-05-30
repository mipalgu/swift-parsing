import Foundation
import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

@testable import G4Import

/// The JSON `.g4` grammar shipped by the module, used as the literal grammar across these tests.
private let inlineJSONGrammar = G4Grammar.jsonGrammar

@Suite("G4 acceptance: imported JSON.g4 agrees with the DSL grammar")
struct AcceptanceTests {
    /// The differential corpus: realistic JSON documents (without string escapes, matching the
    /// first-milestone simplification) spanning objects, arrays, nesting, numbers, the literals, and
    /// whitespace handling.
    static let corpus: [String] = [
        #"{ "a": 1 }"#,
        #"[1, "x", true, null]"#,
        "-2.5e10",
        "{}",
        "[]",
        "true",
        "false",
        "null",
        "0",
        "-1",
        "3.14",
        "1E+9",
        #"{"nested": {"x": [true, false, null]}}"#,
        #"  [ 1 , 2 , 3 ]  "#,
        "\n\t{\n\t\"k\"\t:\t\"v\"\n}\n",
        #"{"k": [true, {"n": null}], "m": "v"}"#,
    ]

    @Test("The shipped JSON.g4 grammar parses every corpus document like the DSL grammar")
    func shippedGrammarAgrees() throws {
        let imported = try G4Grammar.grammar(from: Data(G4Grammar.jsonGrammar.utf8))
        let dsl = JSONGrammar.grammar()
        for input in Self.corpus {
            let importedTree = try UTF8Parser(grammar: imported).parse(Source(input)).sExpression()
            let dslTree = try UTF8Parser(grammar: dsl).parse(Source(input)).sExpression()
            #expect(importedTree == dslTree, "mismatch for \(input)")
        }
    }

    @Test("An inline JSON.g4 string agrees with the DSL grammar across the corpus")
    func inlineGrammarAgrees() throws {
        let imported = try G4Grammar.grammar(fromString: inlineJSONGrammar)
        let dsl = JSONGrammar.grammar()
        for input in Self.corpus {
            let importedTree = try UTF8Parser(grammar: imported).parse(Source(input)).sExpression()
            let dslTree = try UTF8Parser(grammar: dsl).parse(Source(input)).sExpression()
            #expect(importedTree == dslTree, "mismatch for \(input)")
        }
    }

    @Test("Imported grammar metadata matches the authored grammar")
    func grammarMetadata() throws {
        let imported = try G4Grammar.grammar(fromString: inlineJSONGrammar)
        #expect(imported.name == "JSON")
        #expect(imported.startRule == "document")
        // Only the parser rules become IR rules; lexer rules are inlined as token matchers.
        #expect(
            Set(imported.rules.keys) == [
                "document", "_value", "object", "pair", "array", "string", "string_content", "number", "true", "false",
                "null",
            ])
    }

    @Test("Malformed input still yields a complete tree with error nodes, as for the DSL grammar")
    func errorRecoveryAgrees() throws {
        let imported = try G4Grammar.grammar(fromString: inlineJSONGrammar)
        let dsl = JSONGrammar.grammar()
        for input in ["true false", "@@@", "{", "[1,"] {
            let importedResult = try UTF8Parser(grammar: imported).parse(Source(input))
            let dslResult = try UTF8Parser(grammar: dsl).parse(Source(input))
            #expect(importedResult.sExpression() == dslResult.sExpression(), "mismatch for \(input)")
            #expect(importedResult.tree.green.reconstructedText == input)
        }
    }
}

@Suite("G4 lexer")
struct LexerTests {
    private func tokenise(_ text: String) throws -> [G4Token] {
        var lexer = G4Lexer(text)
        return try lexer.tokenise()
    }

    @Test("Tokenises punctuation, keywords, and operators")
    func punctuation() throws {
        let tokens = try tokenise("grammar fragment : ; | ( ) ? * + ~ . , = += ->")
        #expect(
            tokens == [
                .grammarKeyword, .fragmentKeyword, .colon, .semicolon, .pipe, .leftParenthesis,
                .rightParenthesis, .question, .star, .plus, .tilde, .dot, .comma, .equals, .equals, .arrow,
                .endOfFile,
            ])
    }

    @Test("Distinguishes identifiers from keywords")
    func identifiers() throws {
        let tokens = try tokenise("rule_name RULE_NAME _hidden grammarish")
        #expect(
            tokens == [
                .identifier("rule_name"), .identifier("RULE_NAME"), .identifier("_hidden"),
                .identifier("grammarish"), .endOfFile,
            ])
    }

    @Test("Decodes string-literal escapes")
    func stringEscapes() throws {
        let tokens = try tokenise(#"'a\nb' '\'' '\\' '\t' '\x'"#)
        #expect(
            tokens == [
                .stringLiteral("a\nb"), .stringLiteral("'"), .stringLiteral("\\"),
                .stringLiteral("\t"), .stringLiteral("x"), .endOfFile,
            ])
    }

    @Test("Decodes the control-character escapes")
    func controlEscapes() throws {
        let tokens = try tokenise(#"'\r\b\f'"#)
        #expect(tokens == [.stringLiteral("\r\u{08}\u{0C}"), .endOfFile])
    }

    @Test("Captures character sets verbatim, keeping escapes")
    func characterSets() throws {
        let tokens = try tokenise(#"[a-z] [0-9] [ \t\n\r] [\]]"#)
        #expect(
            tokens == [
                .characterSet("a-z"), .characterSet("0-9"), .characterSet(" \\t\\n\\r"),
                .characterSet("\\]"), .endOfFile,
            ])
    }

    @Test("Skips line and block comments")
    func comments() throws {
        let text = """
            // a line comment
            grammar /* inline */ Name ; /* trailing
            spanning lines */ rule
            """
        let tokens = try tokenise(text)
        #expect(tokens == [.grammarKeyword, .identifier("Name"), .semicolon, .identifier("rule"), .endOfFile])
    }

    @Test("A trailing plus at end of input lexes as a bare plus")
    func trailingPlusAtEnd() throws {
        let tokens = try tokenise("a+")
        #expect(tokens == [.identifier("a"), .plus, .endOfFile])
    }

    @Test("A trailing minus at end of input is an unexpected character")
    func trailingMinusAtEnd() {
        #expect(throws: G4ImportError.unexpectedCharacter("-", at: 1)) {
            var lexer = G4Lexer("a-")
            _ = try lexer.tokenise()
        }
    }

    @Test("Rejects an unexpected character")
    func unexpectedCharacter() {
        #expect(throws: G4ImportError.unexpectedCharacter("#", at: 0)) {
            var lexer = G4Lexer("# label")
            _ = try lexer.tokenise()
        }
    }

    @Test("Rejects an unterminated string literal")
    func unterminatedString() {
        #expect(throws: G4ImportError.unterminatedLiteral) {
            var lexer = G4Lexer("'abc")
            _ = try lexer.tokenise()
        }
    }

    @Test("Rejects a string literal whose final backslash is unterminated")
    func unterminatedEscape() {
        #expect(throws: G4ImportError.unterminatedLiteral) {
            var lexer = G4Lexer("'abc\\")
            _ = try lexer.tokenise()
        }
    }

    @Test("Rejects an unterminated character set")
    func unterminatedSet() {
        #expect(throws: G4ImportError.unterminatedLiteral) {
            var lexer = G4Lexer("[a-z")
            _ = try lexer.tokenise()
        }
    }

    @Test("Rejects a character set whose final backslash is unterminated")
    func unterminatedSetEscape() {
        #expect(throws: G4ImportError.unterminatedLiteral) {
            var lexer = G4Lexer("[a\\")
            _ = try lexer.tokenise()
        }
    }

    @Test("Rejects an unterminated block comment")
    func unterminatedBlockComment() {
        #expect(throws: G4ImportError.unterminatedLiteral) {
            var lexer = G4Lexer("/* never closed")
            _ = try lexer.tokenise()
        }
    }
}

@Suite("G4 lowering of elements")
struct LoweringTests {
    @Test("A string literal lowers to an anonymous literal token")
    func stringLiteral() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'hello' ;")
        #expect(grammar.rules["r"] == .literal("hello"))
    }

    @Test("EBNF suffixes lower to the matching repetition rules")
    func suffixes() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a'? 'b'* 'c'+ ;")
        #expect(
            grammar.rules["r"]
                == .sequence([
                    .optional(.literal("a")), .repeatZeroOrMore(.literal("b")), .repeatOneOrMore(.literal("c")),
                ]))
    }

    @Test("Non-greedy markers lower like their greedy equivalents")
    func nonGreedy() throws {
        let greedy = try G4Grammar.grammar(fromString: "grammar G; r : 'a'?? 'b'*? 'c'+? ;")
        let plain = try G4Grammar.grammar(fromString: "grammar G; r : 'a'? 'b'* 'c'+ ;")
        #expect(greedy.rules["r"] == plain.rules["r"])
    }

    @Test("Alternatives lower to an ordered choice")
    func alternatives() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a' | 'b' | 'c' ;")
        #expect(grammar.rules["r"] == .choice([.literal("a"), .literal("b"), .literal("c")]))
    }

    @Test("A parenthesised group lowers to a nested choice")
    func group() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : ( 'a' | 'b' ) 'c' ;")
        #expect(grammar.rules["r"] == .sequence([.choice([.literal("a"), .literal("b")]), .literal("c")]))
    }

    @Test("An element label lowers to a grammar field")
    func label() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : k='a' ;")
        #expect(grammar.rules["r"] == .field("k", .literal("a")))
    }

    @Test("A `+=` element label also lowers to a grammar field")
    func listLabel() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : k+='a' ;")
        #expect(grammar.rules["r"] == .field("k", .literal("a")))
    }

    @Test("The dot wildcard lowers to an any-element token")
    func wildcard() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : . ;")
        #expect(grammar.rules["r"] == .token(name: "", matcher: .anyElement, isNamed: false))
    }

    @Test("A character set used directly in a parser rule lowers to an anonymous token")
    func characterSetInParserRule() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : [a-z] ;")
        #expect(grammar.rules["r"] == .token(name: "", matcher: .scalarRange(97...122), isNamed: false))
    }

    @Test("A reference to another parser rule lowers to a rule reference")
    func parserReference() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : s ; s : 'x' ;")
        #expect(grammar.rules["r"] == .reference("s"))
    }

    @Test("A reference to a lexer rule lowers to an anonymous token carrying its matcher")
    func lexerReference() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : T ; T : 'x' ;")
        #expect(grammar.rules["r"] == .token(name: "T", matcher: .literal("x"), isNamed: false))
    }

    @Test("The EOF reference contributes no node")
    func endOfFile() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a' EOF ;")
        #expect(grammar.rules["r"] == .literal("a"))
    }

    @Test("An empty alternative lowers to an empty sequence")
    func emptyAlternative() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a' | ;")
        #expect(grammar.rules["r"] == .choice([.literal("a"), .sequence([])]))
    }

    @Test("A labelled element that resolves to nothing (EOF) is dropped")
    func labelledEOF() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : x=EOF 'a' ;")
        #expect(grammar.rules["r"] == .literal("a"))
    }

    @Test("A suffixed EOF reference is dropped")
    func suffixedEOF() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : EOF? 'a' ;")
        #expect(grammar.rules["r"] == .literal("a"))
    }
}

@Suite("G4 lowering of lexer rules")
struct LexerLoweringTests {
    @Test("A character set lowers to a scalar range")
    func characterSetRange() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : D ; D : [0-9] ;")
        #expect(grammar.rules["r"] == .token(name: "D", matcher: .scalarRange(48...57), isNamed: false))
    }

    @Test("A multi-member character set lowers to an alternation")
    func characterSetAlternation() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : S ; S : [eE] ;")
        #expect(
            grammar.rules["r"]
                == .token(name: "S", matcher: .alternation([.literal("e"), .literal("E")]), isNamed: false))
    }

    @Test("A negated character set lowers to a negation")
    func negatedSet() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : N ; N : ~[\"] ;")
        #expect(grammar.rules["r"] == .token(name: "N", matcher: .negated(.literal("\"")), isNamed: false))
    }

    @Test("A negated string element lowers to a negation")
    func negatedString() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : ~'\"' ;")
        #expect(grammar.rules["r"] == .token(name: "", matcher: .negated(.literal("\"")), isNamed: false))
    }

    @Test("A negated lexer-rule reference lowers to a negation of its matcher")
    func negatedReference() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : ~Q ; Q : '\"' ;")
        #expect(grammar.rules["r"] == .token(name: "", matcher: .negated(.literal("\"")), isNamed: false))
    }

    @Test("A fragment is inlined into the lexer rule that references it")
    func fragmentInlining() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : H ; H : DIGIT DIGIT ; fragment DIGIT : [0-9] ;")
        let range = TokenMatcher.scalarRange(48...57)
        #expect(grammar.rules["r"] == .token(name: "H", matcher: .sequence([range, range]), isNamed: false))
    }

    @Test("Lexer-rule alternatives and suffixes lower into the matcher")
    func lexerCombinators() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : T ; T : ( 'a' | 'b' )+ 'c'? . ;")
        let expected = TokenMatcher.sequence([
            .repeated(min: 1, max: nil, .alternation([.literal("a"), .literal("b")])),
            .repeated(min: 0, max: 1, .literal("c")),
            .anyElement,
        ])
        #expect(grammar.rules["r"] == .token(name: "T", matcher: expected, isNamed: false))
    }

    @Test("A labelled element inside a lexer rule keeps its inner matcher")
    func lexerLabel() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : T ; T : x='a' ;")
        #expect(grammar.rules["r"] == .token(name: "T", matcher: .literal("a"), isNamed: false))
    }

    @Test("A zero-or-more suffix inside a lexer rule lowers to an unbounded repetition")
    func lexerZeroOrMore() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : T ; T : 'a'* ;")
        #expect(
            grammar.rules["r"] == .token(name: "T", matcher: .repeated(min: 0, max: nil, .literal("a")), isNamed: false)
        )
    }

    @Test("A `-> skip` lexer rule becomes a trivia extra")
    func skipBecomesExtra() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; WS : [ \\t]+ -> skip ;")
        #expect(grammar.extras == [.repeated(min: 1, max: nil, .alternation([.literal(" "), .literal("\t")]))])
    }

    @Test("A `-> channel(...)` lexer rule becomes a trivia extra")
    func channelBecomesExtra() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; COMMENT : '#' -> channel(HIDDEN) ;")
        #expect(grammar.extras == [.literal("#")])
    }

    @Test("With no skip or channel rule, extras default to whitespace")
    func defaultExtras() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : 'a' ;")
        #expect(grammar.extras == [.builtin(.whitespace)])
    }

    @Test("An empty lexer alternative lowers to an empty literal matcher")
    func emptyLexerAlternative() throws {
        let grammar = try G4Grammar.grammar(fromString: "grammar G; r : T ; T : 'a' | ;")
        #expect(
            grammar.rules["r"]
                == .token(name: "T", matcher: .alternation([.literal("a"), .literal("")]), isNamed: false))
    }
}

@Suite("G4 character-set lowering")
struct CharacterSetTests {
    @Test("Decodes escapes inside a set")
    func escapes() {
        let matcher = G4CharacterSet.matcher(body: " \\t\\n\\r", isNegated: false)
        #expect(matcher == .alternation([.literal(" "), .literal("\t"), .literal("\n"), .literal("\r")]))
    }

    @Test("Lowers an escaped range bound")
    func escapedRangeBound() {
        let matcher = G4CharacterSet.matcher(body: "\\t-\\r", isNegated: false)
        #expect(matcher == .scalarRange(9...13))
    }

    @Test("A trailing dash is treated as a literal member")
    func trailingDash() {
        let matcher = G4CharacterSet.matcher(body: "a-", isNegated: false)
        #expect(matcher == .alternation([.literal("a"), .literal("-")]))
    }
}

@Suite("G4 import errors")
struct ErrorTests {
    @Test("A missing grammar header is rejected")
    func missingHeader() {
        #expect(throws: G4ImportError.missingGrammarHeader) {
            try G4Grammar.grammar(fromString: "r : 'a' ;")
        }
    }

    @Test("A header without a name is rejected")
    func headerWithoutName() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar ;")
        }
    }

    @Test("A header without a terminating semicolon is rejected")
    func headerWithoutSemicolon() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G r : 'a' ;")
        }
    }

    @Test("A rule without a colon is rejected")
    func ruleWithoutColon() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r 'a' ;")
        }
    }

    @Test("A rule without a name is rejected")
    func ruleWithoutName() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; : 'a' ;")
        }
    }

    @Test("A rule without a terminating semicolon is rejected")
    func ruleWithoutSemicolon() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a'")
        }
    }

    @Test("An unclosed group is rejected")
    func unclosedGroup() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : ( 'a' ;")
        }
    }

    @Test("A bare `~` without a set is rejected")
    func danglingTilde() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : ~ ;")
        }
    }

    @Test("An undefined reference is rejected")
    func undefinedReference() {
        #expect(throws: G4ImportError.undefinedReference("missing")) {
            try G4Grammar.grammar(fromString: "grammar G; r : T ; T : missing ;")
        }
    }

    @Test("A reference to an undefined name from a parser rule is rejected")
    func undefinedParserReference() {
        #expect(throws: G4ImportError.undefinedReference("Nope")) {
            try G4Grammar.grammar(fromString: "grammar G; r : Nope ;")
        }
    }

    @Test("A grammar with no parser rules is rejected")
    func noParserRules() {
        #expect(throws: G4ImportError.noParserRules) {
            try G4Grammar.grammar(fromString: "grammar G; T : 'a' ;")
        }
    }

    @Test("A duplicate parser rule is rejected")
    func duplicateRule() {
        #expect(throws: G4ImportError.duplicateRule("r")) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; r : 'b' ;")
        }
    }

    @Test("An unsupported lexer command is rejected")
    func unsupportedCommand() {
        #expect(throws: G4ImportError.unsupportedConstruct("lexer command 'more'")) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; T : 'b' -> more ;")
        }
    }

    @Test("An arrow without a command is rejected")
    func arrowWithoutCommand() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; T : 'b' -> ;")
        }
    }

    @Test("A channel command without parentheses is rejected")
    func channelWithoutParentheses() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; T : 'b' -> channel ;")
        }
    }

    @Test("A channel command without an argument name is rejected")
    func channelWithoutArgument() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; T : 'b' -> channel() ;")
        }
    }

    @Test("A channel command without a closing parenthesis is rejected")
    func channelWithoutClose() {
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : 'a' ; T : 'b' -> channel(HIDDEN ;")
        }
    }

    @Test("A reference to a skipped lexer rule from a parser rule is rejected")
    func referenceToSkipped() {
        #expect(throws: G4ImportError.unsupportedConstruct("reference to skipped lexer rule 'WS'")) {
            try G4Grammar.grammar(fromString: "grammar G; r : WS ; WS : ' ' -> skip ;")
        }
    }

    @Test("A recursive lexer rule is rejected")
    func recursiveLexerRule() {
        #expect(throws: G4ImportError.unsupportedConstruct("recursive lexer rule 'T'")) {
            try G4Grammar.grammar(fromString: "grammar G; r : T ; T : 'a' T ;")
        }
    }

    @Test("Negating an undefined reference is rejected")
    func negatedUndefinedReference() {
        #expect(throws: G4ImportError.undefinedReference("Missing")) {
            try G4Grammar.grammar(fromString: "grammar G; r : ~Missing ;")
        }
    }

    @Test("Negating a compound element is rejected")
    func negatedCompound() {
        #expect(throws: G4ImportError.unsupportedConstruct("negation of a compound element")) {
            try G4Grammar.grammar(fromString: "grammar G; r : ~( 'a' 'b' ) ;")
        }
    }

    @Test(
        "Error messages name the offending token",
        arguments: [
            ("grammar G; r : ) ;", "')'"),
            ("grammar G; r : * ;", "'*'"),
            ("grammar G; r : = ;", "'='"),
            ("grammar G; r : , ;", "','"),
            ("grammar G; r : ? ;", "'?'"),
            ("grammar G; r : + ;", "'+'"),
            ("grammar G; r : : ;", "':'"),
            ("grammar G; r : fragment ;", "'fragment'"),
            ("grammar G; r : grammar ;", "'grammar'"),
        ])
    func errorNamesToken(source: String, fragment: String) {
        let error = capturedError(source)
        guard case .unexpectedToken(let found, _) = error else {
            Issue.record("expected an unexpectedToken error, got \(String(describing: error))")
            return
        }
        #expect(found.contains(fragment), "message '\(found)' should mention \(fragment)")
    }

    @Test("End of input is named in an error message")
    func errorNamesEndOfInput() {
        let error = capturedError("grammar G; r :")
        guard case .unexpectedToken(let found, _) = error else {
            Issue.record("expected an unexpectedToken error, got \(String(describing: error))")
            return
        }
        #expect(found.contains("end of input"))
    }

    @Test("A dangling label identifier at end of input is treated as a reference, then errors on EOF")
    func danglingLabelIdentifier() {
        // `x` is not followed by `=`, so it is a (last) reference; the missing `;` then errors.
        #expect(throws: G4ImportError.self) {
            try G4Grammar.grammar(fromString: "grammar G; r : x")
        }
    }

    /// Imports `source`, returning the `G4ImportError` it throws (failing the test if it does not throw).
    private func capturedError(_ source: String) -> G4ImportError? {
        do {
            _ = try G4Grammar.grammar(fromString: source)
            Issue.record("expected the import to throw")
            return nil
        } catch let error as G4ImportError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }
}

@Suite("G4 data entry point")
struct DataEntryTests {
    @Test("Importing from UTF-8 data matches importing from a string")
    func dataMatchesString() throws {
        let fromString = try G4Grammar.grammar(fromString: inlineJSONGrammar)
        let fromData = try G4Grammar.grammar(from: Data(inlineJSONGrammar.utf8))
        #expect(fromString == fromData)
    }
}
