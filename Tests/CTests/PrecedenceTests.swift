import ParsingCore
import ParsingDSL
import SwiftALLStar
import Testing

/// Precedence and associativity proofs for the directly left-recursive C expression grammar.
///
/// These run on the ALL(*) engine only, because it is the engine whose left-recursion rewriter turns the
/// `.precedence`-annotated `expr` ladder into a precedence-climbing operator loop. Each test parses an
/// expression and asserts the nesting shape that proves the operators bound with the right precedence and
/// associativity, read from the operand children directly under the top `expr` node: a flat run of operand
/// children is left-leaning, while two operands whose last one nests a further operator is right-leaning
/// (or a tighter operator pulled into the right operand). The grammar's fifteen-level ladder, with its
/// right-associative assignment and conditional tiers, is the headline proof that the ALL(*) precedence
/// climber scales to C's full operator hierarchy.
@Suite("C expression precedence and associativity")
struct CPrecedenceTests {
    /// A reusable ALL(*) engine over the expression grammar; constructing it proves the rewriter accepts
    /// the fifteen-tier direct left recursion.
    private static let engine: ALLStarUTF8Parser = {
        // Force-try is acceptable in a test fixture: a construction failure is itself a test failure.
        try! ALLStarUTF8Parser(grammar: CGrammar.expressions())
    }()

