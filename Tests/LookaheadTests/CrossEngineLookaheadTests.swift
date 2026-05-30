import Testing

import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR

/// Proves the zero-width `lookahead` primitive behaves identically across all three native engines.
///
/// The three engines (``UTF8Parser``, ``UTF8GLRParser`` and ``ALLStarUTF8Parser``) interpret the same
/// data-only ``TokenMatcher`` but through independent code paths (recursive descent, GLR with a
/// scannerless lexer, and ALL(*) prediction). A grammar that distinguishes the keyword `if` from the
/// identifier `iffy` purely through `notFollowedBy` is therefore a sharp cross-engine agreement test:
/// every engine must treat `if` as a keyword and `iffy` as a name.
@Suite("Cross-engine keyword versus identifier lookahead")
struct CrossEngineLookaheadTests {
    /// A tiny grammar where `if` is a keyword (the literal `if` *not* followed by a further identifier
    /// character) and `name` is any identifier that is not exactly the bare `if` keyword, so `iffy`
    /// remains a name. The boundary is expressed entirely with zero-width lookahead.
    private func keywordGrammar() -> Grammar {
        // An identifier-continue character: a letter, a digit, or an underscore.
        let idChar = Match.oneOf(Match.letter, Match.digit, Match.lit("_"))
        // The keyword `if`: the literal followed by a word boundary (no identifier char may follow).
        let keyword = Match.seq(Match.lit("if"), Match.notFollowedBy(idChar))
        // A name: one or more identifier characters, but not the bare keyword `if` at the start.
        let name = Match.seq(Match.notFollowedBy(keyword), Match.oneOrMore(idChar))
        return Grammar(
            name: "kw",
            startRule: "s",
            rules: [
                "s": .choice([.reference("keyword"), .reference("name")]),
                "keyword": .token(name: "keyword", matcher: keyword, isNamed: true),
                "name": .token(name: "name", matcher: name, isNamed: true),
            ])
    }

    /// Parses `input` with each engine and returns the three resulting S-expressions, tagged by engine.
    private func parseEverywhere(_ input: String) throws -> (rd: String, glr: String, allStar: String) {
        let grammar = keywordGrammar()
        let rd = try UTF8Parser(grammar: grammar).parse(Source(input))
        let glr = try UTF8GLRParser(grammar: grammar).parse(Source(input))
        let allStar = try ALLStarUTF8Parser(grammar: grammar).parse(Source(input))
        return (rd.sExpression(), glr.sExpression(), allStar.sExpression())
    }

    @Test("`if` is a keyword on every engine")
    func ifIsKeyword() throws {
        let trees = try parseEverywhere("if")
        #expect(trees.rd == "(s (keyword (keyword)))")
        #expect(trees.glr == trees.rd)
        #expect(trees.allStar == trees.rd)
    }

    @Test("`iffy` is a name on every engine")
    func iffyIsName() throws {
        let trees = try parseEverywhere("iffy")
        #expect(trees.rd == "(s (name (name)))")
        #expect(trees.glr == trees.rd)
        #expect(trees.allStar == trees.rd)
    }

    @Test("`if_` is a name on every engine (underscore is an identifier continue)")
    func ifUnderscoreIsName() throws {
        let trees = try parseEverywhere("if_")
        #expect(trees.rd == "(s (name (name)))")
        #expect(trees.glr == trees.rd)
        #expect(trees.allStar == trees.rd)
    }

    @Test("Other identifiers are names on every engine", arguments: ["x", "iff", "if1", "ifs"])
    func otherIdentifiersAreNames(_ input: String) throws {
        let trees = try parseEverywhere(input)
        #expect(trees.rd == "(s (name (name)))")
        #expect(trees.glr == trees.rd)
        #expect(trees.allStar == trees.rd)
    }
}
