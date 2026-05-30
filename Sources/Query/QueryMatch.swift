import ParsingCore

/// A single node captured by a query, paired with the capture name it was bound to.
///
/// A capture records the `ParsingCore` `Syntax` node that matched together with the `@name` used in
/// the query. The node carries its own absolute offset and span, so callers can recover its source
/// text or position directly.
public struct QueryCapture: Sendable {
    /// The capture name from the query (the text after `@`).
    public let name: String
    /// The matched node, positioned at its absolute byte offset within the tree.
    public let node: Syntax

    /// Creates a capture.
    /// - Parameters:
    ///   - name: The capture name from the query.
    ///   - node: The matched node.
    public init(name: String, node: Syntax) {
        self.name = name
        self.node = node
    }
}

/// One successful match of a query pattern against a subtree, with all of its captures.
///
/// A match groups the captures produced by a single top-level pattern matching at one position.
/// Captures appear in the order they were bound during the structural walk.
public struct QueryMatch: Sendable {
    /// The zero-based index of the top-level pattern that produced this match.
    public let patternIndex: Int
    /// The captures bound by this match, in binding order.
    public let captures: [QueryCapture]

    /// Creates a match.
    /// - Parameters:
    ///   - patternIndex: The index of the top-level pattern that produced the match.
    ///   - captures: The captures bound by the match.
    public init(patternIndex: Int, captures: [QueryCapture]) {
        self.patternIndex = patternIndex
        self.captures = captures
    }

    /// The nodes captured under a given name, in binding order.
    /// - Parameter name: The capture name to look up.
    /// - Returns: The matched nodes bound to that name, possibly empty.
    public func nodes(for name: String) -> [Syntax] {
        captures.filter { $0.name == name }.map(\.node)
    }
}
