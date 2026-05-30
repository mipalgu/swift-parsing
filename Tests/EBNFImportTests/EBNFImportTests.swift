import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

@testable import EBNFImport

/// A non-trivial grammar of arithmetic expressions, authored in the IR with only the constructs that
/// the W3C EBNF dialect can faithfully represent (references, sequence, choice, optional, repetition,
/// literal terminals and character-class tokens). It deliberately avoids field labels and precedence,
/// which have no EBNF surface form, so an IR round-trip through EBNF is exact.
private enum ExpressionGrammar {
    static func grammar() -> Grammar {
        Grammar(name: "expr", start: "expr") {
            rule("expr") {
                seq {
                    ref("term")
                    repeat0 {
                        seq {
                            choice {
                                "+"; "-"
                            }
                            ref("term")
                        }
                    }
                }
            }
            rule("term") {
                seq {
                    ref("factor")
                    repeat0 {
                        seq {
                            choice {
                                "*"; "/"
                            }
                            ref("factor")
                        }
                    }
                }
            }
            rule("factor") {
                choice {
                    ref("number")
                    seq {
                        "("; ref("expr"); ")"
                    }
                }
            }
            rule("number") {
                seq {
                    optional { "-" }
                    ref("digits")
                }
            }
            rule("digits") { token(Match.oneOrMore(Match.digit)) }
        }
    }

    /// Inputs the grammar must parse identically before and after a round-trip.
    static let corpus = ["1", "1+2", "1+2*3", "(1+2)*3", "-5", "10*-3", "(1)", "1+2+3+4", "((1))"]
}

@Suite("EBNF round-trip acceptance")
struct RoundTripTests {
    @Test("The re-imported grammar parses the corpus identically via the native engine")
    func corpusParsesIdentically() throws {
        // The acceptance gate: a non-trivial grammar (arithmetic expressions with references, choice,
        // sequence, optional and repetition) is lowered to EBNF and re-imported, and the re-imported
        // grammar must parse a corpus to byte-for-byte identical trees via the native engine.
        let original = ExpressionGrammar.grammar()
        let text = EBNFGrammar.export(original)
        let reimported = try EBNFGrammar.grammar(from: text, name: original.name, startRule: original.startRule)

        let before = try UTF8Parser(grammar: original)
        let after = try UTF8Parser(grammar: reimported)
        for input in ExpressionGrammar.corpus {
            let lhs = before.parse(Source(input)).sExpression()
            let rhs = after.parse(Source(input)).sExpression()
            #expect(lhs == rhs, "mismatch for \(input)")
        }
    }

    @Test("A grammar of references and literal terminals round-trips exactly")
    func literalGrammarRoundTripExact() throws {
        // References and literal terminals carry their identity in the IR (a literal's token name is its
        // own text), so a grammar built only from them survives IR -> EBNF -> IR with structural equality.
        // Anonymous character-class tokens carry no stable name and so are covered by the semantic
        // (corpus) gate above instead.
        let rules: [String: Rule] = [
            "s": .sequence([
                .reference("kw"),
                .optional(.literal("?")),
                .repeatZeroOrMore(.literal("x")),
                .repeatOneOrMore(.literal("y")),
                .choice([.literal("a"), .literal("b")]),
                .reference("kw"),
            ]),
            "kw": .literal("kw"),
        ]
        let original = Grammar(name: "lit", startRule: "s", rules: rules)
        let text = EBNFGrammar.export(original)
        let reimported = try EBNFGrammar.grammar(from: text, name: "lit", startRule: "s")
        #expect(reimported == original)
    }
}

@Suite("EBNF hand-written import")
struct HandWrittenTests {
    @Test("A hand-written EBNF grammar parses input with the native engine")
    func handWrittenParses() throws {
        let ebnf = """
            /* a small grammar of comma-separated greetings */
            greetings ::= greeting (',' greeting)*
            greeting  ::= ('hello' | 'hi') name
            name      ::= [A-Za-z]+
            """
        let grammar = try EBNFGrammar.grammar(from: ebnf, name: "greetings")
        #expect(grammar.startRule == "greetings")
        #expect(grammar.rules.count == 3)

        let parser = try UTF8Parser(grammar: grammar)
        let result = parser.parse(Source("hello World, hi There"))
        #expect(!result.hasErrors)
        #expect(result.sExpression().contains("greeting"))
        #expect(result.sExpression().contains("name"))
    }

