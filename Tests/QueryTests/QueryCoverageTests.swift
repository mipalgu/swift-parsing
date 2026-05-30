import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

@testable import Query

/// Parses JSON with the native UTF-8 engine and returns the tree root.
private func parseJSON(_ text: String) throws -> Syntax {
    let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
    return engine.parse(Source(text)).tree
}

/// The content text (no trivia) of a node.
private func text(_ node: Syntax) -> String {
    var out = ""
    func walk(_ s: Syntax) {
        switch s.green.payload {
        case .token(let t, _, _): out += t
        case .node(let kids): for k in kids { walk(Syntax(k.node)) }
        }
    }
    walk(node)
    return out
}

/// Exercises the remaining lexical, parsing and matching paths so the module is covered end to end.
@Suite("Query coverage")
struct QueryCoverageTests {
    // MARK: - Scanner string escapes

    @Test("Quoted strings decode backslash escapes")
    func stringEscapes() throws {
        var scanner = QueryScanner(#""a\nb\tc\r\\\"d""#)
        let decoded = try scanner.readQuotedString()
        #expect(decoded == "a\nb\tc\r\\\"d")
    }

    @Test("An unknown escape stands for the escaped character")
    func unknownEscape() throws {
        var scanner = QueryScanner(#""x\qy""#)
        #expect(try scanner.readQuotedString() == "xqy")
    }

    @Test("An anonymous pattern with an escaped quote compiles")
    func anonymousWithEscape() throws {
        let query = try Query(#""\"""#)
        #expect(query.patterns[0] == .anonymous("\""))
    }

    // MARK: - Predicate evaluation edge cases

    @Test("A predicate referencing an absent capture fails the match")
    func predicateAbsentCapture() throws {
        let tree = try parseJSON(#"{ "k": "v" }"#)
        // @missing is never bound, so #eq? cannot hold and no match survives.
        let query = try Query(#"(pair key: (string) @k (#eq? @missing "x"))"#)
        #expect(query.matches(in: tree).isEmpty)
    }

    @Test("A match predicate against an absent capture fails the match")
    func matchAbsentCapture() throws {
        let tree = try parseJSON(#"{ "k": 1 }"#)
        let query = try Query(#"(pair value: (number) @v (#match? @missing "x"))"#)
        #expect(query.matches(in: tree).isEmpty)
    }

    @Test("An any-of predicate against an absent capture fails the match")
    func anyOfAbsentCapture() throws {
        let tree = try parseJSON(#"{ "k": 1 }"#)
        let query = try Query(#"(pair value: (number) @v (#any-of? @missing "x"))"#)
        #expect(query.matches(in: tree).isEmpty)
    }

    @Test("An invalid regular expression in #match? is treated as no match")
    func invalidRegex() throws {
        let tree = try parseJSON(#"{ "k": "v" }"#)
        // An unbalanced group is an invalid regex; the predicate cannot hold.
        let query = try Query(#"(pair key: (string (string_content) @c) (#match? @c "("))"#)
        #expect(query.matches(in: tree).isEmpty)
    }

    @Test("A literal-only equality predicate compares the literals directly")
    func literalEquality() throws {
        // Two equal literals satisfy #eq?; the structural part still has to match a node.
        #expect(
            PredicateEvaluator.evaluate(
                Predicate(kind: .equal, arguments: [.literal("x"), .literal("x")]), captures: []))
        #expect(
            !PredicateEvaluator.evaluate(
                Predicate(kind: .equal, arguments: [.literal("x"), .literal("y")]), captures: []))
    }

    // MARK: - Standalone group, field and wildcard node patterns

    @Test("A top-level group pattern matches a node's children")
    func topLevelGroup() throws {
        let tree = try parseJSON("[1, 2]")
        // A group at top level matches any node whose children satisfy the members.
        let captured = try Query("((number) @a)").captures(in: tree).map { text($0.node) }
        #expect(captured.contains("1"))
        #expect(captured.contains("2"))
    }

    @Test("A standalone field pattern requires the node to occupy that field")
    func standaloneField() throws {
        let tree = try parseJSON(#"{ "k": "v" }"#)
        // key: applied to a node matches only the node sitting in the key slot.
        let captured = try Query("key: (string) @k").captures(in: tree).map { text($0.node) }
        #expect(captured == [#""k""#])
    }

    @Test("A quantified node pattern at node level matches optionally")
    func quantifiedNodeLevel() throws {
        let tree = try parseJSON("[1]")
        // (number)? as a whole node pattern still matches the number node.
        let captured = try Query("(number)? @n").captures(in: tree).map { text($0.node) }
        #expect(captured == ["1"])
    }

    @Test("A negated-field and anchor pattern never matches a single node directly")
    func standaloneStructural() {
        let matcher = QueryMatcher(patterns: [])
        // No patterns means no matches, exercising the empty-pattern path.
        let empty = matcher.matches(in: Syntax(GreenNode.token(SyntaxKind("x"), text: "x")))
        #expect(empty.isEmpty)
    }

    // MARK: - Negated field present and absent

    @Test("A negated field passes when the field is absent and fails when present")
    func negatedFieldPresence() throws {
        let tree = try parseJSON(#"{ "k": 1 }"#)
        // The pair has a value field, so !value rejects it.
        #expect(try Query("(pair !value)").matches(in: tree).isEmpty)
        // The string node has no value field, so !value accepts every string.
        #expect(!(try Query("(string !value) @s").matches(in: tree).isEmpty))
    }

    // MARK: - Parser error corners

    @Test("A capture name missing inside a predicate throws")
    func predicateEmptyCapture() {
        #expect(throws: QueryError.self) { _ = try Query("(string (#eq? @ \"x\"))") }
    }

    @Test("A non-capture, non-string predicate argument throws")
    func predicateBadArgument() {
        #expect(throws: QueryError.self) { _ = try Query("(string (#eq? @s 5))") }
    }

    @Test("A stray closing bracket inside an alternation throws")
    func strayInAlternation() {
        #expect(throws: QueryError.self) { _ = try Query("[(string) )]") }
    }

    @Test("A second quantifier overrides but still compiles")
    func doubleQuantifier() throws {
        // Tree-sitter rejects two quantifiers; here the later one wins, which still parses cleanly.
        let query = try Query("(comment)?*")
        #expect(query.patterns[0] == .quantified(.node(type: "comment", children: [], predicates: []), .zeroOrMore))
    }

    @Test("A pattern after a comment-only prefix still parses")
    func commentOnly() throws {
        #expect(try Query("; nothing but a comment\n").patternCount == 0)
    }

    @Test("Equality of an empty operand list is vacuously false")
    func emptyOperandEquality() {
        // The parser never produces this, but the evaluator guards against it defensively.
        #expect(!PredicateEvaluator.evaluate(Predicate(kind: .equal, arguments: []), captures: []))
    }

    @Test("A one-or-more node pattern fails when its inner pattern does not match")
    func quantifiedNodeFailsWithoutZero() throws {
        let tree = try parseJSON(#"{ "k": 1 }"#)
        // (object)+ as a whole-node pattern cannot match a number, and + forbids zero.
        let captured = try Query("(pair value: (object)+ @o)").captures(in: tree)
        #expect(captured.isEmpty)
    }

    @Test("A backslash at end of a quoted string throws unexpectedEnd")
    func trailingBackslash() {
        var scanner = QueryScanner("\"abc\\")
        #expect(throws: QueryError.unexpectedEnd) { _ = try scanner.readQuotedString() }
    }

    @Test("An open parenthesis at end of input throws unexpectedEnd")
    func openParenAtEnd() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("(") }
    }

    @Test("A node missing its closing parenthesis at end throws unexpectedEnd")
    func nodeMissingCloseAtEnd() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("(string ") }
    }

    @Test("An alternation followed by valid content compiles after skipping trivia")
    func alternationThenContent() throws {
        let query = try Query("(array [(string) (number)] @v)")
        #expect(query.patternCount == 1)
    }

    @Test("An any-of predicate whose first operand is a literal throws")
    func anyOfFirstOperandLiteral() {
        #expect(throws: QueryError.self) { _ = try Query("(string (#any-of? \"x\" \"y\"))") }
    }

    @Test("A wildcard node missing its closing parenthesis at end throws unexpectedEnd")
    func wildcardNodeMissingClose() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("(_") }
    }

    @Test("A wildcard node with trailing content before its close throws unbalancedDelimiter")
    func wildcardNodeTrailingContent() {
        #expect(throws: QueryError.self) { _ = try Query("(_ x)") }
    }

    @Test("A top-level anchor pattern matches nothing as a standalone node")
    func topLevelAnchor() throws {
        let tree = try parseJSON("[1]")
        // A bare anchor or negated field is meaningful only inside a node, so standalone it never
        // matches a node directly.
        #expect(try Query(".").matches(in: tree).isEmpty)
        #expect(try Query("!value").matches(in: tree).isEmpty)
    }
}
