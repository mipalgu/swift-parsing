import ParsingCore
import ParsingDSL
import Query
import RecursiveDescent
import Testing

/// Tree-query (tree-sitter S-expression) coverage over a real parsed C tree.
///
/// These exercise the `Query` module against the C grammar, demonstrating the headline
/// tree-sitter-compatible use case on C: matching named node types, field labels, anonymous tokens,
/// wildcards, alternations, and textual predicates, with the captured nodes and their source text asserted
/// against a known fixture.
@Suite("C tree queries")
struct CQueryTests {
    /// The shared C fixture the queries run against.
    private static let source = """
        int counter = 0;
        const double ratio = 1.5;
        int add(int a, int b) {
            return a + b;
        }
        void run(int n) {
            for (int i = 0; i < n; i = i + 1) {
                counter = counter + add(i, 1);
            }
        }
        int classify(int x) {
            if (x > 0) {
                return 1;
            } else {
                return 0;
            }
        }
        char *label = "value";
        """

    /// Parses the fixture with the recursive-descent engine and returns the tree root.
    private func tree() throws -> Syntax {
        try UTF8Parser(grammar: CGrammar.translationUnit()).parse(Source(Self.source)).tree
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

    @Test("Capture every function definition's name")
    func functionNames() throws {
        let query = try Query("(function_definition declarator: (function_declarator name: (_) @name))")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == ["add", "run", "classify"])
    }

    @Test("Capture every string literal's text")
    func strings() throws {
        let query = try Query("(string_literal) @s")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == [#""value""#])
    }

    @Test("Capture every if statement, with its condition field")
    func ifStatements() throws {
        let query = try Query("(if_statement condition: (_) @cond)")
        let matches = query.matches(in: try tree())
        #expect(matches.count == 1)
        #expect(text(try #require(matches.first?.nodes(for: "cond").first)) == "x>0")
    }

    @Test("Capture every integer literal's text")
    func integers() throws {
        let query = try Query("(integer_literal) @n")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        // The integer literals: `counter = 0`, the for-loop `0`, the `+ 1` update, the `add(i, 1)` argument,
        // the `x > 0` comparison, and the two returns. (`1.5` is a floating literal, not an integer.)
        #expect(captured == ["0", "0", "1", "1", "0", "1", "0"])
    }

    @Test("Capture every return statement's value")
    func returnValues() throws {
        let query = try Query("(return_statement value: (_) @v)")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == ["a+b", "1", "0"])
    }

    @Test("An anonymous token pattern matches the return keyword in every return statement")
    func anonymousKeyword() throws {
        let query = try Query("(return_statement \"return\" @kw)")
        let captured = query.captures(in: try tree())
        #expect(captured.count == 3)
        #expect(captured.allSatisfy { text($0.node) == "return" })
    }

    @Test("A #eq? predicate keeps only the function named add")
    func predicateEqual() throws {
        let query = try Query(
            #"(function_definition declarator: (function_declarator name: (identifier) @n) (#eq? @n "add"))"#)
        let captured = query.captures(in: try tree()).filter { $0.name == "n" }.map { text($0.node) }
        #expect(captured == ["add"])
    }

    @Test("A #match? predicate keeps function names containing a vowel-led pattern")
    func predicateMatch() throws {
        // Capture the function names that begin with a lowercase letter in the first half of the alphabet.
        let query = try Query(
            #"(function_definition declarator: (function_declarator name: (identifier) @n) (#match? @n "^[a-c]"))"#)
        let captured = query.captures(in: try tree()).filter { $0.name == "n" }.map { text($0.node) }
        #expect(captured == ["add", "classify"])
    }

    @Test("An alternation matches either an integer or a string literal")
    func alternation() throws {
        let query = try Query("[(integer_literal) (string_literal)] @v")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == ["0", "0", "1", "1", "0", "1", "0", #""value""#])
    }

    @Test("Capture each parameter declaration's declarator name")
    func parameterNames() throws {
        let query = try Query("(parameter_declaration declarator: (declarator name: (_) @p))")
        let captured = query.captures(in: try tree()).map { text($0.node) }
        #expect(captured == ["a", "b", "n", "x"])
    }

    @Test("A pattern with no structural match yields no results")
    func noMatch() throws {
        #expect(try Query("(struct_specifier) @s").matches(in: tree()).isEmpty)
    }
}
