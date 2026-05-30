import ParsingCore

/// A native, pure-Swift parser engine that interprets a `Grammar` by recursive descent.
///
/// The engine is generic over the input element granularity (`ParserInput`): instantiate it as
/// ``UTF8Parser`` (fastest, the default), ``ScalarParser`` (code points), or ``GraphemeParser``
/// (extended grapheme clusters, the most faithful for composite characters). It is pure Swift with no
/// `Regex`, no `Foundation`, and no existentials, so it compiles under Embedded Swift.
///
/// Token matching is driven by the data-only `TokenMatcher` interpreted element-by-element, so the
/// same grammar parses identically at every granularity. The engine walks the grammar's intermediate
/// representation top-down with ordered-choice backtracking and builds a lossless concrete syntax tree
/// directly. Rules whose names begin with an underscore are *hidden* (their children splice into the
/// parent, mirroring tree-sitter). It is resilient: it never throws past ``parse(_:)`` — unparseable
/// trailing input becomes an `ERROR` node and a wholly unparseable input yields a `MISSING` node, each
/// with a diagnostic.
public struct RecursiveDescentEngine<Input: ParserInput>: ParserEngine {
    /// The capabilities this engine guarantees: lossless trees with error recovery.
    public static var capabilities: EngineCapabilities { [.lossless, .errorRecovering] }
    /// The stable identifier under which this engine is registered, suffixed with the input granularity.
    public static var identifier: String { "rd-\(Input.granularityName)" }

    /// The grammar lowered once into the engine-internal compiled form, shared across all parses.
    private let compiled: CompiledGrammar<Input>

    /// Creates an engine for a grammar.
    /// - Parameter grammar: The grammar to parse against.
    /// - Throws: `GrammarError.undefinedStartRule(_:)` if the start rule is not defined.
    public init(grammar: Grammar) throws(GrammarError) {
        guard grammar.rules[grammar.startRule] != nil else {
            throw .undefinedStartRule(grammar.startRule)
        }
        self.compiled = CompiledGrammar(grammar)
    }

    /// Parses a source into a complete, lossless tree plus diagnostics.
    /// - Parameter source: The source to parse.
    /// - Returns: A `ParseResult` whose tree is always complete, even for malformed input.
    public func parse(_ source: Source) -> ParseResult {
        let input = Input.make(from: source.text)
        let parser = Parser<Input>(compiled: compiled, input: input)
        let root = parser.parseDocument()
        return ParseResult(tree: Syntax(root), source: source, diagnostics: parser.diagnostics)
    }
}

/// The native engine specialised for UTF-8 code units (fastest; the default granularity).
public typealias UTF8Parser = RecursiveDescentEngine<Substring.UTF8View>
/// The native engine specialised for Unicode scalars (code points).
public typealias ScalarParser = RecursiveDescentEngine<Substring.UnicodeScalarView>
/// The native engine specialised for extended grapheme clusters (most faithful, slowest).
public typealias GraphemeParser = RecursiveDescentEngine<Substring>

/// Signals a speculative parse mismatch used for ordered-choice backtracking. Never escapes the engine.
private struct ParseMismatch: Error {}

/// The mutable per-parse state driving recursive descent over a generic input.
private final class Parser<Input: ParserInput> {
    let compiled: CompiledGrammar<Input>
    let input: Input
    /// The input's end index, hoisted out of the per-element `endIndex` accessor on the hot path.
    let endIndex: Input.Index
    var index: Input.Index
    var byteOffset: Int = 0
    var diagnostics: [Diagnostic] = []

    init(compiled: CompiledGrammar<Input>, input: Input) {
        self.compiled = compiled
        self.input = input
        self.endIndex = input.endIndex
        self.index = input.startIndex
    }

    /// A saved cursor position for backtracking.
    private struct Mark { let index: Input.Index; let byteOffset: Int }
    @inline(__always) private func mark() -> Mark { Mark(index: index, byteOffset: byteOffset) }
    @inline(__always) private func reset(to mark: Mark) { index = mark.index; byteOffset = mark.byteOffset }

    /// Advances the cursor to `end`, accumulating the consumed UTF-8 bytes for diagnostics.
    ///
    /// The byte count is the sum of each consumed element's ``ParserElement/utf8Width`` (O(1) per
    /// element, allocation-free) rather than re-materialising and counting a `String`.
    @inline(__always) private func advance(to end: Input.Index) {
        if end != index {
            byteOffset += byteWidth(from: index, to: end)
            index = end
        }
    }

    /// The UTF-8 byte width of the input slice `from..<to`, summing per-element widths.
    @inline(__always) private func byteWidth(from start: Input.Index, to end: Input.Index) -> Int {
        var total = 0
        var cursor = start
        while cursor != end {
            total += input[cursor].utf8Width
            input.formIndex(after: &cursor)
        }
        return total
    }

    // MARK: - Document / recovery

