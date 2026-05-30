/// The W3C EBNF notation vocabulary, defined once and shared by the parser and the exporter.
///
/// Centralising the operator and delimiter spellings means the importer and exporter cannot drift
/// apart: there is a single authority for what `::=`, `|`, the quantifiers, the delimiters and the
/// comment markers are.
enum Notation {
    /// The production definition operator.
    static let define = "::="
    /// The alternation operator.
    static let alternate: Character = "|"
    /// The optional postfix quantifier.
    static let optional: Character = "?"
    /// The zero-or-more postfix quantifier.
    static let star: Character = "*"
    /// The one-or-more postfix quantifier.
    static let plus: Character = "+"
    /// The grouping open delimiter.
    static let groupOpen: Character = "("
    /// The grouping close delimiter.
    static let groupClose: Character = ")"
    /// The character-class open delimiter.
    static let classOpen: Character = "["
    /// The character-class close delimiter.
    static let classClose: Character = "]"
    /// The character-class negation marker (immediately after ``classOpen``).
    static let classNegate: Character = "^"
    /// The range marker inside a character class.
    static let rangeMarker: Character = "-"
    /// The single-quote terminal delimiter.
    static let singleQuote: Character = "'"
    /// The double-quote terminal delimiter.
    static let doubleQuote: Character = "\""
    /// The marker that introduces a hexadecimal code point (`#x...`).
    static let hexPrefix = "#x"
    /// The opening of a comment.
    static let commentOpen = "/*"
    /// The closing of a comment.
    static let commentClose = "*/"
    /// The descriptive text used inside the comment that flags a positive lookahead, which W3C EBNF has
    /// no surface form for.
    static let positiveLookaheadNote = "followed-by"
    /// The descriptive text used inside the comment that flags a negative lookahead, which W3C EBNF has
    /// no surface form for.
    static let negativeLookaheadNote = "not-followed-by"
}
