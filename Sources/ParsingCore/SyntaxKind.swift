/// Identifies the kind of a concrete-syntax-tree node or token.
///
/// Kinds carry the grammar's node-type name plus a flag distinguishing *named*
/// nodes and tokens (rules such as `object` or `string`) from *anonymous* literal
/// tokens (punctuation such as `{` or `,`). Following tree-sitter convention, only
/// named nodes appear in the canonical S-expression rendering, which keeps the
/// differential comparison between engines stable.
public struct SyntaxKind: Hashable, Sendable, CustomStringConvertible {
    /// The grammar node-type name (for example `"object"`, `"string"`, `"{"`).
    public let name: String

    /// Whether this kind is a named grammar symbol (`true`) or an anonymous literal token (`false`).
    public let isNamed: Bool

    /// Creates a syntax kind.
    ///
    /// - Parameters:
    ///   - name: The grammar node-type name.
    ///   - isNamed: Whether the kind is a named grammar symbol. Defaults to `true`.
    public init(_ name: String, isNamed: Bool = true) {
        self.name = name
        self.isNamed = isNamed
    }

    /// The kind used for error-recovery nodes wrapping unexpected input.
    public static let error = SyntaxKind("ERROR", isNamed: true)

    /// The kind's name, used as its textual description.
    public var description: String { name }
}
