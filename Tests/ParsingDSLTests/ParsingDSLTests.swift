import Testing

import ParsingCore
@testable import ParsingDSL

@Suite("DSL combinators")
struct DSLCombinatorTests {
    @Test("String literal becomes anonymous literal token")
    func stringLiteral() {
        let expr: RuleExpr = "{"
        #expect(expr.rule == .literal("{"))
    }

    @Test("ref builds a reference")
    func reference() {
        #expect(ref("value").rule == .reference("value"))
    }

    @Test("seq collapses a single element but wraps multiples")
    func sequenceCollapse() {
        #expect(seq { ref("a") }.rule == .reference("a"))
        #expect(seq { "a"; ref("b") }.rule == .sequence([.literal("a"), .reference("b")]))
    }

    @Test("choice, optional, repeat, field")
    func compositeCombinators() {
        #expect(choice { ref("a"); ref("b") }.rule == .choice([.reference("a"), .reference("b")]))
        #expect(optional { ref("a") }.rule == .optional(.reference("a")))
        #expect(repeat0 { ref("a") }.rule == .repeatZeroOrMore(.reference("a")))
        #expect(repeat1 { ref("a") }.rule == .repeatOneOrMore(.reference("a")))
        #expect(field("key") { ref("a") }.rule == .field("key", .reference("a")))
    }

    @Test("token builders produce named and anonymous token rules")
    func tokenBuilders() {
        #expect(token("number", Match.oneOrMore(Match.digit)).rule
            == .token(name: "number", matcher: .repeated(min: 1, max: nil, .builtin(.digit)), isNamed: true))
        #expect(token(Match.lit("x")).rule == .token(name: "_token", matcher: .literal("x"), isNamed: false))
    }

    @Test("Match combinators build the matcher tree")
    func matchCombinators() {
        #expect(Match.range("0", "9") == .scalarRange(0x30 ... 0x39))
        #expect(Match.not(Match.lit("\"")) == .negated(.literal("\"")))
        #expect(Match.oneOf(Match.lit("a"), Match.lit("b")) == .alternation([.literal("a"), .literal("b")]))
        #expect(Match.seq(Match.digit, Match.any) == .sequence([.builtin(.digit), .anyElement]))
        #expect(Match.optional(Match.lit("-")) == .repeated(min: 0, max: 1, .literal("-")))
        #expect(Match.zeroOrMore(Match.whitespace) == .repeated(min: 0, max: nil, .builtin(.whitespace)))
        #expect(Match.hexDigit == .builtin(.hexDigit))
        #expect(Match.letter == .builtin(.letter))
    }

    @Test("Control-flow builders: if, if/else and for")
    func controlFlow() {
        let includeB = true
        let s = seq {
            ref("a")
            if includeB { ref("b") }
            if false { ref("never") } else { ref("c") }
            for name in ["d", "e"] { ref(name) }
        }
        #expect(s.rule == .sequence([
            .reference("a"), .reference("b"), .reference("c"), .reference("d"), .reference("e"),
        ]))
    }

    @Test("if-without-else omitted branch contributes nothing")
    func optionalBranchOmitted() {
        let s = seq {
            ref("a")
            if false { ref("b") }
        }
        #expect(s.rule == .reference("a"))
    }

    @Test("if/else taken branch (buildEither first)")
    func eitherFirst() {
        let s = seq {
            if true { ref("a") } else { ref("b") }
        }
        #expect(s.rule == .reference("a"))
    }
}

@Suite("Grammar building")
struct GrammarBuildingTests {
    @Test("Grammar DSL collects rules and start symbol")
    func grammarDSL() {
        let g = Grammar(name: "tiny", start: "s") {
            rule("s") { seq { "a"; ref("b") } }
            rule("b") { "b" }
        }
        #expect(g.name == "tiny")
        #expect(g.startRule == "s")
        #expect(g.rules.count == 2)
        #expect(g.rules["s"] == .sequence([.literal("a"), .reference("b")]))
        #expect(g.rules["b"] == .literal("b"))
    }
}

@Suite("JSON grammar")
struct JSONGrammarTests {
    let g = JSONGrammar.grammar()

    @Test("Top-level shape")
    func topLevel() {
        #expect(g.name == "json")
        #expect(g.startRule == "document")
        #expect(g.rules["document"] == .reference("_value"))
    }

    @Test("_value is a hidden choice of the seven JSON kinds")
    func valueChoice() {
        guard case let .choice(alts) = g.rules["_value"] else {
            Issue.record("_value should be a choice")
            return
        }
        let names = alts.compactMap { rule -> String? in
            if case let .reference(n) = rule { return n }
            return nil
        }
        #expect(names == ["object", "array", "string", "number", "true", "false", "null"])
    }

    @Test("pair labels key and value fields")
    func pairFields() {
        guard case let .sequence(parts) = g.rules["pair"] else {
            Issue.record("pair should be a sequence")
            return
        }
        let fieldNames = parts.compactMap { rule -> String? in
            if case let .field(name, _) = rule { return name }
            return nil
        }
        #expect(fieldNames == ["key", "value"])
    }

    @Test("literal keyword rules are present")
    func keywords() {
        #expect(g.rules["true"] == .literal("true"))
        #expect(g.rules["false"] == .literal("false"))
        #expect(g.rules["null"] == .literal("null"))
    }

    @Test("number and string_content are anonymous matcher tokens")
    func tokens() {
        // The token itself is anonymous; the named node comes from the rule reference.
        if case let .token(_, _, isNamed) = g.rules["number"] {
            #expect(!isNamed)
        } else {
            Issue.record("number should be a token")
        }
        #expect(g.rules["string_content"]
            == .token(name: "_token", matcher: .repeated(min: 1, max: nil, .negated(.literal("\""))), isNamed: false))
    }
}
