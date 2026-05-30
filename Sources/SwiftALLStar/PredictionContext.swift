/// A graph-structured call stack used during adaptive prediction.
///
/// Prediction simulates the parser over many possible futures at once; the call stacks of those futures
/// are shared maximally as a directed acyclic graph so the configuration set stays linear in the input
/// length. The wildcard case stands for "any stack" and makes SLL prediction stack-insensitive, hence
/// cacheable; the empty case is the bottom of a concrete full-LL stack. A fork node represents the merge
/// of two stacks that share a common tail.
indirect enum PredictionContext: Hashable, Sendable {
    /// The empty stack (the bottom of a concrete full-LL stack).
    case empty
    /// The wildcard stack (`#`): "no stack information", used by stack-insensitive SLL prediction.
    case wildcard
    /// A stack whose top is a return state, over a parent stack.
    case node(returnState: ATNStateID, parent: PredictionContext)
    /// A merge of two or more distinct stacks sharing structure.
    case fork([PredictionContext])

    /// Whether this context is or contains the wildcard (so a return cannot be resolved concretely).
    var hasWildcard: Bool {
        switch self {
        case .wildcard: true
        case .empty: false
        case .node(_, let parent): parent.hasWildcard
        case .fork(let parts): parts.contains { $0.hasWildcard }
        }
    }
}

extension PredictionContext {
    /// Pushes a return state onto this stack.
    /// - Parameter returnState: The ATN state to return to when the called submachine stops.
    /// - Returns: A new context with `returnState` on top.
    func pushing(_ returnState: ATNStateID) -> PredictionContext {
        .node(returnState: returnState, parent: self)
    }

    /// The set of immediate tops of this stack with their parents, used to model a submachine return.
    ///
    /// A `node` yields its single top; a `fork` yields the tops of all its branches; `empty` and
    /// `wildcard` yield nothing concrete (the caller handles those terminal cases separately).
    ///
    /// - Returns: The `(returnState, parent)` pairs at the top of this stack.
    func tops() -> [(returnState: ATNStateID, parent: PredictionContext)] {
        switch self {
        case .empty, .wildcard:
            return []
        case .node(let returnState, let parent):
            return [(returnState, parent)]
        case .fork(let parts):
            return parts.flatMap { $0.tops() }
        }
    }

    /// Merges two stacks into one, sharing a common tail where possible.
    ///
    /// The wildcard absorbs everything (SLL); identical stacks collapse; otherwise the result is the
    /// canonical fork of the distinct branches.
    ///
    /// - Parameter other: The stack to merge with.
    /// - Returns: The merged stack.
    func merged(with other: PredictionContext) -> PredictionContext {
        if self == other { return self }
        if self == .wildcard || other == .wildcard { return .wildcard }
        var branches: [PredictionContext] = []
        func collect(_ context: PredictionContext) {
            if case .fork(let parts) = context { parts.forEach(collect) } else { branches.append(context) }
        }
        collect(self)
        collect(other)
        // Deduplicate while preserving order for a canonical, hashable representation.
        var seen: Set<PredictionContext> = []
        var unique: [PredictionContext] = []
        for branch in branches where seen.insert(branch).inserted { unique.append(branch) }
        if unique.count == 1 { return unique[0] }
        if unique.contains(.wildcard) { return .wildcard }
        return .fork(unique)
    }
}
