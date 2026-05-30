import Testing

import ParsingCore
import ParsingDSL

@testable import SwiftALLStar

@Suite("Adaptive prediction")
struct PredictionTests {
    /// Builds the JSON ATN and a predictor over the given UTF-8 input.
    private func jsonPredictor(_ text: String) throws -> (ATN, Predictor<Substring.UTF8View>, Substring.UTF8View) {
        let grammar = try LeftRecursionRewriter.rewrite(JSONGrammar.grammar())
        let atn = try ATNBuilder.build(grammar)
        let input = Substring.UTF8View.make(from: text)
        let predictor = Predictor(atn: atn, input: input, extras: grammar.extras)
        return (atn, predictor, input)
    }

    /// The decision id of the `_value` choice in the JSON ATN.
    private func valueDecision(_ atn: ATN) -> DecisionID {
        atn.states.first { $0.rule == "_value" && $0.decision != nil }!.decision!
    }

    @Test("_value prediction picks the alternative matching the first token", arguments: [
        ("{}", 1), ("[]", 2), (#""x""#, 3), ("123", 4), ("true", 5), ("false", 6), ("null", 7),
    ])
    func valuePredictions(_ pair: (String, Int)) throws {
        let (atn, predictor, input) = try jsonPredictor(pair.0)
        let decision = valueDecision(atn)
        let alt = predictor.adaptivePredict(
            decision: decision, callStack: [], start: input.startIndex, minPrecedence: 0)
        #expect(alt == pair.1)
    }

    @Test("Negative numbers predict the number alternative")
    func negativeNumberPrediction() throws {
        let (atn, predictor, input) = try jsonPredictor("-5")
        let alt = predictor.adaptivePredict(
            decision: valueDecision(atn), callStack: [], start: input.startIndex, minPrecedence: 0)
        #expect(alt == 4)
    }

    @Test("No viable alternative is reported for unmatched input")
    func noViableAlternative() throws {
        let (atn, predictor, input) = try jsonPredictor("@")
        let alt = predictor.adaptivePredict(
            decision: valueDecision(atn), callStack: [], start: input.startIndex, minPrecedence: 0)
        #expect(alt == Predictor<Substring.UTF8View>.noViableAlternative)
    }

    @Test("A common prefix that diverges past the decision yields no viable alternative")
    func divergingPrefixIsNoViable() throws {
        // Both alternatives share the prefix 'a' then require 'b' or 'c'; input "ax" matches the prefix
        // then dies during lookahead, exercising the DFA error sentinel.
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .choice([
                .sequence([.literal("a"), .literal("b")]),
                .sequence([.literal("a"), .literal("c")]),
            ]),
        ], extras: [])
        let atn = try ATNBuilder.build(grammar)
        let input = Substring.UTF8View.make(from: "ax")
        let predictor = Predictor(atn: atn, input: input, extras: grammar.extras)
        let decision = atn.states.first { $0.rule == "s" && $0.decision != nil }!.decision!
        let alt = predictor.adaptivePredict(
            decision: decision, callStack: [], start: input.startIndex, minPrecedence: 0)
        #expect(alt == Predictor<Substring.UTF8View>.noViableAlternative)
    }

    @Test("Predicting the same decision twice reuses cached DFA edges")
    func dfaCacheReuse() throws {
        let (atn, predictor, input) = try jsonPredictor("true")
        let decision = valueDecision(atn)
        _ = predictor.adaptivePredict(decision: decision, callStack: [], start: input.startIndex, minPrecedence: 0)
        let hitsAfterFirst = predictor.cacheHits
        _ = predictor.adaptivePredict(decision: decision, callStack: [], start: input.startIndex, minPrecedence: 0)
        #expect(predictor.cacheHits > hitsAfterFirst)
    }

    @Test("closure terminates on a right-recursive rule")
    func closureTerminatesOnRightRecursion() throws {
        // r -> 'a' r | 'a' : right recursion must not loop the closure.
        let grammar = Grammar(name: "g", startRule: "r", rules: [
            "r": .choice([
                .sequence([.literal("a"), .reference("r")]),
                .literal("a"),
            ]),
        ])
        let atn = try ATNBuilder.build(grammar)
        let input = Substring.UTF8View.make(from: "aaa")
        let predictor = Predictor(atn: atn, input: input, extras: grammar.extras)
        let decision = atn.states.first { $0.rule == "r" && $0.decision != nil }!.decision!
        // Prediction must return without diverging.
        let alt = predictor.adaptivePredict(decision: decision, callStack: [], start: input.startIndex, minPrecedence: 0)
        #expect(alt == 1)
    }

    @Test("closure terminates on a zero-or-more loop")
    func closureTerminatesOnStar() throws {
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .repeatZeroOrMore(.literal("a")),
        ])
        let atn = try ATNBuilder.build(grammar)
        let input = Substring.UTF8View.make(from: "aaa")
        let predictor = Predictor(atn: atn, input: input, extras: grammar.extras)
        let decision = atn.states.first { $0.rule == "s" && $0.decision != nil }!.decision!
        let alt = predictor.adaptivePredict(decision: decision, callStack: [], start: input.startIndex, minPrecedence: 0)
        // Alternative 1 is "take the body" (an 'a' is present).
        #expect(alt == 1)
    }

    @Test("SLL conflicts fail over to full LL for a stack-sensitive grammar")
    func stackSensitiveFailover() throws {
        // The report's canonical stack-sensitive grammar:
        //   S -> x B | y C ; B -> A 'a' ; C -> A 'b' 'a' ; A -> 'b' | (empty)
        // On lookahead beginning 'b', SLL cannot decide A's alternative without the call stack.
        let grammar = Grammar(name: "g", startRule: "s", rules: [
            "s": .choice([
                .sequence([.literal("x"), .reference("b")]),
                .sequence([.literal("y"), .reference("c")]),
            ]),
            "b": .sequence([.reference("a"), .literal("a")]),
            "c": .sequence([.reference("a"), .literal("b"), .literal("a")]),
            "a": .choice([.literal("b"), .sequence([])]),
        ])
        let engine = try ALLStarUTF8Parser(grammar: grammar)
        // Both stack contexts must parse correctly, exercising the LL failover path.
        let viaB = engine.parse(Source("xba"))
        let viaC = engine.parse(Source("ybba"))
        #expect(!viaB.hasErrors)
        #expect(!viaC.hasErrors)
        #expect(viaB.tree.green.reconstructedText == "xba")
        #expect(viaC.tree.green.reconstructedText == "ybba")
    }
}
