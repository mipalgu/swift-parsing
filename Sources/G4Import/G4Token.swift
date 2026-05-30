/// The associativity declared by an ANTLR `<assoc=left|right>` element option.
///
/// ANTLR 4 writes this option as a leading annotation on a rule alternative to mark the operator that
/// alternative defines as left- or right-associative. This is the single authoritative definition of the
/// two recognised values; lowering maps them to `ParsingCore`'s `Associativity`.
enum G4OptionAssociativity: Hashable, Sendable {
    /// `<assoc=left>`: the operator groups left-to-right (ANTLR's default).
    case left
    /// `<assoc=right>`: the operator groups right-to-left.
    case right
}

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
    /// An `<assoc=left|right>` element option, carrying the declared associativity.
    case elementOption(G4OptionAssociativity)
    /// The end-of-input marker.
    case endOfFile
}
