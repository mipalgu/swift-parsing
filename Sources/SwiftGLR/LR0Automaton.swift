import ParsingCore

/// An LR(0) item: a production with a dot marking how much of its right-hand side has been recognised.
///
/// Items are the vertices of the LR(0) construction. The dot position ranges from `0` (nothing
/// recognised) to the production's length (the whole right-hand side recognised, a complete item).
struct LR0Item: Hashable, Sendable {
    /// The production this item belongs to, identified by its production id.
    let production: Int
    /// The dot position within the production's right-hand side.
    let dot: Int
}

/// A reduction enabled in a state under a lookahead terminal.
///
/// For an ordinary complete item the length is the full right-hand side and the nullable suffix is
/// empty. For a right-nulled item `A → α • β` (with `β` entirely nullable) the length is `|α|` and the
/// nullable suffix is `β`, so RNGLR can reduce early and attach the required nullable subtrees.
struct ReduceAction: Hashable, Sendable {
    /// The production being reduced.
    let production: Int
    /// The number of symbols actually consumed from the stack (`|α|`).
    let length: Int
    /// The entirely nullable suffix `β`, rendered from the epsilon forest.
    let nullableSuffix: [Symbol]
}

/// Builds the LR(0) automaton, SLR(1) lookahead, and right-nulled reduction table for a flattened
/// grammar.
///
/// The construction is the standard canonical LR(0) collection of item sets with GOTO, extended with
/// SLR(1) FOLLOW-set lookahead to keep deterministic grammars fork-free, and with the RNGLR
/// right-nulled correction so epsilon and hidden recursion terminate and derive correctly.
struct LR0Automaton {
    /// The shift table: `shift[state][terminal] = nextState`.
    private(set) var shift: [[Int: Int]] = []
    /// The goto table: `goto[state][nonterminal] = nextState`.
    private(set) var goto: [[Int: Int]] = []
    /// The reduce table: `reduce[state][terminal] = [ReduceAction]` (multiple for GLR conflicts).
    private(set) var reduce: [[Int: [ReduceAction]]] = []
    /// The item sets, indexed by state.
    private(set) var states: [[LR0Item]] = []
    /// The start state index.
    let startState = 0
    /// Whether end-of-input is accepted in each state (the augmented accept).
    private(set) var accepting: [Bool] = []

    private let productions: [Production]
    private let nonterminalCount: Int
    private let acceptProduction: Int

    private var nullable: [Bool] = []
    private var first: [Set<FollowSymbol>] = []
    private var follow: [Set<FollowSymbol>] = []

    /// A symbol appearing in FIRST/FOLLOW sets: a terminal id or end-of-input.
    private enum FollowSymbol: Hashable {
        case terminal(Int)
        case endOfInput
    }

    /// Builds the automaton for a flattened grammar.
    ///
    /// - Parameters:
    ///   - productions: The flattened productions.
    ///   - nonterminalCount: The number of nonterminals.
    ///   - acceptProduction: The id of the augmented accept production `S' → start $`.
    ///   - augmentedStart: The nonterminal id of the augmented start symbol.
    init(productions: [Production], nonterminalCount: Int, acceptProduction: Int, augmentedStart: Int) {
        self.productions = productions
        self.nonterminalCount = nonterminalCount
        self.acceptProduction = acceptProduction

        computeNullable()
        computeFirst()
        computeFollow(augmentedStart: augmentedStart)
        buildStates(augmentedStart: augmentedStart)
        buildTables()
    }

    /// Whether a symbol can derive the empty string.
    func isNullable(_ symbol: Symbol) -> Bool {
        switch symbol {
        case .nonterminal(let nt): return nullable[nt]
        case .terminal, .endOfInput: return false
        }
    }

    // MARK: - Nullable / FIRST / FOLLOW

    private mutating func computeNullable() {
        nullable = Array(repeating: false, count: nonterminalCount)
        var changed = true
        while changed {
            changed = false
            for production in productions {
                guard !nullable[production.lhs] else { continue }
                if production.rhs.allSatisfy({ isNullable($0) }) {
                    nullable[production.lhs] = true
                    changed = true
                }
            }
        }
    }

    private mutating func computeFirst() {
        first = Array(repeating: [], count: nonterminalCount)
        var changed = true
        while changed {
            changed = false
            for production in productions {
                let before = first[production.lhs]
                for symbol in production.rhs {
                    switch symbol {
                    case .terminal(let t):
                        first[production.lhs].insert(.terminal(t))
                    case .endOfInput:
                        first[production.lhs].insert(.endOfInput)
                    case .nonterminal(let nt):
                        first[production.lhs].formUnion(first[nt])
                    }
                    if !isNullable(symbol) { break }
                }
                if first[production.lhs] != before { changed = true }
            }
        }
    }

    /// The FIRST set of a symbol sequence, taking nullability into account.
    private func firstOf(_ symbols: ArraySlice<Symbol>) -> (set: Set<FollowSymbol>, nullable: Bool) {
        var result: Set<FollowSymbol> = []
        for symbol in symbols {
            switch symbol {
            case .terminal(let t): result.insert(.terminal(t)); return (result, false)
            case .endOfInput: result.insert(.endOfInput); return (result, false)
            case .nonterminal(let nt):
                result.formUnion(first[nt])
                if !nullable[nt] { return (result, false) }
            }
        }
        return (result, true)
    }

