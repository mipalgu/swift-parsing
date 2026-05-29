/// Operator associativity used when resolving precedence conflicts.
public enum Associativity: Hashable, Sendable {
    /// Left-associative.
    case left
    /// Right-associative.
    case right
    /// No declared associativity.
    case none
}

/// A grammar production, expressed as a recursive expression tree.
///
/// `Rule` is the normalised intermediate representation that every surface syntax (the Swift DSL,
/// tree-sitter `grammar.json`, ANTLR `.g4`, EBNF) lowers to, and that every engine consumes. Keeping a
/// single hub representation means each new surface syntax is one importer/exporter rather than a
/// pairwise converter. Terminals carry a ``TokenMatcher`` (not a regular expression), so the IR is
/// Embedded-safe and granularity-agnostic.
public enum Rule: Hashable, Sendable {
    /// A terminal matching a token, tagged with a node kind name and whether the node is named.
    case token(name: String, matcher: TokenMatcher, isNamed: Bool)
    /// A reference to another named rule.
    case reference(String)
    /// An ordered sequence: all sub-rules must match in order.
    case sequence([Rule])
    /// An ordered choice: the first matching alternative wins.
    case choice([Rule])
    /// Zero or more repetitions of a sub-rule.
    indirect case repeatZeroOrMore(Rule)
    /// One or more repetitions of a sub-rule.
    indirect case repeatOneOrMore(Rule)
    /// An optional sub-rule (zero or one).
    indirect case optional(Rule)
    /// Labels a sub-rule with a grammar field name.
    indirect case field(String, Rule)
    /// Assigns static precedence and associativity to a sub-rule.
    indirect case precedence(level: Int, associativity: Associativity, Rule)

    /// Convenience constructor for an anonymous literal token.
    ///
    /// - Parameter text: The exact text to match.
    /// - Returns: A `.token` rule whose kind name is the literal text and which is anonymous.
    public static func literal(_ text: String) -> Rule {
        .token(name: text, matcher: .literal(text), isNamed: false)
    }
}

/// A complete grammar: a set of named rules with a designated start symbol and `extras`.
///
/// `extras` are token matchers (typically whitespace and comments) permitted to appear between any two
/// tokens; they are attached to the tree as trivia rather than structural nodes. Each extra matcher is
/// applied repeatedly at the cursor, so a single-element matcher such as ``BuiltinClass/whitespace``
/// consumes a whole run.
public struct Grammar: Hashable, Sendable {
    /// The grammar's name (for example `"json"`).
    public let name: String

    /// The name of the start rule.
    public let startRule: String

    /// The named rules, keyed by rule name.
    public let rules: [String: Rule]

    /// Token matchers permitted between tokens and captured as trivia (whitespace, comments).
    public let extras: [TokenMatcher]

    /// Creates a grammar.
    ///
    /// - Parameters:
    ///   - name: The grammar's name.
    ///   - startRule: The name of the start rule. Must exist in `rules`.
    ///   - rules: The named rules.
    ///   - extras: Trivia token matchers. Defaults to ASCII whitespace.
    public init(
        name: String,
        startRule: String,
        rules: [String: Rule],
        extras: [TokenMatcher] = [.builtin(.whitespace)]
    ) {
        self.name = name
        self.startRule = startRule
        self.rules = rules
        self.extras = extras
    }
}
