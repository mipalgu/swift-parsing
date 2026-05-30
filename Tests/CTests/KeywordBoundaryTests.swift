import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// Keyword-boundary coverage for the shared C lexical core.
///
/// A C reserved word is never a valid identifier, so `int return = 1;` must be rejected: the identifier
/// matcher must not split the keyword `return` into the identifier `retur` followed by `n`. Conversely, an
/// identifier that merely begins with, ends with, or wholly contains a keyword (such as `internal`,
/// `ifdef`, or `_int`) is a perfectly good name. Both properties are checked on all three native engines
/// through the structural grammar so the keyword boundary holds uniformly. The boundary uses the same
/// lookahead-driven exclusion as Lua, the pattern this grammar inherits.
@Suite("C keyword boundary")
struct CKeywordBoundaryTests {
    /// A representative set of C reserved words. A `int <word> = 1;` declaration is illegal for each.
    static let reservedWords: [String] = [
        "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum",
        "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return",
        "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void",
        "volatile", "while", "_Bool", "_Complex", "_Atomic", "_Noreturn",
    ]

    /// Identifiers that merely contain, begin with, or end with a keyword and so are valid names.
    static let validNames: [String] = [
        "internal", "ifdef", "ifx", "intx", "returns", "_int", "int2", "do_it", "ints", "longish",
        "forall", "switcher", "casey", "elsewhere", "x", "_", "__", "a1", "voidness", "constant",
    ]

    @Test(
        "A reserved word is rejected as a name on all three engines",
        arguments: reservedWords)
    func reservedWordRejected(_ word: String) throws {
        let source = "int \(word) = 1;"
        let grammar = CGrammar.translationUnit()
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
        let source = "int \(name) = 1;"
        let grammar = CGrammar.translationUnit()
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
