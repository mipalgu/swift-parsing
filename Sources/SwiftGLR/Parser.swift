import ParsingCore

/// The outcome of driving the RNGLR parse loop.
///
/// `completedRoot` references the start-symbol forest node once the start rule has been fully derived.
/// When the loop reaches end of input with such a root, `acceptedAtEnd` is `true` and the parse is
/// clean; when it stalls earlier with a root already completed, the residue is trailing input the
/// caller turns into an error node, mirroring the reference engine.
struct ParseOutcome<Input: ParserInput> {
    /// The start-symbol forest node, once the start rule is fully derived, or `nil` if never reached.
    let completedRoot: SPPFNode?
    /// Whether the parse reached an accepting configuration at end of input.
    let acceptedAtEnd: Bool
    /// The byte offset reached when the parse finished or stalled.
    let endOffset: Int
    /// The input index reached when the parse finished or stalled.
    let endCursor: Input.Index
    /// The byte offset of the start-symbol root's end, when one was completed.
    let rootEndOffset: Int
    /// The input index just past the completed start-symbol root, when one was completed.
    let rootEndCursor: Input.Index
}

/// Drives the Right-Nulled GLR parse loop over a graph-structured stack and shared packed parse forest.
///
/// Each input step recognises the candidate terminals legal in the live states, drains all reductions
/// (including right-nulled ones) to a fixed point at the current level, then shifts to the next level.
/// Graph-structured-stack vertex merging and edge deduplication guarantee the reduction fixed point
/// terminates even for epsilon and hidden-recursive grammars. The loop never throws.
struct GLRParser<Input: ParserInput> {
    let tables: GLRTables
    let lexer: Lexer<Input>
    let input: Input

    /// A pending reduction to apply at the current level.
    ///
    /// For a reduction of length one or more the task is anchored to the first edge of its path
    /// (`viaEdge`), so that an edge added after the node's reductions were already processed still
    /// contributes its derivations. This per-edge anchoring is the RNGLR correctness condition that
    /// makes right recursion and hidden recursion derive completely.
    private struct ReductionTask {
        let from: GSSNode
        let action: ReduceAction
        let viaEdge: GSSEdge?
    }

    /// A pending shift to apply when building the next level.
    private struct ShiftTask {
        let from: GSSNode
        let to: Int
        let match: LexMatch<Input>
    }

    private struct ReductionKey: Hashable {
        let node: ObjectIdentifier
        let production: Int
        let length: Int
        let viaTarget: ObjectIdentifier?
        let viaSPPF: ObjectIdentifier?
    }

    private struct ShiftKey: Hashable {
        let node: ObjectIdentifier
        let to: Int
        let terminal: Int
    }

    /// Per-step mutable state threaded through reduction and shifting.
    private final class Step {
        var reductionQueue: [ReductionTask] = []
        var shiftTasks: [ShiftTask] = []
        var enqueuedReductions: Set<ReductionKey> = []
        var seededShift: Set<ShiftKey> = []
    }

    /// Creates a parser bound to prepared tables and an input view.
    ///
    /// - Parameters:
    ///   - tables: The immutable parse tables.
    ///   - input: The input view to parse.
    init(tables: GLRTables, input: Input) {
        self.tables = tables
        self.input = input
        self.lexer = Lexer(input: input, terminals: tables.terminals, extras: tables.extras)
    }

