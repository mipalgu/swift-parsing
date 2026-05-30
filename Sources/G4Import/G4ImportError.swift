/// An error encountered while importing an ANTLR `.g4` grammar.
///
/// The importer fails fast on input that falls outside the documented supported subset, so a caller
/// always learns precisely why a grammar could not be lowered rather than receiving a silently
/// truncated result. Each case carries enough context (a position, a name, or the offending text) to
/// locate the problem in the source.
public enum G4ImportError: Error, Hashable, Sendable {
    /// The grammar did not begin with a `grammar Name;` header.
    case missingGrammarHeader
    /// A character that does not belong to the supported `.g4` meta-syntax was found, with its
    /// zero-based offset into the source.
    case unexpectedCharacter(Character, at: Int)
    /// A string literal or character set was not terminated before end of input.
    case unterminatedLiteral
    /// A token was encountered where a different one was required, described in human-readable form.
    case unexpectedToken(found: String, expected: String)
    /// A rule body referenced a name that is neither a defined rule nor the built-in `EOF`.
    case undefinedReference(String)
    /// A construct outside the supported subset was used, with a human-readable description.
    case unsupportedConstruct(String)
    /// The grammar declared no parser rules, so it has no start symbol.
    case noParserRules
    /// A rule was declared more than once.
    case duplicateRule(String)
}
