import ParsingCore

/// A lexer signature for one input level: a terminal recognised at the level and its content byte length.
///
/// A reparse re-lexes the edited input at a reused position and compares the candidates it recognises to
/// the recorded ones; equality (together with matching trivia) proves the token boundary still holds in the
/// edited input, so the saved parser configuration at that point is sound to resume from. This verifies
/// boundaries rather than assuming them, which is what makes resumption correct across token merges, splits
/// and re-opened forward-scanning tokens such as strings and comments.
struct TokenMatchSig: Hashable, Comparable {
    /// The recognised terminal's id.
    let terminalID: Int
    /// The match's content length in UTF-8 bytes.
    let byteLength: Int

    static func < (lhs: TokenMatchSig, rhs: TokenMatchSig) -> Bool {
        lhs.terminalID != rhs.terminalID
            ? lhs.terminalID < rhs.terminalID : lhs.byteLength < rhs.byteLength
    }
}

/// A saved parser configuration at the top of one input level, captured for incremental resumption.
///
/// It records the byte offset reached, a deep copy of the post-shift frontier, and the lexer outcome at the
/// level (the trivia consumed, the candidates recognised, and the byte length of the token shifted out). A
/// reparse uses the lexer outcome to verify the prefix is unchanged and the frontier to resume from it.
final class Checkpoint {
    /// The byte offset reached at this level: the end of the previously shifted token's content.
    let byteOffset: Int
    /// A deep copy of the post-shift graph-structured-stack frontier at this level.
    let frontier: [Int: GSSNode]
    /// The byte length of the trivia consumed before this level's lookahead token.
    var triviaByteLength: Int = 0
    /// The byte length of the token shifted out of this level (zero at the final, end-of-input level).
    var advanceByteLength: Int = 0
    /// The lexer candidates recognised at this level, sorted, used to verify the boundary on reparse.
    var matches: [TokenMatchSig] = []

    init(byteOffset: Int, frontier: [Int: GSSNode]) {
        self.byteOffset = byteOffset
        self.frontier = frontier
    }
}

/// Collects the per-level checkpoints of a parse so a later edit can resume from an unchanged prefix.
final class CheckpointRecorder {
    /// The checkpoints in level order, one per input level including the final end-of-input level.
    var checkpoints: [Checkpoint] = []
}

/// A point from which to resume a parse: the level, byte offset, input cursor and frontier to restore.
struct ResumePoint<Input: ParserInput> {
    /// The input level to resume at.
    let level: Int
    /// The byte offset to resume at.
    let byteOffset: Int
    /// The input cursor in the edited input at `byteOffset`.
    let cursor: Input.Index
    /// The frontier to restore (the saved post-shift frontier for the level).
    let frontier: [Int: GSSNode]
}

