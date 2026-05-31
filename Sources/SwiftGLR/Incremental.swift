import ParsingCore

/// Maps a UTF-8 byte offset to the corresponding index in an input view.
///
/// Byte offsets are the framework's edit and span coordinate, but a non-UTF-8 granularity indexes by
/// scalars or grapheme clusters, so the offset is converted by walking the elements and summing their
/// UTF-8 widths until the target is reached. For the default UTF-8 view each element is one byte, so the
/// walk advances one position per byte.
///
/// - Parameters:
///   - byteOffset: The target UTF-8 byte offset.
///   - input: The input view to index into.
/// - Returns: The index at `byteOffset`, or `input.endIndex` if the offset is past the end.
func glrIndex<Input: ParserInput>(at byteOffset: Int, in input: Input) -> Input.Index {
    if byteOffset <= 0 { return input.startIndex }
    var index = input.startIndex
    var consumed = 0
    while consumed < byteOffset, index != input.endIndex {
        consumed += input[index].utf8Width
        input.formIndex(after: &index)
    }
    return index
}

/// Builds the final parse result from a completed parse outcome and forest.
///
/// This is the shared tail of every GLR parse: it collapses the forest to a single canonical tree (reusing
/// the previous parse's subtrees when a pool is supplied), records ambiguity diagnostics, recovers a
/// missing start rule, and attaches any trailing trivia or junk. Both the one-shot engine and the
/// incremental session route through it so their trees are byte-for-byte identical.
///
/// - Parameters:
///   - outcome: The parse loop's outcome.
///   - input: The parsed input view.
///   - sppf: The populated shared packed parse forest.
///   - tables: The parse tables.
///   - startRuleName: The start rule's name, used as the document node's kind.
///   - source: The source being parsed.
///   - reuse: A pool of the previous parse's subtrees to reuse, or `nil` for a fresh parse.
/// - Returns: The complete parse result.
func glrBuildResult<Input: ParserInput>(
    outcome: ParseOutcome<Input>, input: Input, sppf: SPPF, tables: GLRTables,
    startRuleName: String, source: Source, reuse: ReusePool?
) -> ParseResult {
    var builder = TreeBuilder(tables: tables, disambiguating: sppf.hasPacking, reusePool: reuse)
    var diagnostics: [Diagnostic] = []
    let documentKind = SyntaxKind(startRuleName, isNamed: true)

    var documentNode: GreenNode
    var resumeCursor: Input.Index
    var resumeOffset: Int

    if let root = outcome.completedRoot {
        let kids = builder.emitRoot(root)
        documentNode = GreenNode.node(documentKind, children: kids)
        resumeCursor = outcome.rootEndCursor
        resumeOffset = outcome.rootEndOffset
    } else {
        // Wholly unparseable input: recover with a MISSING value, matching the reference engine.
        diagnostics.append(
            .error(
                Recovery.missingStartMessage(startRule: startRuleName),
                at: .empty(at: outcome.endOffset)))
        documentNode = GreenNode.node(
            documentKind, children: [.init(node: .missingToken(Recovery.missingValueKind))])
        resumeCursor = input.startIndex
        resumeOffset = 0
    }

    for ambiguity in builder.ambiguities {
        diagnostics.append(
            Diagnostic(
                severity: .warning,
                message: "ambiguous parse of \(ambiguity.rule), resolved by the disambiguation policy",
                span: ambiguity.span))
    }

    documentNode = glrAppendTrailing(
        to: documentNode, input: input, tables: tables, from: resumeCursor, offset: resumeOffset,
        diagnostics: &diagnostics)

    return ParseResult(tree: Syntax(documentNode), source: source, diagnostics: diagnostics)
}

