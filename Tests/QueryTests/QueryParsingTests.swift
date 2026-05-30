import Testing

@testable import Query

/// Tests that the query compiler turns source text into the expected pattern IR and rejects
/// malformed input with precise, located errors.
@Suite("Query compilation")
struct QueryParsingTests {
    @Test("A named node with two named children compiles to a node pattern")
    func namedNode() throws {
        let query = try Query("(pair (string) (number))")
        #expect(query.patternCount == 1)
        guard case .node(let type, let children, let predicates) = query.patterns[0] else {
            Issue.record("expected a node pattern")
            return
        }
        #expect(type == "pair")
        #expect(predicates.isEmpty)
        #expect(children.count == 2)
        #expect(children[0] == .node(type: "string", children: [], predicates: []))
        #expect(children[1] == .node(type: "number", children: [], predicates: []))
    }

    @Test("A capture wraps the captured pattern")
    func capture() throws {
        let query = try Query("(string) @s")
        #expect(query.patterns[0] == .capture("s", .node(type: "string", children: [], predicates: [])))
    }

    @Test("A field label wraps its child pattern")
    func fieldLabel() throws {
        let query = try Query("(pair key: (string) @k)")
        guard case .node(_, let children, _) = query.patterns[0] else {
            Issue.record("expected a node pattern")
            return
        }
        #expect(children[0] == .field("key", .capture("k", .node(type: "string", children: [], predicates: []))))
    }

    @Test("Quantifiers compile to quantified patterns")
    func quantifiers() throws {
        #expect(
            try Query("(comment)?").patterns[0]
                == .quantified(.node(type: "comment", children: [], predicates: []), .zeroOrOne))
        #expect(
            try Query("(comment)*").patterns[0]
                == .quantified(.node(type: "comment", children: [], predicates: []), .zeroOrMore))
        #expect(
            try Query("(comment)+").patterns[0]
                == .quantified(.node(type: "comment", children: [], predicates: []), .oneOrMore))
    }

    @Test("Alternations compile to an alternation pattern")
    func alternation() throws {
        let query = try Query("[(string) (number)]")
        #expect(
            query.patterns[0]
                == .alternation([
                    .node(type: "string", children: [], predicates: []),
                    .node(type: "number", children: [], predicates: []),
                ]))
    }

    @Test("Wildcards compile to the any-node and any-named-node patterns")
    func wildcards() throws {
        #expect(try Query("_").patterns[0] == .anyNode)
        #expect(try Query("(_)").patterns[0] == .anyNamedNode)
    }

    @Test("Anonymous tokens compile to anonymous patterns")
    func anonymous() throws {
        #expect(try Query("\",\"").patterns[0] == .anonymous(","))
    }

    @Test("Anchors compile to anchor patterns inside a node")
    func anchor() throws {
        let query = try Query("(array . (number) @first)")
        guard case .node(_, let children, _) = query.patterns[0] else {
            Issue.record("expected a node pattern")
            return
        }
        #expect(children[0] == .anchor)
    }

    @Test("Negated fields compile to a negated-field pattern")
    func negatedField() throws {
        let query = try Query("(pair !value)")
        guard case .node(_, let children, _) = query.patterns[0] else {
            Issue.record("expected a node pattern")
            return
        }
        #expect(children[0] == .negatedField("value"))
    }

    @Test("Groups compile to a group pattern with a quantifier")
    func groupQuantified() throws {
        let query = try Query("((number) (number))*")
        #expect(
            query.patterns[0]
                == .quantified(
                    .group([
                        .node(type: "number", children: [], predicates: []),
                        .node(type: "number", children: [], predicates: []),
                    ]), .zeroOrMore))
    }

    @Test("Predicates are hoisted onto the enclosing node")
    func predicates() throws {
        let query = try Query("((string) @s (#eq? @s \"x\"))")
        // The group's child node carries no predicate; the predicate attaches to the group body.
        // Compile via a node so the predicate is on the node pattern.
        let nodeQuery = try Query("(string (string_content) @c (#match? @c \"a+\"))")
        guard case .node(_, _, let predicates) = nodeQuery.patterns[0] else {
            Issue.record("expected a node pattern")
            return
        }
        #expect(predicates == [Predicate(kind: .match, arguments: [.capture("c"), .literal("a+")])])
        #expect(query.patternCount == 1)
    }

    @Test("Comments and whitespace are skipped")
    func commentsSkipped() throws {
        let query = try Query("; a leading comment\n(string) @s ; trailing\n")
        #expect(query.patternCount == 1)
        #expect(query.patterns[0] == .capture("s", .node(type: "string", children: [], predicates: [])))
    }

    @Test("Multiple top-level patterns are all compiled")
    func multiplePatterns() throws {
        let query = try Query("(string) @s (number) @n")
        #expect(query.patternCount == 2)
    }
}
