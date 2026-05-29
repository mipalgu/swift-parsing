import Testing

import ParsingCore
import ParsingDSL
@testable import TreeSitterBackend

@Suite("TreeSitter backend")
struct TreeSitterBackendTests {
    private func engine() throws -> TreeSitterEngine {
        try TreeSitterEngine(grammar: JSONGrammar.grammar())
    }

    @Test("Identity and capabilities")
    func metadata() {
        #expect(TreeSitterEngine.identifier == "tree-sitter")
        #expect(TreeSitterEngine.capabilities.contains(.errorRecovering))
    }

    @Test("Parses an object to a named-node S-expression")
    func parseObject() throws {
        let result = try engine().parse(Source(#"{ "a": 1 }"#))
        #expect(!result.hasErrors)
        #expect(result.sExpression()
            == "(document (object (pair key: (string (string_content)) value: (number))))")
    }

    @Test("Reports an error for malformed JSON but still returns a tree")
    func malformed() throws {
        let result = try engine().parse(Source("{"))
        #expect(result.hasErrors)
        #expect(result.sExpression().hasPrefix("(document"))
    }

    @Test("An unsupported grammar name is rejected")
    func unsupported() {
        let other = Grammar(name: "klingon", startRule: "s", rules: ["s": .literal("a")])
        #expect(throws: TreeSitterEngine.BackendError.unsupportedLanguage("klingon")) {
            try TreeSitterEngine(grammar: other)
        }
    }
}
