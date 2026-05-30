import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

@testable import Query

/// Parses JSON with the native UTF-8 engine and returns the tree root, for query fixtures.
private func parseJSON(_ text: String) throws -> Syntax {
    let engine = try UTF8Parser(grammar: JSONGrammar.grammar())
    return engine.parse(Source(text)).tree
}

/// The content text (no trivia) of a node, mirroring the predicate evaluator's notion of text.
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

/// Tests that a compiled query matches the expected nodes over real parsed JSON trees, covering
/// every query construct and asserting the captured nodes and texts are exactly right.
@Suite("Query matching")
struct QueryMatchingTests {
    // MARK: - Acceptance: keys and values

    @Test("Capture every pair's key string and value over a real JSON document")
    func keysAndValues() throws {
        let tree = try parseJSON(#"{ "name": "Ada", "age": 36, "ok": true }"#)
        let query = try Query("(pair key: (string) @key value: (_) @value)")
        let matches = query.matches(in: tree)

        #expect(matches.count == 3)
        let keys = matches.compactMap { $0.nodes(for: "key").first }.map(text)
        let values = matches.compactMap { $0.nodes(for: "value").first }.map(text)
        #expect(keys == [#""name""#, #""age""#, #""ok""#])
        #expect(values == [#""Ada""#, "36", "true"])
    }

    @Test("Capture the inner string_content of every key, exact texts")
    func keyContents() throws {
        let tree = try parseJSON(#"{ "alpha": 1, "beta": 2 }"#)
        let query = try Query("(pair key: (string (string_content) @k))")
        let captured = query.captures(in: tree).map { text($0.node) }
        #expect(captured == ["alpha", "beta"])
    }

    // MARK: - Wildcards

    @Test("The bare wildcard matches every node; (_) matches only named nodes")
    func wildcards() throws {
        let tree = try parseJSON("[1]")
        let anyCount = try Query("_ @n").matches(in: tree).count
        let namedCount = try Query("(_) @n").matches(in: tree).count
        // The bare wildcard also matches anonymous punctuation, so it sees strictly more nodes.
        #expect(anyCount > namedCount)
        #expect(namedCount > 0)
    }

    // MARK: - Anonymous tokens

    @Test("An anonymous token pattern matches literal punctuation")
    func anonymousToken() throws {
        let tree = try parseJSON("[1, 2, 3]")
        let commas = try Query("(array \",\" @c)").captures(in: tree)
        #expect(commas.count == 2)
        #expect(commas.allSatisfy { text($0.node) == "," })
    }

    // MARK: - Alternations

    @Test("An alternation matches any listed node type")
    func alternation() throws {
        let tree = try parseJSON(#"[1, "x", 2, "y"]"#)
        let query = try Query("[(number) (string)] @v")
        let captured = query.captures(in: tree).map { text($0.node) }
        #expect(captured == ["1", #""x""#, "2", #""y""#])
    }

    @Test("An alternation inside a field constrains the value type")
    func alternationInField() throws {
        let tree = try parseJSON(#"{ "a": 1, "b": "two", "c": true }"#)
        let query = try Query("(pair value: [(number) (string)] @v)")
        let captured = query.captures(in: tree).map { text($0.node) }
        // Only the number and string values match; the boolean is excluded.
        #expect(captured == ["1", #""two""#])
    }

    // MARK: - Quantifiers

    @Test("A zero-or-more quantifier over a group captures each repetition (greedy)")
    func quantifierStar() throws {
        let tree = try parseJSON("[1, 2, 3, 4]")
        // The first element anchored to the start, then a greedy run of (comma number) pairs.
        let query = try Query("(array . (number) @first (\",\" (number) @rest)*)")
        let matches = query.matches(in: tree)
        // The maximal (greedy) binding is reported first; shorter sub-bindings follow.
        let greedy = try #require(matches.first)
        #expect(text(try #require(greedy.nodes(for: "first").first)) == "1")
        #expect(greedy.nodes(for: "rest").map(text) == ["2", "3", "4"])
        // Every match keeps the same anchored first element.
        #expect(matches.allSatisfy { text($0.nodes(for: "first")[0]) == "1" })
    }

    @Test("A one-or-more quantifier requires at least one occurrence")
    func quantifierPlus() throws {
        let single = try parseJSON("[1]")
        let many = try parseJSON("[1, 2, 3]")
        let query = try Query("(array . (number) (\",\" (number) @more)+)")
        // With only one element there is no comma-number repetition, so nothing matches.
        #expect(query.matches(in: single).isEmpty)
        // The greedy maximal binding captures every following number.
        let greedy = try #require(query.matches(in: many).first)
        #expect(greedy.nodes(for: "more").map(text) == ["2", "3"])
    }

    @Test("An optional quantifier matches whether or not the node is present")
    func quantifierOptional() throws {
        let empty = try parseJSON("[]")
        let one = try parseJSON("[7]")
        let query = try Query("(array (number)? @maybe)")
        // Over an empty array the optional number matches zero times, still producing one match.
        #expect(query.matches(in: empty).count == 1)
        #expect(query.matches(in: empty).allSatisfy { $0.captures.isEmpty })
        // Over a one-element array the greedy binding captures the number.
        let greedy = try #require(query.matches(in: one).first)
        #expect(greedy.nodes(for: "maybe").map(text) == ["7"])
    }

    // MARK: - Anchors

    @Test("A leading anchor matches only the first named child")
    func anchorFirst() throws {
        let tree = try parseJSON("[10, 20, 30]")
        let query = try Query("(array . (number) @first)")
        let captured = query.captures(in: tree).map { text($0.node) }
        #expect(captured == ["10"])
    }

    @Test("A trailing anchor matches only the last named child")
    func anchorLast() throws {
        let tree = try parseJSON("[10, 20, 30]")
        let query = try Query("(array (number) @last .)")
        let captured = query.captures(in: tree).map { text($0.node) }
        #expect(captured == ["30"])
    }

    @Test("An anchor between siblings matches only consecutive named children")
    func anchorBetween() throws {
        let tree = try parseJSON("[1, 2, 3]")
        let query = try Query("(array (number) @a . (number) @b)")
        let matches = query.matches(in: tree)
        let pairs = matches.map { (text($0.nodes(for: "a")[0]), text($0.nodes(for: "b")[0])) }
        #expect(pairs.count == 2)
        #expect(pairs[0] == ("1", "2"))
        #expect(pairs[1] == ("2", "3"))
    }

    // MARK: - Fields and negated fields

    @Test("A field label restricts a capture to the field slot")
    func fieldSlot() throws {
        let tree = try parseJSON(#"{ "k": "v" }"#)
        let keys = try Query("(pair key: (_) @k)").captures(in: tree).map { text($0.node) }
        let values = try Query("(pair value: (_) @v)").captures(in: tree).map { text($0.node) }
        #expect(keys == [#""k""#])
        #expect(values == [#""v""#])
    }

    @Test("A negated field excludes nodes that have that field")
    func negatedField() throws {
        // Every JSON pair has a value field, so a !value negation matches no pair.
        let tree = try parseJSON(#"{ "a": 1 }"#)
        #expect(try Query("(pair !value) @p").matches(in: tree).isEmpty)
        // With no negation, the pair matches.
        #expect(try Query("(pair) @p").matches(in: tree).count == 1)
    }

    // MARK: - Predicates

    @Test("#eq? keeps only matches whose capture text equals the literal")
    func predicateEqual() throws {
        let tree = try parseJSON(#"{ "keep": 1, "drop": 2 }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) value: (_) @v (#eq? @k "keep"))"#)
        let matches = query.matches(in: tree)
        #expect(matches.count == 1)
        #expect(text(try #require(matches.first?.nodes(for: "v").first)) == "1")
    }

    @Test("#not-eq? keeps only matches whose capture text differs")
    func predicateNotEqual() throws {
        let tree = try parseJSON(#"{ "keep": 1, "drop": 2 }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) (#not-eq? @k "keep"))"#)
        let captured = query.captures(in: tree).filter { $0.name == "k" }.map { text($0.node) }
        #expect(captured == ["drop"])
    }

    @Test("#match? keeps only matches whose capture text matches the regular expression")
    func predicateMatch() throws {
        let tree = try parseJSON(#"{ "id_1": 1, "name": 2, "id_2": 3 }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) (#match? @k "^id_[0-9]+$"))"#)
        let captured = query.captures(in: tree).filter { $0.name == "k" }.map { text($0.node) }
        #expect(captured == ["id_1", "id_2"])
    }

    @Test("#not-match? excludes matches whose capture text matches the regular expression")
    func predicateNotMatch() throws {
        let tree = try parseJSON(#"{ "id_1": 1, "name": 2 }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) (#not-match? @k "^id_"))"#)
        let captured = query.captures(in: tree).filter { $0.name == "k" }.map { text($0.node) }
        #expect(captured == ["name"])
    }

    @Test("#any-of? keeps matches whose capture text is one of the listed literals")
    func predicateAnyOf() throws {
        let tree = try parseJSON(#"{ "red": 1, "green": 2, "blue": 3 }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) (#any-of? @k "red" "blue"))"#)
        let captured = query.captures(in: tree).filter { $0.name == "k" }.map { text($0.node) }
        #expect(captured == ["red", "blue"])
    }

    @Test("#not-any-of? excludes matches whose capture text is one of the listed literals")
    func predicateNotAnyOf() throws {
        let tree = try parseJSON(#"{ "red": 1, "green": 2, "blue": 3 }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) (#not-any-of? @k "red" "blue"))"#)
        let captured = query.captures(in: tree).filter { $0.name == "k" }.map { text($0.node) }
        #expect(captured == ["green"])
    }

    @Test("An equality predicate comparing two captures keeps only matching pairs")
    func predicateCaptureEquality() throws {
        let tree = try parseJSON(#"[{ "x": "x" }, { "y": "z" }]"#)
        // Match pairs whose key content equals their value content.
        let query = try Query(
            #"(pair key: (string (string_content) @k) value: (string (string_content) @v) (#eq? @k @v))"#)
        let matches = query.matches(in: tree)
        #expect(matches.count == 1)
        #expect(text(try #require(matches.first?.nodes(for: "k").first)) == "x")
    }

    // MARK: - Nested structure and no-match

    @Test("A nested pattern matches across object depth")
    func nested() throws {
        let tree = try parseJSON(#"{ "outer": { "inner": 42 } }"#)
        let query = try Query(#"(pair key: (string (string_content) @k) value: (number) @n)"#)
        let captured = query.matches(in: tree).map {
            (text($0.nodes(for: "k")[0]), text($0.nodes(for: "n")[0]))
        }
        #expect(captured.count == 1)
        #expect(captured[0] == ("inner", "42"))
    }

    @Test("A pattern with no structural match yields no results")
    func noMatch() throws {
        let tree = try parseJSON("[1, 2, 3]")
        #expect(try Query("(object) @o").matches(in: tree).isEmpty)
    }

    @Test("captures(in:) flattens every match's captures in order")
    func capturesFlatten() throws {
        let tree = try parseJSON("[1, 2]")
        let captures = try Query("(number) @n").captures(in: tree)
        #expect(captures.map { text($0.node) } == ["1", "2"])
        #expect(captures.allSatisfy { $0.name == "n" })
    }

    @Test("Multiple top-level patterns each contribute matches with their pattern index")
    func multiplePatterns() throws {
        let tree = try parseJSON(#"{ "a": 1 }"#)
        let query = try Query("(string) @s (number) @n")
        let matches = query.matches(in: tree)
        let byPattern = Dictionary(grouping: matches, by: \.patternIndex)
        // Two strings (key and would-be value differ here: the value is a number), one number.
        #expect(byPattern[0]?.count == 1)
        #expect(byPattern[1]?.count == 1)
    }
}
