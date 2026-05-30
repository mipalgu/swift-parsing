/// How many times a pattern may repeat when matched against a sequence of sibling nodes.
///
/// Quantifiers mirror tree-sitter's `?`, `*` and `+` operators. A pattern with no explicit
/// quantifier carries ``one``, meaning it must match exactly once.
public enum Quantifier: Hashable, Sendable {
    /// The pattern must match exactly once (the default, written without an operator).
    case one
    /// The pattern may match zero or one times (written `?`).
    case zeroOrOne
    /// The pattern may match zero or more times (written `*`).
    case zeroOrMore
    /// The pattern must match one or more times (written `+`).
    case oneOrMore

    /// Whether matching zero occurrences of the quantified pattern is permitted.
    var allowsZero: Bool { self == .zeroOrOne || self == .zeroOrMore }

    /// Whether matching more than one occurrence of the quantified pattern is permitted.
    var allowsMany: Bool { self == .zeroOrMore || self == .oneOrMore }
}

/// A predicate name that constrains a pattern by inspecting the text of its captures.
///
/// Predicates are written `#name?` inside a pattern, for example `(#eq? @a @b)`. They are
/// evaluated against the source text of the captured nodes after the structural match succeeds.
public enum PredicateKind: Hashable, Sendable {
    /// `#eq?`: every operand must have identical text (a capture's text, or a literal string).
    case equal
    /// `#not-eq?`: the operands must not all have identical text.
    case notEqual
    /// `#match?`: the capture's text must match the regular expression given as the second operand.
    case match
    /// `#not-match?`: the capture's text must not match the regular expression given as the second operand.
    case notMatch
    /// `#any-of?`: the capture's text must equal one of the literal strings that follow.
    case anyOf
    /// `#not-any-of?`: the capture's text must not equal any of the literal strings that follow.
    case notAnyOf
}

/// An argument to a predicate: either a reference to a named capture, or a literal string.
public enum PredicateArgument: Hashable, Sendable {
    /// A reference to a capture by name (written `@name`).
    case capture(String)
    /// A literal string operand (written in double quotes).
    case literal(String)
}

/// A textual constraint attached to a node pattern, evaluated after a structural match.
///
/// Predicates do not change which nodes are visited; they reject candidate matches whose captured
/// text fails the constraint. They are gathered at the level of the enclosing node pattern.
public struct Predicate: Hashable, Sendable {
    /// The kind of constraint to apply.
    public let kind: PredicateKind
    /// The operands, in source order.
    public let arguments: [PredicateArgument]

    /// Creates a predicate.
    /// - Parameters:
    ///   - kind: The kind of constraint.
    ///   - arguments: The operands, in source order.
    public init(kind: PredicateKind, arguments: [PredicateArgument]) {
        self.kind = kind
        self.arguments = arguments
    }
}

/// A compiled query pattern: the structural shape a subtree must have to match.
///
/// `QueryPattern` is the intermediate representation a ``Query`` walks when matching. It is a
/// recursive value mirroring the tree-sitter query grammar: named and anonymous nodes, wildcards,
/// alternations, groups, anchors, quantifiers, field constraints, negated fields and captures.
public indirect enum QueryPattern: Hashable, Sendable {
    /// Matches any single node, named or anonymous (the bare wildcard `_`).
    case anyNode
    /// Matches any single *named* node (the parenthesised wildcard `(_)`).
    case anyNamedNode

    /// Matches an anonymous literal token whose text equals the given string (a quoted pattern).
    case anonymous(String)

    /// Matches a named node of the given type whose children satisfy the child patterns.
    ///
    /// - Parameters:
    ///   - type: The node-type name (a `ParsingCore` `SyntaxKind` name).
    ///   - children: The ordered child patterns to satisfy within this node.
    ///   - predicates: Textual predicates scoped to this node's captures.
    case node(type: String, children: [QueryPattern], predicates: [Predicate])

    /// Matches a parenthesised group of sibling patterns as a unit (so a quantifier can apply to it).
    case group([QueryPattern])

    /// Matches when any one of the alternative patterns matches (`[a b c]`).
    case alternation([QueryPattern])

    /// Constrains a child pattern to appear under the given grammar field label (`name: pattern`).
    case field(String, QueryPattern)

    /// Asserts that the enclosing node has no child under the given field label (`!name`).
    case negatedField(String)

    /// An anchor (`.`) constraining adjacency between named siblings; carries no sub-pattern.
    case anchor

    /// Wraps a pattern with a capture name so matched nodes are reported under that name (`@name`).
    case capture(String, QueryPattern)

    /// Wraps a pattern with a repetition quantifier (`?`, `*` or `+`).
    case quantified(QueryPattern, Quantifier)
}
