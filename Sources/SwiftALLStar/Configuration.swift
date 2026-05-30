/// A single ALL(*) configuration: a point in the simulated parse.
///
/// A configuration records the ATN state currently reached, the alternative (1-based, in production
/// order) the simulation is exploring, and the call stack at that point. The minimum precedence is
/// threaded through so left-recursion guard predicates can be evaluated on the full-LL path.
struct ATNConfig: Hashable, Sendable {
    /// The ATN state this configuration has reached.
    let state: ATNStateID
    /// The alternative being explored (1-based, in production order).
    let alt: Int
    /// The call stack at this point in the simulation.
    let context: PredictionContext
    /// The minimum operator precedence in force, for left-recursion guard predicates.
    let minPrecedence: Int

    /// Creates a configuration.
    init(state: ATNStateID, alt: Int, context: PredictionContext, minPrecedence: Int = 0) {
        self.state = state
        self.alt = alt
        self.context = context
        self.minPrecedence = minPrecedence
    }

    /// A copy of this configuration relocated to a new state and stack.
    /// - Parameters:
    ///   - state: The new ATN state.
    ///   - context: The new call stack.
    /// - Returns: A configuration with the same alternative and precedence.
    func at(state: ATNStateID, context: PredictionContext) -> ATNConfig {
        ATNConfig(state: state, alt: alt, context: context, minPrecedence: minPrecedence)
    }
}

/// A set of ALL(*) configurations explored together at one prediction step.
///
/// Insertion preserves order (so derived DFA states have a stable identity) and deduplicates exact
/// configurations, merging the call stacks of configurations that agree on state, alternative and
/// precedence. The set is the unit the lookahead DFA caches.
struct ConfigSet: Hashable, Sendable {
    /// The configurations, in insertion order, deduplicated.
    private(set) var configs: [ATNConfig] = []
    /// An index for O(1) membership and stack-merge, keyed by the merge identity of a configuration.
    private var index: [MergeKey: Int] = [:]

    /// The identity under which two configurations merge their call stacks.
    private struct MergeKey: Hashable {
        let state: ATNStateID
        let alt: Int
        let minPrecedence: Int
    }

    /// Whether the set holds no configurations.
    var isEmpty: Bool { configs.isEmpty }

    /// The distinct alternatives any configuration in the set is exploring.
    var alternatives: Set<Int> { Set(configs.map(\.alt)) }

    /// Inserts a configuration, merging call stacks with any configuration of the same merge identity.
    /// - Parameter config: The configuration to add.
    mutating func insert(_ config: ATNConfig) {
        let key = MergeKey(state: config.state, alt: config.alt, minPrecedence: config.minPrecedence)
        if let existing = index[key] {
            let merged = configs[existing].context.merged(with: config.context)
            configs[existing] = configs[existing].at(state: config.state, context: merged)
        } else {
            index[key] = configs.count
            configs.append(config)
        }
    }

    /// Hashes the set by its configurations only (the index is derived).
    func hash(into hasher: inout Hasher) {
        hasher.combine(configs)
    }

    /// Equates two sets by their configurations only.
    static func == (lhs: ConfigSet, rhs: ConfigSet) -> Bool {
        lhs.configs == rhs.configs
    }
}
