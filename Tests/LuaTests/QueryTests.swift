import ParsingCore
import ParsingDSL
import Query
import RecursiveDescent
import Testing

/// Tree-query (tree-sitter S-expression) coverage over a real parsed Lua tree.
///
/// These exercise the `Query` module against a non-JSON grammar, demonstrating the headline
/// tree-sitter-compatible use case on Lua: matching named node types, field labels, anonymous tokens,
/// wildcards, and textual predicates, with the captured nodes and their source text asserted against a
/// known fixture.
@Suite("Lua tree queries")
struct LuaQueryTests {
    /// The shared Lua fixture the queries run against.
    private static let source = """
        local x = 1
        local y = "two"
        function greet(name)
            return "hello"
        end
        function M:method(a, b)
            return a + b
        end
        if x then
            print(x)
        end
        local t = { a = 1, b = "value", positional }
        for i = 1, 10 do
            sum = sum + i
        end
        """

    /// Parses the fixture with the recursive-descent engine and returns the tree root.
    private func tree() throws -> Syntax {
        try UTF8Parser(grammar: LuaGrammar.chunk()).parse(Source(Self.source)).tree
    }

    /// The content text (no trivia) of a node, mirroring the predicate evaluator's notion of text.
    private func text(_ node: Syntax) -> String {
        var out = ""
        func walk(_ syntax: Syntax) {
            switch syntax.green.payload {
            case .token(let value, _, _): out += value
            case .node(let children): for child in children { walk(Syntax(child.node)) }
            }
        }
        walk(node)
        return out
    }

    @Test("Capture every function declaration's name")
    func functionNames() throws {
        let query = try Query("(function_declaration name: (_) @name)")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == ["greet", "M:method"])
    }

    @Test("Capture every string literal's text")
    func strings() throws {
        let query = try Query("(string) @s")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == [#""two""#, #""hello""#, #""value""#])
    }

    @Test("Capture every if statement, with its condition field")
    func ifStatements() throws {
        let query = try Query("(if_statement condition: (_) @cond)")
        let matches = query.matches(in: try tree())
        #expect(matches.count == 1)
        #expect(text(try #require(matches.first?.nodes(for: "cond").first)) == "x")
    }

    @Test("Capture every number literal's text")
    func numbers() throws {
        let query = try Query("(number) @n")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        // The numerals in `local x = 1`, `a = 1`, and `for i = 1, 10`.
        #expect(captured == ["1", "1", "1", "10"])
    }

    @Test("Capture each keyed and named table field's name and value")
    func namedTableFields() throws {
        let query = try Query("(named_field name: (name) @key value: (_) @value)")
        let matches = query.matches(in: try tree())
        let pairs = matches.map { (text($0.nodes(for: "key")[0]), text($0.nodes(for: "value")[0])) }
        #expect(pairs.count == 2)
        #expect(pairs[0] == ("a", "1"))
        #expect(pairs[1] == ("b", #""value""#))
    }

    @Test("An anonymous token pattern matches the local keyword in every local declaration")
    func anonymousKeyword() throws {
        let query = try Query("(local_declaration \"local\" @kw)")
        let captured = query.captures(in: try tree())
        #expect(captured.count == 3)
        #expect(captured.allSatisfy { text($0.node) == "local" })
    }

    @Test("A #eq? predicate keeps only the function named greet")
    func predicateEqual() throws {
        let query = try Query(#"(function_declaration name: (function_name (name) @n) (#eq? @n "greet"))"#)
        let captured = query.captures(in: try tree()).filter { $0.name == "n" }.map { text($0.node) }
        #expect(captured == ["greet"])
    }

    @Test("A #match? predicate keeps assignment targets matching a pattern")
    func predicateMatch() throws {
        // Capture the names bound by local declarations whose first character is a lowercase letter.
        let query = try Query(
            #"(local_declaration names: (attributed_name_list (attributed_name (name) @n)) (#match? @n "^[a-z]"))"#)
        let captured = query.captures(in: try tree()).filter { $0.name == "n" }.map { text($0.node) }
        #expect(captured == ["x", "y", "t"])
    }

    @Test("An alternation matches either a number or a string value")
    func alternation() throws {
        let query = try Query("[(number) (string)] @v")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == ["1", #""two""#, #""hello""#, "1", #""value""#, "1", "10"])
    }

    @Test("A pattern with no structural match yields no results")
    func noMatch() throws {
        #expect(try Query("(object) @o").matches(in: tree()).isEmpty)
    }
}
