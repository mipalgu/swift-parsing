import ParsingCore

/// A native, table-driven Right-Nulled Generalised LR parser engine.
///
/// `GLREngine` is a second native engine alongside the recursive-descent engine. It flattens the
/// grammar to context-free productions, builds an LR(0) automaton with SLR(1) lookahead and right-nulled
/// reductions once at construction, then parses each source over a graph-structured stack and shared
/// packed parse forest. It is scannerless and granularity-generic, handles ambiguity by forking and
/// packing then collapses the forest to one canonical concrete syntax tree, produces a lossless tree
/// that round-trips to the source, and never throws past ``parse(_:)``: malformed input yields a
/// complete tree with `ERROR`/`MISSING` nodes plus diagnostics, exactly like the recursive-descent
/// engine.
///
/// Instantiate it per granularity as ``UTF8GLRParser`` (fastest, the default), ``ScalarGLRParser``
/// (code points), or ``GraphemeGLRParser`` (extended grapheme clusters).
public struct GLREngine<Input: ParserInput>: ParserEngine {
    /// The capabilities this engine guarantees: lossless trees, error recovery, ambiguity handling, and
    /// incremental reparsing (unchanged subtrees are reused across edits).
    public static var capabilities: EngineCapabilities {
        [.lossless, .errorRecovering, .ambiguous, .incremental]
    }
    /// The stable identifier under which this engine is registered, suffixed with the input granularity.
    public static var identifier: String { "glr-\(Input.granularityName)" }

    let tables: GLRTables
    let startRuleName: String

    /// Creates an engine for a grammar, building its parse tables.
    ///
    /// - Parameter grammar: The grammar to parse against.
    /// - Throws: `GrammarError.undefinedStartRule(_:)` if the start rule is not defined.
    public init(grammar: Grammar) throws(GrammarError) {
        guard grammar.rules[grammar.startRule] != nil else {
            throw .undefinedStartRule(grammar.startRule)
        }
        self.tables = GLRTables(grammar: grammar)
        self.startRuleName = grammar.startRule
    }

    /// Parses a source into a complete, lossless tree plus diagnostics.
    ///
    /// - Parameter source: The source to parse.
    /// - Returns: A `ParseResult` whose tree is always complete, even for malformed input.
    public func parse(_ source: Source) -> ParseResult {
        parse(source, reusing: nil)
    }

    /// Reparses an edited source, reusing the unchanged subtrees of a previous parse.
    ///
    /// The tree is byte-for-byte what a full ``parse(_:)`` of `source` would produce; the gain is that every
    /// subtree the edits leave unchanged keeps its previous identity rather than being re-allocated. An empty
    /// edit list over an unchanged source returns `previous` directly. For a document edited repeatedly,
    /// `incrementalParse(_:)` returns a session that additionally skips re-examining the unchanged input
    /// before the first edit.
    ///
    /// - Parameters:
    ///   - source: The edited source to parse.
    ///   - edits: The edits that produced `source` from the previous source (used to short-circuit a no-op).
    ///   - previous: The previous parse result whose subtrees are candidates for reuse.
    /// - Returns: A complete `ParseResult` for `source`.
    public func reparse(_ source: Source, edits: [TextEdit], previous: ParseResult) -> ParseResult {
        if edits.isEmpty && source.text == previous.source.text { return previous }
        return parse(source, reusing: ReusePool(previous: previous.tree.green))
    }

    /// Parses a source, optionally reusing a previous parse's subtrees through `pool`.
    private func parse(_ source: Source, reusing pool: ReusePool?) -> ParseResult {
        let input = Input.make(from: source.text)
        let sppf = SPPF()
        let parser = GLRParser<Input>(tables: tables, input: input)
        let outcome = parser.run(sppf: sppf)
        return glrBuildResult(
            outcome: outcome, input: input, sppf: sppf, tables: tables,
            startRuleName: startRuleName, source: source, reuse: pool)
    }
}

/// The native GLR engine specialised for UTF-8 code units (fastest; the default granularity).
public typealias UTF8GLRParser = GLREngine<Substring.UTF8View>
/// The native GLR engine specialised for Unicode scalars (code points).
public typealias ScalarGLRParser = GLREngine<Substring.UnicodeScalarView>
/// The native GLR engine specialised for extended grapheme clusters (most faithful, slowest).
public typealias GraphemeGLRParser = GLREngine<Substring>
