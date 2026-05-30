import ParsingCore

/// The adaptive-prediction engine that selects an alternative at each ATN decision.
///
/// The predictor simulates the ATN over the upcoming input without consuming it, building and caching a
/// lookahead DFA per decision. It first tries stack-insensitive SLL prediction (fast, cacheable across
/// call sites) and fails over to full-LL prediction with the real call stack only when SLL cannot tell a
/// genuine ambiguity from its own stack-blindness. Ambiguities are resolved to the lowest-numbered
/// alternative, matching the ordered-choice reference engine. The predictor never mutates parser state:
/// it checkpoints and restores the input cursor around every prediction.
final class Predictor<Input: ParserInput> {
    /// The sentinel alternative returned when no alternative is viable, triggering recovery.
    static var noViableAlternative: Int { -1 }

    let atn: ATN
    let input: Input
    let extras: [TokenMatcher]
    /// The follow (return) states of every call site, grouped by the called rule's name.
    ///
    /// Precomputed once so the stack-insensitive SLL return at a submachine stop can enumerate a rule's
    /// callers in O(call sites) rather than rescanning the whole ATN on every wildcard return.
    private let callSites: [String: [ATNStateID]]
    /// One lookahead DFA per decision, grown lazily and reused within this parse run.
    private var dfaCache: [DecisionID: DFA] = [:]
    /// Memoises whether each decision is guarded by a semantic predicate; it depends only on the ATN, so
    /// it is computed at most once per decision rather than on every prediction.
    private var predicateDecisionCache: [DecisionID: Bool] = [:]
    /// Counts DFA-edge cache hits, exposed for white-box tests of cache reuse.
    private(set) var cacheHits: Int = 0

    /// Creates a predictor over an ATN and input.
    /// - Parameters:
    ///   - atn: The compiled ATN.
    ///   - input: The input view being parsed.
    ///   - extras: The grammar's trivia matchers, skipped between logical tokens.
    init(atn: ATN, input: Input, extras: [TokenMatcher]) {
        self.atn = atn
        self.input = input
        self.extras = extras
        var sites: [String: [ATNStateID]] = [:]
        for state in atn.states {
            for transition in state.transitions {
                if case .rule(_, let follow, let calledRule, _, _, _, _) = transition {
                    sites[calledRule, default: []].append(follow)
                }
            }
        }
        self.callSites = sites
    }

    // MARK: - adaptivePredict (Function 2)

    /// Predicts the alternative to take at a decision, given the live parser call stack and a cursor.
    ///
    /// - Parameters:
    ///   - decision: The decision to resolve.
    ///   - callStack: The live parser call stack (return states, innermost last), used for full-LL.
    ///   - start: The input index at the decision; prediction starts here and never advances it.
    ///   - minPrecedence: The minimum operator precedence in force, for left-recursion guards.
    /// - Returns: The 1-based alternative to take, or ``noViableAlternative`` if none is viable.
    func adaptivePredict(
        decision: DecisionID, callStack: [ATNStateID], start: Input.Index, minPrecedence: Int
    ) -> Int {
        if decisionHasPredicate(decision) {
            return llPredict(
                decision: decision, start: start, stack: llStack(callStack), minPrecedence: minPrecedence)
        }
        let dfa = dfaCache[decision] ?? makeDFA(decision: decision, minPrecedence: minPrecedence)
        // The full-LL call stack is needed only if SLL fails over, which is rare; building it eagerly is
        // O(stack depth) per decision and dominates deeply nested input, so it is deferred to the fallback.
        return sllPredict(
            decision: decision, dfa: dfa, start: start,
            callStack: callStack, minPrecedence: minPrecedence)
    }

    /// Whether any alternative at a decision is guarded by a semantic predicate.
    ///
    /// The answer depends only on the static ATN, so it is memoised per decision: the recursive reachability
    /// walk runs at most once for each decision rather than on every prediction.
    private func decisionHasPredicate(_ decision: DecisionID) -> Bool {
        if let cached = predicateDecisionCache[decision] { return cached }
        let result: Bool
        if let stateID = atn.decisions[decision] {
            result = reachableHasPredicate(from: stateID, visited: [])
        } else {
            result = false
        }
        predicateDecisionCache[decision] = result
        return result
    }

