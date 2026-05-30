import ParsingCore

/// A vertex of the graph-structured stack: an LR state reached at an input level.
///
/// The graph-structured stack shares common stack prefixes and suffixes across the forked parses so
/// the search stays polynomial. Each vertex pairs an LR state with the input level at which it was
/// created; the merging invariant keeps at most one vertex per state per level.
final class GSSNode {
    /// The LR state at this stack top.
    let state: Int
    /// The input level (token step) at which this vertex lives.
    let level: Int
    /// Outgoing edges toward the stack bottom, each labelled with the forest node spanning a symbol.
    var edges: [GSSEdge] = []

    init(state: Int, level: Int) {
        self.state = state
        self.level = level
    }
}

/// A labelled edge from a stack top toward its predecessor, carrying the consumed symbol's forest node.
struct GSSEdge {
    /// The predecessor vertex (toward the stack bottom).
    let target: GSSNode
    /// The forest node for the symbol consumed along this edge.
    let sppf: SPPFNode
}

/// The graph-structured stack for one parse.
///
/// The stack maintains a frontier of vertices keyed by LR state at the current level, enforcing the
/// one-vertex-per-state-per-level merging invariant that bounds the search and guarantees termination
/// for cyclic and epsilon grammars. Edges are deduplicated so reductions reach a fixed point without
/// looping.
final class GSS {
    private(set) var frontier: [Int: GSSNode] = [:]

    /// Returns the frontier vertex for a state at a level, creating it if absent.
    ///
    /// - Parameters:
    ///   - state: The LR state.
    ///   - level: The input level.
    /// - Returns: The vertex and whether it was newly created.
    func node(state: Int, level: Int) -> (node: GSSNode, isNew: Bool) {
        if let existing = frontier[state] { return (existing, false) }
        let node = GSSNode(state: state, level: level)
        frontier[state] = node
        return (node, true)
    }

    /// Adds an edge between two vertices, deduplicating identical edges.
    ///
    /// - Parameters:
    ///   - from: The stack-top vertex.
    ///   - to: The predecessor vertex.
    ///   - sppf: The forest node labelling the edge.
    /// - Returns: Whether a new edge was added.
    @discardableResult
    func addEdge(from: GSSNode, to: GSSNode, sppf: SPPFNode) -> Bool {
        for edge in from.edges where edge.target === to && edge.sppf === sppf { return false }
        from.edges.append(GSSEdge(target: to, sppf: sppf))
        return true
    }

    /// Replaces the frontier with a fresh one for the next level.
    ///
    /// - Parameter newFrontier: The vertices forming the next level's frontier.
    func advance(to newFrontier: [Int: GSSNode]) {
        frontier = newFrontier
    }

    /// Enumerates all paths of a given length backward from a vertex.
    ///
    /// Each path is the ordered list of forest nodes labelling the traversed edges, from the stack
    /// bottom toward the top, paired with the vertex reached at the far end.
    ///
    /// - Parameters:
    ///   - node: The starting vertex.
    ///   - length: The number of edges to traverse.
    /// - Returns: The paths as `(labels, base)` pairs.
    func paths(from node: GSSNode, length: Int) -> [(labels: [SPPFNode], base: GSSNode)] {
        var result: [(labels: [SPPFNode], base: GSSNode)] = []
        forEachPath(from: node, length: length) { labels, base in
            result.append((labels, base))
        }
        return result
    }

    /// Visits every path of a given length backward from a vertex.
    ///
    /// Each path is the ordered list of forest nodes labelling the traversed edges, from the stack top
    /// toward the bottom, paired with the vertex reached at the far end. A zero-length path is the
    /// vertex itself with no labels. The labels are presented in a buffer reused across invocations, so
    /// the visitor must copy them if it needs to retain them beyond the call.
    ///
    /// - Parameters:
    ///   - node: The starting vertex.
    ///   - length: The number of edges to traverse.
    ///   - body: Invoked once per path with the ordered labels (stack top toward bottom) and the base
    ///     vertex reached at the far end.
    func forEachPath(
        from node: GSSNode, length: Int, _ body: (_ labels: [SPPFNode], _ base: GSSNode) -> Void
    ) {
        if length == 0 {
            body([], node)
            return
        }
        var buffer = [SPPFNode]()
        buffer.reserveCapacity(length)
        walk(from: node, remaining: length, buffer: &buffer, body)
    }

    /// Depth-first walk that accumulates edge labels into a reused buffer, emitting top-to-bottom order.
    private func walk(
        from node: GSSNode, remaining: Int, buffer: inout [SPPFNode],
        _ body: (_ labels: [SPPFNode], _ base: GSSNode) -> Void
    ) {
        for edge in node.edges {
            buffer.append(edge.sppf)
            if remaining == 1 {
                // The buffer holds labels bottom-to-top as appended; reverse for top-to-bottom order.
                body(buffer.reversed(), edge.target)
            } else {
                walk(from: edge.target, remaining: remaining - 1, buffer: &buffer, body)
            }
            buffer.removeLast()
        }
    }
}
