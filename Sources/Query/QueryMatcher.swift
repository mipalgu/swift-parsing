import ParsingCore

/// Walks a concrete syntax tree, matching ``QueryPattern`` values and collecting captures.
///
/// The matcher is the engine behind ``Query``. It visits every node of a tree, attempts each
/// top-level pattern at each node, and yields a ``QueryMatch`` for every distinct structural match
/// whose predicates also hold. A pattern that can match a node in several ways (for example a
/// sibling pair that slides along a list) produces one match per way, mirroring tree-sitter.
/// Matching never throws: a tree that does not satisfy a pattern simply produces no match there.
struct QueryMatcher {
    /// The compiled top-level patterns to attempt, in order.
    let patterns: [QueryPattern]

    /// A partial result of matching within a child sequence: the next child to consider, the
    /// captures bound so far, and whether the most recent match consumed a named child (so a
    /// following anchor knows what adjacency to enforce).
    private struct SequenceState {
        var elementIndex: Int
        var captures: [QueryCapture]
        var consumedNamed: Bool
    }

    /// Collects every match of every pattern across the whole tree rooted at `root`.
    ///
    /// - Parameter root: The tree root to search.
    /// - Returns: The matches found, in document order of the node each pattern anchored at.
    func matches(in root: Syntax) -> [QueryMatch] {
        var results: [QueryMatch] = []
        for (index, pattern) in patterns.enumerated() {
            collect(pattern: pattern, index: index, at: root, into: &results)
        }
        return results
    }

    /// Visits `node` and its descendants, attempting `pattern` rooted at each, recording matches.
    private func collect(
        pattern: QueryPattern,
        index: Int,
        at node: Syntax,
        into results: inout [QueryMatch]
    ) {
        let predicates = collectPredicates(pattern)
        for binding in matchNode(pattern: pattern, node: node, captures: []) {
            if predicates.allSatisfy({ PredicateEvaluator.evaluate($0, captures: binding) }) {
                results.append(QueryMatch(patternIndex: index, captures: binding))
            }
        }
        for child in node.children {
            collect(pattern: pattern, index: index, at: child, into: &results)
        }
    }

    // MARK: - Single-node matching

    /// Enumerates every way a single pattern matches a single node, each as a capture list.
    ///
    /// - Parameters:
    ///   - pattern: The pattern to match (a node, wildcard, alternation, capture, field or anonymous).
    ///   - node: The candidate node.
    ///   - captures: The captures accumulated so far from the enclosing context.
    /// - Returns: One capture list per distinct successful match; empty if the node does not match.
    private func matchNode(
        pattern: QueryPattern,
        node: Syntax,
        captures: [QueryCapture]
    ) -> [[QueryCapture]] {
        switch pattern {
        case .anyNode:
            return [captures]

        case .anyNamedNode:
            return node.kind.isNamed ? [captures] : []

        case .anonymous(let literal):
            return (!node.kind.isNamed && node.kind.name == literal) ? [captures] : []

        case .node(let type, let children, _):
            guard node.kind.isNamed, node.kind.name == type else { return [] }
            return matchChildren(children, of: node, captures: captures)

        case .group(let members):
            return matchChildren(members, of: node, captures: captures)

        case .alternation(let alternatives):
            return alternatives.flatMap { matchNode(pattern: $0, node: node, captures: captures) }

        case .field(let label, let inner):
            guard node.field == label else { return [] }
            return matchNode(pattern: inner, node: node, captures: captures)

        case .capture(let name, let inner):
            return matchNode(pattern: inner, node: node, captures: captures).map {
                $0 + [QueryCapture(name: name, node: node)]
            }

        case .quantified(let inner, let quantifier):
            let matched = matchNode(pattern: inner, node: node, captures: captures)
            if !matched.isEmpty { return matched }
            return quantifier.allowsZero ? [captures] : []

        case .negatedField, .anchor:
            return []
        }
    }

    // MARK: - Child-sequence matching

