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

    /// The number of distinct terminals; the stride of the flat shift table.
    private let terminalCount: Int
    /// The number of distinct nonterminals; the stride of the flat goto table.
    private let nonterminalCount: Int
    /// A dense shift table: `shiftFlat[state * terminalCount + terminal]`, `-1` where no shift exists.
    private let shiftFlat: [Int]
    /// A dense goto table: `gotoFlat[state * nonterminalCount + nt]`, `-1` where no goto exists.
    private let gotoFlat: [Int]
    /// A dense reduce table: `reduceFlat[state * (terminalCount + 1) + terminal + 1]`. Slot `0` of each
    /// state's stripe holds the end-of-input reductions; empty cells share one empty array.
    private let reduceFlat: [[ReduceAction]]

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

        // Derive dense flat tables for the hot per-token lookups, eliminating dictionary hashing on the
        // shift, goto and reduce accesses in the reducer and shifter loops.
        let stateCount = automaton.states.count
        let terminalCount = flattener.terminals.count
        let nonterminalCount = flattener.nonterminalNames.count
        self.terminalCount = terminalCount
        self.nonterminalCount = nonterminalCount

        var shiftFlat = Array(repeating: -1, count: stateCount * terminalCount)
        for (state, row) in automaton.shift.enumerated() {
            for (terminal, target) in row { shiftFlat[state * terminalCount + terminal] = target }
        }
        self.shiftFlat = shiftFlat

        var gotoFlat = Array(repeating: -1, count: stateCount * nonterminalCount)
        for (state, row) in automaton.goto.enumerated() {
            for (nt, target) in row { gotoFlat[state * nonterminalCount + nt] = target }
        }
        self.gotoFlat = gotoFlat

        let reduceStride = terminalCount + 1
        var reduceFlat = Array(repeating: [ReduceAction](), count: stateCount * reduceStride)
        for (state, row) in automaton.reduce.enumerated() {
            for (terminal, actions) in row {
                // The end-of-input key (-1) maps to slot 0; ordinary terminals to slot terminal + 1.
                reduceFlat[state * reduceStride + terminal + 1] = actions
            }
        }
        self.reduceFlat = reduceFlat
    }

    /// The reductions enabled in a state under a terminal lookahead (or end-of-input).
    ///
    /// - Parameters:
    ///   - state: The LR state.
    ///   - terminal: The terminal id, or ``LR0Automaton/endOfInputKey`` for end-of-input.
    /// - Returns: The reduce actions, possibly empty.
    func reductions(state: Int, terminal: Int) -> [ReduceAction] {
        reduceFlat[state * (terminalCount + 1) + terminal + 1]
    }

    /// The shift target for a state and terminal, if any.
    ///
    /// - Parameters:
    ///   - state: The LR state.
    ///   - terminal: The terminal id.
    /// - Returns: The next state, or `nil` if no shift is defined.
    func shiftTarget(state: Int, terminal: Int) -> Int? {
        let target = shiftFlat[state * terminalCount + terminal]
        return target < 0 ? nil : target
    }

    /// The goto target for a state and nonterminal, if any.
    ///
    /// - Parameters:
    ///   - state: The LR state.
    ///   - nonterminal: The nonterminal id.
    /// - Returns: The next state, or `nil` if no goto is defined.
    func gotoTarget(state: Int, nonterminal: Int) -> Int? {
        let target = gotoFlat[state * nonterminalCount + nonterminal]
        return target < 0 ? nil : target
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
