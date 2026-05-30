import ParsingCore

/// Collapses a shared packed parse forest into a single canonical concrete syntax tree.
///
/// The builder walks the forest from the start-symbol root, resolving every packed ambiguity by a
/// deterministic, total disambiguation order so the result is a single tree. Its emit rules mirror the
/// recursive-descent engine exactly: opaque nonterminals wrap their children in a node, transparent
/// ones splice their children into the parent, and field-labelled ones attach the label using the same
/// single-child-versus-group rule, so the rendered S-expression is byte-identical for unambiguous
/// grammars.
struct TreeBuilder {
    let tables: GLRTables
    /// Ambiguities resolved during the walk, recorded as warning diagnostics by the engine.
    private(set) var ambiguities: [(rule: String, span: SourceSpan)] = []
    /// The forest nodes currently on the recursion path, used to break derivation cycles.
    ///
    /// A nullable left- or right-recursive rule (for example `r*` over an empty span) can produce a
    /// self-referential family in the forest. Rejecting any family that re-enters a node already on the
    /// path collapses such a cycle to its non-cyclic (empty) derivation, mirroring the reference engine.
    private var active: Set<ObjectIdentifier> = []
    /// Whether the forest contains any packed (multiply derived) node.
    ///
    /// When the forest is a plain tree no family is ever rejected for cyclicity and no node carries
    /// alternatives, so the recursion-path bookkeeping in ``active`` serves no purpose and is skipped.
    private let disambiguating: Bool

    /// Creates a tree builder bound to the parse tables.
    /// - Parameters:
    ///   - tables: The immutable parse tables.
    ///   - disambiguating: Whether the forest packs any ambiguity needing cycle-aware disambiguation.
    init(tables: GLRTables, disambiguating: Bool = true) {
        self.tables = tables
        self.disambiguating = disambiguating
    }

    /// Builds the children of the start-symbol root, ignoring its own opaque wrapper.
    ///
    /// The engine wraps these children in the document node itself, so the start symbol's own opaque
    /// emit is unwrapped here to avoid a doubled `(document (document …))`.
    ///
    /// - Parameter root: The start-symbol forest node.
    /// - Returns: The ordered child slots forming the document's body.
    mutating func emitRoot(_ root: SPPFNode) -> [GreenChild] {
        guard case .nonterminal(let nt, _, _) = root.label, let family = chooseFamily(root, nt: nt) else {
            return []
        }
        if disambiguating { active.insert(ObjectIdentifier(root)) }
        defer { if disambiguating { active.remove(ObjectIdentifier(root)) } }
        var kids: [GreenChild] = []
        for child in family.children { emit(child, into: &kids) }
        return kids
    }

    /// Builds the children that a forest node contributes to its parent.
    ///
    /// - Parameter node: The forest node to render.
    /// - Returns: The ordered child slots the node contributes.
    mutating func emit(_ node: SPPFNode) -> [GreenChild] {
        var out: [GreenChild] = []
        emit(node, into: &out)
        return out
    }

    /// Appends the children that a forest node contributes to its parent into an accumulator.
    ///
    /// Threading a single accumulator down the walk avoids allocating and concatenating a fresh array
    /// for every node, which is the dominant cost when collapsing a large forest.
    ///
    /// - Parameters:
    ///   - node: The forest node to render.
    ///   - out: The accumulator to append the node's contributed child slots to.
    private mutating func emit(_ node: SPPFNode, into out: inout [GreenChild]) {
        switch node.label {
        case .terminal(let terminalID, _, _, _):
            let term = tables.terminals[terminalID]
            guard let leaf = node.lex else { return }
            let token = GreenNode.token(
                SyntaxKind(term.kindName, isNamed: term.isNamed),
                text: leaf.text, leadingTrivia: leaf.leadingTrivia)
            out.append(GreenChild(node: token))

        case .epsilon:
            return

        case .nonterminal(let nt, _, _):
            guard let family = chooseFamily(node, nt: nt) else { return }
            if disambiguating { active.insert(ObjectIdentifier(node)) }
            defer { if disambiguating { active.remove(ObjectIdentifier(node)) } }

            guard let productionID = family.production else {
                // No production: splice the children directly into the parent.
                for child in family.children { emit(child, into: &out) }
                return
            }
            let production = tables.productions[productionID]
            switch production.emit {
            case .transparent:
                // Transparent: children flow straight into the parent's accumulator.
                for child in family.children { emit(child, into: &out) }
            case .field(let name):
                var kids: [GreenChild] = []
                kids.reserveCapacity(family.children.count)
                for child in family.children { emit(child, into: &kids) }
                if kids.count == 1 {
                    out.append(GreenChild(field: name, node: kids[0].node))
                } else {
                    let group = GreenNode.node(SyntaxKind("group", isNamed: false), children: kids)
                    out.append(GreenChild(field: name, node: group))
                }
            case .opaque(let kind):
                var kids: [GreenChild] = []
                kids.reserveCapacity(family.children.count)
                for child in family.children { emit(child, into: &kids) }
                out.append(GreenChild(node: GreenNode.node(kind, children: kids)))
            }
        }
    }