    /// Enumerates every way an ordered child-pattern list matches a node's children.
    ///
    /// Negated fields are absence assertions checked once against the node. The remaining patterns
    /// are matched against the children with full backtracking, honouring anchors, quantifiers,
    /// fields, groups and alternations, yielding one capture list per distinct successful assignment.
    private func matchChildren(
        _ patterns: [QueryPattern],
        of node: Syntax,
        captures: [QueryCapture]
    ) -> [[QueryCapture]] {
        for pattern in patterns {
            if case .negatedField(let label) = pattern {
                if node.children.contains(where: { $0.field == label }) { return [] }
            }
        }
        let elements = node.children
        let start = SequenceState(elementIndex: 0, captures: captures, consumedNamed: false)
        return matchSequence(patterns: patterns, patternIndex: 0, elements: elements, state: start)
            .map(\.captures)
    }

    /// Enumerates every way a suffix of child patterns matches a suffix of child elements.
    ///
    /// - Parameters:
    ///   - patterns: The full child-pattern list.
    ///   - patternIndex: The next pattern to satisfy.
    ///   - elements: The node's children.
    ///   - state: The current cursor, bound captures, and adjacency flag.
    /// - Returns: One end state per distinct way the remaining patterns are satisfied.
    private func matchSequence(
        patterns: [QueryPattern],
        patternIndex: Int,
        elements: [Syntax],
        state: SequenceState
    ) -> [SequenceState] {
        guard patternIndex < patterns.count else { return [state] }
        let pattern = patterns[patternIndex]

        switch pattern {
        case .negatedField:
            return matchSequence(
                patterns: patterns, patternIndex: patternIndex + 1, elements: elements, state: state)

        case .anchor:
            // A trailing anchor demands no further named child; otherwise it constrains the next match.
            if patternIndex == patterns.count - 1 {
                if elements[state.elementIndex...].contains(where: { $0.kind.isNamed }) { return [] }
                return [state]
            }
            return matchAnchored(
                patterns: patterns, patternIndex: patternIndex + 1, elements: elements, state: state)

        case .quantified(let inner, let quantifier):
            return matchQuantified(
                inner: inner, quantifier: quantifier, patterns: patterns,
                patternIndex: patternIndex, elements: elements, state: state)

        default:
            var results: [SequenceState] = []
            for placement in placements(of: pattern, in: elements, from: state) {
                results += matchSequence(
                    patterns: patterns, patternIndex: patternIndex + 1,
                    elements: elements, state: placement)
            }
            return results
        }
    }

    /// Continues matching where the next placed pattern must begin at the anchor position exactly.
    private func matchAnchored(
        patterns: [QueryPattern],
        patternIndex: Int,
        elements: [Syntax],
        state: SequenceState
    ) -> [SequenceState] {
        let pattern = patterns[patternIndex]
        // The anchored pattern may not skip over any named child before it matches.
        var results: [SequenceState] = []
        for placement in placements(of: pattern, in: elements, from: state, allowSkippingNamed: false) {
            results += matchSequence(
                patterns: patterns, patternIndex: patternIndex + 1, elements: elements, state: placement)
        }
        return results
    }

    /// Enumerates every position at which a single (non-anchor, non-quantifier) pattern can match,
    /// returning the state after consuming it.
    ///
    /// A group consumes a run of sibling elements; every other pattern consumes one element of the
    /// matching kind. Skipping over intervening anonymous children is always allowed; skipping over
    /// named children is allowed unless `allowSkippingNamed` is `false` (enforced after an anchor).
    private func placements(
        of pattern: QueryPattern,
        in elements: [Syntax],
        from state: SequenceState,
        allowSkippingNamed: Bool = true
    ) -> [SequenceState] {
        if case .group(let members) = pattern {
            return groupPlacements(
                members: members, elements: elements, from: state,
                allowSkippingNamed: allowSkippingNamed)
        }

        let wantsAnonymous = patternIsAnonymous(pattern)
        var results: [SequenceState] = []
        var cursor = state.elementIndex
        var skippedNamed = false
        while cursor < elements.count {
            // Adjacency (after an anchor) forbids placing the pattern past any skipped named child.
            if skippedNamed, !allowSkippingNamed { break }
            let element = elements[cursor]
            let candidateIsNamed = element.kind.isNamed
            let typesAgree = wantsAnonymous ? !candidateIsNamed : candidateIsNamed
            if typesAgree {
                for bound in matchNode(pattern: pattern, node: element, captures: state.captures) {
                    results.append(
                        SequenceState(
                            elementIndex: cursor + 1, captures: bound, consumedNamed: candidateIsNamed))
                }
            }
            if candidateIsNamed { skippedNamed = true }
            cursor += 1
        }
        return results
    }

