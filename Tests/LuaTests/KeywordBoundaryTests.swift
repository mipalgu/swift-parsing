import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// Keyword-boundary coverage for the shared Lua lexical core.
///
/// A Lua reserved word is never a valid identifier, so `local and = 1` must be rejected: the name matcher
/// must not split the keyword `and` into the identifier `an` followed by `d`. Conversely, an identifier
/// that merely begins with, ends with, or wholly contains a keyword (such as `ending`, `andy`, or `_end`)
/// is a perfectly good name. Both properties are checked on all three native engines through the
/// structural grammar so the keyword boundary holds uniformly.
@Suite("Lua keyword boundary")
struct LuaKeywordBoundaryTests {
    /// The 22 Lua 5.4 reserved words. A `local <word> = 1` declaration is illegal for each of these.
    static let reservedWords: [String] = [
        "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto", "if",
        "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until", "while",
    ]

    /// Identifiers that merely contain, begin with, or end with a keyword and so are valid names.
    static let validNames: [String] = [
        "ending", "endx", "andy", "ornament", "returns", "_end", "end2", "do_it", "iffy", "locals",
        "nilable", "forall", "inner", "t", "_", "__", "a1", "self", "_G",
    ]

    @Test(
        "A reserved word is rejected as a name on all three engines",
        arguments: reservedWords)
    func reservedWordRejected(_ word: String) throws {
        let source = "local \(word) = 1"
        let grammar = LuaGrammar.chunk()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(source))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(source))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(source))
        #expect(rd.hasErrors, "recursive descent should reject keyword as name: \(source)")
        #expect(glr.hasErrors, "GLR should reject keyword as name: \(source)")
        #expect(allstar.hasErrors, "ALL(*) should reject keyword as name: \(source)")
    }

    @Test(
        "An identifier containing or bordering a keyword is accepted as a name on all three engines",
        arguments: validNames)
    func keywordAdjacentNameAccepted(_ name: String) throws {
        let source = "local \(name) = 1"
        let grammar = LuaGrammar.chunk()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(source))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(source))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(source))
        #expect(!rd.hasErrors, "recursive descent should accept name: \(source)")
        #expect(!glr.hasErrors, "GLR should accept name: \(source)")
        #expect(!allstar.hasErrors, "ALL(*) should accept name: \(source)")
        #expect(rd.tree.green.reconstructedText == source)
        #expect(glr.sExpression() == rd.sExpression(), "GLR vs RD on: \(source)")
        #expect(allstar.sExpression() == rd.sExpression(), "ALL(*) vs RD on: \(source)")
    }
}