    /// Runs the parse loop over the whole input.
    ///
    /// - Parameter sppf: The forest to populate; the tree builder reads it afterward.
    /// - Returns: The parse outcome, including the completed start-symbol root, if any.
    func run(sppf: SPPF) -> ParseOutcome<Input> {
        let gss = GSS()
        var byteOffset = 0
        var level = 0
        var cursor = input.startIndex
        _ = gss.node(state: tables.startState, level: 0)

        var completedRoot: SPPFNode? = nil
        var rootEndOffset = 0
        var rootEndCursor = cursor

        while true {
            // The lexer must try every terminal the live states could act on: those they can shift now,
            // and those that key a reduction (so an epsilon or right-nulled reduction whose lookahead is
            // a not-yet-shiftable terminal still fires).
            var expected: Set<Int> = []
            for node in gss.frontier.values {
                for terminal in tables.shiftableTerminals(state: node.state) { expected.insert(terminal) }
                for terminal in tables.reduceLookaheads(state: node.state) where terminal >= 0 {
                    expected.insert(terminal)
                }
            }
            let (matches, afterTrivia) = lexer.candidates(at: cursor, expected: expected)
            let atEnd = afterTrivia == input.endIndex
            let triviaBytes = byteOffset + bytes(from: cursor, to: afterTrivia)

            var lookaheads: Set<Int> = Set(matches.map { $0.terminalID })
            if atEnd || matches.isEmpty { lookaheads.insert(LR0Automaton.endOfInputKey) }

            let step = Step()
            for node in gss.frontier.values {
                seed(node: node, matches: matches, lookaheads: lookaheads, step: step)
            }
            // Empty and nullable reductions anchor at the pre-trivia offset (the end of the last real
            // token), so an empty production placed before a lookahead's leading trivia gets the same
            // span however it is reached. This keeps the forest free of spurious trivia-boundary
            // duplicates that would otherwise read as ambiguities.
            drainReductions(
                step: step, gss: gss, sppf: sppf, level: level, contentOffset: byteOffset,
                matches: matches, lookaheads: lookaheads)

            // Detect a freshly completed start-symbol root reachable on end-of-input. The root spans up
            // to the last shifted token, so any trivia consumed this step is trailing: resume from the
            // pre-trivia cursor so the engine can attach that trivia losslessly.
            if let root = startRoot(in: gss) {
                if completedRoot == nil || root.end >= rootEndOffset {
                    completedRoot = root
                    rootEndOffset = byteOffset
                    rootEndCursor = cursor
                }
            }

            if atEnd {
                let accepted = completedRoot != nil
                return ParseOutcome(
                    completedRoot: completedRoot, acceptedAtEnd: accepted, endOffset: triviaBytes,
                    endCursor: afterTrivia, rootEndOffset: rootEndOffset, rootEndCursor: rootEndCursor)
            }

            if step.shiftTasks.isEmpty {
                return ParseOutcome(
                    completedRoot: completedRoot, acceptedAtEnd: false, endOffset: triviaBytes,
                    endCursor: afterTrivia, rootEndOffset: rootEndOffset, rootEndCursor: rootEndCursor)
            }

            let chosen = disambiguateLexically(step.shiftTasks)
            let nextLevel = level + 1
            var newFrontier: [Int: GSSNode] = [:]
            var advancedMatch: LexMatch<Input>? = nil
            for task in chosen {
                let match = task.match
                advancedMatch = match
                let leaf = LexLeaf(
                    terminalID: match.terminalID, text: match.text, leadingTrivia: match.leadingTrivia)
                let leafNode = sppf.terminalNode(
                    terminalID: match.terminalID, start: byteOffset, end: triviaBytes + match.byteLength,
                    leaf: leaf)
                let target: GSSNode
                if let existing = newFrontier[task.to] {
                    target = existing
                } else {
                    target = GSSNode(state: task.to, level: nextLevel)
                    newFrontier[task.to] = target
                }
                gss.addEdge(from: target, to: task.from, sppf: leafNode)
            }
            gss.advance(to: newFrontier)

            guard let match = advancedMatch else {
                return ParseOutcome(
                    completedRoot: completedRoot, acceptedAtEnd: false, endOffset: triviaBytes,
                    endCursor: afterTrivia, rootEndOffset: rootEndOffset, rootEndCursor: rootEndCursor)
            }
            byteOffset = triviaBytes + match.byteLength
            cursor = match.endIndex
            level = nextLevel
        }
    }

    // MARK: - Seeding and draining

    private func seed(
        node: GSSNode, matches: [LexMatch<Input>], lookaheads: Set<Int>, step: Step
    ) {
        enqueueReductions(at: node, alongEdge: nil, lookaheads: lookaheads, step: step)
        enqueueShifts(at: node, matches: matches, step: step)
    }

    /// Enqueues the reductions enabled at a node.
    ///
    /// Length-zero reductions are enqueued once per node; longer reductions are anchored to each
    /// outgoing edge so that an edge added later still contributes. When `alongEdge` is given, only
    /// that edge is considered for the longer reductions; otherwise every current edge is.
    private func enqueueReductions(
        at node: GSSNode, alongEdge: GSSEdge?, lookaheads: Set<Int>, step: Step
    ) {
        for la in lookaheads {
            for action in tables.reductions(state: node.state, terminal: la) {
                if action.length == 0 {
                    let key = ReductionKey(
                        node: ObjectIdentifier(node), production: action.production, length: 0,
                        viaTarget: nil, viaSPPF: nil)
                    if step.enqueuedReductions.insert(key).inserted {
                        step.reductionQueue.append(
                            ReductionTask(from: node, action: action, viaEdge: nil))
                    }
                } else {
                    let edges = alongEdge.map { [$0] } ?? node.edges
                    for edge in edges {
                        let key = ReductionKey(
                            node: ObjectIdentifier(node), production: action.production,
                            length: action.length, viaTarget: ObjectIdentifier(edge.target),
                            viaSPPF: ObjectIdentifier(edge.sppf))
                        if step.enqueuedReductions.insert(key).inserted {
                            step.reductionQueue.append(
                                ReductionTask(from: node, action: action, viaEdge: edge))
                        }
                    }
                }
            }
        }
    }

    private func enqueueShifts(at node: GSSNode, matches: [LexMatch<Input>], step: Step) {
        for match in matches {
            if let target = tables.shiftTarget(state: node.state, terminal: match.terminalID) {
                let key = ShiftKey(
                    node: ObjectIdentifier(node), to: target, terminal: match.terminalID)
                if step.seededShift.insert(key).inserted {
                    step.shiftTasks.append(ShiftTask(from: node, to: target, match: match))
                }
            }
        }
    }

