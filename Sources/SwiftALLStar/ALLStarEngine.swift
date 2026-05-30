import ParsingCore

/// A native, pure-Swift ALL(*) (Adaptive LL(*)) parser engine, the algorithm behind ANTLR 4.
///
/// The engine compiles a ``Grammar`` into an Augmented Transition Network once at construction, then
/// parses by walking that network top-down and consulting an adaptive predictor at every decision. The
/// predictor performs grammar-directed lookahead, caching a lookahead DFA per decision so prediction is
/// near-constant time after warm-up. Like the recursive-descent reference engine it is generic over the
/// input element granularity, scannerless (terminals are matched element-by-element with no separate
/// lexer), and lossless: it preserves trivia and never throws past ``parse(_:)``, recovering unparseable
/// input into `ERROR`/`MISSING` nodes. Ambiguity is resolved deterministically to the lowest-numbered
/// production, so the tree it builds matches the ordered-choice reference engine exactly.
public struct ALLStarParser<Input: ParserInput>: ParserEngine {
    /// The capabilities this engine guarantees: lossless trees with error recovery.
    ///
    /// ALL(*) resolves ambiguity deterministically by lowest production number, so it does not advertise
    /// ``EngineCapabilities/ambiguous``; it behaves like an ordered-choice engine.
    public static var capabilities: EngineCapabilities { [.lossless, .errorRecovering] }

    /// The stable identifier under which this engine is registered, suffixed with the input granularity.
    public static var identifier: String { "allstar-\(Input.granularityName)" }

    private let grammar: Grammar
    private let atn: ATN

    /// Creates an engine for a grammar, compiling its ATN.
    ///
    /// - Parameter grammar: The grammar to parse against.
    /// - Throws: ``GrammarError/undefinedStartRule(_:)`` if the start rule is not defined, or
    ///   ``GrammarError/invalidGrammar(_:)`` if the grammar is left-recursive in a way the engine cannot
    ///   eliminate (indirect left recursion, or direct recursion with no base alternative).
    public init(grammar: Grammar) throws(GrammarError) {
        guard grammar.rules[grammar.startRule] != nil else {
            throw .undefinedStartRule(grammar.startRule)
        }
        let prepared = try LeftRecursionRewriter.rewrite(grammar)
        self.grammar = prepared
        self.atn = try ATNBuilder.build(prepared)
    }

    /// Parses a source into a complete, lossless tree plus diagnostics.
    ///
    /// - Parameter source: The source to parse.
    /// - Returns: A ``ParseResult`` whose tree is always complete, even for malformed input.
    public func parse(_ source: Source) -> ParseResult {
        let input = Input.make(from: source.text)
        let parser = StructuralParser<Input>(grammar: grammar, atn: atn, input: input)
        let root = parser.parseDocument()
        return ParseResult(tree: Syntax(root), source: source, diagnostics: parser.diagnostics)
    }
}

/// The ALL(*) engine specialised for UTF-8 code units (fastest; the default granularity).
public typealias ALLStarUTF8Parser = ALLStarParser<Substring.UTF8View>
/// The ALL(*) engine specialised for Unicode scalars (code points).
public typealias ALLStarScalarParser = ALLStarParser<Substring.UnicodeScalarView>
/// The ALL(*) engine specialised for extended grapheme clusters (most faithful, slowest).
public typealias ALLStarGraphemeParser = ALLStarParser<Substring>