    /// Enumerates every way a group's member patterns match a contiguous-enough run of siblings,
    /// starting at some position from `state`.
    private func groupPlacements(
        members: [QueryPattern],
        elements: [Syntax],
        from state: SequenceState,
        allowSkippingNamed: Bool
    ) -> [SequenceState] {
        var results: [SequenceState] = []
        var start = state.elementIndex
        while start <= elements.count {
            let inner = SequenceState(
                elementIndex: start, captures: state.captures, consumedNamed: state.consumedNamed)
            results += matchSequence(
                patterns: members, patternIndex: 0, elements: elements, state: inner)
            // When adjacency is required, the group may not begin past a skipped named child.
            if !allowSkippingNamed, start < elements.count, elements[start].kind.isNamed { break }
            start += 1
        }
        return results
    }

    /// Enumerates matches where a quantified child pattern consumes a run of consecutive repetitions.
    private func matchQuantified(
        inner: QueryPattern,
        quantifier: Quantifier,
        patterns: [QueryPattern],
        patternIndex: Int,
        elements: [Syntax],
        state: SequenceState
    ) -> [SequenceState] {
        // Greedily extend a single chain of repetitions, recording the state after each one. Each
        // repetition begins adjacently to the previous (no named child skipped between repetitions).
        var chain: [SequenceState] = [state]
        var current = state
        var first = true
        while true {
            let options = placements(
                of: inner, in: elements, from: current, allowSkippingNamed: first)
            guard let next = options.first else { break }
            current = next
            chain.append(current)
            first = false
            if !quantifier.allowsMany { break }
        }

        let minimum = quantifier.allowsZero ? 0 : 1
        var results: [SequenceState] = []
        // Longest chain first, so greedy quantifiers report the maximal binding before shorter ones.
        for count in stride(from: chain.count - 1, through: 0, by: -1) {
            if count < minimum { break }
            results += matchSequence(
                patterns: patterns, patternIndex: patternIndex + 1,
                elements: elements, state: chain[count])
        }
        return results
    }

    /// Whether a pattern targets an anonymous token rather than a named node.
    private func patternIsAnonymous(_ pattern: QueryPattern) -> Bool {
        switch pattern {
        case .anonymous:
            return true
        case .capture(_, let inner), .field(_, let inner), .quantified(let inner, _):
            return patternIsAnonymous(inner)
        case .alternation(let alternatives):
            return !alternatives.isEmpty && alternatives.allSatisfy(patternIsAnonymous)
        default:
            return false
        }
    }

    // MARK: - Predicates

    /// Gathers the predicates declared anywhere within a pattern.
    private func collectPredicates(_ pattern: QueryPattern) -> [Predicate] {
        switch pattern {
        case .node(_, let children, let predicates):
            return predicates + children.flatMap(collectPredicates)
        case .group(let members):
            return members.flatMap(collectPredicates)
        case .alternation(let alternatives):
            return alternatives.flatMap(collectPredicates)
        case .field(_, let inner), .capture(_, let inner), .quantified(let inner, _):
            return collectPredicates(inner)
        case .anyNode, .anyNamedNode, .anonymous, .negatedField, .anchor:
            return []
        }
    }
}
