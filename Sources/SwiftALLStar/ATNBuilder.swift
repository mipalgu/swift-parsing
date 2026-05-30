import ParsingCore

/// Builds an Augmented Transition Network from a grammar's intermediate representation.
///
/// One submachine is constructed per named rule. EBNF closures (`optional`, `repeatZeroOrMore`,
/// `repeatOneOrMore`) are admitted directly as ATN subgraphs rather than desugared, so the concrete
/// syntax tree the structural parser builds keeps the same shape the reference engine produces. Field
/// and precedence wrappers carry no parsing semantics for the ALL(*) core but are preserved as edge
/// annotations the CST builder re-applies. After construction the builder verifies that no rule remains
/// left-recursive, which the prediction algorithm requires.
enum ATNBuilder {
    /// Constructs the ATN for a grammar.
    ///
    /// - Parameter grammar: The grammar whose rules to compile, assumed already free of left recursion
    ///   (the ``LeftRecursionRewriter`` runs first).
    /// - Returns: The compiled, immutable ATN.
    /// - Throws: ``GrammarError/invalidGrammar(_:)`` if a rule is still left-recursive after rewriting.
    static func build(_ grammar: Grammar) throws(GrammarError) -> ATN {
        var builder = Builder(grammar: grammar)
        builder.buildAll()
        try builder.verifyNoLeftRecursion()
        return builder.finish()
    }

    /// The mutable accumulator threaded through recursive construction.
    private struct Builder {
        let grammar: Grammar
        var states: [ATNState] = []
        var ruleEntry: [String: ATNStateID] = [:]
        var ruleStop: [String: ATNStateID] = [:]
        var decisions: [DecisionID: ATNStateID] = [:]
        var predicates: [Predicate] = []
        var nextDecision: DecisionID = 0
        /// The field label currently in force, applied to the next emitted token or rule edge.
        var currentField: String?
        /// The enter-at precedence currently in force, applied to the next emitted rule edge.
        ///
        /// Set by a `.precedence` wrapper around a rule's self-reference (the right operand of a rewritten
        /// left-recursive operator alternative) and consumed once, like ``currentField``. `nil` everywhere
        /// else, so ordinary rule calls carry no enter-at precedence.
        var pendingEnterPrecedence: Int?

        init(grammar: Grammar) {
            self.grammar = grammar
        }

        /// Allocates a fresh state owned by `rule`.
        mutating func newState(rule: String, isStop: Bool = false) -> ATNStateID {
            let id = states.count
            states.append(ATNState(id: id, rule: rule, isStop: isStop, transitions: [], decision: nil))
            return id
        }

        /// Appends a transition to a state, assigning a decision id once it becomes a fan-out.
        mutating func addTransition(_ transition: ATNTransition, from: ATNStateID) {
            states[from].transitions.append(transition)
            if states[from].transitions.count >= 2 && states[from].decision == nil {
                let decision = nextDecision
                nextDecision += 1
                states[from].decision = decision
                decisions[decision] = from
            }
        }

        /// Reserves an entry and stop state for every rule before emitting bodies (so calls resolve).
        mutating func buildAll() {
            // Deterministic order keeps state ids stable across builds, which the white-box tests rely on.
            let names = grammar.rules.keys.sorted()
            for name in names {
                ruleEntry[name] = newState(rule: name)
                ruleStop[name] = newState(rule: name, isStop: true)
            }
            for name in names {
                let entry = ruleEntry[name]!
                let stop = ruleStop[name]!
                currentField = nil
                let last = emit(grammar.rules[name]!, from: entry, rule: name)
                addTransition(.epsilon(target: stop), from: last)
            }
        }

