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
    /// The capabilities this engine guarantees: lossless trees, error recovery, and ambiguity handling.
    public static var capabilities: EngineCapabilities { [.lossless, .errorRecovering, .ambiguous] }
    /// The stable identifier under which this engine is registered, suffixed with the input granularity.
    public static var identifier: String { "glr-\(Input.granularityName)" }

    private let tables: GLRTables
    private let startRuleName: String

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
        let input = Input.make(from: source.text)
        let sppf = SPPF()
        let parser = GLRParser<Input>(tables: tables, input: input)
        let outcome = parser.run(sppf: sppf)

        var builder = TreeBuilder(tables: tables, disambiguating: sppf.hasPacking)
        var diagnostics: [Diagnostic] = []
        let documentKind = SyntaxKind(startRuleName, isNamed: true)

        var documentNode: GreenNode
        var resumeCursor: Input.Index
        var resumeOffset: Int

        if let root = outcome.completedRoot {
            let kids = builder.emitRoot(root)
            documentNode = GreenNode.node(documentKind, children: kids)
            resumeCursor = outcome.rootEndCursor
            resumeOffset = outcome.rootEndOffset
        } else {
            // Wholly unparseable input: recover with a MISSING value, matching the reference engine.
            diagnostics.append(
                .error(
                    Recovery.missingStartMessage(startRule: startRuleName),
                    at: .empty(at: outcome.endOffset)))
            documentNode = GreenNode.node(
                documentKind, children: [.init(node: .missingToken(Recovery.missingValueKind))])
            resumeCursor = input.startIndex
            resumeOffset = 0
        }

        for ambiguity in builder.ambiguities {
            diagnostics.append(
                Diagnostic(
                    severity: .warning,
                    message: "ambiguous parse of \(ambiguity.rule), resolved by the disambiguation policy",
                    span: ambiguity.span))
        }

        documentNode = appendTrailing(
            to: documentNode, input: input, from: resumeCursor, offset: resumeOffset,
            diagnostics: &diagnostics)

        return ParseResult(
            tree: Syntax(documentNode), source: source, diagnostics: diagnostics)
    }

    /// Appends trailing trivia or trailing junk to the document node, mirroring the reference engine.
    ///
    /// Trivia after the completed parse is consumed first. If input remains, it becomes an `ERROR` node
    /// carrying the residue with the trivia as leading trivia, and an error diagnostic. If only trivia
    /// remains, it is attached to a zero-width carrier token so the tree round-trips losslessly.
    private func appendTrailing(
        to documentNode: GreenNode, input: Input, from cursor: Input.Index, offset: Int,
        diagnostics: inout [Diagnostic]
    ) -> GreenNode {
        let lexer = Lexer<Input>(input: input, terminals: tables.terminals, extras: tables.extras)
        let (afterTrivia, trivia) = lexer.consumeTrivia(at: cursor)
        if afterTrivia != input.endIndex {
            diagnostics.append(.error(Recovery.trailingMessage, at: .empty(at: offset)))
            let junk = Input.text(of: input[afterTrivia..<input.endIndex])
            let errorToken = GreenNode.token(
                Recovery.errorTokenKind, text: junk, leadingTrivia: trivia)
            let errorNode = GreenNode.errorNode(children: [.init(node: errorToken)])
            return GreenNode.node(
                documentNode.kind, children: documentNode.children + [.init(node: errorNode)])
        } else if !trivia.isEmpty {
            let carrier = GreenNode.token(SyntaxKind("", isNamed: false), text: "", leadingTrivia: trivia)
            return GreenNode.node(
                documentNode.kind, children: documentNode.children + [.init(node: carrier)])
        }
        return documentNode
    }
}

/// The native GLR engine specialised for UTF-8 code units (fastest; the default granularity).
public typealias UTF8GLRParser = GLREngine<Substring.UTF8View>
/// The native GLR engine specialised for Unicode scalars (code points).
public typealias ScalarGLRParser = GLREngine<Substring.UnicodeScalarView>
/// The native GLR engine specialised for extended grapheme clusters (most faithful, slowest).
public typealias GraphemeGLRParser = GLREngine<Substring>