    @Test("Malformed input yields an error-bearing but complete tree")
    func malformedInputRecovers() throws {
        let grammar = try EBNFGrammar.grammar(from: "s ::= 'a' 'b'")
        let result = try UTF8Parser(grammar: grammar).parse(Source("a c"))
        #expect(result.hasErrors)
    }
}

@Suite("EBNF construct mapping")
struct ConstructTests {
    private func rule(_ ebnf: String) throws -> Rule {
        let grammar = try EBNFGrammar.grammar(from: "s ::= \(ebnf)")
        guard let rule = grammar.rules["s"] else {
            Issue.record("missing start rule")
            return .sequence([])
        }
        return rule
    }

    @Test("A bare reference lowers to .reference")
    func reference() throws {
        #expect(try rule("a") == .reference("a"))
    }

    @Test("Single- and double-quoted terminals lower to literal tokens")
    func terminals() throws {
        #expect(try rule("'x'") == .literal("x"))
        #expect(try rule("\"y\"") == .literal("y"))
        #expect(try rule("\"it's\"") == .literal("it's"))
    }

    @Test("Concatenation lowers to .sequence")
    func sequence() throws {
        #expect(try rule("'a' 'b' 'c'") == .sequence([.literal("a"), .literal("b"), .literal("c")]))
    }

    @Test("Alternation lowers to .choice")
    func alternation() throws {
        #expect(try rule("'a' | 'b'") == .choice([.literal("a"), .literal("b")]))
    }

    @Test("The postfix quantifiers lower to optional and repetition")
    func quantifiers() throws {
        #expect(try rule("'a'?") == .optional(.literal("a")))
        #expect(try rule("'a'*") == .repeatZeroOrMore(.literal("a")))
        #expect(try rule("'a'+") == .repeatOneOrMore(.literal("a")))
    }

    @Test("Grouping binds a quantifier to a whole sub-expression")
    func grouping() throws {
        #expect(try rule("('a' 'b')*") == .repeatZeroOrMore(.sequence([.literal("a"), .literal("b")])))
        #expect(try rule("('a' | 'b')?") == .optional(.choice([.literal("a"), .literal("b")])))
    }

    @Test("A character range lowers to a scalar-range token")
    func characterRange() throws {
        #expect(try rule("[a-z]") == .token(name: "_class", matcher: .scalarRange(0x61...0x7A), isNamed: false))
    }

    @Test("A multi-member character class lowers to an alternation token")
    func characterClassMembers() throws {
        let expected = TokenMatcher.alternation([.scalarRange(0x61...0x7A), .literal("_")])
        #expect(try rule("[a-z_]") == .token(name: "_class", matcher: expected, isNamed: false))
    }

    @Test("A negated character class lowers to a negated token")
    func negatedClass() throws {
        let expected = TokenMatcher.negated(.alternation([.literal("'"), .literal("\"")]))
        #expect(try rule("[^'\"]") == .token(name: "_class", matcher: expected, isNamed: false))
        #expect(try rule("[^x]") == .token(name: "_class", matcher: .negated(.literal("x")), isNamed: false))
    }

    @Test("A hexadecimal code point lowers to a scalar value")
    func hexScalar() throws {
        #expect(try rule("[#x41-#x5A]") == .token(name: "_class", matcher: .scalarRange(0x41...0x5A), isNamed: false))
    }

    @Test("The full-Unicode class lowers to .anyElement")
    func anyElement() throws {
        #expect(try rule("[#x0-#x10FFFF]") == .token(name: "_class", matcher: .anyElement, isNamed: false))
    }

    @Test("Built-in classes are recognised on import")
    func builtinClasses() throws {
        #expect(try rule("[0-9]") == .token(name: "_class", matcher: .builtin(.digit), isNamed: false))
        #expect(try rule("[A-Za-z]") == .token(name: "_class", matcher: .builtin(.letter), isNamed: false))
        #expect(try rule("[0-9A-Fa-f]") == .token(name: "_class", matcher: .builtin(.hexDigit), isNamed: false))
    }

    @Test("A negated built-in class lowers to a negated built-in matcher")
    func negatedBuiltinClass() throws {
        #expect(try rule("[^0-9]") == .token(name: "_class", matcher: .negated(.builtin(.digit)), isNamed: false))
    }

    @Test("A backslash escape inside a class is taken literally")
    func classEscape() throws {
        #expect(try rule("[\\]]") == .token(name: "_class", matcher: .literal("]"), isNamed: false))
    }