    private func drainReductions(
        step: Step, gss: GSS, sppf: SPPF, level: Int, contentOffset: Int,
        matches: [LexMatch<Input>], lookaheads: Set<Int>
    ) {
        var index = 0
        while index < step.reductionQueue.count {
            let task = step.reductionQueue[index]
            index += 1
            applyReduction(
                task, gss: gss, sppf: sppf, level: level, contentOffset: contentOffset,
                matches: matches, lookaheads: lookaheads, step: step)
        }
    }

    private func applyReduction(
        _ task: ReductionTask, gss: GSS, sppf: SPPF, level: Int, contentOffset: Int,
        matches: [LexMatch<Input>], lookaheads: Set<Int>, step: Step
    ) {
        let production = tables.productions[task.action.production]
        let nt = production.lhs

        // Enumerate the reduction paths. A length-zero reduction starts and ends at the node itself; a
        // longer reduction is anchored to its first edge and walks the remaining length from there.
        let enumerated: [(labels: [SPPFNode], base: GSSNode)]
        if let edge = task.viaEdge {
            enumerated = gss.paths(from: edge.target, length: task.action.length - 1).map {
                ($0.labels + [edge.sppf], $0.base)
            }
        } else {
            enumerated = gss.paths(from: task.from, length: task.action.length)
        }

        for path in enumerated {
            let base = path.base
            guard let goState = tables.goto[base.state][nt] else { continue }

            var children = path.labels
            let suffixOffset = children.last?.end ?? contentOffset
            for symbol in task.action.nullableSuffix {
                children.append(nullableSubtree(for: symbol, at: suffixOffset, sppf: sppf))
            }
            let start = children.first?.start ?? contentOffset
            let end = children.last?.end ?? contentOffset

            let (ntNode, _) = sppf.nonterminalNode(nt: nt, start: start, end: end)
            sppf.addFamily(to: ntNode, production: task.action.production, children: children)

            let (target, isNewNode) = gss.node(state: goState, level: level)
            let edgeIsNew = gss.addEdge(from: target, to: base, sppf: ntNode)

            if isNewNode {
                // A brand-new node: enqueue its length-zero reductions, the length-one-or-more
                // reductions along its (single, new) edge, and its shifts.
                enqueueReductions(at: target, alongEdge: nil, lookaheads: lookaheads, step: step)
                enqueueShifts(at: target, matches: matches, step: step)
            } else if edgeIsNew {
                // An existing node gained an edge: re-process only the reductions along that edge.
                enqueueReductions(
                    at: target, alongEdge: target.edges.last, lookaheads: lookaheads, step: step)
            }
        }
    }

    // MARK: - Helpers

    /// The start-symbol forest node held on an accepting frontier vertex, if any.
    private func startRoot(in gss: GSS) -> SPPFNode? {
        var best: SPPFNode? = nil
        for node in gss.frontier.values where tables.accepting[node.state] {
            for edge in node.edges {
                if case .nonterminal(let nt, _, _) = edge.sppf.label, nt == tables.userStartID {
                    if best == nil || edge.sppf.end > best!.end { best = edge.sppf }
                }
            }
        }
        return best
    }

    private func nullableSubtree(for symbol: Symbol, at offset: Int, sppf: SPPF) -> SPPFNode {
        switch symbol {
        case .nonterminal(let nt):
            let (node, isNew) = sppf.nonterminalNode(nt: nt, start: offset, end: offset)
            if isNew {
                if let emptyID = emptyProduction(of: nt) {
                    sppf.addFamily(to: node, production: emptyID, children: [])
                } else {
                    sppf.addFamily(to: node, production: nil, children: [])
                }
            }
            return node
        case .terminal, .endOfInput:
            return sppf.epsilonNode(at: offset)
        }
    }

    private func emptyProduction(of nt: Int) -> Int? {
        for (id, production) in tables.productions.enumerated()
        where production.lhs == nt && production.rhs.isEmpty {
            return id
        }
        for (id, production) in tables.productions.enumerated()
        where production.lhs == nt && !production.rhs.isEmpty
            && production.rhs.allSatisfy({ tables.nullableSymbol($0) }) {
            return id
        }
        return nil
    }

    /// Chooses the surviving shifts under the longest-match policy.
    private func disambiguateLexically(_ tasks: [ShiftTask]) -> [ShiftTask] {
        guard let maxLength = tasks.map({ $0.match.byteLength }).max() else { return [] }
        let longest = tasks.filter { $0.match.byteLength == maxLength }
        let terminalIDs = Set(longest.map { $0.match.terminalID })
        if terminalIDs.count == 1 { return longest }
        let chosenTerminal = terminalIDs.sorted().first!
        return longest.filter { $0.match.terminalID == chosenTerminal }
    }

    private func bytes(from start: Input.Index, to end: Input.Index) -> Int {
        guard start != end else { return 0 }
        return Input.text(of: input[start..<end]).utf8.count
    }
}