    /// Whether a predicate edge is reachable from a decision before consuming a token.
    private func reachableHasPredicate(from state: ATNStateID, visited: Set<ATNStateID>) -> Bool {
        if visited.contains(state) { return false }
        var seen = visited
        seen.insert(state)
        for transition in atn[state].transitions {
            switch transition {
            case .predicate: return true
            case .epsilon(let t), .action(let t):
                if reachableHasPredicate(from: t, visited: seen) { return true }
            case .atom, .rule:
                continue
            }
        }
        return false
    }

    /// Builds the full-LL call-stack context from the live parser stack (innermost last).
    private func llStack(_ callStack: [ATNStateID]) -> PredictionContext {
        var context = PredictionContext.empty
        for returnState in callStack { context = context.pushing(returnState) }
        return context
    }

    // MARK: - startState (Function 3) and closure (Function 7)

    /// Builds the start configuration set for a decision over a given call stack.
    private func startConfigs(decision: DecisionID, stack: PredictionContext, minPrecedence: Int) -> ConfigSet {
        var set = ConfigSet()
        guard let stateID = atn.decisions[decision] else { return set }
        let transitions = atn[stateID].transitions
        for (offset, transition) in transitions.enumerated() {
            let alt = offset + 1
            let config = ATNConfig(state: transition.target, alt: alt, context: stack, minPrecedence: minPrecedence)
            var busy: Set<ClosureKey> = []
            closure(config, into: &set, busy: &busy)
        }
        return set
    }

    /// The identity used by the closure busy-set to break epsilon and recursion cycles.
    private struct ClosureKey: Hashable {
        let state: ATNStateID
        let alt: Int
        let context: PredictionContext
    }

    /// Chases epsilon, action, predicate and rule edges from a configuration, adding reachable
    /// configurations to `set`. The busy set prevents non-termination on epsilon cycles and right
    /// recursion. Action edges are free moves. A precedence-guard predicate is evaluated on the concrete
    /// full-LL path (where the minimum precedence is meaningful) and pruned when it fails; on the SLL
    /// wildcard path it is treated as a free move, deferring the check to the LL retry.
    private func closure(_ config: ATNConfig, into set: inout ConfigSet, busy: inout Set<ClosureKey>) {
        let key = ClosureKey(state: config.state, alt: config.alt, context: config.context)
        if busy.contains(key) { return }
        busy.insert(key)

        let state = atn[config.state]
        if state.isStop {
            closureAtStop(config, into: &set, busy: &busy)
            return
        }

        var hasAtom = false
        for transition in state.transitions {
            switch transition {
            case .atom:
                // A terminal edge ends the closure here; the configuration waits for `move`.
                hasAtom = true
            case .epsilon(let t), .action(let t):
                closure(config.at(state: t, context: config.context), into: &set, busy: &busy)
            case .predicate(let id, let t):
                if config.context.hasWildcard || atn.predicates[id].holds(minPrecedence: config.minPrecedence) {
                    closure(config.at(state: t, context: config.context), into: &set, busy: &busy)
                }
            case .rule(let callee, let follow, _, _, _, _, _):
                let pushed = config.context.pushing(follow)
                closure(config.at(state: callee, context: pushed), into: &set, busy: &busy)
            }
        }
        // Record the configuration itself when it sits on a terminal edge (the waiting point for `move`).
        if hasAtom {
            set.insert(config)
        }
    }

    /// Handles closure at a submachine stop state: returns through the call stack or, under the wildcard,
    /// across all call sites of the rule (the stack-insensitive SLL return).
    private func closureAtStop(_ config: ATNConfig, into set: inout ConfigSet, busy: inout Set<ClosureKey>) {
        let context = config.context
        if context.hasWildcard {
            // SLL wildcard: return to every call site of this rule (enumerated from the precomputed map,
            // in ATN order, so the resulting configuration set is identical to a full ATN rescan).
            let ruleName = atn[config.state].rule
            let follows = callSites[ruleName] ?? []
            for follow in follows {
                closure(config.at(state: follow, context: .wildcard), into: &set, busy: &busy)
            }
            let returned = !follows.isEmpty
            // A top-level rule has no callers: the alternative has completed, so record it as an accept.
            if !returned { set.insert(config) }
            return
        }
        let tops = context.tops()
        if tops.isEmpty {
            // Empty stack at the start rule's stop: the alternative has completed; record it as an accept.
            set.insert(config)
            return
        }
        for top in tops {
            closure(config.at(state: top.returnState, context: top.parent), into: &set, busy: &busy)
        }
    }

    // MARK: - DFA construction and SLL prediction (Functions 4, 5)

