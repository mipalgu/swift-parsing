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

    // MARK: - Helpers

    private func findDecisionState(in atn: ATN, rule: String) -> ATNStateID? {
        atn.states.first { $0.rule == rule && $0.decision != nil }?.id
    }

    private func decisionStates(in atn: ATN, rule: String) -> [ATNStateID] {
        atn.states.filter { $0.rule == rule && $0.decision != nil }.map(\.id)
    }
}
