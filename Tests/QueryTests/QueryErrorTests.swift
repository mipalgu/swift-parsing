import Testing

@testable import Query

/// Tests that malformed query source is rejected with the appropriate located ``QueryError``.
@Suite("Query compilation errors")
struct QueryErrorTests {
    @Test("An unclosed node throws unexpectedEnd")
    func unclosedNode() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("(string") }
    }

    @Test("An unclosed alternation throws unexpectedEnd")
    func unclosedAlternation() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("[(string)") }
    }

    @Test("An unclosed quoted string throws unexpectedEnd")
    func unclosedString() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("\"abc") }
    }

    @Test("A stray closing parenthesis throws unbalancedDelimiter")
    func strayClose() {
        #expect(throws: QueryError.unbalancedDelimiter(")", offset: 0)) { _ = try Query(")") }
    }

    @Test("A node beginning without a type name throws expectedNodeName")
    func emptyNodeName() {
        // `(123)` starts with a digit, which is an identifier character, so a name is read; use `(:)`.
        #expect(throws: QueryError.self) { _ = try Query("(:)") }
    }

    @Test("A capture with no name throws expectedCaptureName")
    func emptyCaptureName() {
        #expect(throws: QueryError.expectedCaptureName(offset: 9)) { _ = try Query("(string) @") }
    }

    @Test("A leading capture with no pattern throws unexpectedCharacter")
    func leadingCapture() {
        #expect(throws: QueryError.unexpectedCharacter("@", offset: 0)) { _ = try Query("@x") }
    }

    @Test("A dangling quantifier throws danglingQuantifier")
    func danglingQuantifier() {
        #expect(throws: QueryError.danglingQuantifier("*", offset: 0)) { _ = try Query("*") }
    }

    @Test("An unknown predicate name throws unknownPredicate")
    func unknownPredicate() {
        #expect(throws: QueryError.self) { _ = try Query("(string (#frobnicate? @s))") }
    }

    @Test("A malformed predicate throws malformedPredicate")
    func malformedPredicate() {
        #expect(throws: QueryError.self) { _ = try Query("(string (#eq? @s))") }
        #expect(throws: QueryError.self) { _ = try Query("(string (#match? \"x\" \"y\"))") }
        #expect(throws: QueryError.self) { _ = try Query("(string (#any-of? @s @t))") }
    }

    @Test("A negated field with no name throws")
    func negatedFieldNoName() {
        #expect(throws: QueryError.self) { _ = try Query("(pair !)") }
    }

    @Test("A field label with no following pattern throws danglingField")
    func danglingField() {
        #expect(throws: QueryError.self) { _ = try Query("(pair key: )") }
    }

    @Test("An unexpected character throws unexpectedCharacter")
    func unexpectedCharacter() {
        #expect(throws: QueryError.unexpectedCharacter("%", offset: 0)) { _ = try Query("%") }
    }

    @Test("A predicate hash outside a node throws")
    func predicateOutsideNode() {
        #expect(throws: QueryError.self) { _ = try Query("(#eq? @a @b)") }
    }

    @Test("A predicate missing its closing paren throws unexpectedEnd")
    func predicateUnclosed() {
        #expect(throws: QueryError.unexpectedEnd) { _ = try Query("(string (#eq? @s \"x\"") }
    }
}
