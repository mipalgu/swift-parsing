import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR
import Testing

/// Coverage for the Lua 5.4 `\z` whitespace-skip string escape on the shared lexical core.
///
/// The `\z` escape skips the run of whitespace following it, including newlines, so a long literal can be
/// wrapped across source lines without embedding the line break. The grammar must accept such a literal,
/// round-trip it losslessly (the skipped whitespace is part of the string token's text), and agree across
/// the recursive-descent, GLR, and ALL(*) engines.
@Suite("Lua \\z whitespace-skip escape")
struct LuaStringEscapeTests {
    /// Sources whose string literals use a `\z` escape followed by a run of whitespace to skip.
    static let zEscapeSources: [String] = [
        // `\z` before a newline and the leading indent of the continued line.
        "local c = \"line one \\z\n    line two\"",
        // `\z` followed only by spaces and tabs.
        "local c = \"a \\z   \tb\"",
        // `\z` immediately before the closing quote (skips nothing).
        "local c = \"trailing \\z\"",
        // `\z` skipping a multi-line run of blank lines.
        "local c = \"x \\z\n\n\t  y\"",
    ]

    @Test(
        "A \\z escape skips following whitespace, round-trips, and agrees across all three engines",
        arguments: zEscapeSources)
    func zEscapeSkipsWhitespace(_ source: String) throws {
        let grammar = LuaGrammar.chunk()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(source))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(source))
        let allstar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(source))
        #expect(!rd.hasErrors, "recursive descent should accept: \(source.debugDescription)")
        #expect(!glr.hasErrors, "GLR should accept: \(source.debugDescription)")
        #expect(!allstar.hasErrors, "ALL(*) should accept: \(source.debugDescription)")
        #expect(rd.tree.green.reconstructedText == source, "round-trip: \(source.debugDescription)")
        #expect(glr.tree.green.reconstructedText == source)
        #expect(allstar.tree.green.reconstructedText == source)
        #expect(glr.sExpression() == rd.sExpression(), "GLR vs RD on: \(source.debugDescription)")
        #expect(allstar.sExpression() == rd.sExpression(), "ALL(*) vs RD on: \(source.debugDescription)")
    }
}
