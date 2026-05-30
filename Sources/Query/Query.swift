import ParsingCore

/// A compiled tree-query over a `ParsingCore` concrete syntax tree.
///
/// `Query` models tree-sitter's query language: an S-expression pattern compiled once from source
/// text and then run against any number of trees. A pattern describes the shape a subtree must have
/// (named nodes by type, anonymous tokens by literal, wildcards, field labels, alternations, groups,
/// quantifiers and anchors) and binds matched nodes to `@`-prefixed capture names. Optional textual
/// predicates (`#eq?`, `#match?`, `#any-of?` and their negations) further constrain matches by the
/// captured nodes' source text.
///
/// Compilation is the only fallible step: invalid source throws a ``QueryError`` pinpointing the
/// problem. Running a compiled query never throws; a tree that does not satisfy a pattern simply
/// yields no match there.
///
/// ```swift
/// let query = try Query("(pair key: (string) @k value: (_) @v)")
/// for match in query.matches(in: tree) {
///     let key = match.nodes(for: "k").first
///     let value = match.nodes(for: "v").first
/// }
/// ```
public struct Query: Sendable {
    /// The compiled top-level patterns, in source order.
    public let patterns: [QueryPattern]

    /// Compiles a query from its source text.
    ///
    /// - Parameter source: The query source in tree-sitter S-expression syntax.
    /// - Throws: ``QueryError`` describing the first malformed construct, with its byte offset.
    public init(_ source: String) throws(QueryError) {
        var parser = QueryParser(source)
        self.patterns = try parser.parse()
    }

    /// The number of top-level patterns this query contains.
    public var patternCount: Int { patterns.count }

    /// Finds every match of every pattern in the tree rooted at `root`.
    ///
    /// - Parameter root: The root node to search; every node beneath it is also considered.
    /// - Returns: The matches, each carrying the index of the pattern that produced it and its
    ///   bound captures, ordered by the document position of the node each pattern anchored at.
    public func matches(in root: Syntax) -> [QueryMatch] {
        QueryMatcher(patterns: patterns).matches(in: root)
    }

    /// Finds every capture produced by running this query over the tree rooted at `root`.
    ///
    /// This flattens ``matches(in:)`` to the individual ``QueryCapture`` values, which is convenient
    /// when the grouping of captures into matches is not needed.
    ///
    /// - Parameter root: The root node to search.
    /// - Returns: The captures, in the order their matches were produced.
    public func captures(in root: Syntax) -> [QueryCapture] {
        matches(in: root).flatMap(\.captures)
    }
}
