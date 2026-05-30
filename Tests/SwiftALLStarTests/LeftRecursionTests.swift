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

    /// A right-associative assignment grammar: `e -> e '=' e | id`.
    ///
    /// The single operator `=` is right-associative at level 1, so its right operand re-enters at the same
    /// precedence and absorbs a following `=`, yielding a right-leaning tree.
    private func assignmentGrammar() -> Grammar {
        Grammar(name: "assign", startRule: "e", rules: [
            "e": .choice([
                .precedence(level: 1, associativity: .right,
                    .sequence([.reference("e"), .literal("="), .reference("e")])),
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
        let engine = try ALLStarUTF8Parser(grammar: assignmentGrammar())
        let result = engine.parse(Source("a=b=c"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "a=b=c")
    }

    @Test("Multiplication binds tighter than addition, distinguishing a*b+c from a+b*c")
    func multiplicationBindsTighterThanAddition() throws {
        // Precedence-climbing must make these two inputs produce structurally different trees. Before the
        // fix every operator collapsed to the same right-leaning shape, so both were byte-identical.
        let engine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let timesThenPlus = engine.parse(Source("a*b+c"))
        let plusThenTimes = engine.parse(Source("a+b*c"))
        #expect(!timesThenPlus.hasErrors)
        #expect(!plusThenTimes.hasErrors)
        #expect(timesThenPlus.tree.green.reconstructedText == "a*b+c")
        #expect(plusThenTimes.tree.green.reconstructedText == "a+b*c")
        // The observable proof of binding: the two trees are no longer identical.
        #expect(timesThenPlus.sExpression() != plusThenTimes.sExpression())
        // `a*b+c`: the higher-precedence `*` refuses the lower `+` on its right operand, so the `+` is taken
        // by the outer loop as a sibling. The top `expr` therefore has three named `expr`/`id` children
        // (left operand, the `*` operand, the `+` operand) at one level rather than a single deep right
        // spine.
        let timesChildren = timesThenPlus.tree.green.children.filter { $0.node.kind.isNamed }
        #expect(timesChildren.count == 3)
        // `a+b*c`: the lower `+`'s right operand (entered at precedence 2) absorbs the `*`, so the `*`
        // subtree nests INSIDE the `+`'s right operand: exactly two top-level named children with a nested
        // operator below.
        let plusChildren = plusThenTimes.tree.green.children.filter { $0.node.kind.isNamed }
        #expect(plusChildren.count == 2)
    }

    @Test("1+2*3 nests the multiplication under the addition's right operand")
    func multiplicationNestsUnderAddition() throws {
        // The canonical precedence example. With climbing, `*` is bound below `+` (its right operand), which
        // is observable as a deeper nesting on the right than the all-`+` chain of the same length.
        let engine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let mixed = engine.parse(Source("a+b*c"))
        let allPlus = engine.parse(Source("a+b+c"))
        #expect(!mixed.hasErrors)
        #expect(!allPlus.hasErrors)
        // `a+b*c` has a nested operator under the addition (2 top-level named children, one of them an
        // operator subtree); `a+b+c` is left-leaning and flat (3 sibling named children, no nesting).
        let mixedChildren = mixed.tree.green.children.filter { $0.node.kind.isNamed }
        let plusChildren = allPlus.tree.green.children.filter { $0.node.kind.isNamed }
        #expect(mixedChildren.count == 2)
        #expect(plusChildren.count == 3)
        #expect(mixed.sExpression() != allPlus.sExpression())
    }

    @Test("A left-associative operator chain is left-leaning (flat siblings)")
    func leftAssociativeChainIsLeftLeaning() throws {
        // Left-assoc `+`: the first `+`'s right operand enters at level+1 and refuses the second `+`, which
        // the outer loop takes on the left. The result is a flat spine of sibling operands, NOT the deep
        // right nesting a right-associative operator of the same input length produces.
        let leftEngine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let leftChain = leftEngine.parse(Source("a+b+c"))
        let rightEngine = try ALLStarUTF8Parser(grammar: assignmentGrammar())
        let rightChain = rightEngine.parse(Source("a=b=c"))
        #expect(!leftChain.hasErrors)
        #expect(!rightChain.hasErrors)
        // Left-leaning: three sibling named children directly under the top `expr`.
        let leftChildren = leftChain.tree.green.children.filter { $0.node.kind.isNamed }
        #expect(leftChildren.count == 3)
        // Right-leaning: two top-level named children, the second of which nests the remaining chain.
        let rightChildren = rightChain.tree.green.children.filter { $0.node.kind.isNamed }
        #expect(rightChildren.count == 2)
        // The two associativities therefore yield structurally different trees for the analogous input.
        #expect(treeDepth(leftChain) < treeDepth(rightChain))
    }

    @Test("A right-associative operator chain is right-leaning (deep nesting)")
    func rightAssociativeChainIsRightLeaning() throws {
        // Right-assoc `=`: the first `=`'s right operand enters at level (not level+1), so it admits the
        // second `=` and nests it on the right, producing a deeper tree than the left-assoc chain.
        let engine = try ALLStarUTF8Parser(grammar: assignmentGrammar())
        let chain = engine.parse(Source("a=b=c"))
        #expect(!chain.hasErrors)
        #expect(chain.tree.green.reconstructedText == "a=b=c")
        // Two top-level named children; the second one nests the rest of the chain (right-leaning).
        let topChildren = chain.tree.green.children.filter { $0.node.kind.isNamed }
        #expect(topChildren.count == 2)
        // A longer chain nests one level deeper, confirming each operator nests on the right.
        let longer = engine.parse(Source("a=b=c=d"))
        #expect(!longer.hasErrors)
        #expect(treeDepth(longer) > treeDepth(chain))
    }

    @Test("A mixed-precedence expression climbs across three operators")
    func mixedPrecedenceClimb() throws {
        // `a+b*c+d`: the middle `*` binds `b` and `c` together (nested), while the two `+`s form a flat
        // left-leaning outer spine, distinct from both the all-`+` and the simple `a+b*c` trees.
        let engine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let mixed = engine.parse(Source("a+b*c+d"))
        let allPlus = engine.parse(Source("a+b+c+d"))
        #expect(!mixed.hasErrors)
        #expect(!allPlus.hasErrors)
        #expect(mixed.tree.green.reconstructedText == "a+b*c+d")
        #expect(allPlus.tree.green.reconstructedText == "a+b+c+d")
        // The two trees differ: the mixed input has the `*` nested inside one of the `+` operands, the
        // all-`+` input is a flat four-way left-leaning spine.
        #expect(mixed.sExpression() != allPlus.sExpression())
        let mixedChildren = mixed.tree.green.children.filter { $0.node.kind.isNamed }
        let allPlusChildren = allPlus.tree.green.children.filter { $0.node.kind.isNamed }
        // `a+b+c+d` is a flat spine of four sibling operands; `a+b*c+d` has fewer top-level children
        // because one `+` operand wraps the nested `*`.
        #expect(allPlusChildren.count == 4)
        #expect(mixedChildren.count < allPlusChildren.count)
    }

    @Test("A deep left-associative chain terminates without overflow")
    func deepChainTerminates() throws {
        // The right operand re-enters through a token-consuming operator edge, so no new left recursion is
        // introduced and the busy set bounds right recursion: a long chain parses without looping.
        let engine = try ALLStarUTF8Parser(grammar: arithmeticGrammar())
        let input = Array(repeating: "a", count: 40).joined(separator: "+")
        let result = engine.parse(Source(input))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == input)
    }

    /// The maximum depth of named nodes in a parse tree, used to compare left- vs right-leaning shapes.
    private func treeDepth(_ result: ParseResult) -> Int {
        func depth(_ node: GreenNode) -> Int {
            let childDepths = node.children.map { depth($0.node) }
            return 1 + (childDepths.max() ?? 0)
        }
        return depth(result.tree.green)
    }
}