    /// Builds and caches the start state of a decision's lookahead DFA (SLL wildcard stack).
    private func makeDFA(decision: DecisionID, minPrecedence: Int) -> DFA {
        let dfa = DFA()
        let startSet = startConfigs(decision: decision, stack: .wildcard, minPrecedence: minPrecedence)
        let startState = dfa.intern(startSet)
        resolvePrediction(startState)
        dfa.start = startState
        dfaCache[decision] = dfa
        return dfa
    }

    /// Runs SLL prediction over the lookahead DFA, failing over to full LL on stack sensitivity.
    private func sllPredict(
        decision: DecisionID, dfa: DFA, start: Input.Index,
        callStack: [ATNStateID], minPrecedence: Int
    ) -> Int {
        var cursor = start
        var state = dfa.start!
        while true {
            if state.isError { return Self.noViableAlternative }
            if state.isStackSensitive {
                return llPredict(
                    decision: decision, start: start, stack: llStack(callStack), minPrecedence: minPrecedence)
            }
            if let prediction = state.prediction { return prediction }

            let tokenStart = skipTrivia(extras, in: input, at: cursor)
            guard let (key, end) = nextTokenKey(configs: state.configs, at: tokenStart) else {
                // No upcoming token matches any waiting edge: the surviving configurations are completed
                // alternatives, so the lowest-numbered such alternative is predicted (production order).
                return completedAlternative(state.configs)
            }
            if let cached = state.edges[key] {
                cacheHits += 1
                state = cached
            } else {
                let target = computeTarget(dfa: dfa, from: state, key: key, at: tokenStart)
                state.edges[key] = target
                state = target
            }
            cursor = end
        }
    }

    /// The lowest-numbered alternative whose configuration has completed (reached a stop state).
    ///
    /// Used when no upcoming token matches any waiting edge: an alternative survives only if it has run
    /// to completion, so the lowest such alternative is predicted, matching ordered choice.
    private func completedAlternative(_ configs: ConfigSet) -> Int {
        var best: Int?
        for config in configs.configs where atn[config.state].isStop {
            if best == nil || config.alt < best! { best = config.alt }
        }
        return best ?? Self.noViableAlternative
    }

    /// Computes the DFA successor for a token, interning and resolving it (Function 5).
    private func computeTarget(dfa: DFA, from state: DFAState, key: TokenKey, at tokenStart: Input.Index) -> DFAState {
        let moved = move(state.configs, key: key, at: tokenStart)
        if moved.isEmpty { return .error() }
        let target = dfa.intern(moved)
        resolvePrediction(target)
        return target
    }

    /// Resolves a DFA state to an accept (unique alternative) or marks it stack-sensitive / conflicting.
    private func resolvePrediction(_ state: DFAState) {
        if state.prediction != nil || state.isStackSensitive { return }
        let alts = state.configs.alternatives
        if alts.count == 1 {
            state.prediction = alts.first
            return
        }
        if alts.isEmpty {
            state.isError = true
            return
        }
        // A conflict: some location predicts more than one alternative. Under SLL we cannot distinguish a
        // genuine ambiguity from stack-blindness, so we mark the state stack-sensitive to force LL retry.
        if hasConflict(state.configs) {
            state.isStackSensitive = true
        }
    }

    // MARK: - move (scannerless, Function 5 / §5.2)

    /// The token key and consumed span for the next logical token under a configuration set.
    ///
    /// Skips trivia, then asks every waiting atom edge what it consumes at the token start. All viable
    /// JSON decisions agree on the consumed span (they are LL(1) on the first token); the longest match
    /// is taken as the canonical step so the lookahead is deterministic.
    private func nextTokenKey(configs: ConfigSet, at tokenStart: Input.Index) -> (TokenKey, Input.Index)? {
        // The DFA edge is identified by the set of atom edges that match at the longest span: that set,
        // and not the literal text, is exactly what `move` follows, so identifying the edge this way reuses
        // one cached edge for every token that drives the same atoms (every JSON number, every string, ...).
        // A single matching pass records both the longest span and the targets that reach it; when a longer
        // match appears the partial set is discarded, since only the longest-span edges survive into `move`.
        var bestEnd: Input.Index?
        var firstTarget: ATNStateID = -1
        var targetCount = 0
        var overflow: [ATNStateID] = []
        for config in configs.configs {
            for transition in atn[config.state].transitions {
                if case .atom(let matcher, _, _, _, let target) = transition,
                    let end = matchToken(matcher, in: input, at: tokenStart)
                {
                    if bestEnd == nil || end > bestEnd! {
                        bestEnd = end
                        firstTarget = target
                        targetCount = 1
                        overflow.removeAll(keepingCapacity: true)
                    } else if end == bestEnd! {
                        if targetCount == 1 { overflow.append(firstTarget) }
                        overflow.append(target)
                        targetCount += 1
                    }
                }
            }
        }
        guard let end = bestEnd else { return nil }
        if targetCount == 1 {
            return (TokenKey(matchedTargets: [firstTarget]), end)
        }
        overflow.sort()
        var deduped: [ATNStateID] = []
        deduped.reserveCapacity(overflow.count)
        for target in overflow where deduped.last != target { deduped.append(target) }
        return (TokenKey(matchedTargets: deduped), end)
    }

