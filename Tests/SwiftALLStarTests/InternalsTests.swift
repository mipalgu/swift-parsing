import Testing

import ParsingCore
import ParsingDSL

@testable import SwiftALLStar

@Suite("Prediction internals")
struct InternalsTests {
    @Test("A precedence guard admits operators at or above the minimum and rejects below it")
    func predicateHolds() {
        let high = Predicate(level: 3, associativity: .left)
        let low = Predicate(level: 1, associativity: .right)
        #expect(high.holds(minPrecedence: 0))
        #expect(high.holds(minPrecedence: 3))
        #expect(!low.holds(minPrecedence: 2))
        #expect(low.holds(minPrecedence: 1))
    }

    @Test("Merging a stack with itself returns that stack")
    func mergeIdentical() {
        let context = PredictionContext.empty.pushing(1).pushing(2)
        #expect(context.merged(with: context) == context)
    }

    @Test("The wildcard absorbs any other stack on merge")
    func wildcardAbsorbs() {
        let concrete = PredictionContext.empty.pushing(5)
        #expect(concrete.merged(with: .wildcard) == .wildcard)
        #expect(PredictionContext.wildcard.merged(with: concrete) == .wildcard)
    }

    @Test("Merging two distinct stacks forks them")
    func mergeForks() {
        let a = PredictionContext.empty.pushing(1)
        let b = PredictionContext.empty.pushing(2)
        let merged = a.merged(with: b)
        if case .fork(let parts) = merged {
            #expect(parts.count == 2)
        } else {
            Issue.record("expected a fork of two distinct stacks")
        }
        // A fork exposes the tops of all its branches.
        #expect(merged.tops().count == 2)
    }

    @Test("A fork carrying the wildcard collapses to the wildcard")
    func forkWithWildcardCollapses() {
        let a = PredictionContext.empty.pushing(1)
        let withWildcard = a.merged(with: .wildcard)
        #expect(withWildcard == .wildcard)
    }

    @Test("hasWildcard detects the wildcard through nodes and forks")
    func hasWildcardDetection() {
        #expect(PredictionContext.wildcard.hasWildcard)
        #expect(PredictionContext.wildcard.pushing(3).hasWildcard)
        #expect(!PredictionContext.empty.pushing(3).hasWildcard)
        #expect(PredictionContext.fork([.empty, .wildcard]).hasWildcard)
    }

    @Test("A configuration set deduplicates and merges by location")
    func configSetMerge() {
        var set = ConfigSet()
        set.insert(ATNConfig(state: 1, alt: 1, context: .empty.pushing(1)))
        set.insert(ATNConfig(state: 1, alt: 1, context: .empty.pushing(2)))
        // Same (state, alt): one configuration with a merged (forked) context.
        #expect(set.configs.count == 1)
        set.insert(ATNConfig(state: 1, alt: 2, context: .empty))
        #expect(set.configs.count == 2)
        #expect(set.alternatives == [1, 2])
    }

    @Test("A precedence-guarded decision routes through full LL and parses correctly")
    func precedenceGuardedRoutesThroughLL() throws {
        // The operator loop's body reaches a precedence-guard predicate, so its decision is recognised as
        // predicated and resolved by full LL.
        let grammar = Grammar(name: "expr", startRule: "e", rules: [
            "e": .choice([
                .precedence(level: 1, associativity: .left,
                    .sequence([.reference("e"), .literal("+"), .reference("e")])),
                .token(name: "id", matcher: Match.oneOrMore(Match.letter), isNamed: true),
            ]),
        ], extras: [])
        let result = try ALLStarUTF8Parser(grammar: grammar).parse(Source("a+b"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "a+b")
    }
}
