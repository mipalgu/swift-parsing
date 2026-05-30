import ParsingCore
import SwiftALLStar
import Testing

@testable import G4Import

/// Verifies that directly left-recursive `.g4` rules imported as `Rule.precedence` tiers bind with the
/// correct precedence and associativity when executed by the ALL(*) precedence-climbing engine.
///
/// These tests construct an `ALLStarUTF8Parser` over the imported grammar (the same engine `LuaGrammar`
/// and `CGrammar` drive) and assert the resulting tree shape, which is the observable proof of binding:
/// a higher-precedence operator nests under a lower-precedence operator's operand, and a right-associative
/// operator nests on the right while a left-associative one stays flat.
@Suite("G4 imported precedence binding (ALL(*))")
struct G4PrecedenceTests {
    /// An arithmetic grammar whose operator alternatives, in source order, are `^` (tightest), `*`, then
    /// `+` (loosest), with `^` declared right-associative via a leading `<assoc=right>` option.
    private static let arithmetic = """
        grammar Arith;
        e :<assoc=right> e '^' e | e '*' e | e '+' e | INT ;
        INT : [0-9]+ ;
        """

    /// A grammar isolating a right-associative `^` and a default left-associative `-`.
    private static let powerAndMinus = """
        grammar PM;
        e :<assoc=right> e '^' e | e '-' e | INT ;
        INT : [0-9]+ ;
        """

    private func parser(_ source: String) throws -> ALLStarUTF8Parser {
        try ALLStarUTF8Parser(grammar: G4Grammar.grammar(fromString: source))
    }

    /// The number of named children directly under the parse tree's root.
    private func topNamedChildCount(_ result: ParseResult) -> Int {
        result.tree.green.children.filter { $0.node.kind.isNamed }.count
    }

    /// The maximum depth of the parse tree, used to compare left- and right-leaning shapes.
    private func treeDepth(_ result: ParseResult) -> Int {
        func depth(_ node: GreenNode) -> Int {
            1 + (node.children.map { depth($0.node) }.max() ?? 0)
        }
        return depth(result.tree.green)
    }

    @Test("Multiplication binds tighter than addition in an imported grammar")
    func multiplicationNestsUnderAddition() throws {
        let engine = try parser(Self.arithmetic)
        let plusThenTimes = engine.parse(Source("1+2*3"))
        let timesThenPlus = engine.parse(Source("1*2+3"))
        #expect(!plusThenTimes.hasErrors)
        #expect(!timesThenPlus.hasErrors)
        #expect(plusThenTimes.tree.green.reconstructedText == "1+2*3")
        #expect(timesThenPlus.tree.green.reconstructedText == "1*2+3")
        // `1+2*3`: the `+`'s right operand absorbs the tighter `*`, so the `*` subtree nests inside the
        // `+`'s operand: a single nested named child and a deeper tree.
        #expect(topNamedChildCount(plusThenTimes) == 1)
        // `1*2+3`: the tighter `*` refuses the looser `+` on its right, so the `+` is taken by the outer
        // loop as a sibling, giving two flat named children and a shallower tree.
        #expect(topNamedChildCount(timesThenPlus) == 2)
        #expect(treeDepth(plusThenTimes) > treeDepth(timesThenPlus))
        #expect(plusThenTimes.sExpression() != timesThenPlus.sExpression())
    }

    @Test("A right-associative imported power operator is right-leaning")
    func rightAssociativePowerIsRightLeaning() throws {
        let engine = try parser(Self.powerAndMinus)
        let chain = engine.parse(Source("2^2^3"))
        #expect(!chain.hasErrors)
        #expect(chain.tree.green.reconstructedText == "2^2^3")
        // Right-associative: the right operand absorbs the next `^`, so the chain nests on the right as a
        // single deep spine (one named child at the top) rather than flat siblings.
        #expect(topNamedChildCount(chain) == 1)
        // A longer chain nests one level deeper, confirming each `^` groups on the right.
        let deeper = engine.parse(Source("2^2^2^3"))
        #expect(!deeper.hasErrors)
        #expect(treeDepth(deeper) > treeDepth(chain))
    }

    @Test("A default left-associative imported operator is left-leaning")
    func leftAssociativeChainIsLeftLeaning() throws {
        let engine = try parser(Self.powerAndMinus)
        let chain = engine.parse(Source("5-3-1"))
        #expect(!chain.hasErrors)
        #expect(chain.tree.green.reconstructedText == "5-3-1")
        // Left-associative: the right operand refuses the next `-`, which the outer loop takes on the left,
        // so the operands stay flat siblings (two named children) rather than a deep right spine.
        #expect(topNamedChildCount(chain) == 2)
        let rightChain = engine.parse(Source("2^2^2"))
        #expect(!rightChain.hasErrors)
        // The same input length is shallower when left-associative than when right-associative.
        #expect(treeDepth(chain) < treeDepth(rightChain))
    }

    @Test("A deep left-associative chain parses without overflow and round-trips")
    func deepLeftAssociativeChainRoundTrips() throws {
        let engine = try parser(Self.powerAndMinus)
        let input = Array(repeating: "1", count: 40).joined(separator: "-")
        let result = engine.parse(Source(input))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == input)
    }

    @Test("ANTLR's documented `<assoc=right>` example imports with `=` right-associative")
    func antlrDocumentedExampleImports() throws {
        // The exact example from the ANTLR 4 reference: `*` and `+` default to left-associative, while the
        // ternary `?:` and `=` carry leading `<assoc=right>` options.
        let source = """
            grammar G;
            e : e '*' e
              | e '+' e
              |<assoc=right> e '?' e ':' e
              |<assoc=right> e '=' e
              | INT
              ;
            INT : [0-9]+ ;
            """
        let grammar = try G4Grammar.grammar(fromString: source)
        let choice = try #require(
            grammar.rules["e"].flatMap { if case .choice(let alts) = $0 { alts } else { nil } })
        // Four operator tiers (levels 4..1) precede the INT primary; the `=` tier is the loosest (level 1)
        // and must be right-associative.
        let assignmentTier = try #require(choice.dropLast().last)
        guard case .precedence(let level, let associativity, _) = assignmentTier else {
            Issue.record("the `=` alternative did not lower to a precedence tier")
            return
        }
        #expect(level == 1)
        #expect(associativity == .right)
        // The imported grammar also constructs and parses, proving the tiers are engine-valid.
        let engine = try ALLStarUTF8Parser(grammar: grammar)
        let result = engine.parse(Source("1=2=3"))
        #expect(!result.hasErrors)
        #expect(result.tree.green.reconstructedText == "1=2=3")
    }
}