/// Appends trailing trivia or trailing junk to the document node, mirroring the reference engine.
///
/// Trivia after the completed parse is consumed first. If input remains, it becomes an `ERROR` node
/// carrying the residue with the trivia as leading trivia, and an error diagnostic. If only trivia remains,
/// it is attached to a zero-width carrier token so the tree round-trips losslessly.
///
/// - Parameters:
///   - documentNode: The document node to extend.
///   - input: The parsed input view.
///   - tables: The parse tables (for the trivia matchers).
///   - cursor: The cursor just past the completed parse.
///   - offset: The byte offset just past the completed parse, for diagnostics.
///   - diagnostics: The diagnostics to append to.
/// - Returns: The document node with any trailing content attached.
func glrAppendTrailing<Input: ParserInput>(
    to documentNode: GreenNode, input: Input, tables: GLRTables, from cursor: Input.Index, offset: Int,
    diagnostics: inout [Diagnostic]
) -> GreenNode {
    let lexer = Lexer<Input>(input: input, terminals: tables.terminals, extras: tables.extras)
    let (afterTrivia, trivia) = lexer.consumeTrivia(at: cursor)
    if afterTrivia != input.endIndex {
        diagnostics.append(.error(Recovery.trailingMessage, at: .empty(at: offset)))
        let junk = Input.text(of: input[afterTrivia..<input.endIndex])
        let errorToken = GreenNode.token(Recovery.errorTokenKind, text: junk, leadingTrivia: trivia)
        let errorNode = GreenNode.errorNode(children: [.init(node: errorToken)])
        return GreenNode.node(
            documentNode.kind, children: documentNode.children + [.init(node: errorNode)])
    } else if !trivia.isEmpty {
        let carrier = GreenNode.token(SyntaxKind("", isNamed: false), text: "", leadingTrivia: trivia)
        return GreenNode.node(
            documentNode.kind, children: documentNode.children + [.init(node: carrier)])
    }
    return documentNode
}

/// A reusable GLR parsing session that reparses successive edits by re-deriving only the changed suffix.
///
/// Where ``GLREngine/reparse(_:edits:previous:)`` keeps a full parse's work but reuses unchanged subtrees
/// at tree-construction time, a session additionally truncates the graph-structured stack and shared packed
/// parse forest to a sound, lexer-verified token boundary before the first edit and resumes parsing from
/// there, so the unchanged prefix is neither re-lexed into tokens nor re-reduced. Each ``result`` is
/// byte-for-byte what a full parse of the same source produces.
///
/// A session is single use: ``reparse(_:edits:)`` consumes the shared forest in place and returns the next
/// session to continue from. Continue editing through the returned session, not the previous one.
public final class IncrementalGLRParser<Input: ParserInput> {
    /// The most recent parse result; byte-for-byte identical to a full parse of the current source.
    public let result: ParseResult

    /// The parse tables shared with the originating engine.
    let tables: GLRTables
    /// The start rule's name, used as the document node's kind.
    let startRuleName: String
    /// The forest of the most recent parse, truncated and extended in place by the next reparse.
    let sppf: SPPF
    /// The per-level checkpoints of the most recent parse, in level order.
    let checkpoints: [Checkpoint]
    /// The text of the most recent source, for the no-op short-circuit.
    let sourceText: String

    init(
        result: ParseResult, tables: GLRTables, startRuleName: String, sppf: SPPF,
        checkpoints: [Checkpoint], sourceText: String
    ) {
        self.result = result
        self.tables = tables
        self.startRuleName = startRuleName
        self.sppf = sppf
        self.checkpoints = checkpoints
        self.sourceText = sourceText
    }

    /// Reparses an edited source, reusing the unchanged prefix of the previous parse.
    ///
    /// The returned session's ``result`` is byte-for-byte what a full parse of `source` would produce. The
    /// edits are used to locate the first changed byte; the unchanged token prefix before it, verified by
    /// re-lexing, is reused from the previous parse and only the suffix is re-derived.
    ///
    /// - Parameters:
    ///   - source: The edited source.
    ///   - edits: The edits that produced `source` from this session's source.
    /// - Returns: A new session to continue editing from.
    public func reparse(_ source: Source, edits: [TextEdit]) -> IncrementalGLRParser<Input> {
        if edits.isEmpty && source.text == sourceText { return self }

        let newInput = Input.make(from: source.text)
        let reuse = ReusePool(previous: result.tree.green)
        let firstEdit = edits.map { $0.startByte }.min() ?? 0

        let resumeLevel = safeResumeLevel(newInput: newInput, firstEdit: firstEdit)
        let resumeCheckpoint = checkpoints[resumeLevel]
        let boundary = resumeCheckpoint.byteOffset

        sppf.truncate(removingFrom: boundary)

        let parser = GLRParser<Input>(tables: tables, input: newInput)
        let recorder = CheckpointRecorder()
        let outcome: ParseOutcome<Input>
        if resumeLevel == 0 {
            // Nothing reusable: a full parse, still reusing subtrees at construction time.
            outcome = parser.run(sppf: sppf, recorder: recorder)
        } else {
            let resumePoint = ResumePoint<Input>(
                level: resumeLevel, byteOffset: boundary,
                cursor: glrIndex(at: boundary, in: newInput),
                frontier: deepCopyFrontier(resumeCheckpoint.frontier))
            outcome = parser.run(sppf: sppf, resume: resumePoint, recorder: recorder)
        }

        let newResult = glrBuildResult(
            outcome: outcome, input: newInput, sppf: sppf, tables: tables,
            startRuleName: startRuleName, source: source, reuse: reuse)
        let newCheckpoints = Array(checkpoints[0..<resumeLevel]) + recorder.checkpoints
        return IncrementalGLRParser(
            result: newResult, tables: tables, startRuleName: startRuleName, sppf: sppf,
            checkpoints: newCheckpoints, sourceText: source.text)
    }

