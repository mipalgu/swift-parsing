import ParsingCore

/// The identity of an ATN state, an index into ``ATN/states``.
typealias ATNStateID = Int

/// The identity of a decision (a state with two or more outgoing transitions).
typealias DecisionID = Int

/// The identity of a semantic predicate, an index into ``ATN/predicates``.
typealias PredicateID = Int

/// A transition out of an ATN state.
///
/// The Augmented Transition Network represents each grammar rule as a submachine; transitions are the
/// edges between states. Terminal edges consume a token, rule edges call a submachine, and epsilon and
/// action edges move freely. Predicate edges guard alternatives by a semantic test and are used only by
/// the left-recursion precedence machinery. CST metadata (token kind, field label) rides on the edge so
/// the structural parser can rebuild a lossless tree.
enum ATNTransition: Sendable {
    /// Consumes one logical token matching `matcher`, carrying the metadata to build its CST leaf.
    case atom(matcher: TokenMatcher, isNamed: Bool, name: String, field: String?, target: ATNStateID)
    /// Calls the submachine for `ruleName`: jumps to `callee`, returning to `follow` at its stop state.
    ///
    /// `enterPrecedence`, when non-`nil`, is the minimum precedence the callee submachine must enter at; it
    /// is set only on the right-operand rule call of a rewritten directly left-recursive rule, where it
    /// realises operator binding and associativity. Every ordinary rule call leaves it `nil`, so the callee
    /// enters at the base precedence `0`.
    case rule(
        callee: ATNStateID, follow: ATNStateID, ruleName: String, isHidden: Bool, isDefined: Bool, field: String?,
        target: ATNStateID, enterPrecedence: Int? = nil)
    /// A free epsilon move to `target`.
    case epsilon(target: ATNStateID)
    /// A semantic-mutator move (a no-op for this engine), treated as epsilon.
    case action(target: ATNStateID)
    /// A semantic predicate guarding the move to `target`; evaluated only on the full-LL path.
    case predicate(PredicateID, target: ATNStateID)

    /// The state this transition leads to.
    var target: ATNStateID {
        switch self {
        case .atom(_, _, _, _, let t): t
        case .rule(_, _, _, _, _, _, let t, _): t
        case .epsilon(let t): t
        case .action(let t): t
        case .predicate(_, let t): t
        }
    }
}

/// A single state in the Augmented Transition Network.
///
/// A state belongs to exactly one rule's submachine. A state with two or more transitions is a
/// *decision* state at which adaptive prediction selects an alternative; it carries a ``DecisionID``.
struct ATNState: Sendable {
    /// The state's index, equal to its position in ``ATN/states``.
    let id: ATNStateID
    /// The name of the rule whose submachine this state belongs to.
    let rule: String
    /// Whether this is a submachine stop state (`p'_A`).
    var isStop: Bool
    /// The outgoing transitions, in grammar order (so alternative numbering follows production order).
    var transitions: [ATNTransition]
    /// The decision identity, assigned iff this state has two or more transitions.
    var decision: DecisionID?
}

/// A semantic predicate guarding a left-recursive alternative by operator precedence.
///
/// The predicate succeeds when an operator at `level` may bind given the minimum precedence `pr` the
/// rule was entered at, accounting for associativity (the right operand of a left-associative operator
/// must bind strictly tighter).
struct Predicate: Sendable {
    /// The operator's precedence level (higher binds tighter).
    let level: Int
    /// The operator's associativity.
    let associativity: Associativity

    /// Evaluates the predicate against the minimum precedence the rule was entered at.
    ///
    /// An operator may be taken when its level meets the minimum precedence in force. Associativity is not
    /// expressed by this comparison: it is realised entirely by the precedence the right operand enters at
    /// (`level + 1` for left-associative, `level` for right-associative and non-associative operators), so
    /// the single inequality `level >= minPrecedence` is correct for both forms.
    ///
    /// - Parameter minPrecedence: The minimum precedence `pr` in force at the decision.
    /// - Returns: `true` if an operator at this level may be taken under `minPrecedence`.
    func holds(minPrecedence: Int) -> Bool {
        level >= minPrecedence
    }
}

/// An Augmented Transition Network: one submachine per named rule, sharing a flat state pool.
///
/// Built once from a ``Grammar`` and immutable thereafter, the ATN is the static structure adaptive
/// prediction and the structural parser both walk. It is a value type of value types, hence `Sendable`.
struct ATN: Sendable {
    /// The flat state pool, indexed by ``ATNStateID``.
    var states: [ATNState]
    /// The entry state of each rule's submachine, keyed by rule name.
    var ruleEntry: [String: ATNStateID]
    /// The stop state of each rule's submachine, keyed by rule name.
    var ruleStop: [String: ATNStateID]
    /// The state owning each decision, keyed by ``DecisionID``.
    var decisions: [DecisionID: ATNStateID]
    /// The semantic predicates, indexed by ``PredicateID``.
    var predicates: [Predicate]
    /// The entry state of the grammar's start rule.
    let startEntry: ATNStateID

    /// Accesses a state by its identity.
    /// - Parameter id: The state identity.
    /// - Returns: The state at `id`.
    subscript(_ id: ATNStateID) -> ATNState { states[id] }
}
