/// A position-aware, value-type facade over a ``GreenNode`` in the *red* layer of the tree.
///
/// `Syntax` is created lazily as callers traverse the tree. It pairs an immutable green
/// node with the absolute UTF-8 byte offset at which that node begins, and an optional
/// grammar field name describing the node's role in its parent. Because it stores only a
/// reference to the shared green node plus two small values, it is cheap to create and copy.
public struct Syntax: Sendable {
    /// The underlying immutable green node.
    public let green: GreenNode

    /// The absolute UTF-8 byte offset at which this node begins (including leading trivia).
    public let offset: Int

    /// The grammar field name describing this node's role in its parent, if any.
    public let field: String?

    /// Wraps a green node as the root of a red tree.
    ///
    /// - Parameters:
    ///   - green: The root green node.
    ///   - offset: The absolute byte offset of the root. Defaults to `0`.
    ///   - field: The field name, if any. Defaults to `nil`.
    public init(_ green: GreenNode, offset: Int = 0, field: String? = nil) {
        self.green = green
        self.offset = offset
        self.field = field
    }

    /// The kind of the underlying node.
    public var kind: SyntaxKind { green.kind }

    /// Whether the underlying node is a missing (recovery-synthesised) token.
    public var isMissing: Bool { green.isMissing }

    /// Whether the underlying node is a leaf token.
    public var isToken: Bool { green.isToken }

    /// The full byte span of this node, including any token trivia.
    public var span: SourceSpan { SourceSpan(start: offset, length: green.byteWidth) }

    /// The child facades of this node, in order, each positioned at its absolute offset.
    ///
    /// Child offsets accumulate the widths of preceding siblings, so traversal is linear
    /// in the number of children.
    public var children: [Syntax] {
        var result: [Syntax] = []
        var cursor = offset
        for child in green.children {
            result.append(Syntax(child.node, offset: cursor, field: child.field))
            cursor += child.node.byteWidth
        }
        return result
    }

    /// Renders the subtree as a canonical S-expression.
    ///
    /// Only named nodes and named tokens appear, matching tree-sitter's convention, so the
    /// rendering is a stable basis for comparing the output of different parser engines.
    /// Field names are shown as `name:` prefixes; `MISSING` and `ERROR` nodes are marked.
    ///
    /// - Returns: The S-expression string for this subtree, or an empty string if the node is anonymous.
    public func sExpression() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        // Anonymous literal tokens (punctuation) are omitted from the canonical rendering.
        guard kind.isNamed else { return }

        if let field { out += "\(field): " }

        if green.isMissing {
            out += "(MISSING \(kind.name))"
            return
        }

        let namedChildren = children.filter { $0.kind.isNamed }
        if namedChildren.isEmpty {
            out += "(\(kind.name))"
        } else {
            out += "(\(kind.name)"
            for child in namedChildren {
                out += " "
                child.write(into: &out)
            }
            out += ")"
        }
    }
}
