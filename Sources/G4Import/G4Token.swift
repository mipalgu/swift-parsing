/// A lexical token of ANTLR `.g4` meta-syntax.
///
/// The `.g4` importer tokenises grammar text into this small, closed vocabulary before parsing it into
/// rules. Keeping the token set explicit (rather than re-lexing inside the parser) keeps the parser
/// readable and the supported subset auditable.
enum G4Token: Hashable, Sendable {
    /// An identifier: a parser-rule name (lowercase initial) or token/lexer-rule name (uppercase initial).
    case identifier(String)
    /// A single-quoted string literal, with its escape sequences already decoded.
    case stringLiteral(String)
    /// A character set written `[...]`, captured verbatim (without the surrounding brackets) for lowering.
    case characterSet(String)
    /// The `grammar` keyword.
    case grammarKeyword
    /// The `fragment` keyword.
    case fragmentKeyword
    /// A colon `:` beginning a rule body.
    case colon
    /// A semicolon `;` ending a rule.
    case semicolon
    /// A vertical bar `|` separating alternatives.
    case pipe
    /// An opening parenthesis `(`.
    case leftParenthesis
    /// A closing parenthesis `)`.
    case rightParenthesis
    /// A question mark `?` (optional, or the trailing non-greedy marker).
    case question
    /// An asterisk `*` (zero or more).
    case star
    /// A plus `+` (one or more).
    case plus
    /// A tilde `~` (set negation).
    case tilde
    /// A dot `.` (wildcard).
    case dot
    /// The lexer-command arrow `->`.
    case arrow
    /// A comma `,` (used inside lexer-command argument lists).
    case comma
    /// An element-label assignment operator (`=` or `+=`).
    case equals
    /// The end-of-input marker.
    case endOfFile
}
