import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent
import TreeSitterBackend

/// Differential tests: the native engine and the tree-sitter backend must produce the *same* concrete
/// syntax tree (compared by canonical S-expression) for the same JSON input. This is the core
/// validation the multi-backend protocol framework was designed to enable: a native engine checked
/// against a battle-tested reference implementation through one shared abstraction.
@Suite("Native vs tree-sitter agreement")
struct DifferentialTests {
    /// A corpus of well-formed JSON without escape sequences (a documented first-milestone limit).
    static let corpus: [String] = [
        "true", "false", "null", "42", "-3.14", "1e9",
        #""hello""#,
        "{}", "[]",
        #"{ "a": 1 }"#,
        #"[1, 2, 3]"#,
        #"[true, false, null]"#,
        #"{ "name": "Ada", "age": 42 }"#,
        #"{ "nested": { "x": [1, 2], "y": "z" } }"#,
        "  [ 1 , 2 ]  ",
        #"{"a":{"b":{"c":[1,[2,[3]]]}}}"#,
    ]

    private static func engines() throws -> (RecursiveDescentEngine, TreeSitterEngine) {
        let grammar = JSONGrammar.grammar()
        return (try RecursiveDescentEngine(grammar: grammar), try TreeSitterEngine(grammar: grammar))
    }

    @Test("Both engines produce identical syntax trees", arguments: corpus)
    func agreement(_ input: String) throws {
        let (native, treeSitter) = try Self.engines()
        let nativeTree = native.parse(Source(input)).sExpression()
        let treeSitterTree = treeSitter.parse(Source(input)).sExpression()
        #expect(nativeTree == treeSitterTree, "input \(input): native=\(nativeTree) tree-sitter=\(treeSitterTree)")
    }

    @Test("Both engines agree there are no errors on well-formed input", arguments: corpus)
    func bothClean(_ input: String) throws {
        let (native, treeSitter) = try Self.engines()
        #expect(!native.parse(Source(input)).hasErrors)
        #expect(!treeSitter.parse(Source(input)).hasErrors)
    }
}
