import Testing

import ParsingCore
import ParsingDSL

@testable import SwiftALLStar

@Suite("ATN construction")
struct ATNTests {
    /// Builds the ATN for the JSON grammar, after the (no-op) left-recursion rewrite.
    private func jsonATN() throws -> ATN {
        let grammar = try LeftRecursionRewriter.rewrite(JSONGrammar.grammar())
        return try ATNBuilder.build(grammar)
    }

    @Test("Every rule has an entry and a stop state")
    func entryAndStopStates() throws {
        let atn = try jsonATN()
        for rule in ["document", "_value", "object", "pair", "array", "string", "string_content", "number", "true", "false", "null"] {
            #expect(atn.ruleEntry[rule] != nil)
            #expect(atn.ruleStop[rule] != nil)
            let stop = atn.ruleStop[rule]!
            #expect(atn[stop].isStop)
        }
    }

    @Test("The _value choice is a seven-way decision")
    func valueDecisionFanout() throws {
        let atn = try jsonATN()
        let entry = atn.ruleEntry["_value"]!
        // The entry's first transition leads to the decision state of the choice.
        let decisionState = findDecisionState(in: atn, rule: "_value")
        #expect(decisionState != nil)
        #expect(atn[decisionState!].transitions.count == 7)
        _ = entry
    }

    @Test("object and array contain optional and loop decisions")
    func objectAndArrayDecisions() throws {
        let atn = try jsonATN()
        // Each has an optional (presence) decision and a repeat0 (comma loop) decision.
        for rule in ["object", "array"] {
            let decisions = decisionStates(in: atn, rule: rule)
            #expect(decisions.count >= 2)
        }
    }

    @Test("Atom edges carry the right token metadata and fields")
    func atomMetadata() throws {
        let atn = try jsonATN()
        // The `pair` rule labels its key and value children via fields on rule edges.
        var keyFieldSeen = false
        var valueFieldSeen = false
        for state in atn.states where state.rule == "pair" {
            for transition in state.transitions {
                if case .rule(_, _, _, _, _, let field, _, _) = transition {
                    if field == "key" { keyFieldSeen = true }
                    if field == "value" { valueFieldSeen = true }
                }
            }
        }
        #expect(keyFieldSeen)
        #expect(valueFieldSeen)
    }

    @Test("true/false/null submachines consume a single literal")
    func keywordSubmachines() throws {
        let atn = try jsonATN()
        for (rule, literal) in [("true", "true"), ("false", "false"), ("null", "null")] {
            var found = false
            for state in atn.states where state.rule == rule {
                for transition in state.transitions {
                    if case .atom(let matcher, _, _, _, _) = transition, matcher == .literal(literal) {
                        found = true
                    }
                }
            }
            #expect(found)
        }
    }

    @Test("A directly self-recursive rule with no base case is rejected")
    func unsalvageableSelfRecursion() {
        let grammar = Grammar(name: "g", startRule: "a", rules: ["a": .reference("a")])
        #expect(throws: GrammarError.self) {
            let rewritten = try LeftRecursionRewriter.rewrite(grammar)
            _ = try ATNBuilder.build(rewritten)
        }
    }

    // MARK: - Precedence carrier (left-recursion right operand)

    /// The arithmetic ATN: `expr -> expr '*' expr | expr '+' expr | id`, after the rewrite.
    private func arithmeticATN() throws -> ATN {
        let grammar = Grammar(name: "arith", startRule: "expr", rules: [
            "expr": .choice([
                .precedence(level: 2, associativity: .left,
                    .sequence([.reference("expr"), .literal("*"), .reference("expr")])),
                .precedence(level: 1, associativity: .left,
                    .sequence([.reference("expr"), .literal("+"), .reference("expr")])),
                .token(name: "id", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ], extras: [])
        return try ATNBuilder.build(LeftRecursionRewriter.rewrite(grammar))
    }

    /// The enter-at precedences carried by every `expr` self-call edge, paired with the operator literal
    /// that immediately precedes the edge (so left- vs right-associativity can be told apart).
    private func selfCallEnterPrecedences(in atn: ATN, rule: String) -> [Int?] {
        atn.states
            .filter { $0.rule == rule }
            .flatMap(\.transitions)
            .compactMap { transition -> Int? in
                if case .rule(_, _, rule, _, _, _, _, let enterPrecedence) = transition { return enterPrecedence }
                return nil
            }
    }

    @Test("The right-operand rule edge carries level+1 for left-associative operators")
    func leftAssociativeRightOperandEntersAtLevelPlusOne() throws {
        let atn = try arithmeticATN()
        // `*` is declared at level 2 and `+` at level 1, both left-associative, so their right operands
        // re-enter at 3 and 2 respectively.
        let enterPrecedences = Set(selfCallEnterPrecedences(in: atn, rule: "expr"))
        #expect(enterPrecedences == [3, 2])
    }

    @Test("The right-operand rule edge carries level for right-associative operators")
    func rightAssociativeRightOperandEntersAtLevel() throws {
        let grammar = Grammar(name: "assign", startRule: "e", rules: [
            "e": .choice([
                .precedence(level: 1, associativity: .right,
                    .sequence([.reference("e"), .literal("="), .reference("e")])),
                .token(name: "id", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ], extras: [])
        let atn = try ATNBuilder.build(LeftRecursionRewriter.rewrite(grammar))
        // `=` is right-associative at level 1, so its right operand re-enters at exactly 1, not 2.
        #expect(selfCallEnterPrecedences(in: atn, rule: "e") == [1])
    }

    @Test("Ordinary rule edges carry no enter-at precedence")
    func ordinaryRuleEdgesCarryNoEnterPrecedence() throws {
        let atn = try jsonATN()
        // JSON has no precedence wrappers and no self-recursion, so no rule edge carries an enter-at
        // precedence: the whole precedence path is dead code for it.
        var sawRuleEdge = false
        for state in atn.states {
            for transition in state.transitions {
                if case .rule(_, _, _, _, _, _, _, let enterPrecedence) = transition {
                    sawRuleEdge = true
                    #expect(enterPrecedence == nil)
                }
            }
        }
        #expect(sawRuleEdge)
    }

    @Test("Both decisions of a left-recursive rule are predicated and route through full LL")
    func leftRecursiveDecisionsArePredicated() throws {
        let atn = try arithmeticATN()
        let predictor = Predictor(atn: atn, input: Substring.UTF8View.make(from: ""), extras: [])
        let decisions = decisionStates(in: atn, rule: "expr").compactMap { atn[$0].decision }
        // The rewritten `expr` has exactly two decisions: the operator-loop-stop (repeat) decision and the
        // operator-choice decision. Both reach a precedence-guard predicate, so both are recognised as
        // predicated and never reuse a precedence-0 SLL DFA state.
        #expect(decisions.count == 2)
        for decision in decisions {
            #expect(predictor.isPredicated(decision))
        }
    }

    // MARK: - Helpers

    private func findDecisionState(in atn: ATN, rule: String) -> ATNStateID? {
        atn.states.first { $0.rule == rule && $0.decision != nil }?.id
    }

    private func decisionStates(in atn: ATN, rule: String) -> [ATNStateID] {
        atn.states.filter { $0.rule == rule && $0.decision != nil }.map(\.id)
    }
}
