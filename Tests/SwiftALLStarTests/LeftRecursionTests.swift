import Testing

import ParsingCore
import ParsingDSL

@testable import SwiftALLStar

@Suite("Left recursion")
struct LeftRecursionTests {
    /// An arithmetic grammar with direct left recursion and declared operator precedence.
    ///
    /// `expr -> expr '+' expr | expr '*' expr | id`, with `*` binding tighter than `+`, both
    /// left-associative. The rewriter must eliminate the direct left recursion before the ATN is built.
    private func arithmeticGrammar() -> Grammar {
        Grammar(name: "arith", startRule: "expr", rules: [
            "expr": .choice([
                .precedence(level: 2, associativity: .left,
                    .sequence([.reference("expr"), .literal("*"), .reference("expr")])),
                .precedence(level: 1, associativity: .left,
                    .sequence([.reference("expr"), .literal("+"), .reference("expr")])),
                .token(name: "id", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ], extras: [])
    }

    @Test("The rewriter eliminates direct left recursion so the engine constructs")
    func constructsAfterRewrite() throws {
        #expect(throws: Never.self) { _ = try ALLStarUTF8Parser(grammar: arithmeticGrammar()) }
    }

    @Test("The rewritten grammar has no left recursion remaining")
    func rewriteRemovesLeftRecursion() throws {
        let rewritten = try LeftRecursionRewriter.rewrite(arithmeticGrammar())
        // Building the ATN runs the post-rewrite left-recursion guard; it must not throw.
        #expect(throws: Never.self) { _ = try ATNBuilder.build(rewritten) }
    }

    @Test("A simple left-recursive expression parses and round-trips")
    func parsesExpression() throws {
        let engine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let result = engine.parse(Source("a+b*c"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "a+b*c")
    }

    @Test("Repeated left-associative operators all parse")
    func leftAssociativeChain() throws {
        let engine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let result = engine.parse(Source("a+b+c+d"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "a+b+c+d")
    }

    @Test("A right-associative grammar constructs and parses")
    func rightAssociative() throws {
        let grammar = Grammar(name: "assign", startRule: "e", rules: [
            "e": .choice([
                .precedence(level: 1, associativity: .right,
                    .sequence([.reference("e"), .literal("="), .reference("e")])),
                .token(name: "id", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ], extras: [])
        let engine = try ALLStarUTF8Parser(grammar: grammar)
        let result = engine.parse(Source("a=b=c"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "a=b=c")
    }
}