    @Test("The first production becomes the start rule when none is given")
    func defaultStartRule() throws {
        let grammar = try EBNFGrammar.grammar(from: "first ::= second\nsecond ::= 'x'")
        #expect(grammar.startRule == "first")
    }

    @Test("An explicit start rule overrides the first production")
    func explicitStartRule() throws {
        let grammar = try EBNFGrammar.grammar(from: "first ::= second\nsecond ::= 'x'", startRule: "second")
        #expect(grammar.startRule == "second")
    }
}

@Suite("EBNF import errors")
struct ImportErrorTests {
    @Test("Empty text is rejected")
    func emptyGrammar() {
        #expect(throws: EBNFGrammar.ImportError.emptyGrammar) {
            try EBNFGrammar.grammar(from: "   \n  /* only a comment */  ")
        }
    }

    @Test("A missing definition operator is rejected")
    func missingDefinition() {
        #expect(throws: EBNFGrammar.ImportError.expectedDefinitionOperator(line: 1)) {
            try EBNFGrammar.grammar(from: "s 'a'")
        }
    }

    @Test("A production starting with punctuation is rejected")
    func expectedProductionName() {
        #expect(throws: EBNFGrammar.ImportError.expectedProductionName(line: 1)) {
            try EBNFGrammar.grammar(from: "::= 'a'")
        }
    }

    @Test("An empty right-hand side is rejected")
    func expectedTerm() {
        #expect(throws: EBNFGrammar.ImportError.expectedTerm(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= ")
        }
    }

    @Test("An unbalanced parenthesis is rejected")
    func unbalancedParenthesis() {
        #expect(throws: EBNFGrammar.ImportError.unbalancedParenthesis(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= ('a' 'b'")
        }
    }

    @Test("An unterminated string is rejected")
    func unterminatedString() {
        #expect(throws: EBNFGrammar.ImportError.unterminatedString(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= 'a")
        }
    }

    @Test("An unterminated character class is rejected")
    func unterminatedClass() {
        #expect(throws: EBNFGrammar.ImportError.unterminatedCharacterClass(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= [a-z")
        }
    }

    @Test("An empty hexadecimal escape is rejected")
    func invalidHex() {
        #expect(throws: EBNFGrammar.ImportError.invalidHexadecimal(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= [#xZ]")
        }
    }

    @Test("An unterminated comment is rejected")
    func unterminatedComment() {
        #expect(throws: EBNFGrammar.ImportError.unterminatedComment(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= 'a' /* never closed")
        }
    }

    @Test("A stray operator where a term is expected is rejected")
    func unexpectedToken() {
        #expect(throws: EBNFGrammar.ImportError.unexpectedToken("=", line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= =")
        }
    }

    @Test("A class ending after a trailing escape is rejected")
    func unterminatedClassAfterEscape() {
        #expect(throws: EBNFGrammar.ImportError.unterminatedCharacterClass(line: 1)) {
            try EBNFGrammar.grammar(from: "s ::= [a-\\")
        }
    }
}

@Suite("EBNF export")
struct ExportTests {
    @Test("Export renders every construct in canonical form")
    func canonicalForms() throws {
        let rules: [String: Rule] = [
            "s": .sequence([
                .reference("a"),
                .optional(.literal("?")),
                .repeatZeroOrMore(.literal("x")),
                .repeatOneOrMore(.reference("a")),
                .choice([.literal("a"), .literal("b")]),
            ]),
            "a": .literal("a"),
        ]
        let grammar = Grammar(name: "g", startRule: "s", rules: rules)
        let text = EBNFGrammar.export(grammar)
        #expect(text.contains("s ::="))
        #expect(text.contains("a ::= 'a'"))
        #expect(text.contains("'?'?"))
        #expect(text.contains("'x'*"))
        #expect(text.contains("a+"))
        #expect(text.contains("('a' | 'b')"))
    }

    @Test("Export quotes a terminal containing a single quote with double quotes")
    func quotePreference() {
        let grammar = Grammar(name: "g", startRule: "s", rules: ["s": .literal("it's")])
        #expect(EBNFGrammar.export(grammar).contains("\"it's\""))
    }

