/// The capabilities a parser engine supports.
///
/// Differential tests consult these flags to decide which comparisons are meaningful for a
/// given engine (for example, only comparing incremental reparses against engines that
/// declare ``incremental``).
public struct EngineCapabilities: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    /// Creates a capability set from its raw bitmask.
    /// - Parameter rawValue: The raw option-set bitmask.
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The engine produces a lossless concrete syntax tree (trivia preserved, round-trippable to source).
    public static let lossless = EngineCapabilities(rawValue: 1 << 0)
    /// The engine recovers from errors and always returns a complete tree.
    public static let errorRecovering = EngineCapabilities(rawValue: 1 << 1)
    /// The engine supports incremental reparsing of edited input.
    public static let incremental = EngineCapabilities(rawValue: 1 << 2)
    /// The engine can parse ambiguous grammars (for example via GLR).
    public static let ambiguous = EngineCapabilities(rawValue: 1 << 3)
}

/// The result of a parse: a complete tree plus any diagnostics.
///
/// Engines never throw past their public API. Even for malformed input, ``tree`` is a
/// complete concrete syntax tree (with `ERROR`/`MISSING` nodes) and ``diagnostics``
/// describes the problems encountered.
public struct ParseResult: Sendable {
    /// The root of the parsed concrete syntax tree.
    public let tree: Syntax

    /// The source that was parsed.
    public let source: Source

    /// Diagnostics produced while parsing, in source order.
    public let diagnostics: [Diagnostic]

    /// Creates a parse result.
    ///
    /// - Parameters:
    ///   - tree: The root of the parsed tree.
    ///   - source: The source that was parsed.
    ///   - diagnostics: Diagnostics produced while parsing.
    public init(tree: Syntax, source: Source, diagnostics: [Diagnostic]) {
        self.tree = tree
        self.source = source
        self.diagnostics = diagnostics
    }

    /// Whether any error-severity diagnostics were produced.
    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }

    /// The canonical S-expression rendering of the parsed tree.
    /// - Returns: The S-expression string for the tree.
    public func sExpression() -> String { tree.sExpression() }
}

/// A parser engine: anything that can turn a ``Grammar`` and a ``Source`` into a ``ParseResult``.
///
/// This is the single abstraction behind which every backend sits, native (GLR, ALL(*)) or
/// wrapped (tree-sitter, ANTLR). It lets the framework drive any engine uniformly and compare
/// their output, which is the basis for differential testing and cross-engine benchmarking.
public protocol ParserEngine: Sendable {
    /// The capabilities this engine supports.
    static var capabilities: EngineCapabilities { get }

    /// A short, stable identifier for the engine (for example `"glr"`, `"tree-sitter"`).
    static var identifier: String { get }

    /// Prepares the engine to parse a particular grammar.
    ///
    /// - Parameter grammar: The grammar to parse against.
    /// - Throws: ``GrammarError`` if the grammar cannot be prepared by this engine. Typed throws keep
    ///   the protocol usable from Embedded Swift, where the `any Error` existential is unavailable.
    init(grammar: Grammar) throws(GrammarError)

    /// Parses a source into a complete tree plus diagnostics.
    ///
    /// - Parameter source: The source to parse.
    /// - Returns: A ``ParseResult`` whose tree is always complete, even for malformed input.
    func parse(_ source: Source) -> ParseResult
}
