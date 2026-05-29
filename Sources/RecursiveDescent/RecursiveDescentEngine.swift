import ParsingCore

/// A native, pure-Swift parser engine that interprets a ``Grammar`` by recursive descent.
///
/// The engine is generic over the input element granularity (``ParserInput``): instantiate it as
/// ``UTF8Parser`` (fastest, the default), ``ScalarParser`` (code points), or ``GraphemeParser``
/// (extended grapheme clusters, the most faithful for composite characters). It is pure Swift with no
/// `Regex`, no `Foundation`, and no existentials, so it compiles under Embedded Swift.
///
/// Token matching is driven by the data-only ``TokenMatcher`` interpreted element-by-element, so the
/// same grammar parses identically at every granularity. The engine walks the grammar's intermediate
/// representation top-down with ordered-choice backtracking and builds a lossless concrete syntax tree
/// directly. Rules whose names begin with an underscore are *hidden* (their children splice into the
/// parent, mirroring tree-sitter). It is resilient: it never throws past ``parse(_:)`` — unparseable
/// trailing input becomes an `ERROR` node and a wholly unparseable input yields a `MISSING` node, each
/// with a diagnostic.
public struct RecursiveDescentEngine<Input: ParserInput>: ParserEngine {
    public static var capabilities: EngineCapabilities { [.lossless, .errorRecovering] }
    public static var identifier: String { "rd-\(Input.granularityName)" }

    private let grammar: Grammar

    /// Creates an engine for a grammar.
    /// - Parameter grammar: The grammar to parse against.
    /// - Throws: ``GrammarError/undefinedStartRule(_:)`` if the start rule is not defined.
    public init(grammar: Grammar) throws(GrammarError) {
        guard grammar.rules[grammar.startRule] != nil else {
            throw .undefinedStartRule(grammar.startRule)
        }
        self.grammar = grammar
    }