    /// Moves a configuration set across the token identified by `key`, then takes the closure.
    ///
    /// The configurations whose waiting atom edge is one of the key's matched targets advance across it;
    /// they are exactly the edges that matched at the longest span when the key was computed.
    private func move(_ configs: ConfigSet, key: TokenKey, at tokenStart: Input.Index) -> ConfigSet {
        var next = ConfigSet()
        for config in configs.configs {
            for transition in atn[config.state].transitions {
                if case .atom(_, _, _, _, let target) = transition,
                    key.matchedTargets.contains(target)
                {
                    var busy: Set<ClosureKey> = []
                    closure(config.at(state: target, context: config.context), into: &next, busy: &busy)
                }
            }
        }
        return next
    }

    // MARK: - LLpredict (Function 6)

    /// Full-LL prediction over the real call stack, resolving ambiguity to the lowest alternative.
    private func llPredict(
        decision: DecisionID, start: Input.Index, stack: PredictionContext, minPrecedence: Int
    ) -> Int {
        // The start configurations are taken over the concrete stack, so precedence guards are already
        // evaluated within `closure`; no separate predicate pass is needed.
        var configs = startConfigs(decision: decision, stack: stack, minPrecedence: minPrecedence)
        var cursor = start
        while true {
            let alts = configs.alternatives
            if alts.isEmpty { return Self.noViableAlternative }
            if alts.count == 1 { return alts.first! }
            if conflictIsAmbiguity(configs) { return alts.min()! }

            let tokenStart = skipTrivia(extras, in: input, at: cursor)
            guard let (key, end) = nextTokenKey(configs: configs, at: tokenStart) else {
                return completedAlternative(configs)
            }
            configs = move(configs, key: key, at: tokenStart)
            cursor = end
        }
    }

    // MARK: - Conflict detection (Functions 8, 9)

    /// Whether the configuration set has a conflict: one ATN location predicts multiple alternatives and
    /// no location uniquely predicts a single alternative (so SLL cannot decide).
    private func hasConflict(_ configs: ConfigSet) -> Bool {
        let perLocation = conflictSetsPerLocation(configs)
        let conflicting = perLocation.contains { $0.count > 1 }
        guard conflicting else { return false }
        // If some state still predicts exactly one alternative, SLL can make progress without LL.
        let perState = prodSetsPerState(configs)
        let hasUnique = perState.contains { $0.count == 1 }
        return !hasUnique
    }

    /// Whether a full-LL conflict is a genuine ambiguity (all conflicting locations agree on the same
    /// alternative set), in which case prediction resolves to the lowest alternative.
    private func conflictIsAmbiguity(_ configs: ConfigSet) -> Bool {
        let perLocation = conflictSetsPerLocation(configs).filter { $0.count > 1 }
        guard let first = perLocation.first else { return false }
        return perLocation.allSatisfy { $0 == first }
    }

    /// The alternative sets per `(state, context)` location (Function 8).
    private func conflictSetsPerLocation(_ configs: ConfigSet) -> [Set<Int>] {
        var byLocation: [LocationKey: Set<Int>] = [:]
        for config in configs.configs {
            byLocation[LocationKey(state: config.state, context: config.context), default: []].insert(config.alt)
        }
        return Array(byLocation.values)
    }

    /// The alternative sets per ATN state (Function 9).
    private func prodSetsPerState(_ configs: ConfigSet) -> [Set<Int>] {
        var byState: [ATNStateID: Set<Int>] = [:]
        for config in configs.configs {
            byState[config.state, default: []].insert(config.alt)
        }
        return Array(byState.values)
    }

    /// The identity of a `(state, context)` location for conflict detection.
    private struct LocationKey: Hashable {
        let state: ATNStateID
        let context: PredictionContext
    }
}