    /// Chooses one derivation family of a packed node by the deterministic disambiguation order.
    ///
    /// The order is: higher precedence level, then associativity, then lower ordered-choice ordinal,
    /// then the longer first-differing child span, then the lower production id. This total order yields
    /// a single canonical tree and, for unambiguous grammars, the derivation the reference engine's
    /// ordered backtracking would pick.
    private mutating func chooseFamily(_ node: SPPFNode, nt: Int) -> PackedFamily? {
        guard !node.families.isEmpty else { return nil }

        // The overwhelmingly common case is a single, acyclic family: avoid the filtering allocation.
        if node.families.count == 1 { return node.families[0] }

        // Reject families that re-enter a node already on the recursion path: they form a derivation
        // cycle (a nullable recursive rule over an empty span) and must not be expanded.
        let acyclic = node.families.filter { family in
            !family.children.contains { active.contains(ObjectIdentifier($0)) }
        }
        let candidates = acyclic.isEmpty ? node.families : acyclic
        if candidates.count == 1 { return candidates[0] }

        var best = candidates[0]
        for candidate in candidates.dropFirst() {
            if prefers(candidate, over: best) { best = candidate }
        }

        // Only a genuine ambiguity (families differing in production or in a non-nullable child's span)
        // is reported. Families differing only in a nullable child's anchor render identically and are
        // canonicalised silently.
        if candidates.contains(where: { !equivalent($0, best) }) {
            ambiguities.append(
                (
                    rule: tables.nonterminalNames[nt],
                    span: SourceSpan(start: node.start, length: node.end - node.start)
                ))
        }
        return best
    }

    /// Whether two families denote the same derivation up to nullable-child anchoring.
    ///
    /// Two families are equivalent when they share a production and their non-empty children cover the
    /// same spans; differences confined to zero-width (nullable) children are spurious right-nulled
    /// duplicates rather than real ambiguities.
    private func equivalent(_ lhs: PackedFamily, _ rhs: PackedFamily) -> Bool {
        guard lhs.production == rhs.production, lhs.children.count == rhs.children.count else {
            return false
        }
        return zip(lhs.children, rhs.children).allSatisfy { l, r in
            let lEmpty = l.start == l.end
            let rEmpty = r.start == r.end
            if lEmpty && rEmpty { return true }
            return l.start == r.start && l.end == r.end
        }
    }

    private func prefers(_ lhs: PackedFamily, over rhs: PackedFamily) -> Bool {
        let lhsPrec = lhs.production.flatMap { tables.productions[$0].precedence }
        let rhsPrec = rhs.production.flatMap { tables.productions[$0].precedence }
        if let l = lhsPrec?.level, let r = rhsPrec?.level, l != r { return l > r }

        if let assoc = lhsPrec?.assoc ?? rhsPrec?.assoc, lhsPrec?.level == rhsPrec?.level {
            // Among equal-precedence operators, left associativity prefers the family whose first child
            // spans more (a left-leaning tree); right associativity prefers the opposite.
            if let lFirst = lhs.children.first, let rFirst = rhs.children.first {
                let lSpan = lFirst.end - lFirst.start
                let rSpan = rFirst.end - rFirst.start
                if lSpan != rSpan {
                    switch assoc {
                    case .left: return lSpan > rSpan
                    case .right: return lSpan < rSpan
                    case .none: break
                    }
                }
            }
        }

        let lhsOrdinal = lhs.production.flatMap { tables.productions[$0].choiceOrdinal }
        let rhsOrdinal = rhs.production.flatMap { tables.productions[$0].choiceOrdinal }
        if let l = lhsOrdinal, let r = rhsOrdinal, l != r { return l < r }

        // Longer first-differing child span, then leftmost.
        for (l, r) in zip(lhs.children, rhs.children) where !(l === r) {
            let lSpan = l.end - l.start
            let rSpan = r.end - r.start
            if lSpan != rSpan { return lSpan > rSpan }
        }

        // Stable production-id tie-break.
        if let l = lhs.production, let r = rhs.production, l != r { return l < r }
        return false
    }
}