        /// Emits the subgraph for `rule`, returning the state reached after it.
        mutating func emit(_ rule: Rule, from: ATNStateID, rule owner: String) -> ATNStateID {
            switch rule {
            case .token(let name, let matcher, let isNamed):
                let field = currentField
                currentField = nil
                let q = newState(rule: owner)
                addTransition(
                    .atom(matcher: matcher, isNamed: isNamed, name: name, field: field, target: q), from: from)
                return q

            case .reference(let name):
                let field = currentField
                currentField = nil
                let enterPrecedence = pendingEnterPrecedence
                pendingEnterPrecedence = nil
                let q = newState(rule: owner)
                let isDefined = grammar.rules[name] != nil
                let callee = ruleEntry[name] ?? q
                addTransition(
                    .rule(
                        callee: callee, follow: q, ruleName: name,
                        isHidden: name.hasPrefix("_"), isDefined: isDefined, field: field, target: q,
                        enterPrecedence: enterPrecedence),
                    from: from)
                return q

            case .sequence(let rules):
                var cursor = from
                for r in rules { cursor = emit(r, from: cursor, rule: owner) }
                return cursor

            case .choice(let alternatives):
                let merge = newState(rule: owner)
                for alt in alternatives {
                    let savedField = currentField
                    let s = newState(rule: owner)
                    addTransition(.epsilon(target: s), from: from)
                    currentField = savedField
                    let e = emit(alt, from: s, rule: owner)
                    addTransition(.epsilon(target: merge), from: e)
                }
                return merge

            case .optional(let sub):
                let merge = newState(rule: owner)
                // Alternative 1: take the sub-rule. Alternative 2: bypass. Take wins (production order).
                let take = newState(rule: owner)
                addTransition(.epsilon(target: take), from: from)
                let savedField = currentField
                let afterSub = emit(sub, from: take, rule: owner)
                addTransition(.epsilon(target: merge), from: afterSub)
                currentField = savedField
                addTransition(.epsilon(target: merge), from: from)
                return merge

            case .repeatZeroOrMore(let sub):
                // Loop entry is a decision: alternative 1 takes the body and loops, alternative 2 exits.
                let loop = newState(rule: owner)
                addTransition(.epsilon(target: loop), from: from)
                let merge = newState(rule: owner)
                let body = newState(rule: owner)
                addTransition(.epsilon(target: body), from: loop)
                let savedField = currentField
                let afterBody = emit(sub, from: body, rule: owner)
                addTransition(.epsilon(target: loop), from: afterBody)
                currentField = savedField
                addTransition(.epsilon(target: merge), from: loop)
                return merge

            case .repeatOneOrMore(let sub):
                let savedField = currentField
                let afterFirst = emit(sub, from: from, rule: owner)
                currentField = savedField
                return emit(.repeatZeroOrMore(sub), from: afterFirst, rule: owner)

            case .field(let name, let sub):
                // The field label is applied to the sub-rule's first structural child; the structural
                // parser groups multiple children under the label when needed, matching the reference.
                currentField = name
                return emit(sub, from: from, rule: owner)

            case .precedence(let level, let assoc, let sub):
                // The rewriter marks a left-recursive operator alternative with a precedence wrapper around
                // an empty body; that becomes a guard predicate edge so the operator loop only fires for
                // operators of sufficient binding power. A precedence wrapper with a non-empty body is a
                // plain annotation and is emitted transparently.
                if case .sequence(let inner) = sub, inner.isEmpty {
                    let predicateID = predicates.count
                    predicates.append(Predicate(level: level, associativity: assoc))
                    let q = newState(rule: owner)
                    addTransition(.predicate(predicateID, target: q), from: from)
                    return q
                }
                // The rewriter wraps the trailing self-reference (the right operand of a left-recursive
                // operator alternative) in a precedence node carrying its enter-at precedence. Record that
                // precedence on the rule edge so the right operand re-enters at a higher minimum, which is
                // what realises operator binding and associativity.
                if case .reference(owner) = sub {
                    pendingEnterPrecedence = level
                    let q = emit(sub, from: from, rule: owner)
                    pendingEnterPrecedence = nil
                    return q
                }
                return emit(sub, from: from, rule: owner)
            }
        }

        /// Verifies no rule can reach its own entry without consuming a token (left recursion).
        func verifyNoLeftRecursion() throws(GrammarError) {
            for (name, entry) in ruleEntry {
                if reachesEntryWithoutConsuming(from: entry, target: entry, visited: []) {
                    throw .invalidGrammar("left-recursive rule '\(name)' is not eliminable")
                }
            }
        }

        /// Whether `target`'s entry is reachable from `state` through only epsilon/action/predicate and
        /// rule-call edges that immediately re-enter, without first consuming a token.
        func reachesEntryWithoutConsuming(
            from state: ATNStateID, target: ATNStateID, visited: Set<ATNStateID>
        ) -> Bool {
            if visited.contains(state) { return false }
            var seen = visited
            seen.insert(state)
            for transition in states[state].transitions {
                switch transition {
                case .atom:
                    continue  // consumes a token: this path cannot be left recursion
                case .epsilon(let t), .action(let t), .predicate(_, let t):
                    if t == target { return true }
                    if reachesEntryWithoutConsuming(from: t, target: target, visited: seen) { return true }
                case .rule(let callee, _, _, _, _, _, _, _):
                    if callee == target { return true }
                    if reachesEntryWithoutConsuming(from: callee, target: target, visited: seen) { return true }
                }
            }
            return false
        }

        /// Finalises the immutable ATN value.
        func finish() -> ATN {
            ATN(
                states: states,
                ruleEntry: ruleEntry,
                ruleStop: ruleStop,
                decisions: decisions,
                predicates: predicates,
                startEntry: ruleEntry[grammar.startRule] ?? 0)
        }
    }
}
