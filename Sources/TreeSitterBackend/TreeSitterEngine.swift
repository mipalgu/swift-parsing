import ParsingCore
import SwiftTreeSitter
import TreeSitterJSON

/// A ``ParserEngine`` that wraps the C tree-sitter runtime.
///
/// This is an opt-in wrapper backend: it lives in its own module so the pure-Swift core never pulls
/// in the C runtime. It exists chiefly so the framework can run the *same* grammar and input through
/// a battle-tested engine and a native one, and assert their concrete syntax trees agree
/// (differential testing), and so their throughput can be compared.
///
/// tree-sitter languages are compiled C parse tables rather than something derivable from the
/// ``Grammar`` IR, so this backend maps a grammar by *name* to a bundled tree-sitter language. The
/// first milestone wires the JSON language; further languages slot in here as they are bundled.
///
/// The wrapped tree-sitter tree is converted into the framework's concrete syntax tree by keeping
/// named nodes and their field names (anonymous punctuation is dropped), which yields the same
/// canonical S-expression a native engine produces for the same grammar.
public struct TreeSitterEngine: ParserEngine {
    public static let capabilities: EngineCapabilities = [.errorRecovering]
    public static let identifier = "tree-sitter"

    /// An error constructing the tree-sitter backend.
    public enum BackendError: Error, Equatable {
        /// No bundled tree-sitter language matches the grammar's name.
        case unsupportedLanguage(String)
    }

    private let language: Language
    private let rootKind: String

    /// Creates a tree-sitter engine for a grammar, by mapping the grammar's name to a bundled language.
    /// - Parameter grammar: The grammar to parse against. Only its `name` is consulted.
    /// - Throws: ``BackendError/unsupportedLanguage(_:)`` if no bundled language matches.
    public init(grammar: Grammar) throws {
        switch grammar.name {
        case "json":
            self.language = Language(language: tree_sitter_json())
            self.rootKind = grammar.startRule
        default:
            throw BackendError.unsupportedLanguage(grammar.name)
        }
    }

    /// Parses a source by delegating to the tree-sitter runtime and converting the result.
    /// - Parameter source: The source to parse.
    /// - Returns: A ``ParseResult`` whose tree mirrors the tree-sitter parse (named nodes and fields).
    public func parse(_ source: Source) -> ParseResult {
        let parser = Parser()
        // setLanguage only throws on an ABI mismatch between the runtime and the compiled grammar,
        // which cannot happen for a grammar bundled against this same runtime.
        try? parser.setLanguage(language)

        // Defensive: tree-sitter always produces a (possibly error-laden) tree for any input, so this
        // fallback only guards against a malfunctioning runtime and is not exercised by tests.
        guard let tree = parser.parse(source.text), let root = tree.rootNode else {
            let empty = GreenNode.node(SyntaxKind(rootKind, isNamed: true), children: [])
            let diagnostic = Diagnostic.error("tree-sitter produced no tree", at: .empty(at: 0))
            return ParseResult(tree: Syntax(empty), source: source, diagnostics: [diagnostic])
        }

        let green = convert(root)
        var diagnostics: [Diagnostic] = []
        if root.hasError {
            diagnostics.append(.error("tree-sitter reported a syntax error", at: .empty(at: 0)))
        }
        return ParseResult(tree: Syntax(green), source: source, diagnostics: diagnostics)
    }

    /// Recursively converts a tree-sitter node into a green node, keeping named children and fields.
    private func convert(_ node: Node) -> GreenNode {
        // `nodeType` is non-nil for every real node; the fallback is defensive only.
        let kindName = node.nodeType ?? "ERROR"
        let kind = SyntaxKind(kindName, isNamed: node.isNamed)

        var children: [GreenChild] = []
        for index in 0..<node.childCount {
            guard let child = node.child(at: index), child.isNamed else { continue }
            children.append(GreenChild(field: node.fieldNameForChild(at: index), node: convert(child)))
        }
        return GreenNode.node(kind, children: children)
    }
}
