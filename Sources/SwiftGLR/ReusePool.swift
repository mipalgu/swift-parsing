import ParsingCore

/// A content-addressed pool of a previous parse's green subtrees, used to reuse the unchanged ones.
///
/// Green nodes are immutable and position-independent, so any subtree the new parse rebuilds that is
/// structurally identical to one in the previous tree can be replaced by the previous node without changing
/// the tree. The pool indexes every previous subtree by a structural hash; ``reuse(_:)`` looks a freshly
/// built node up, confirms a candidate with ``GreenNode/isEquivalent(to:)``, and returns the previous node
/// when one matches. Reuse therefore keeps the identities of unchanged subtrees stable across an edit and
/// avoids re-allocating them, while the rebuilt tree stays byte-for-byte what a full parse would produce.
///
/// This realises subtree reuse at tree-construction time. Truncating the graph-structured stack and shared
/// packed parse forest to skip re-deriving the unchanged prefix is a further optimisation left to a later
/// pass; the pool is correct and beneficial on its own.
final class ReusePool {
    /// Previous subtrees grouped by structural hash, the buckets ``reuse(_:)`` searches.
    private var byHash: [Int: [GreenNode]] = [:]
    /// Memoised structural hashes keyed by node identity, shared across the previous and new trees so each
    /// node is hashed at most once and a parent's hash is an O(children) combine of cached child hashes.
    private var hashes: [ObjectIdentifier: Int] = [:]
    /// Strong references to every node the pool has hashed.
    ///
    /// A node's identity is its memory address, which the runtime may recycle once the node is freed. A
    /// freshly built node that the builder discards (because ``reuse(_:)`` matched it to a previous node)
    /// could otherwise be deallocated and its address reused, so a later node would collide with its
    /// memoised hash. Retaining every hashed node for the pool's lifetime keeps each identity unique and the
    /// memo sound; the references are released when the reparse completes and the pool is discarded.
    private var retained: [GreenNode] = []

    /// Builds a pool from the root of the previous parse's tree.
    /// - Parameter previous: The previous tree's green root.
    init(previous: GreenNode) {
        register(previous)
    }

    /// Indexes a subtree and all of its descendants.
    private func register(_ node: GreenNode) {
        byHash[structuralHash(node), default: []].append(node)
        for child in node.children { register(child.node) }
    }

    /// Returns a structurally equivalent node from the previous tree, or `node` unchanged when none exists.
    ///
    /// - Parameter node: A freshly built green node.
    /// - Returns: The previous node equivalent to `node`, reusing its identity, or `node` itself.
    func reuse(_ node: GreenNode) -> GreenNode {
        guard let candidates = byHash[structuralHash(node)] else { return node }
        for candidate in candidates where candidate.isEquivalent(to: node) { return candidate }
        return node
    }

    /// The structural hash of a node, memoised by identity and combined from its children bottom-up.
    private func structuralHash(_ node: GreenNode) -> Int {
        let identity = ObjectIdentifier(node)
        if let cached = hashes[identity] { return cached }
        retained.append(node)
        var hasher = Hasher()
        hasher.combine(node.kind)
        hasher.combine(node.isMissing)
        hasher.combine(node.byteWidth)
        switch node.payload {
        case .token(let text, let leading, let trailing):
            hasher.combine(0)
            hasher.combine(text)
            hasher.combine(leading)
            hasher.combine(trailing)
        case .node(let children):
            hasher.combine(1)
            hasher.combine(children.count)
            for child in children {
                hasher.combine(child.field)
                hasher.combine(structuralHash(child.node))
            }
        }
        let value = hasher.finalize()
        hashes[identity] = value
        return value
    }
}
