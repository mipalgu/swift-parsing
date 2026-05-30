import ParsingCore

/// The abstract syntax tree of a parsed ANTLR `.g4` grammar.
///
/// The parser produces this faithful, surface-level tree first; lowering to the `ParsingCore` grammar
/// intermediate representation is a separate, testable step. Element nodes mirror the `.g4` element
/// vocabulary supported by this importer.

/// A single `.g4` element: the atoms and combinators that make up a rule alternative.
indirect enum G4Element: Hashable, Sendable {
    /// A reference to another rule by name (parser rule, lexer rule, or `EOF`).
    case reference(String)
    /// A single-quoted string literal terminal.
    case stringLiteral(String)
    /// A character set `[...]` (negated when `isNegated` is `true`).
    case characterSet(body: String, isNegated: Bool)
    /// A negated single-element set written `~'x'` or `~ELEMENT`.
    case negatedElement(G4Element)
    /// The dot wildcard, matching any single element.
    case dot
    /// A parenthesised group of alternatives.
    case group([G4Alternative])
    /// An optional element (`element?`).
    case optional(G4Element)
    /// Zero or more repetitions (`element*`).
    case zeroOrMore(G4Element)
    /// One or more repetitions (`element+`).
    case oneOrMore(G4Element)
    /// An element labelled with a name (`label=element` or `label+=element`), lowered to a grammar field.
    case labelled(String, G4Element)
    /// An element carrying a trailing `<assoc=...>` option. ANTLR ignores a trailing option, so lowering
    /// passes through to the inner element; only the leading alternative option sets associativity.
    case elementOption(G4OptionAssociativity, G4Element)
}

/// One alternative of a rule: an ordered sequence of elements.
struct G4Alternative: Hashable, Sendable {
    /// The elements matched in order.
    var elements: [G4Element]
    /// The associativity declared by a leading `<assoc=left|right>` option on this alternative.
    ///
    /// In ANTLR 4 the option is written immediately after the `|` (or after `:` for the first
    /// alternative). It defaults to `.left`, matching ANTLR's default for an undecorated operator
    /// alternative.
    var declaredAssociativity: Associativity = .left
}

/// A lexer command attached to the end of a lexer-rule alternative (the `-> ...` clause).
enum G4LexerCommand: Hashable, Sendable {
    /// `-> skip`: the matched text is discarded (trivia).
    case skip
    /// `-> channel(...)`: the matched text is routed to a hidden channel (treated as trivia here).
    case channel(String)
}

/// A complete `.g4` rule (parser rule, lexer rule, or fragment).
struct G4Rule: Hashable, Sendable {
    /// The rule's name.
    var name: String
    /// The rule's alternatives.
    var alternatives: [G4Alternative]
    /// Whether the rule was declared `fragment` (a lexer helper, never a parser-visible token).
    var isFragment: Bool
    /// The lexer command attached to the rule, if any.
    var command: G4LexerCommand?

    /// Whether the rule is a lexer rule (its name begins with an uppercase letter) or a fragment.
    var isLexerRule: Bool { isFragment || (name.first?.isUppercase ?? false) }
}

/// A parsed `.g4` grammar: a name plus its rules in declaration order.
struct G4ParsedGrammar: Hashable, Sendable {
    /// The grammar's name from its header.
    var name: String
    /// The rules, in the order they were declared.
    var rules: [G4Rule]
}