/// Deep-copies a frontier so a snapshot keeps the edge set it had when the snapshot was taken.
///
/// Each vertex is duplicated with its current edges; the edges' predecessor vertices and forest labels are
/// shared, because they belong to already-finished levels and are never mutated again. A later append to a
/// live vertex's edges triggers copy-on-write on its array and so leaves the snapshot untouched. The copy
/// is essential because a level's reductions merge fresh goto vertices into the live frontier after the
/// snapshot, which would otherwise pollute a configuration meant to be frozen.
func deepCopyFrontier(_ frontier: [Int: GSSNode]) -> [Int: GSSNode] {
    var copy: [Int: GSSNode] = [:]
    copy.reserveCapacity(frontier.count)
    for (state, node) in frontier {
        let duplicate = GSSNode(state: node.state, level: node.level)
        duplicate.edges = node.edges
        copy[state] = duplicate
    }
    return copy
}

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
    ///
    /// A single instance is reused across input steps; ``reset()`` clears its collections while
    /// retaining their backing storage, so the steady-state parse loop performs no per-step set or
    /// array reallocation.
    private final class Step {
        var reductionQueue: [ReductionTask] = []
        var shiftTasks: [ShiftTask] = []
        var enqueuedReductions: Set<ReductionKey> = []
        var seededShift: Set<ShiftKey> = []

        func reset() {
            reductionQueue.removeAll(keepingCapacity: true)
            shiftTasks.removeAll(keepingCapacity: true)
            enqueuedReductions.removeAll(keepingCapacity: true)
            seededShift.removeAll(keepingCapacity: true)
        }
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
    func run(
        sppf: SPPF, resume: ResumePoint<Input>? = nil, recorder: CheckpointRecorder? = nil
    ) -> ParseOutcome<Input> {
        let gss = GSS()
        var byteOffset: Int
        var level: Int
        var cursor: Input.Index
        if let resume {
            gss.resume(from: resume.frontier)
            byteOffset = resume.byteOffset
            level = resume.level
            cursor = resume.cursor
        } else {
            byteOffset = 0
            level = 0
            cursor = input.startIndex
            _ = gss.node(state: tables.startState, level: 0)
        }

        var completedRoot: SPPFNode? = nil
        var rootEndOffset = 0
        var rootEndCursor = cursor
        let step = Step()

        while true {
            // Record a checkpoint of the live frontier at the top of the loop, before this level's
            // reductions merge goto vertices into it. The deep copy freezes the post-shift edge set so a
            // later reparse can resume from exactly this configuration.
            let checkpoint: Checkpoint?
            if let recorder {
                let saved = Checkpoint(byteOffset: byteOffset, frontier: deepCopyFrontier(gss.frontier))
                recorder.checkpoints.append(saved)
                checkpoint = saved
            } else {
                checkpoint = nil
            }

            // The lexer must try every terminal the live states could act on: those they can shift now,
            // and those that key a reduction (so an epsilon or right-nulled reduction whose lookahead is
            // a not-yet-shiftable terminal still fires).
            var expected: Set<Int> = []
            for node in gss.frontier.values {
                for terminal in tables.shift[node.state].keys { expected.insert(terminal) }
                for terminal in tables.reduce[node.state].keys where terminal >= 0 {
                    expected.insert(terminal)
                }
            }
            let (matches, afterTrivia, triviaByteLength) = lexer.candidates(
                at: cursor, expected: expected)
            let atEnd = afterTrivia == input.endIndex
            let triviaBytes = byteOffset + triviaByteLength

            if let checkpoint {
                checkpoint.triviaByteLength = triviaByteLength
                checkpoint.matches = matches.map {
                    TokenMatchSig(terminalID: $0.terminalID, byteLength: $0.byteLength)
                }.sorted()
            }

            var lookaheads: Set<Int> = []
            lookaheads.reserveCapacity(matches.count + 1)
            for match in matches { lookaheads.insert(match.terminalID) }
            if atEnd || matches.isEmpty { lookaheads.insert(LR0Automaton.endOfInputKey) }

            step.reset()
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
            checkpoint?.advanceByteLength = match.byteLength
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
        let nodeID = ObjectIdentifier(node)
        for la in lookaheads {
            for action in tables.reductions(state: node.state, terminal: la) {
                if action.length == 0 {
                    let key = ReductionKey(
                        node: nodeID, production: action.production, length: 0,
                        viaTarget: nil, viaSPPF: nil)
                    if step.enqueuedReductions.insert(key).inserted {
                        step.reductionQueue.append(
                            ReductionTask(from: node, action: action, viaEdge: nil))
                    }
                } else if let edge = alongEdge {
                    enqueueEdgeReduction(
                        node: node, nodeID: nodeID, action: action, edge: edge, step: step)
                } else {
                    for edge in node.edges {
                        enqueueEdgeReduction(
                            node: node, nodeID: nodeID, action: action, edge: edge, step: step)
                    }
                }
            }
        }
    }

    /// Enqueues a length-one-or-more reduction anchored to a single outgoing edge, deduplicating it.
    private func enqueueEdgeReduction(
        node: GSSNode, nodeID: ObjectIdentifier, action: ReduceAction, edge: GSSEdge, step: Step
    ) {
        let key = ReductionKey(
            node: nodeID, production: action.production, length: action.length,
            viaTarget: ObjectIdentifier(edge.target), viaSPPF: ObjectIdentifier(edge.sppf))
        if step.enqueuedReductions.insert(key).inserted {
            step.reductionQueue.append(ReductionTask(from: node, action: action, viaEdge: edge))
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
        // longer reduction is anchored to its first edge and walks the remaining length from there. The
        // anchoring edge's label, when present, is the last child (closest to the stack top).
        let anchor = task.viaEdge?.sppf
        let walkFrom = task.viaEdge?.target ?? task.from
        let walkLength = task.viaEdge != nil ? task.action.length - 1 : task.action.length

        gss.forEachPath(from: walkFrom, length: walkLength) { labels, base in
            guard let goState = tables.gotoTarget(state: base.state, nonterminal: nt) else { return }

            var children: [SPPFNode]
            if let anchor {
                children = labels
                children.append(anchor)
            } else {
                children = labels
            }
            let suffixOffset = children.last?.end ?? contentOffset
            for symbol in task.action.nullableSuffix {
                children.append(self.nullableSubtree(for: symbol, at: suffixOffset, sppf: sppf))
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
                self.enqueueReductions(at: target, alongEdge: nil, lookaheads: lookaheads, step: step)
                self.enqueueShifts(at: target, matches: matches, step: step)
            } else if edgeIsNew {
                // An existing node gained an edge: re-process only the reductions along that edge.
                self.enqueueReductions(
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
            && production.rhs.allSatisfy({ tables.nullableSymbol($0) })
        {
            return id
        }
        return nil
    }

    /// Chooses the surviving shifts under the longest-match policy.
    private func disambiguateLexically(_ tasks: [ShiftTask]) -> [ShiftTask] {
        if tasks.isEmpty { return [] }
        if tasks.count == 1 { return tasks }

        // Longest byte length wins; among equally long, the lowest terminal id is chosen.
        var maxLength = 0
        for task in tasks where task.match.byteLength > maxLength { maxLength = task.match.byteLength }

        // Determine whether the longest matches already agree on one terminal, tracking its lowest id.
        var lowestTerminal = Int.max
        var singleTerminal = true
        for task in tasks where task.match.byteLength == maxLength {
            let id = task.match.terminalID
            if lowestTerminal == Int.max {
                lowestTerminal = id
            } else if id != lowestTerminal {
                singleTerminal = false
                if id < lowestTerminal { lowestTerminal = id }
            }
        }

        var result: [ShiftTask] = []
        result.reserveCapacity(tasks.count)
        for task in tasks where task.match.byteLength == maxLength {
            if singleTerminal || task.match.terminalID == lowestTerminal { result.append(task) }
        }
        return result
    }
}
