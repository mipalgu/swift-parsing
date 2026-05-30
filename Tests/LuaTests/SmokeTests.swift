import ParsingCore
import ParsingDSL
import RecursiveDescent
import Testing

@Suite("Lua smoke")
struct LuaSmokeTests {
    @Test("Structural inputs parse without errors on the reference engine", arguments: Corpus.structural)
    func structuralParses(_ input: String) throws {
        let result = try Corpus.parseReference(input)
        #expect(!result.hasErrors, "input: \(input)\n\(result.sExpression())")
        #expect(result.tree.green.reconstructedText == input)
    }

    @Test("Expression inputs parse on the ALL(*) engine", arguments: Corpus.expression)
    func expressionParses(_ input: String) throws {
        let result = try Corpus.parseExpression(input)
        #expect(!result.hasErrors, "input: \(input)\n\(result.sExpression())")
        #expect(result.tree.green.reconstructedText == input)
    }
}
