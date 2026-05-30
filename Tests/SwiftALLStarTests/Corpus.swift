import ParsingCore
import ParsingDSL
import RecursiveDescent

@testable import SwiftALLStar

/// The shared JSON differential corpus and helpers for the SwiftALLStar test suite.
///
/// The corpus is the canonical set of JSON inputs every engine in the framework must agree on by exact
/// S-expression equality. It is declared here in one place so the differential, granularity, and
/// recovery suites all draw from the same authoritative list.
enum Corpus {
    /// The sixteen JSON inputs (valid, structural, recovery, and multibyte) the engines must agree on.
    static let json: [String] = [
        #"{ "a": 1 }"#,
        #"[1, "x", true, null]"#,
        "{}",
        "[]",
        "true",
        "false",
        "null",
        #"{"o": {"a": [1, 2]}}"#,
        "  [1,2,3]  ",
        "\n\ttrue\n",
        #"{"nested": {"x": [true, false, null]}}"#,
        "true false",
        "@@@",
        "",
        #"["é", "🇦🇺", true]"#,
        #"{"key": "naïve café"}"#,
    ]
}

/// Parses an input with the ALL(*) UTF-8 engine.
///
/// - Parameter text: The JSON text to parse.
/// - Returns: The parse result.
/// - Throws: A grammar error if engine construction fails.
func parseAllStar(_ text: String) throws -> ParseResult {
    try ALLStarUTF8Parser(grammar: JSONGrammar.grammar()).parse(Source(text))
}

/// Parses an input with the recursive-descent reference UTF-8 engine.
///
/// - Parameter text: The JSON text to parse.
/// - Returns: The parse result.
/// - Throws: A grammar error if engine construction fails.
func parseReference(_ text: String) throws -> ParseResult {
    try UTF8Parser(grammar: JSONGrammar.grammar()).parse(Source(text))
}
