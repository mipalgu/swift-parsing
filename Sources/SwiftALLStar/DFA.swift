/// The identity of a lookahead-DFA edge: the set of atom edges that matched the next logical token at its
/// longest span, in ascending target order.
///
/// Because the framework is scannerless there is no fixed token lexicon. What determines the successor
/// configuration set, however, is not the literal token text but *which* waiting atom edges fired at the
/// step (the move follows exactly those). Keying the edge by that set rather than by the consumed text
/// lets value-bearing tokens that drive the same edges (for example every distinct JSON number or string)
/// share one cached DFA edge, which keeps the lookahead cache warm across value-rich input. The key is
/// identical across input granularities because it is composed of ATN target identities, not raw elements.
struct TokenKey: Hashable {
    /// The targets of the atom edges that matched at the longest span, sorted ascending and deduplicated.
    let matchedTargets: [ATNStateID]
}

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
