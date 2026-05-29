import ParsingCore

/// A native, pure-Swift parser engine that interprets a ``Grammar`` by recursive descent.
///
/// This is the first native engine behind the ``ParserEngine`` protocol. It walks the grammar's
/// intermediate representation top-down with ordered-choice backtracking, scanning terminals on
/// demand (so lexing is context-sensitive) and building a lossless concrete syntax tree directly.
/// Rules whose names begin with an underscore are *hidden*: they contribute their children to the
/// parent without creating a node of their own (mirroring tree-sitter's convention), so passthrough
/// rules such as `_value` do not clutter the tree.
///
/// The engine is resilient: it never throws past ``parse(_:)``. Unparseable trailing input is
/// gathered into an `ERROR` node, and a completely unparseable input yields a tree containing a
/// `MISSING` node, each accompanied by a diagnostic.
///
/// True table-driven engines (`SwiftGLR`, `SwiftALLStar`) are intended to join later behind the
/// same protocol; this engine establishes the protocol contract and the differential-testing basis.
public struct RecursiveDescentEngine: ParserEngine {
    public static let capabilities: EngineCapabilities = [.lossless, .errorRecovering]
    public static let identifier = "rd"

    private let grammar: Grammar
    private let patterns: PatternSet

    /// Creates an engine for a grammar.
    /// - Parameter grammar: The grammar to parse against.
    /// - Throws: If the grammar's terminal patterns cannot be compiled.
    public init(grammar: Grammar) throws {
        self.grammar = grammar
        self.patterns = try PatternSet(grammar: grammar)
    }

    /// Parses a source into a complete, lossless tree plus diagnostics.
    /// - Parameter source: The source to parse.
    /// - Returns: A ``ParseResult`` whose tree is always complete, even for malformed input.
    public func parse(_ source: Source) -> ParseResult {
        let scanner = Scanner(source: source, patterns: patterns)
        let parser = Parser(grammar: grammar, scanner: scanner)
        let root = parser.parseDocument()
        return ParseResult(tree: Syntax(root), source: source, diagnostics: parser.diagnostics)
    }
}

/// Signals a speculative parse mismatch used for ordered-choice backtracking. Never escapes the engine.
private struct ParseMismatch: Error {}

/// The mutable per-parse state driving recursive descent over a scanner.
private final class Parser {
    let grammar: Grammar
    let scanner: Scanner
    var diagnostics: [Diagnostic] = []

    init(grammar: Grammar, scanner: Scanner) {
        self.grammar = grammar
        self.scanner = scanner
    }

    /// Parses the grammar's start rule, recovering into `ERROR`/`MISSING` nodes as needed.
    /// - Returns: The root green node (always of the start rule's named kind).
    func parseDocument() -> GreenNode {
        let startKind = SyntaxKind(grammar.startRule, isNamed: true)
        var documentNode: GreenNode
        do {
            // The (non-hidden) start rule yields exactly one child: the document node itself.
            documentNode = try parse(.reference(grammar.startRule))[0].node
        } catch {
            diagnostics.append(.error("expected \(grammar.startRule)", at: .empty(at: scanner.byteOffset)))
            documentNode = GreenNode.node(startKind, children: [
                .init(node: .missingToken(SyntaxKind("value"))),
            ])
        }

        // Consume trailing trivia; whatever remains is unparseable input.
        let trailingTrivia = scanner.consumeTrivia()
        if !scanner.isAtEnd {
            let junkStart = scanner.byteOffset
            diagnostics.append(.error("unexpected trailing input", at: .empty(at: junkStart)))
            let junk = String(scanner.rest)
            let errorToken = GreenNode.token(
                SyntaxKind("<error>", isNamed: false), text: junk, leadingTrivia: trailingTrivia)
            let errorNode = GreenNode.errorNode(children: [.init(node: errorToken)])
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: errorNode)])
        } else if !trailingTrivia.isEmpty {
            // Preserve trailing whitespace losslessly on an anonymous, hidden carrier token.
            let carrier = GreenNode.token(SyntaxKind("", isNamed: false), text: "", leadingTrivia: trailingTrivia)
            documentNode = GreenNode.node(documentNode.kind, children: documentNode.children + [.init(node: carrier)])
        }

        return documentNode
    }

    /// Recursively parses a rule, returning the child slots it produced.
    /// - Parameter rule: The rule to parse.
    /// - Returns: The produced child slots.
    /// - Throws: ``ParseMismatch`` on a speculative mismatch (used for backtracking).
    private func parse(_ rule: Rule) throws -> [GreenChild] {
        switch rule {
        case let .token(name, pattern, isNamed):
            let saved = scanner.mark()
            let leading = scanner.consumeTrivia()
            guard let text = scanner.match(pattern) else {
                scanner.reset(to: saved)
                throw ParseMismatch()
            }
            let token = GreenNode.token(SyntaxKind(name, isNamed: isNamed), text: text, leadingTrivia: leading)
            return [GreenChild(node: token)]

        case let .reference(name):
            guard let body = grammar.rules[name] else { throw ParseMismatch() }
            let kids = try parse(body)
            if name.hasPrefix("_") {
                return kids // hidden rule: splice children into the parent
            }
            return [GreenChild(node: .node(SyntaxKind(name, isNamed: true), children: kids))]

        case let .sequence(rules):
            var kids: [GreenChild] = []
            for r in rules { kids += try parse(r) }
            return kids

        case let .choice(alternatives):
            for alternative in alternatives {
                let saved = scanner.mark()
                do {
                    return try parse(alternative)
                } catch {
                    scanner.reset(to: saved)
                }
            }
            throw ParseMismatch()

        case let .optional(sub):
            let saved = scanner.mark()
            do {
                return try parse(sub)
            } catch {
                scanner.reset(to: saved)
                return []
            }

        case let .repeatZeroOrMore(sub):
            return try repeating(sub, atLeastOne: false)

        case let .repeatOneOrMore(sub):
            return try repeating(sub, atLeastOne: true)

        case let .field(name, sub):
            let kids = try parse(sub)
            if kids.count == 1 {
                return [GreenChild(field: name, node: kids[0].node)]
            }
            let group = GreenNode.node(SyntaxKind("group", isNamed: false), children: kids)
            return [GreenChild(field: name, node: group)]

        case let .precedence(_, _, sub):
            return try parse(sub) // precedence is irrelevant to ordered-choice descent
        }
    }

    private func repeating(_ sub: Rule, atLeastOne: Bool) throws -> [GreenChild] {
        var kids: [GreenChild] = []
        if atLeastOne {
            kids += try parse(sub)
        }
        while true {
            let saved = scanner.mark()
            do {
                let next = try parse(sub)
                if scanner.byteOffset == saved.byteOffset { break } // guard against zero-width loops
                kids += next
            } catch {
                scanner.reset(to: saved)
                break
            }
        }
        return kids
    }
}
