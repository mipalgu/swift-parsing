import ParsingCore
import ParsingDSL
import RecursiveDescent
import SwiftALLStar
import SwiftGLR

/// The shared Lua corpora and parsing helpers for the `LuaTests` suite.
///
/// The corpus is split by which acceptance gate each input feeds. ``structural`` inputs drive all three
/// engines through ``LuaGrammar/chunk()`` and must agree by byte-identical S-expression and round-trip
/// losslessly. ``expression`` inputs drive the ALL(*) engine through ``LuaGrammar/expressions()`` and
/// prove precedence and associativity. ``multibyte`` inputs additionally exercise granularity agreement.
enum Corpus {
    /// Structural Lua inputs every engine must agree on, exercising the full statement and expression grammar.
    static let structural: [String] = [
        // Empty and trivial chunks.
        "",
        "  ",
        "\n\t\n",
        // Local declarations, assignment, multiple assignment.
        "local x = 1",
        "local a, b = 1, 2",
        "a, b = b, a",
        "local x <const> = 1",
        "local h <close> = open()",
        "x = 1 + 2 * 3",
        "t.x = 1",
        "t[k] = v",
        // do / while / repeat.
        "do local x = 1 end",
        "while c do x = x + 1 end",
        "repeat x = x - 1 until x == 0",
        // if / elseif / else.
        "if c then return 1 end",
        "if c then x = 1 elseif d then x = 2 else x = 3 end",
        // for loops.
        "for i = 1, 10 do x = x + i end",
        "for i = 1, 10, 2 do end",
        "for k, v in pairs(t) do print(k, v) end",
        // Functions, methods, local functions.
        "function f() return 1 end",
        "function M.f(a, b) return a + b end",
        "function M:g(x) return self.x + x end",
        "local function fact(n) return n end",
        "local add = function(a, b) return a + b end",
        "function variadic(...) return ... end",
        // Tables.
        "local t = {}",
        "local t = {1, 2, 3}",
        "local t = {x = 1, y = 2}",
        "local t = {[1] = \"a\", name = \"b\", positional}",
        "local t = {1; 2; 3;}",
        "local t = {1, 2,}",
        // Call forms.
        "f(x)",
        "f\"literal\"",
        "f{1, 2}",
        "o:m()",
        "o:m(1, 2)",
        "a.b.c.d()",
        "print(\"hello\")",
        // goto / labels / break.
        "do break end",
        "goto continue",
        "::continue::",
        "while true do goto done end ::done::",
        // Nested blocks three deep.
        "do do do local x = 1 end end end",
        // Numerals.
        "local n = 0xFF",
        "local n = 1e10",
        "local n = 0x1p4",
        "local n = 3.14",
        "local n = 100",
        "local n = 0x1.8p1",
        "local n = .5",
        // Strings and escapes.
        "local s = \"a\\tb\\n\"",
        "local s = '\\u{1F1E6}'",
        "local s = \"\\x41\\65\"",
        "local s = [[raw\\nnot-escaped]]",
        "local s = [==[ long ]==]",
        "local s = [=[ level one ]=]",
        // Operators across tiers.
        "local v = a or b and c",
        "local v = 1 + 2 * 3 - 4 / 5 % 6",
        "local v = a .. b .. c",
        "local v = 2 ^ 2 ^ 3",
        "local v = #t + 1",
        "local v = not a",
        "local v = -x",
        "local v = a < b and b <= c",
        "local v = x | y & z",
        "local v = x << 2 >> 1",
        // Trivia: comments before, between, and after tokens.
        "-- a line comment\nx = 1",
        "x = 1 -- trailing comment",
        "x = --[[ block ]] 1",
        "--[==[ nested-ish ]==]\nx = 1",
        "-- one\n-- two\nx = 1",
        // Unicode payloads in strings and comments (mirrors the JSON multibyte rows).
        "local s = \"café\"",
        "local s = \"🇦🇺\"",
        "-- café comment\nx = 1",
    ]

    /// Structural inputs carrying multibyte payloads, used for cross-granularity agreement checks.
    static let multibyte: [String] = [
        "local s = \"café\"",
        "local s = \"🇦🇺\"",
        "local t = {name = \"naïve café\"}",
        "-- 🇦🇺 comment\nlocal x = 1",
    ]

    /// Expression inputs that drive the ALL(*) precedence ladder in ``LuaGrammar/expressions()``.
    static let expression: [String] = [
        "a",
        "a - b - c",
        "a .. b .. c",
        "2 ^ 2 ^ 3",
        "a or b and c",
        "a + b * c",
        "a * b + c",
        "a < b == c",
        "-2 ^ 2",
        "#t + 1",
        "a and b or c",
        "not a == b",
        "1 + 2 * 3 - 4 / 5 % 6 .. 7",
        "x | y & z",
        "x << 2 >> 1",
        "a <= b",
    ]

    // MARK: - Parsing helpers

    /// Parses Lua source with the recursive-descent reference engine over the structural grammar.
    /// - Parameter text: The Lua source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseReference(_ text: String) throws -> ParseResult {
        try UTF8Parser(grammar: LuaGrammar.chunk()).parse(Source(text))
    }

    /// Parses Lua source with the GLR engine over the structural grammar.
    /// - Parameter text: The Lua source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseGLR(_ text: String) throws -> ParseResult {
        try UTF8GLRParser(grammar: LuaGrammar.chunk()).parse(Source(text))
    }

    /// Parses Lua source with the ALL(*) engine over the structural grammar.
    /// - Parameter text: The Lua source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseAllStar(_ text: String) throws -> ParseResult {
        try ALLStarUTF8Parser(grammar: LuaGrammar.chunk()).parse(Source(text))
    }

    /// Parses a Lua expression with the ALL(*) engine over the left-recursive expression grammar.
    /// - Parameter text: The Lua expression source.
    /// - Returns: The parse result.
    /// - Throws: A grammar error if engine construction fails.
    static func parseExpression(_ text: String) throws -> ParseResult {
        try ALLStarUTF8Parser(grammar: LuaGrammar.expressions()).parse(Source(text))
    }
}
