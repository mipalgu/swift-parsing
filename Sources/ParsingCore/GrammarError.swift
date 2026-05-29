/// An error raised while preparing an engine for a grammar.
///
/// The parser core uses *typed* throws (`throws(GrammarError)`) rather than untyped `throws`, because
/// untyped throws relies on the `any Error` existential, which is unavailable in Embedded Swift.
/// Parsing itself never throws: malformed input yields a complete tree with `ERROR`/`MISSING` nodes.
public enum GrammarError: Error, Hashable, Sendable {
    /// The grammar's start rule is not defined in its rules.
    case undefinedStartRule(String)
    /// No engine backend supports the grammar (for example an unbundled tree-sitter language).
    case unsupportedLanguage(String)
    /// The grammar is otherwise invalid, with a human-readable reason.
    case invalidGrammar(String)
}