    @Test("Export renders every built-in class, ranges and negation")
    func matcherForms() {
        let rules: [String: Rule] = [
            "s": .sequence([
                .token(name: "d", matcher: .builtin(.digit), isNamed: false),
                .token(name: "w", matcher: .builtin(.whitespace), isNamed: false),
                .token(name: "h", matcher: .builtin(.hexDigit), isNamed: false),
                .token(name: "l", matcher: .builtin(.letter), isNamed: false),
                .token(name: "r", matcher: .scalarRange(0x61...0x7A), isNamed: false),
                .token(name: "n", matcher: .negated(.literal("x")), isNamed: false),
                .token(name: "a", matcher: .anyElement, isNamed: false),
            ])
        ]
        let text = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules))
        #expect(text.contains("[0-9]"))
        #expect(text.contains("[#x9#xA#xD#x20]"))
        #expect(text.contains("[0-9A-Fa-f]"))
        #expect(text.contains("[A-Za-z]"))
        #expect(text.contains("[a-z]"))
        #expect(text.contains("[^x]"))
        #expect(text.contains("[#x0-#x10FFFF]"))
    }

    @Test("Field and precedence wrappers are emitted as their inner expression")
    func wrapperForms() throws {
        let rules: [String: Rule] = [
            "s": .sequence([
                .field("key", .reference("a")),
                .precedence(level: 2, associativity: .left, .reference("a")),
            ]),
            "a": .literal("a"),
        ]
        let grammar = Grammar(name: "g", startRule: "s", rules: rules)
        let text = EBNFGrammar.export(grammar)
        // The wrappers vanish, leaving two bare references, so the re-import is a plain sequence.
        let reimported = try EBNFGrammar.grammar(from: text, startRule: "s")
        #expect(reimported.rules["s"] == .sequence([.reference("a"), .reference("a")]))
    }

    @Test("A scalar range with a non-printable bound uses a #x escape on export")
    func nonPrintableScalar() throws {
        let rules: [String: Rule] = ["s": .token(name: "t", matcher: .scalarRange(0x9...0x7F), isNamed: false)]
        let text = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules))
        #expect(text.contains("[#x9-#x7F]"))
        let reimported = try EBNFGrammar.grammar(from: text, startRule: "s")
        #expect(reimported.rules["s"] == .token(name: "_class", matcher: .scalarRange(0x9...0x7F), isNamed: false))
    }

    @Test("A class-member alternation exports as a single character class")
    func classMemberAlternation() throws {
        let matcher = TokenMatcher.alternation([.scalarRange(0x61...0x7A), .literal("_")])
        let rules: [String: Rule] = ["s": .token(name: "c", matcher: matcher, isNamed: false)]
        let text = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules))
        #expect(text.contains("[a-z_]"))
        let reimported = try EBNFGrammar.grammar(from: text, startRule: "s")
        #expect(reimported.rules["s"] == .token(name: "_class", matcher: matcher, isNamed: false))
    }

    @Test("A non-class alternation exports as alternated terminals")
    func nonClassAlternation() {
        let matcher = TokenMatcher.alternation([.literal("ab"), .literal("cd")])
        let rules: [String: Rule] = ["s": .token(name: "c", matcher: matcher, isNamed: false)]
        let text = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules))
        #expect(text.contains("'ab' | 'cd'"))
    }

    @Test("A sequence matcher exports as concatenated terminals")
    func sequenceMatcher() {
        let matcher = TokenMatcher.sequence([.literal("a"), .literal("b")])
        let rules: [String: Rule] = ["s": .token(name: "c", matcher: matcher, isNamed: false)]
        #expect(EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules)).contains("'a''b'"))
    }

    @Test("A repeated matcher exports with the matching postfix quantifier")
    func repeatedMatcher() {
        func text(_ matcher: TokenMatcher) -> String {
            EBNFGrammar.export(
                Grammar(name: "g", startRule: "s", rules: ["s": .token(name: "c", matcher: matcher, isNamed: false)]))
        }
        #expect(text(.repeated(min: 0, max: 1, .literal("a"))).contains("'a'?"))
        #expect(text(.repeated(min: 0, max: nil, .literal("a"))).contains("'a'*"))
        #expect(text(.repeated(min: 1, max: nil, .literal("a"))).contains("'a'+"))
        // A bounded repetition has no W3C EBNF quantifier, so the atom is emitted without one.
        #expect(text(.repeated(min: 2, max: 4, .literal("a"))).contains("'a'"))
    }

    @Test("A negated class body covers ranges, alternations and built-in classes")
    func negatedClassBodies() {
        func text(_ matcher: TokenMatcher) -> String {
            EBNFGrammar.export(
                Grammar(name: "g", startRule: "s", rules: ["s": .token(name: "c", matcher: matcher, isNamed: false)]))
        }
        #expect(text(.negated(.scalarRange(0x61...0x7A))).contains("[^a-z]"))
        #expect(text(.negated(.alternation([.literal("a"), .literal("b")]))).contains("[^ab]"))
        #expect(text(.negated(.builtin(.digit))).contains("[^0-9]"))
        #expect(text(.negated(.builtin(.whitespace))).contains("[^"))
    }

    @Test("Field and precedence wrappers inside a sequence and under a quantifier are emitted bare")
    func wrappersInContext() throws {
        let rules: [String: Rule] = [
            "s": .sequence([
                .field("f", .choice([.reference("a"), .reference("b")])),
                .repeatZeroOrMore(.precedence(level: 1, associativity: .none, .reference("a"))),
            ]),
            "a": .literal("a"),
            "b": .literal("b"),
        ]
        let text = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules))
        let reimported = try EBNFGrammar.grammar(from: text, startRule: "s")
        #expect(
            reimported.rules["s"]
                == .sequence([.choice([.reference("a"), .reference("b")]), .repeatZeroOrMore(.reference("a"))]))
    }

    @Test("Export tolerates a start rule that is absent from the rules")
    func exportMissingStartRule() {
        // The exporter does not validate the grammar (the engine does); a dangling start name is simply
        // skipped, leaving the remaining productions.
        let grammar = Grammar(name: "g", startRule: "ghost", rules: ["a": .literal("a")])
        #expect(EBNFGrammar.export(grammar) == "a ::= 'a'\n")
    }

    @Test("A production that is itself a field or precedence wrapper exports as its inner expression")
    func topLevelWrappers() {
        let field = Grammar(name: "g", startRule: "s", rules: ["s": .field("f", .reference("a")), "a": .literal("a")])
        #expect(EBNFGrammar.export(field).contains("s ::= a"))
        let prec = Grammar(
            name: "g", startRule: "s",
            rules: ["s": .precedence(level: 1, associativity: .left, .reference("a")), "a": .literal("a")])
        #expect(EBNFGrammar.export(prec).contains("s ::= a"))
    }

    @Test("An alternation mixing a class member and a built-in class exports as alternated forms")
    func mixedAlternation() {
        let matcher = TokenMatcher.alternation([.literal("a"), .builtin(.digit)])
        let rules: [String: Rule] = ["s": .token(name: "c", matcher: matcher, isNamed: false)]
        // The built-in member is not a single character, so the whole alternation falls back to the
        // alternated-terminal form rather than a single character class.
        #expect(EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules)).contains("'a' | [0-9]"))
    }

    @Test("A class member that is a delimiter is escaped on export")
    func escapedClassMembers() throws {
        let matcher = TokenMatcher.alternation([.literal("]"), .scalarRange(0x2D...0x2D)])
        let rules: [String: Rule] = ["s": .token(name: "c", matcher: matcher, isNamed: false)]
        let text = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: rules))
        #expect(text.contains("\\]"))
        #expect(text.contains("\\-"))
        let reimported = try EBNFGrammar.grammar(from: text, startRule: "s")
        #expect(reimported.rules["s"] == .token(name: "_class", matcher: matcher, isNamed: false))
    }

    @Test("A lookahead has no EBNF surface form, so it exports as a visible comment, not silently dropped")
    func lookaheadExportsAsComment() throws {
        let positive: [String: Rule] = [
            "s": .token(name: "k", matcher: .lookahead(negate: false, .literal("a")), isNamed: false)
        ]
        let positiveText = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: positive))
        #expect(positiveText.contains("/*"))
        #expect(positiveText.contains("followed-by"))
        #expect(positiveText.contains("'a'"))
        #expect(positiveText.contains("*/"))

        // A lookahead guarding a real terminal exports the terminal plus the comment; on re-import the
        // comment is skipped, leaving the terminal, so the construct is visible yet inert (never dropped
        // and never corrupting the re-imported grammar).
        let guarded = TokenMatcher.sequence([.lookahead(negate: true, .builtin(.digit)), .literal("x")])
        let negative: [String: Rule] = ["s": .token(name: "k", matcher: guarded, isNamed: false)]
        let negativeText = EBNFGrammar.export(Grammar(name: "g", startRule: "s", rules: negative))
        #expect(negativeText.contains("not-followed-by"))
        let reimported = try EBNFGrammar.grammar(from: negativeText, startRule: "s")
        #expect(reimported.rules["s"] == .literal("x"))
    }
}