    /// Parses the grammar's start rule, recovering into `ERROR`/`MISSING` nodes as needed.
    func parseDocument() -> GreenNode {
        let startKind = compiled.startKind
        var documentNode: GreenNode
        do {
            documentNode = try parse(compiled.startReference)[0].node
        } catch {
            diagnostics.append(.error("expected \(startKind.name)", at: .empty(at: byteOffset)))
            documentNode = GreenNode.node(startKind, children: [.init(node: .missingToken(SyntaxKind("value")))])
        }

        let trailingTrivia = consumeTrivia()
        if index != input.endIndex {
            diagnostics.append(.error("unexpected trailing input", at: .empty(at: byteOffset)))
            let junk = Input.text(of: input[index..<input.endIndex])
            let errorToken = GreenNode.token(
                SyntaxKind("<error>", isNamed: false), text: junk, leadingTrivia: trailingTrivia)
            let errorNode = GreenNode.errorNode(children: [.init(node: errorToken)])
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: errorNode)])
        } else if !trailingTrivia.isEmpty {
            let carrier = GreenNode.token(SyntaxKind("", isNamed: false), text: "", leadingTrivia: trailingTrivia)
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: carrier)])
        }
        return documentNode
    }

    // MARK: - Rule parsing

    private func parse(_ rule: CompiledRule<Input>) throws(ParseMismatch) -> [GreenChild] {
        switch rule.kind! {
        case .token(let kind, let matcher):
            let saved = mark()
            let triviaStart = index
            consumeTrivia()
            let leading = triviaStart == index ? "" : Input.text(of: input[triviaStart..<index])
            guard let end = match(matcher, at: index) else {
                reset(to: saved)
                throw ParseMismatch()
            }
            let text = Input.text(of: input[index..<end])
            advance(to: end)
            let token = GreenNode.token(kind, text: text, leadingTrivia: leading)
            return [GreenChild(node: token)]

        case .reference(let body, let kind, let isHidden):
            let kids = try parse(body)
            if isHidden { return kids }  // hidden rule: splice
            return [GreenChild(node: .node(kind, children: kids))]

        case .unresolvedReference:
            throw ParseMismatch()

        case .sequence(let rules):
            var kids: [GreenChild] = []
            for r in rules { kids += try parse(r) }
            return kids

        case .choice(let alternatives):
            for alternative in alternatives {
                let saved = mark()
                do { return try parse(alternative) } catch { reset(to: saved) }
            }
            throw ParseMismatch()

        case .optional(let sub):
            let saved = mark()
            do { return try parse(sub) } catch {
                reset(to: saved)
                return []
            }

        case .repeatZeroOrMore(let sub):
            return try repeating(sub, atLeastOne: false)

        case .repeatOneOrMore(let sub):
            return try repeating(sub, atLeastOne: true)

        case .field(let name, let sub):
            let kids = try parse(sub)
            if kids.count == 1 { return [GreenChild(field: name, node: kids[0].node)] }
            let group = GreenNode.node(SyntaxKind("group", isNamed: false), children: kids)
            return [GreenChild(field: name, node: group)]
        }
    }

    private func repeating(_ sub: CompiledRule<Input>, atLeastOne: Bool) throws(ParseMismatch) -> [GreenChild] {
        var kids: [GreenChild] = []
        if atLeastOne { kids += try parse(sub) }
        while true {
            let saved = mark()
            do {
                let next = try parse(sub)
                if index == saved.index { break }  // guard against zero-width loops
                kids += next
            } catch {
                reset(to: saved)
                break
            }
        }
        return kids
    }

    // MARK: - Trivia and token matching

    /// Consumes a run of trivia (extras) at the cursor, advancing it; returns the consumed text.
    @discardableResult
    private func consumeTrivia() -> String {
        let start = index
        // Fast path: the overwhelmingly common single ASCII-whitespace extra consumes a run of
        // whitespace elements directly, with no per-element matcher dispatch and no `advance` call
        // (the byte width is accumulated inline). This avoids the general matcher loop entirely.
        if compiled.extrasAreWhitespaceOnly {
            var cursor = index
            var bytes = 0
            while cursor != endIndex {
                let element = input[cursor]
                guard element.isASCIIWhitespace else { break }
                bytes += element.utf8Width
                input.formIndex(after: &cursor)
            }
            if cursor != index {
                index = cursor
                byteOffset += bytes
            }
            return start == index ? "" : Input.text(of: input[start..<index])
        }
        scanning: while index != endIndex {
            for extra in compiled.extras {
                if let end = match(extra, at: index), end != index {
                    advance(to: end)
                    continue scanning
                }
            }
            break
        }
        return start == index ? "" : Input.text(of: input[start..<index])
    }

    /// Matches a compiled token matcher at a position, returning the end index of the match, or `nil`.
    private func match(_ matcher: CompiledMatcher<Input.Element>, at start: Input.Index) -> Input.Index? {
        switch matcher.kind {
        case .literal(let elements):
            var cursor = start
            for element in elements {
                guard cursor != endIndex, input[cursor] == element else { return nil }
                input.formIndex(after: &cursor)
            }
            return cursor

        case .anyElement:
            guard start != endIndex else { return nil }
            return input.index(after: start)

        case .scalarRange(let range):
            guard start != endIndex, range.contains(input[start].scalarValue) else { return nil }
            return input.index(after: start)

        case .builtin(let builtinClass):
            guard start != endIndex, classify(input[start], builtinClass) else { return nil }
            return input.index(after: start)

        case .negated(let inner):
            guard start != endIndex, match(inner, at: start) == nil else { return nil }
            return input.index(after: start)

        case .sequence(let matchers):
            var cursor = start
            for matcher in matchers {
                guard let next = match(matcher, at: cursor) else { return nil }
                cursor = next
            }
            return cursor

        case .alternation(let matchers):
            for matcher in matchers {
                if let next = match(matcher, at: start) { return next }
            }
            return nil

        case .repeated(let min, let max, let inner):
            var cursor = start
            var count = 0
            while max == nil || count < max! {
                guard let next = match(inner, at: cursor), next != cursor else { break }
                cursor = next
                count += 1
            }
            return count >= min ? cursor : nil
        }
    }

    private func classify(_ element: Input.Element, _ builtinClass: BuiltinClass) -> Bool {
        switch builtinClass {
        case .digit: element.isASCIIDigit
        case .whitespace: element.isASCIIWhitespace
        case .hexDigit: element.isASCIIHexDigit
        case .letter: element.isASCIILetter
        }
    }
}
