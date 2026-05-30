import ParsingCore
import ParsingDSL
import SwiftALLStar
import Testing

/// Precedence and associativity proofs for the directly left-recursive Lua expression grammar.
///
/// These run on the ALL(*) engine only, because it is the engine whose left-recursion rewriter turns the
/// `.precedence`-annotated `exp` ladder into a precedence-climbing operator loop. Each test parses an
/// expression and asserts the nesting shape that proves the operators bound with the right precedence and
/// associativity, read from the named operand children directly under the top `exp` node: a flat run of
/// operand children is left-leaning, while two operands whose last one nests a further operator is
/// right-leaning (or a tighter operator pulled into the right operand).
@Suite("Lua expression precedence and associativity")
struct LuaPrecedenceTests {
    /// A reusable ALL(*) engine over the expression grammar; constructing it proves the rewriter accepts
    /// the eight-tier direct left recursion.
    private static let engine: ALLStarUTF8Parser = {
        // Force-try is acceptable in a test fixture: a construction failure is itself a test failure.
        try! ALLStarUTF8Parser(grammar: LuaGrammar.expressions())
    }()

    /// Parses an expression, asserting it is accepted and round-trips losslessly.
    private func parse(_ input: String, _ sourceLocation: SourceLocation = #_sourceLocation) -> ParseResult {
        let result = Self.engine.parse(Source(input))
        #expect(!result.hasErrors, "should parse: \(input)", sourceLocation: sourceLocation)
        #expect(
            result.tree.green.reconstructedText == input, "should round-trip: \(input)",
            sourceLocation: sourceLocation)
        return result
    }

    /// The operand children (named `exp` or `primary_exp` nodes) directly under a node.
    ///
    /// The first operand of an operator loop renders as a `primary_exp` (the loop's primary), and each
    /// subsequent operand as an `exp`, so both kinds count as operands.
    private func operands(of node: Syntax) -> [Syntax] {
        node.children.filter { $0.kind.name == "exp" || $0.kind.name == "primary_exp" }
    }

    /// Whether a node's last operand itself nests a further operator (an `exp` with its own operands).
    private func lastOperandNests(_ node: Syntax) -> Bool {
        guard let last = operands(of: node).last else { return false }
        return last.kind.name == "exp" && operands(of: last).count >= 2
    }

    @Test("Constructing the ALL(*) engine accepts the eight-tier direct left recursion")
    func engineConstructs() throws {
        #expect(throws: Never.self) { _ = try ALLStarUTF8Parser(grammar: LuaGrammar.expressions()) }
    }

    @Test("A bare name parses as a single primary expression")
    func bareName() {
        let result = parse("a")
        #expect(result.sExpression() == "(exp (primary_exp (name)))")
    }

    @Test("Subtraction is left-associative: a - b - c groups flat as (a - b) - c")
    func subtractionLeftAssociative() {
        let result = parse("a - b - c")
        // Left-leaning: three flat operand siblings under one top exp, none nesting a further operator.
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("Concatenation is right-associative: a .. b .. c groups as a .. (b .. c)")
    func concatenationRightAssociative() {
        let result = parse("a .. b .. c")
        // Right-leaning: two operands, the second nesting the remaining concatenation.
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    @Test("Exponentiation is right-associative: 2 ^ 2 ^ 3 groups as 2 ^ (2 ^ 3)")
    func exponentiationRightAssociative() {
        let result = parse("2 ^ 2 ^ 3")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    @Test("and binds tighter than or: a or b and c nests the and under the or's right operand")
    func andBindsTighterThanOr() {
        let result = parse("a or b and c")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    @Test("Multiplication binds tighter than addition: a + b * c nests the product under the sum")
    func multiplicationNestsUnderAddition() {
        let result = parse("a + b * c")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    @Test("Multiplication does not absorb a trailing addition: a * b + c keeps the + at the top")
    func multiplicationDoesNotAbsorbTrailingAddition() {
        let result = parse("a * b + c")
        // The `+` is the outermost operator with the `*` product as its flat left operand: three flat
        // operands, the product not pulled into a right operand.
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("a + b * c and a * b + c produce structurally different trees")
    func mixedPrecedenceTreesDiffer() {
        let plusThenTimes = parse("a + b * c")
        let timesThenPlus = parse("a * b + c")
        #expect(plusThenTimes.sExpression() != timesThenPlus.sExpression())
    }

    @Test("Comparison chains left: a < b == c groups flat as (a < b) == c")
    func comparisonLeftAssociative() {
        let result = parse("a < b == c")
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("Unary minus binds tighter than every binary operator but looser than power: -2 ^ 2 is -(2 ^ 2)")
    func unaryMinusBindsBelowPower() {
        let result = parse("-2 ^ 2")
        // The top node is the unary operator applied to a single operand, the `2 ^ 2` power, which nests.
        #expect(result.sExpression().hasPrefix("(exp (unary_operator)"))
        #expect(operands(of: result.tree).count == 1)
        #expect(operands(of: result.tree).first.map { operands(of: $0).count >= 2 } == true)
    }

    @Test("Unary length binds tighter than addition: #t + 1 is (#t) + 1")
    func lengthBindsTighterThanAddition() {
        let result = parse("#t + 1")
        // The `+` is the top operator; the unary `#t` is its left operand, marked by the unary_operator node.
        #expect(result.sExpression().hasPrefix("(exp (unary_operator)"))
        #expect(operands(of: result.tree).count == 2)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("not binds tighter than comparison: not a == b is (not a) == b")
    func notBindsTighterThanComparison() {
        let result = parse("not a == b")
        // The unary `not` applies to `a`; the `==` is the top operator, so the unary_operator marks the left
        // operand rather than wrapping the whole comparison.
        #expect(result.sExpression().hasPrefix("(exp (unary_operator)"))
        #expect(operands(of: result.tree).count == 2)
    }

    @Test("A deep mixed expression parses and round-trips")
    func deepMixedExpression() {
        let result = parse("1 + 2 * 3 - 4 / 5 % 6 .. 7")
        #expect(!result.hasErrors)
    }

    @Test("Concatenation binds tighter than shift: 1 << 2 .. 3 groups as 1 << (2 .. 3)")
    func concatenationBindsTighterThanShift() {
        // Per the Lua 5.4 manual (section 3.4.8), `..` (concatenation, level 8) binds tighter than the
        // shift operators `<<` and `>>` (level 7). The grammar encodes this, and this regression guards it
        // against a future incorrect swap: the `<<` is the top operator with the `2 .. 3` concatenation
        // pulled into its right operand, so there are two operands and the last one nests.
        let result = parse("1 << 2 .. 3")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
        // The contrasting `1 .. 2 << 3` groups the other way ((1 .. 2) << 3), giving a different tree, which
        // confirms the precedence is genuinely ordered rather than the operators being interchangeable.
        let swapped = parse("1 .. 2 << 3")
        #expect(swapped.sExpression() != result.sExpression())
    }
}
