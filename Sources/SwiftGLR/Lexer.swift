import ParsingCore

/// A recognised terminal at a cursor position, with the text and leading trivia needed for a lossless leaf.
///
/// The lexer recognises candidate terminals scannerlessly at the cursor, after consuming trivia. A
/// match records which terminal matched, where it ends, its byte length, its content text, and the
/// trivia that preceded it, so the tree builder can emit a leaf byte-identical to the reference engine.
struct LexMatch<Input: ParserInput> {
    /// The matched terminal's id.
    let terminalID: Int
    /// The input index one past the match.
    let endIndex: Input.Index
    /// The match's content length in UTF-8 bytes.
    let byteLength: Int
    /// The match's content text.
    let text: String
    /// The trivia consumed immediately before the match.
    let leadingTrivia: String
    /// The byte length of the consumed leading trivia.
    let triviaByteLength: Int
}

/// Scannerless, state-directed terminal recognition over a `ParserInput`.
///
/// Because terminals are token matchers applied at the cursor rather than pre-lexed tokens, the lexer
/// recognises only the terminals the parser can actually shift in its live states, consuming trivia
/// first exactly as the reference engine does. Its matcher interpreter is a verbatim copy of the
/// recursive-descent engine's, so trivia boundaries and token extents agree byte-for-byte, which is a
/// prerequisite for byte-identical S-expressions and lossless round-tripping.
struct Lexer<Input: ParserInput> {
    let input: Input
    let terminals: [Terminal]
    let extras: [TokenMatcher]

    /// Creates a lexer over an input view.
    ///
    /// - Parameters:
    ///   - input: The input view.
    ///   - terminals: The terminal table from the parse tables.
    ///   - extras: The trivia matchers.
    init(input: Input, terminals: [Terminal], extras: [TokenMatcher]) {
        self.input = input
        self.terminals = terminals
        self.extras = extras
    }

    /// Consumes a run of trivia at a position, returning where it ends and the consumed text.
    ///
    /// - Parameter start: The cursor position.
    /// - Returns: The index past the trivia and the trivia text.
    func consumeTrivia(at start: Input.Index) -> (end: Input.Index, text: String) {
        var cursor = start
        scanning: while cursor != input.endIndex {
            for extra in extras {
                if let end = match(extra, at: cursor), end != cursor {
                    cursor = end
                    continue scanning
                }
            }
            break
        }
        return (cursor, Input.text(of: input[start..<cursor]))
    }

    /// Recognises the candidate terminals from an expected set at a position.
    ///
    /// Trivia is consumed first; then each expected terminal's matcher is applied at the post-trivia
    /// cursor. Successful matches are returned with their extents and the shared leading trivia.
    ///
    /// - Parameters:
    ///   - start: The cursor position.
    ///   - expected: The terminal ids the parser can shift in its current states.
    /// - Returns: The recognised matches (possibly empty) and the index where trivia ended.
    func candidates(
        at start: Input.Index, expected: Set<Int>
    ) -> (matches: [LexMatch<Input>], afterTrivia: Input.Index) {
        let (afterTrivia, trivia) = consumeTrivia(at: start)
        let triviaBytes = trivia.utf8.count
        var matches: [LexMatch<Input>] = []
        for terminalID in expected {
            guard let end = match(terminals[terminalID].matcher, at: afterTrivia) else { continue }
            let text = Input.text(of: input[afterTrivia..<end])
            matches.append(
                LexMatch(
                    terminalID: terminalID, endIndex: end, byteLength: text.utf8.count, text: text,
                    leadingTrivia: trivia, triviaByteLength: triviaBytes))
        }
        return (matches, afterTrivia)
    }

    // MARK: - Matcher interpreter (kept byte-identical to the recursive-descent engine)

    /// Matches a token matcher at a position, returning the end index of the longest match, or `nil`.
    func match(_ matcher: TokenMatcher, at start: Input.Index) -> Input.Index? {
        switch matcher {
        case .literal(let text):
            var cursor = start
            for element in Input.elements(of: text) {
                guard cursor != input.endIndex, input[cursor] == element else { return nil }
                input.formIndex(after: &cursor)
            }
            return cursor

        case .anyElement:
            guard start != input.endIndex else { return nil }
            return input.index(after: start)

        case .scalarRange(let range):
            guard start != input.endIndex, range.contains(input[start].scalarValue) else { return nil }
            return input.index(after: start)

        case .builtin(let builtinClass):
            guard start != input.endIndex, classify(input[start], builtinClass) else { return nil }
            return input.index(after: start)

        case .negated(let inner):
            guard start != input.endIndex, match(inner, at: start) == nil else { return nil }
            return input.index(after: start)

        case .sequence(let matchers):
            var cursor = start
            for matcher in matchers {
                guard let next = match(matcher, at: cursor) else { return nil }
                cursor = next
            }
            return cursor

        case .alternation(let matchers):
            for matcher in matchers {
                if let next = match(matcher, at: start) { return next }
            }
            return nil

        case .repeated(let min, let max, let inner):
            var cursor = start
            var count = 0
            while max == nil || count < max! {
                guard let next = match(inner, at: cursor), next != cursor else { break }
                cursor = next
                count += 1
            }
            return count >= min ? cursor : nil
        }
    }

    private func classify(_ element: Input.Element, _ builtinClass: BuiltinClass) -> Bool {
        switch builtinClass {
        case .digit: element.isASCIIDigit
        case .whitespace: element.isASCIIWhitespace
        case .hexDigit: element.isASCIIHexDigit
        case .letter: element.isASCIILetter
        }
    }
}
