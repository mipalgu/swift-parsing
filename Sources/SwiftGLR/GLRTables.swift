import ParsingCore

/// The immutable parse tables a `GLREngine` builds once and shares across parses.
///
/// `GLRTables` bundles the flattened productions, terminal and nonterminal tables, the LR(0) automaton
/// with SLR(1) lookahead and right-nulled reductions, and the trivia matchers. It is `Sendable` and
/// read-only after construction, so a single engine value can drive concurrent parses, each owning its
/// own mutable graph-structured stack and forest.
struct GLRTables: Sendable {
    /// The flattened productions, indexed by production id.
    let productions: [Production]
    /// The deduplicated terminal table, indexed by terminal id.
    let terminals: [Terminal]
    /// The nonterminal names, indexed by nonterminal id.
    let nonterminalNames: [String]
    /// The trivia (extras) matchers consumed between tokens.
    let extras: [TokenMatcher]
    /// The start state index.
    let startState: Int
    /// The shift table: `shift[state][terminal] = nextState`.
    let shift: [[Int: Int]]
    /// The reduce table keyed by `(state, terminal)`; the end-of-input key is ``LR0Automaton/endOfInputKey``.
    let reduce: [[Int: [ReduceAction]]]
    /// The goto table: `goto[state][nonterminal] = nextState`.
    let goto: [[Int: Int]]
    /// Whether each state accepts end-of-input.
    let accepting: [Bool]
    /// Whether each nonterminal can derive the empty string.
    let nullableNonterminals: [Bool]
    /// The number of states.
    let stateCount: Int
    /// The nonterminal id of the user start rule.
    let userStartID: Int
    /// The production id of the augmented accept production `S' → start $`.
    let acceptProductionID: Int

    /// Builds the parse tables from a grammar.
    ///
    /// - Parameter grammar: The grammar to prepare. Its start rule must already be validated as defined.
    init(grammar: Grammar) {
        let flattener = GrammarFlattener(grammar: grammar)
        let automaton = LR0Automaton(
            productions: flattener.productions,
            nonterminalCount: flattener.nonterminalNames.count,
            acceptProduction: flattener.acceptProduction,
            augmentedStart: flattener.augmentedStart)

        self.productions = flattener.productions
        self.terminals = flattener.terminals
        self.nonterminalNames = flattener.nonterminalNames
        self.extras = flattener.extras
        self.startState = automaton.startState
        self.shift = automaton.shift
        self.reduce = automaton.reduce
        self.goto = automaton.goto
        self.accepting = automaton.accepting
        self.stateCount = automaton.states.count
        self.userStartID = flattener.userStart
        self.acceptProductionID = flattener.acceptProduction

        var nullable = Array(repeating: false, count: flattener.nonterminalNames.count)
        for nt in 0..<flattener.nonterminalNames.count {
            nullable[nt] = automaton.isNullable(.nonterminal(nt))
        }
        self.nullableNonterminals = nullable
    }

    /// The reductions enabled in a state under a terminal lookahead (or end-of-input).
    ///
    /// - Parameters:
    ///   - state: The LR state.
    ///   - terminal: The terminal id, or ``LR0Automaton/endOfInputKey`` for end-of-input.
    /// - Returns: The reduce actions, possibly empty.
    func reductions(state: Int, terminal: Int) -> [ReduceAction] {
        reduce[state][terminal] ?? []
    }

    /// The shift target for a state and terminal, if any.
    ///
    /// - Parameters:
    ///   - state: The LR state.
    ///   - terminal: The terminal id.
    /// - Returns: The next state, or `nil` if no shift is defined.
    func shiftTarget(state: Int, terminal: Int) -> Int? {
        shift[state][terminal]
    }

    /// The terminals that can be shifted from a state.
    ///
    /// - Parameter state: The LR state.
    /// - Returns: The shiftable terminal ids.
    func shiftableTerminals(state: Int) -> [Int] {
        Array(shift[state].keys)
    }

    /// The terminal lookaheads that key a reduction in a state (including the end-of-input key).
    ///
    /// - Parameter state: The LR state.
    /// - Returns: The reduce-lookahead keys.
    func reduceLookaheads(state: Int) -> [Int] {
        Array(reduce[state].keys)
    }

    /// Whether a symbol can derive the empty string.
    ///
    /// - Parameter symbol: The symbol to test.
    /// - Returns: `true` for a nullable nonterminal, `false` for terminals and end-of-input.
    func nullableSymbol(_ symbol: Symbol) -> Bool {
        switch symbol {
        case .nonterminal(let nt): return nullableNonterminals[nt]
        case .terminal, .endOfInput: return false
        }
    }
}
