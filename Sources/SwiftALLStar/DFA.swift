/// The identity of a lookahead-DFA edge: the text a logical token consumed.
///
/// Because the framework is scannerless there is no fixed token lexicon; a DFA edge is therefore keyed
/// by the exact text the surviving atom edges consumed at a step. Equal source text reuses the same edge
/// (a cache hit) while distinct tokens take distinct edges, and the key is identical across input
/// granularities because it is the decoded text, not a raw element.
typealias TokenKey = String

/// A state in a decision's lookahead DFA.
///
/// Each DFA state caches the ALL(*) configuration set reached after consuming a particular run of
/// lookahead tokens, together with the resolved prediction (if the set uniquely predicts an alternative)
/// and edges to successor states. A reference type lets edges form a shared graph that grows lazily.
final class DFAState {
    /// The ALL(*) configuration set this DFA state represents.
    let configs: ConfigSet
    /// The cached successor states, keyed by the token consumed to reach them.
    var edges: [TokenKey: DFAState] = [:]
    /// The uniquely predicted alternative, set once the configurations agree (an accept state).
    var prediction: Int?
    /// Whether this state was found to need full-LL prediction (SLL could not resolve it).
    var isStackSensitive: Bool = false
    /// Whether this state is the error sentinel (no viable configuration survived).
    var isError: Bool = false

    /// Creates a DFA state for a configuration set.
    /// - Parameter configs: The configuration set the state represents.
    init(configs: ConfigSet) {
        self.configs = configs
    }

    /// The dedicated error sentinel state.
    static func error() -> DFAState {
        let state = DFAState(configs: ConfigSet())
        state.isError = true
        return state
    }
}

/// The lookahead DFA for a single decision, grown lazily during prediction.
///
/// One DFA exists per decision per parse run. Its states are interned by their configuration set so that
/// re-reaching an equivalent set reuses the cached state and its onward edges, which is what amortises
/// adaptive prediction to near-constant time after warm-up.
final class DFA {
    /// The start state (`D_0`), created from the decision's alternatives.
    var start: DFAState?
    /// The interned states, keyed by their configuration set.
    var states: [ConfigSet: DFAState] = [:]

    /// Interns a DFA state for a configuration set, reusing an existing one if present.
    /// - Parameter configs: The configuration set to look up or create a state for.
    /// - Returns: The shared DFA state for `configs`.
    func intern(_ configs: ConfigSet) -> DFAState {
        if let existing = states[configs] { return existing }
        let state = DFAState(configs: configs)
        states[configs] = state
        return state
    }
}