    /// Parses an expression, asserting it is accepted and round-trips losslessly.
    @discardableResult
    private func parse(_ input: String, _ sourceLocation: SourceLocation = #_sourceLocation) -> ParseResult {
        let result = Self.engine.parse(Source(input))
        #expect(!result.hasErrors, "should parse: \(input)", sourceLocation: sourceLocation)
        #expect(
            result.tree.green.reconstructedText == input, "should round-trip: \(input)",
            sourceLocation: sourceLocation)
        return result
    }

    /// The operand children (named `expr` or `primary_expr` nodes) directly under a node.
    ///
    /// The first operand of an operator loop renders as a `primary_expr` (the loop's primary), and each
    /// subsequent operand as an `expr`, so both kinds count as operands.
    private func operands(of node: Syntax) -> [Syntax] {
        node.children.filter { $0.kind.name == "expr" || $0.kind.name == "primary_expr" }
    }

    /// Whether a node's last operand itself nests a further operator (an `expr` with its own operands).
    private func lastOperandNests(_ node: Syntax) -> Bool {
        guard let last = operands(of: node).last else { return false }
        return last.kind.name == "expr" && operands(of: last).count >= 2
    }

    @Test("Constructing the ALL(*) engine accepts the fifteen-tier direct left recursion")
    func engineConstructs() throws {
        #expect(throws: Never.self) { _ = try ALLStarUTF8Parser(grammar: CGrammar.expressions()) }
    }

    @Test("A bare identifier parses as a single primary expression")
    func bareIdentifier() {
        let result = parse("a")
        #expect(result.sExpression() == "(expr (primary_expr (identifier)))")
    }

    // MARK: Associativity of the right-associative tiers.

    @Test("Assignment is right-associative: a = b = c groups as a = (b = c)")
    func assignmentRightAssociative() {
        let result = parse("a = b = c")
        // Right-leaning: two operands, the second nesting the remaining assignment.
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    @Test("Compound assignment is right-associative: a += b *= c groups as a += (b *= c)")
    func compoundAssignmentRightAssociative() {
        let result = parse("a += b *= c")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    @Test("The conditional operator is right-associative: a ? b : c ? d : e groups as a ? b : (c ? d : e)")
    func conditionalRightAssociative() {
        let result = parse("a ? b : c ? d : e")
        // The else branch (the last operand) nests the inner conditional.
        #expect(lastOperandNests(result.tree))
    }

    @Test("Assignment binds looser than the conditional: a = b ? c : d groups as a = (b ? c : d)")
    func assignmentLooserThanConditional() {
        let result = parse("a = b ? c : d")
        // Two operands; the right operand is the whole conditional, which nests.
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
    }

    // MARK: Associativity of the left-associative tiers.

    @Test("Subtraction is left-associative: a - b - c groups flat as (a - b) - c")
    func subtractionLeftAssociative() {
        let result = parse("a - b - c")
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("The comma operator is left-associative: a, b, c groups flat as (a, b), c")
    func commaLeftAssociative() {
        let result = parse("a, b, c")
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    // MARK: Relative binding across the ladder.

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

    @Test("Additive binds tighter than shift: a << b + c groups as a << (b + c)")
    func additiveTighterThanShift() {
        let result = parse("a << b + c")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
        // The contrasting `a + b << c` groups the other way ((a + b) << c), a different tree, confirming the
        // ordering is genuine rather than the operators being interchangeable.
        let swapped = parse("a + b << c")
        #expect(swapped.sExpression() != result.sExpression())
    }

    @Test("Logical-and binds tighter than logical-or: a && b || c keeps the && as a flat left operand")
    func logicalAndTighterThanLogicalOr() {
        let result = parse("a && b || c")
        // The `||` is the top operator with the `a && b` conjunction as its flat left operand.
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
        // And the converse direction differs.
        let swapped = parse("a || b && c")
        #expect(swapped.sExpression() != result.sExpression())
    }

    @Test("The bitwise tiers nest by precedence: a | b ^ c & d groups as a | (b ^ (c & d))")
    func bitwiseTiersNestByPrecedence() {
        // Bitwise-and (tightest) then bitwise-xor then bitwise-or (loosest), so each tighter operator is
        // pulled into the right operand of the looser one.
        let result = parse("a | b ^ c & d")
        #expect(operands(of: result.tree).count == 2)
        #expect(lastOperandNests(result.tree))
        // The right operand is the xor, whose own right operand is the and: a three-deep right spine.
        let xor = try? #require(operands(of: result.tree).last)
        if let xor {
            #expect(operands(of: xor).count == 2)
            #expect(lastOperandNests(xor))
        }
    }

    @Test("Equality chains left: a == b != c groups flat as (a == b) != c")
    func equalityLeftAssociative() {
        let result = parse("a == b != c")
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("Relational chains left: a < b <= c groups flat as (a < b) <= c")
    func relationalLeftAssociative() {
        let result = parse("a < b <= c")
        #expect(operands(of: result.tree).count == 3)
        #expect(!lastOperandNests(result.tree))
    }

    // MARK: Unary, postfix, and cast.

    @Test("Postfix increment binds tighter than prefix dereference: *p++ is *(p++)")
    func postfixTighterThanDereference() {
        // The top node is the prefix `*` applied to a single operand, the `p++` postfix expression; the
        // contrasting `(*p)++` applies the postfix to the parenthesised dereference, a different tree.
        let result = parse("*p++")
        #expect(result.sExpression().hasPrefix("(expr operator: (prefix_operator)"))
        let parenthesised = parse("(*p)++")
        #expect(parenthesised.sExpression() != result.sExpression())
    }

    @Test("Unary minus binds tighter than addition: -a + b is (-a) + b")
    func unaryMinusTighterThanAddition() {
        let result = parse("-a + b")
        // The `+` is the top operator; the unary `-a` is its left operand, marked by the prefix_operator.
        #expect(result.sExpression().hasPrefix("(expr operator: (prefix_operator)"))
        #expect(operands(of: result.tree).count == 2)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("Logical-not binds tighter than logical-and: !a && b is (!a) && b")
    func logicalNotTighterThanLogicalAnd() {
        let result = parse("!a && b")
        #expect(result.sExpression().hasPrefix("(expr operator: (prefix_operator)"))
        #expect(operands(of: result.tree).count == 2)
    }

    @Test("A cast applies to its right operand: (int)x + 1 is ((int)x) + 1")
    func castBindsToOperand() {
        let result = parse("(int)x + 1")
        // The `+` is the top operator with the cast as its left operand, which carries the type field.
        #expect(result.sExpression().contains("type: (type_name"))
        #expect(operands(of: result.tree).count == 2)
        #expect(!lastOperandNests(result.tree))
    }

    @Test("sizeof of a parenthesised type and of an expression both parse")
    func sizeofForms() {
        parse("sizeof(int)")
        parse("sizeof x")
        parse("sizeof(int *)")
    }

    // MARK: The full mixed ladder.

    @Test("A deep mixed expression spanning every tier parses and round-trips")
    func deepMixedLadder() {
        let result = parse("a = b , c ? d : e || f && g | h ^ i & j == k < l << m + n * o")
        #expect(!result.hasErrors)
    }

    @Test("Function-call arguments separate on the comma operator boundary")
    func callArgumentsUseAssignmentLevel() {
        // Each argument is an assignment-level expression, so the top-level comma operator does not swallow
        // the argument list: `f(a, b)` is one call with two arguments, not `f((a, b))`.
        let result = parse("f(a, b)")
        #expect(!result.hasErrors)
        #expect(result.sExpression().contains("argument_list"))
    }
}