    private mutating func computeFollow(augmentedStart: Int) {
        follow = Array(repeating: [], count: nonterminalCount)
        follow[augmentedStart].insert(.endOfInput)
        var changed = true
        while changed {
            changed = false
            for production in productions {
                for (index, symbol) in production.rhs.enumerated() {
                    guard case .nonterminal(let nt) = symbol else { continue }
                    let rest = production.rhs[(index + 1)...]
                    let (firstRest, restNullable) = firstOf(rest)
                    let before = follow[nt]
                    follow[nt].formUnion(firstRest)
                    if restNullable { follow[nt].formUnion(follow[production.lhs]) }
                    if follow[nt] != before { changed = true }
                }
            }
        }
    }

    // MARK: - Item sets

    private func closure(_ items: Set<LR0Item>) -> Set<LR0Item> {
        var result = items
        var worklist = Array(items)
        while let item = worklist.popLast() {
            let production = productions[item.production]
            guard item.dot < production.rhs.count,
                case .nonterminal(let nt) = production.rhs[item.dot]
            else { continue }
            for (id, candidate) in productions.enumerated() where candidate.lhs == nt {
                let newItem = LR0Item(production: id, dot: 0)
                if result.insert(newItem).inserted { worklist.append(newItem) }
            }
        }
        return result
    }

    private func goto(_ items: Set<LR0Item>, _ symbol: Symbol) -> Set<LR0Item> {
        var moved: Set<LR0Item> = []
        for item in items {
            let production = productions[item.production]
            guard item.dot < production.rhs.count, production.rhs[item.dot] == symbol else { continue }
            moved.insert(LR0Item(production: item.production, dot: item.dot + 1))
        }
        return moved.isEmpty ? [] : closure(moved)
    }

    private mutating func buildStates(augmentedStart: Int) {
        let startItem = LR0Item(production: acceptProduction, dot: 0)
        let start = closure([startItem])
        var setIndex: [Set<LR0Item>: Int] = [start: 0]
        var ordered: [Set<LR0Item>] = [start]
        var worklist = [0]

        while let stateIndex = worklist.popLast() {
            let itemSet = ordered[stateIndex]
            var symbols: Set<Symbol> = []
            for item in itemSet {
                let production = productions[item.production]
                if item.dot < production.rhs.count { symbols.insert(production.rhs[item.dot]) }
            }
            for symbol in symbols {
                let target = goto(itemSet, symbol)
                guard !target.isEmpty else { continue }
                if setIndex[target] == nil {
                    let id = ordered.count
                    setIndex[target] = id
                    ordered.append(target)
                    worklist.append(id)
                }
            }
        }

        states = ordered.map { Array($0).sorted { lhs, rhs in
            lhs.production != rhs.production ? lhs.production < rhs.production : lhs.dot < rhs.dot
        } }
    }

    // MARK: - Tables

    private mutating func buildTables() {
        let count = states.count
        shift = Array(repeating: [:], count: count)
        goto = Array(repeating: [:], count: count)
        reduce = Array(repeating: [:], count: count)
        accepting = Array(repeating: false, count: count)

        var setIndex: [Set<LR0Item>: Int] = [:]
        for (index, items) in states.enumerated() { setIndex[Set(items)] = index }

        for (stateIndex, items) in states.enumerated() {
            let itemSet = Set(items)

            // Shift and goto edges.
            var symbols: Set<Symbol> = []
            for item in items {
                let production = productions[item.production]
                if item.dot < production.rhs.count { symbols.insert(production.rhs[item.dot]) }
            }
            for symbol in symbols {
                let target = goto(itemSet, symbol)
                guard let targetIndex = setIndex[target] else { continue }
                switch symbol {
                case .terminal(let t): shift[stateIndex][t] = targetIndex
                case .nonterminal(let nt): goto[stateIndex][nt] = targetIndex
                case .endOfInput: accepting[stateIndex] = true
                }
            }

            // Reductions, including right-nulled ones, under SLR(1) lookahead.
            for item in items {
                let production = productions[item.production]
                // The recognised prefix ends at the dot; the suffix must be entirely nullable.
                let suffix = Array(production.rhs[item.dot...])
                guard suffix.allSatisfy({ isNullable($0) }) else { continue }
                // The augmented accept production is handled by `accepting`, not a reduce.
                if item.production == acceptProduction { continue }
                let action = ReduceAction(
                    production: item.production, length: item.dot, nullableSuffix: suffix)
                for lookahead in follow[production.lhs] {
                    let key: Int
                    switch lookahead {
                    case .terminal(let t): key = t
                    case .endOfInput: key = Self.endOfInputKey
                    }
                    reduce[stateIndex][key, default: []].append(action)
                }
            }
        }
    }

    /// The reduce-table key standing in for the end-of-input lookahead.
    static let endOfInputKey = -1
}