    /// Parses a source into a complete, lossless tree plus diagnostics.
    /// - Parameter source: The source to parse.
    /// - Returns: A ``ParseResult`` whose tree is always complete, even for malformed input.
    public func parse(_ source: Source) -> ParseResult {
        let input = Input.make(from: source.text)
        let parser = Parser<Input>(grammar: grammar, input: input)
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
    let grammar: Grammar
    let input: Input
    var index: Input.Index
    var byteOffset: Int = 0
    var diagnostics: [Diagnostic] = []

    init(grammar: Grammar, input: Input) {
        self.grammar = grammar
        self.input = input
        self.index = input.startIndex
    }

    /// A saved cursor position for backtracking.
    private struct Mark { let index: Input.Index; let byteOffset: Int }
    private func mark() -> Mark { Mark(index: index, byteOffset: byteOffset) }
    private func reset(to mark: Mark) { index = mark.index; byteOffset = mark.byteOffset }

    /// Advances the cursor to `end`, accumulating the consumed bytes for diagnostics.
    private func advance(to end: Input.Index) {
        if end != index {
            byteOffset += Input.text(of: input[index ..< end]).utf8.count
            index = end
        }
    }

    // MARK: - Document / recovery

    /// Parses the grammar's start rule, recovering into `ERROR`/`MISSING` nodes as needed.
    func parseDocument() -> GreenNode {
        let startKind = SyntaxKind(grammar.startRule, isNamed: true)
        var documentNode: GreenNode
        do {
            documentNode = try parse(.reference(grammar.startRule))[0].node
        } catch {
            diagnostics.append(.error("expected \(grammar.startRule)", at: .empty(at: byteOffset)))
            documentNode = GreenNode.node(startKind, children: [.init(node: .missingToken(SyntaxKind("value")))])
        }

        let trailingTrivia = consumeTrivia()
        if index != input.endIndex {
            diagnostics.append(.error("unexpected trailing input", at: .empty(at: byteOffset)))
            let junk = Input.text(of: input[index ..< input.endIndex])
            let errorToken = GreenNode.token(SyntaxKind("<error>", isNamed: false), text: junk, leadingTrivia: trailingTrivia)
            let errorNode = GreenNode.errorNode(children: [.init(node: errorToken)])
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: errorNode)])
        } else if !trailingTrivia.isEmpty {
            let carrier = GreenNode.token(SyntaxKind("", isNamed: false), text: "", leadingTrivia: trailingTrivia)
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: carrier)])
        }
        return documentNode
    }

    // MARK: - Rule parsing

    private func parse(_ rule: Rule) throws -> [GreenChild] {
        switch rule {
        case let .token(name, matcher, isNamed):
            let saved = mark()
            let triviaStart = index
            consumeTrivia()
            let leading = Input.text(of: input[triviaStart ..< index])
            guard let end = match(matcher, at: index) else {
                reset(to: saved)
                throw ParseMismatch()
            }
            let text = Input.text(of: input[index ..< end])
            advance(to: end)
            let token = GreenNode.token(SyntaxKind(name, isNamed: isNamed), text: text, leadingTrivia: leading)
            return [GreenChild(node: token)]

        case let .reference(name):
            guard let body = grammar.rules[name] else { throw ParseMismatch() }
            let kids = try parse(body)
            if name.hasPrefix("_") { return kids } // hidden rule: splice
            return [GreenChild(node: .node(SyntaxKind(name, isNamed: true), children: kids))]

        case let .sequence(rules):
            var kids: [GreenChild] = []
            for r in rules { kids += try parse(r) }
            return kids

        case let .choice(alternatives):
            for alternative in alternatives {
                let saved = mark()
                do { return try parse(alternative) } catch { reset(to: saved) }
            }
            throw ParseMismatch()

        case let .optional(sub):
            let saved = mark()
            do { return try parse(sub) } catch {
                reset(to: saved)
                return []
            }

        case let .repeatZeroOrMore(sub):
            return try repeating(sub, atLeastOne: false)

        case let .repeatOneOrMore(sub):
            return try repeating(sub, atLeastOne: true)

        case let .field(name, sub):
            let kids = try parse(sub)
            if kids.count == 1 { return [GreenChild(field: name, node: kids[0].node)] }
            let group = GreenNode.node(SyntaxKind("group", isNamed: false), children: kids)
            return [GreenChild(field: name, node: group)]

        case let .precedence(_, _, sub):
            return try parse(sub)
        }
    }

    private func repeating(_ sub: Rule, atLeastOne: Bool) throws -> [GreenChild] {
        var kids: [GreenChild] = []
        if atLeastOne { kids += try parse(sub) }
        while true {
            let saved = mark()
            do {
                let next = try parse(sub)
                if index == saved.index { break } // guard against zero-width loops
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
        scanning: while index != input.endIndex {
            for extra in grammar.extras {
                if let end = match(extra, at: index), end != index {
                    advance(to: end)
                    continue scanning
                }
            }
            break
        }
        return Input.text(of: input[start ..< index])
    }

    /// Matches a token matcher at a position, returning the end index of the longest match, or `nil`.
    private func match(_ matcher: TokenMatcher, at start: Input.Index) -> Input.Index? {
        switch matcher {
        case let .literal(text):
            var cursor = start
            for element in Input.elements(of: text) {
                guard cursor != input.endIndex, input[cursor] == element else { return nil }
                input.formIndex(after: &cursor)
            }
            return cursor

        case .anyElement:
            guard start != input.endIndex else { return nil }
            return input.index(after: start)

        case let .scalarRange(range):
            guard start != input.endIndex, range.contains(input[start].scalarValue) else { return nil }
            return input.index(after: start)

        case let .builtin(builtinClass):
            guard start != input.endIndex, classify(input[start], builtinClass) else { return nil }
            return input.index(after: start)

        case let .negated(inner):
            guard start != input.endIndex, match(inner, at: start) == nil else { return nil }
            return input.index(after: start)

        case let .sequence(matchers):
            var cursor = start
            for matcher in matchers {
                guard let next = match(matcher, at: cursor) else { return nil }
                cursor = next
            }
            return cursor

        case let .alternation(matchers):
            for matcher in matchers {
                if let next = match(matcher, at: start) { return next }
            }
            return nil

        case let .repeated(min, max, inner):
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
