/// A child slot within an internal green node, optionally carrying a grammar field name.
///
/// Field names (for example `key:` / `value:` on a JSON pair) mirror tree-sitter's
/// field concept and let queries and renderings refer to children by role.
public struct GreenChild: Sendable {
    /// The grammar field name for this child, or `nil` if the child is unlabelled.
    public let field: String?

    /// The child node.
    public let node: GreenNode

    /// Creates a child slot.
    ///
    /// - Parameters:
    ///   - field: The grammar field name, or `nil` if unlabelled.
    ///   - node: The child node.
    public init(field: String? = nil, node: GreenNode) {
        self.field = field
        self.node = node
    }
}

/// An immutable, position-independent node in the *green* layer of the concrete syntax tree.
///
/// Green nodes follow the Roslyn / swift-syntax red-green design: they store a *width*
/// rather than an absolute position, hold no parent pointer, and are fully immutable,
/// so they conform to `Sendable` for free and can be shared structurally across reparses.
/// Absolute positions are computed lazily by the red layer (``Syntax``).
///
/// A green node is either a *token* (a leaf carrying source text plus surrounding trivia)
/// or an *internal node* (carrying ordered ``GreenChild`` slots).
public final class GreenNode: Sendable {
    /// The payload distinguishing tokens from internal nodes.
    public enum Payload: Sendable {
        /// A leaf token: its content text plus leading and trailing trivia (whitespace, comments).
        case token(text: String, leadingTrivia: String, trailingTrivia: String)
        /// An internal node with ordered child slots.
        case node(children: [GreenChild])
    }

    /// The kind of this node or token.
    public let kind: SyntaxKind

    /// The token text / children of this node.
    public let payload: Payload

    /// The total width of this node in UTF-8 bytes, including any token trivia.
    public let byteWidth: Int

    /// Whether this node was synthesised by error recovery to stand in for required-but-absent input.
    public let isMissing: Bool

    private init(kind: SyntaxKind, payload: Payload, byteWidth: Int, isMissing: Bool) {
        self.kind = kind
        self.payload = payload
        self.byteWidth = byteWidth
        self.isMissing = isMissing
    }

    /// Creates a leaf token node.
    ///
    /// - Parameters:
    ///   - kind: The token kind.
    ///   - text: The token's content text.
    ///   - leadingTrivia: Whitespace/comments immediately preceding the token. Defaults to empty.
    ///   - trailingTrivia: Whitespace/comments immediately following the token. Defaults to empty.
    /// - Returns: An immutable token green node.
    public static func token(
        _ kind: SyntaxKind,
        text: String,
        leadingTrivia: String = "",
        trailingTrivia: String = ""
    ) -> GreenNode {
        let width = leadingTrivia.utf8.count + text.utf8.count + trailingTrivia.utf8.count
        return GreenNode(
            kind: kind,
            payload: .token(text: text, leadingTrivia: leadingTrivia, trailingTrivia: trailingTrivia),
            byteWidth: width,
            isMissing: false
        )
    }

    /// Creates a zero-width *missing* token, synthesised by error recovery.
    ///
    /// - Parameter kind: The kind of token that was expected but absent.
    /// - Returns: A zero-width green token flagged as missing.
    public static func missingToken(_ kind: SyntaxKind) -> GreenNode {
        GreenNode(
            kind: kind,
            payload: .token(text: "", leadingTrivia: "", trailingTrivia: ""),
            byteWidth: 0,
            isMissing: true
        )
    }

    /// Creates an internal node from ordered children.
    ///
    /// - Parameters:
    ///   - kind: The node kind.
    ///   - children: The ordered child slots.
    /// - Returns: An immutable internal green node whose width is the sum of its children's widths.
    public static func node(_ kind: SyntaxKind, children: [GreenChild]) -> GreenNode {
        let width = children.reduce(0) { $0 + $1.node.byteWidth }
        return GreenNode(kind: kind, payload: .node(children: children), byteWidth: width, isMissing: false)
    }

    /// Creates an `ERROR` node wrapping unexpected children.
    ///
    /// - Parameter children: The child slots gathered during recovery.
    /// - Returns: An internal node with kind ``SyntaxKind/error``.
    public static func errorNode(children: [GreenChild]) -> GreenNode {
        node(.error, children: children)
    }

    /// The token text, or `nil` for internal nodes.
    public var tokenText: String? {
        if case .token(let text, _, _) = payload { return text }
        return nil
    }

    /// The child slots, or an empty array for tokens.
    public var children: [GreenChild] {
        if case .node(let children) = payload { return children }
        return []
    }

    /// Whether this node is a leaf token.
    public var isToken: Bool {
        if case .token = payload { return true }
        return false
    }

    /// Whether this node and another denote structurally identical subtrees.
    ///
    /// Two green nodes are equivalent when they have the same kind, missing flag and payload: identical
    /// token text and trivia for leaves, or the same ordered children (matched by field and recursively
    /// equivalent) for internal nodes. Because green nodes are immutable and position-independent,
    /// substituting one equivalent node for another leaves the reconstructed text and tree shape unchanged,
    /// which is what makes incremental subtree reuse sound. Reference-identical nodes short-circuit to
    /// `true`, so comparing a shared subtree against itself is constant time.
    ///
    /// - Parameter other: The node to compare against.
    /// - Returns: `true` if the two subtrees are structurally identical.
    public func isEquivalent(to other: GreenNode) -> Bool {
        if self === other { return true }
        guard kind == other.kind, isMissing == other.isMissing, byteWidth == other.byteWidth else {
            return false
        }
        switch (payload, other.payload) {
        case (.token(let text, let lead, let trail), .token(let otherText, let otherLead, let otherTrail)):
            return text == otherText && lead == otherLead && trail == otherTrail
        case (.node(let children), .node(let otherChildren)):
            guard children.count == otherChildren.count else { return false }
            for (lhs, rhs) in zip(children, otherChildren) {
                guard lhs.field == rhs.field, lhs.node.isEquivalent(to: rhs.node) else { return false }
            }
            return true
        default:
            return false
        }
    }

    /// The exact source text this subtree was built from, including all trivia.
    ///
    /// Concatenating leading trivia, content and trailing trivia for every token in order
    /// reproduces the original input verbatim. A round-trip equality check against the source
    /// is the test of an engine's losslessness.
    public var reconstructedText: String {
        switch payload {
        case .token(let text, let leading, let trailing):
            return leading + text + trailing
        case .node(let children):
            var out = ""
            for child in children { out += child.node.reconstructedText }
            return out
        }
    }
}
