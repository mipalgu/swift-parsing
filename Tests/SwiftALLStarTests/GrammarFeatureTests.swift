import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent

@testable import SwiftALLStar

@Suite("Grammar features")
struct GrammarFeatureTests {
    /// Parses a grammar with the ALL(*) engine and asserts agreement with the reference.
    private func bothAgree(_ grammar: Grammar, _ text: String) throws -> ParseResult {
        let reference = try UTF8Parser(grammar: grammar).parse(Source(text))
        let allStar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(text))
        #expect(allStar.sExpression() == reference.sExpression())
        #expect(allStar.tree.green.reconstructedText == text)
        return allStar
    }

    @Test("Rich matchers: ranges, builtins, alternation, repetition and anyElement")
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
        let result = try bothAgree(grammar, "a12!!xZyes")
        #expect(result.sExpression() == "(s (letter) (digits) (bounded) (notbang) (anything) (kw))")
    }

    @Test("hexDigit and letter built-in classes")
    func hexAndLetter() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .sequence([
                .token(name: "hex", matcher: Match.oneOrMore(Match.hexDigit), isNamed: true),
                .token(name: "word", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ], extras: [])
        let result = try bothAgree(grammar, "1aF3Zebra")
        #expect(result.sExpression() == "(s (hex) (word))")
    }

    @Test("repeatOneOrMore parses a run and agrees with the reference")
    func repeatOneOrMore() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .repeatOneOrMore(.token(name: "c", matcher: Match.lit("c"), isNamed: true)),
        ])
        let result = try bothAgree(grammar, "ccc")
        #expect(result.sExpression() == "(s (c) (c) (c))")
    }

    @Test("repeatOneOrMore with no match recovers like the reference")
    func repeatOneOrMoreNoMatch() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: ["s": .repeatOneOrMore(.literal("c"))])
        let result = try bothAgree(grammar, "x")
        #expect(result.hasErrors)
    }

    @Test("Optional, sequence and zero-or-more agree with the reference")
    func optionalAndStar() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .sequence([
                .optional(.token(name: "a", matcher: Match.lit("a"), isNamed: true)),
                .repeatZeroOrMore(.token(name: "b", matcher: Match.lit("b"), isNamed: true)),
            ]),
        ])
        _ = try bothAgree(grammar, "abbb")
        _ = try bothAgree(grammar, "bbb")
        _ = try bothAgree(grammar, "")
    }

    @Test("A multi-element literal matcher agrees with the reference")
    func multiElementLiteral() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .token(name: "kw", matcher: Match.lit("hello"), isNamed: true),
        ])
        let result = try bothAgree(grammar, "hello")
        #expect(result.sExpression() == "(s (kw))")
    }

    @Test("scalarRange matcher agrees with the reference")
    func scalarRange() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .token(name: "d", matcher: .scalarRange(0x30...0x39), isNamed: true),
        ])
        _ = try bothAgree(grammar, "7")
    }

    @Test("A hidden rule that yields several children splices them into the parent")
    func hiddenRuleSplicesChildren() throws {
        // `_pair` is hidden and produces two named children; referenced unlabelled, they splice up.
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .reference("_pair"),
            "_pair": .sequence([
                .token(name: "a", matcher: Match.lit("a"), isNamed: true),
                .token(name: "b", matcher: Match.lit("b"), isNamed: true),
            ]),
        ])
        let result = try bothAgree(grammar, "ab")
        #expect(result.sExpression() == "(s (a) (b))")
    }

    @Test("A field over a hidden multi-child rule groups the children under the label")
    func fieldGroupsHiddenChildren() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .field("pair", .reference("_pair")),
            "_pair": .sequence([
                .token(name: "a", matcher: Match.lit("a"), isNamed: true),
                .token(name: "b", matcher: Match.lit("b"), isNamed: true),
            ]),
        ])
        // The children are wrapped in an anonymous, field-labelled group, matching the reference engine.
        _ = try bothAgree(grammar, "ab")
    }

    @Test("A bare precedence wrapper is transparent")
    func barePrecedenceWrapper() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .precedence(level: 1, associativity: .left,
                .token(name: "c", matcher: Match.lit("c"), isNamed: true)),
        ])
        let result = try bothAgree(grammar, "c")
        #expect(result.sExpression() == "(s (c))")
    }

    @Test("A hidden start rule with a single child surfaces that child directly")
    func hiddenStartRuleSingleChild() throws {
        let grammar = Grammar(name: "g", startRule: "_root", rules: [
            "_root": .token(name: "v", matcher: Match.lit("v"), isNamed: true),
        ])
        let result = try ALLStarUTF8Parser(grammar: grammar).parse(Source("v"))
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(v)")
        #expect(result.tree.green.reconstructedText == "v")
    }

    @Test("A hidden start rule with several children groups them invisibly")
    func hiddenStartRuleMultiChild() throws {
        let grammar = Grammar(name: "g", startRule: "_root", rules: [
            "_root": .sequence([
                .token(name: "a", matcher: Match.lit("a"), isNamed: true),
                .token(name: "b", matcher: Match.lit("b"), isNamed: true),
            ]),
        ])
        let result = try ALLStarUTF8Parser(grammar: grammar).parse(Source("ab"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "ab")
    }

    @Test("A multi-element token that dies mid-lookahead recovers")
    func partialTokenDeath() throws {
        // Two alternatives whose tokens share a prefix; input matches the prefix then diverges, so the
        // longer alternative dies during lookahead and prediction must recover.
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .choice([
                .token(name: "kw", matcher: Match.lit("foobar"), isNamed: true),
                .token(name: "id", matcher: Match.lit("foo"), isNamed: true),
            ]),
        ])
        let result = try ALLStarUTF8Parser(grammar: grammar).parse(Source("foo"))
        #expect(!result.hasErrors)
        #expect(result.sExpression() == "(s (id))")
    }
}