    /// The level to resume from: the largest level whose entire token prefix re-lexes identically in the
    /// edited input and ends before the first edit, so its saved frontier and forest prefix are sound.
    ///
    /// Levels are confirmed from the start. A level is included only when its shifted token ends strictly
    /// before the first edit (so its bytes are unchanged) and re-lexing the edited input at the level's
    /// offset, under the same expected-terminal set, reproduces the recorded trivia and candidates. The
    /// re-lex check, rather than a byte comparison, is what catches a forward-scanning token whose terminator
    /// changed at the edit and a merge or split at the boundary: those re-lex differently and stop the scan.
    ///
    /// - Parameters:
    ///   - newInput: The edited input view.
    ///   - firstEdit: The byte offset of the first edit.
    /// - Returns: The level index to resume at (zero means a full reparse).
    private func safeResumeLevel(newInput: Input, firstEdit: Int) -> Int {
        let lexer = Lexer<Input>(input: newInput, terminals: tables.terminals, extras: tables.extras)
        let shiftLevels = checkpoints.count - 1
        var resumeLevel = 0
        var level = 0
        while level < shiftLevels {
            let checkpoint = checkpoints[level]
            let tokenEnd =
                checkpoint.byteOffset + checkpoint.triviaByteLength + checkpoint.advanceByteLength
            // A token reaching the edit could lex differently now; stop before it.
            if tokenEnd > firstEdit { break }

            var expected: Set<Int> = []
            for node in checkpoint.frontier.values {
                for terminal in tables.shift[node.state].keys { expected.insert(terminal) }
                for terminal in tables.reduce[node.state].keys where terminal >= 0 {
                    expected.insert(terminal)
                }
            }
            let cursor = glrIndex(at: checkpoint.byteOffset, in: newInput)
            let (matches, _, triviaByteLength) = lexer.candidates(at: cursor, expected: expected)
            let signature = matches.map {
                TokenMatchSig(terminalID: $0.terminalID, byteLength: $0.byteLength)
            }.sorted()
            // The boundary holds only if the trivia and the recognised candidates are exactly as before.
            if triviaByteLength != checkpoint.triviaByteLength || signature != checkpoint.matches {
                break
            }
            resumeLevel = level + 1
            level += 1
        }
        return resumeLevel
    }
}

extension GLREngine {
    /// Begins an incremental parsing session for a source.
    ///
    /// The session's ``IncrementalGLRParser/result`` is a full parse of `source`; subsequent edits are
    /// applied with ``IncrementalGLRParser/reparse(_:edits:)``, which reuses the unchanged prefix.
    ///
    /// - Parameter source: The source to parse.
    /// - Returns: A new incremental parsing session.
    public func incrementalParse(_ source: Source) -> IncrementalGLRParser<Input> {
        let input = Input.make(from: source.text)
        let sppf = SPPF()
        let parser = GLRParser<Input>(tables: tables, input: input)
        let recorder = CheckpointRecorder()
        let outcome = parser.run(sppf: sppf, recorder: recorder)
        let result = glrBuildResult(
            outcome: outcome, input: input, sppf: sppf, tables: tables,
            startRuleName: startRuleName, source: source, reuse: nil)
        return IncrementalGLRParser(
            result: result, tables: tables, startRuleName: startRuleName, sppf: sppf,
            checkpoints: recorder.checkpoints, sourceText: source.text)
    }
}
