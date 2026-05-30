import ParsingCore

/// A node in the shared packed parse forest.
///
/// During parsing a single tree cannot represent ambiguity, so derivations are recorded in a forest
/// that shares common sub-derivations and packs alternative derivations of the same span under one
/// symbol node. A node with more than one family is a local ambiguity, resolved deterministically when
/// the forest is collapsed to a single concrete syntax tree.
final class SPPFNode {
    /// The label distinguishing the kinds of forest node.
    enum Label: Hashable {
        /// A token leaf for a terminal recognised over a byte span.
        case terminal(terminalID: Int, start: Int, end: Int, leafID: Int)
        /// A symbol node for a nonterminal over a byte span.
        case nonterminal(nt: Int, start: Int, end: Int)
        /// A zero-width node standing for an entirely nullable suffix.
        case epsilon(id: Int)
    }

    /// The node's label.
    let label: Label
    /// The byte offset at which the node's span begins.
    let start: Int
    /// The byte offset at which the node's span ends.
    let end: Int
    /// The alternative derivations of this node; more than one denotes a packed ambiguity.
    var families: [PackedFamily] = []
    /// The lexer match backing a terminal leaf, or `nil` for nonterminal and epsilon nodes.
    let lex: LexLeaf?

    init(label: Label, start: Int, end: Int, lex: LexLeaf? = nil) {
        self.label = label
        self.start = start
        self.end = end
        self.lex = lex
    }
}

/// A token leaf's lossless content captured from a lexer match.
struct LexLeaf {
    /// The terminal id.
    let terminalID: Int
    /// The token's content text.
    let text: String
    /// The trivia preceding the token.
    let leadingTrivia: String
}

/// One alternative derivation of an SPPF node: a production applied to an ordered list of child nodes.
struct PackedFamily {
    /// The production whose reduction produced this family, or `nil` for a terminal leaf family.
    let production: Int?
    /// The ordered child nodes of this derivation.
    let children: [SPPFNode]
}

/// Builds and interns shared packed parse forest nodes.
///
/// Nonterminal and terminal nodes are interned by label so identical spans and symbols merge (the
/// sharing); each distinct derivation of a node adds a packed family (the packing). Epsilon nodes are
/// created fresh and never need interning because they are zero-width and structurally trivial.
final class SPPF {
    private var nonterminalNodes: [NTKey: SPPFNode] = [:]
    private var terminalNodes: [Int: SPPFNode] = [:]
    private var nextLeafID = 0
    private var nextEpsilonID = 0

    private struct NTKey: Hashable {
        let nt: Int
        let start: Int
        let end: Int
    }

    /// Returns the interned nonterminal node for a symbol over a span, creating it if absent.
    ///
    /// - Parameters:
    ///   - nt: The nonterminal id.
    ///   - start: The span's start byte offset.
    ///   - end: The span's end byte offset.
    /// - Returns: The shared node and whether it was newly created.
    func nonterminalNode(nt: Int, start: Int, end: Int) -> (node: SPPFNode, isNew: Bool) {
        let key = NTKey(nt: nt, start: start, end: end)
        if let existing = nonterminalNodes[key] { return (existing, false) }
        let node = SPPFNode(label: .nonterminal(nt: nt, start: start, end: end), start: start, end: end)
        nonterminalNodes[key] = node
        return (node, true)
    }

    /// Creates a token-leaf node for a recognised terminal.
    ///
    /// - Parameters:
    ///   - terminalID: The terminal id.
    ///   - start: The leaf's start byte offset (including any consumed trivia).
    ///   - end: The leaf's end byte offset.
    ///   - leaf: The lossless content for the leaf.
    /// - Returns: A fresh terminal node carrying one trivial family.
    func terminalNode(terminalID: Int, start: Int, end: Int, leaf: LexLeaf) -> SPPFNode {
        let id = nextLeafID
        nextLeafID += 1
        let node = SPPFNode(
            label: .terminal(terminalID: terminalID, start: start, end: end, leafID: id),
            start: start, end: end, lex: leaf)
        node.families.append(PackedFamily(production: nil, children: []))
        terminalNodes[id] = node
        return node
    }

    /// Creates a fresh zero-width epsilon node.
    ///
    /// - Parameter at: The byte offset of the empty span.
    /// - Returns: A zero-width node.
    func epsilonNode(at offset: Int) -> SPPFNode {
        let id = nextEpsilonID
        nextEpsilonID += 1
        return SPPFNode(label: .epsilon(id: id), start: offset, end: offset)
    }

    /// Adds a derivation family to a node, deduplicating structurally identical families.
    ///
    /// - Parameters:
    ///   - node: The node to extend.
    ///   - production: The production producing the derivation.
    ///   - children: The ordered child nodes.
    func addFamily(to node: SPPFNode, production: Int?, children: [SPPFNode]) {
        for family in node.families where family.production == production
            && family.children.count == children.count {
            if zip(family.children, children).allSatisfy({ $0 === $1 }) { return }
        }
        node.families.append(PackedFamily(production: production, children: children))
    }
}
