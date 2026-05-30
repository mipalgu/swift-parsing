import ParsingCore

// The token-matching routine is kept byte-for-byte equivalent to `RecursiveDescent`'s matcher so the
// two engines tokenise identically; identical tokenisation is a precondition for the differential
// S-expression agreement contract. Keep in sync with `RecursiveDescentEngine.match`/`consumeTrivia`.

/// Matches a token matcher at a position, returning the end index of the longest match.
///
/// Interprets the data-only ``TokenMatcher`` element-by-element against `input`, exactly as the
/// recursive-descent reference engine does, so both engines agree on token boundaries at every input
/// granularity.
///
/// - Parameters:
///   - matcher: The token matcher to apply.
///   - input: The input view being parsed.
///   - start: The index at which to attempt the match.
/// - Returns: The index one past the longest match, or `nil` if the matcher does not match at `start`.
func matchToken<Input: ParserInput>(
    _ matcher: TokenMatcher, in input: Input, at start: Input.Index
) -> Input.Index? {
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
        guard start != input.endIndex, matchToken(inner, in: input, at: start) == nil else { return nil }
        return input.index(after: start)

    case .sequence(let matchers):
        var cursor = start
        for matcher in matchers {
            guard let next = matchToken(matcher, in: input, at: cursor) else { return nil }
            cursor = next
        }
        return cursor

    case .alternation(let matchers):
        for matcher in matchers {
            if let next = matchToken(matcher, in: input, at: start) { return next }
        }
        return nil

    case .repeated(let min, let max, let inner):
        var cursor = start
        var count = 0
        while max == nil || count < max! {
            guard let next = matchToken(inner, in: input, at: cursor), next != cursor else { break }
            cursor = next
            count += 1
        }
        return count >= min ? cursor : nil

    case .lookahead(let negate, let inner):
        // Zero-width: evaluate the inner matcher at `start` without advancing. Succeeds (returning the
        // unchanged position) when the inner match agrees with the polarity, and fails otherwise.
        let innerMatched = matchToken(inner, in: input, at: start) != nil
        return innerMatched == !negate ? start : nil
    }
}

/// Classifies an element against a built-in character class on the ASCII fast path.
///
/// - Parameters:
///   - element: The input element to classify.
///   - builtinClass: The built-in class to test membership in.
/// - Returns: `true` if `element` belongs to `builtinClass`.
private func classify<E: ParserElement>(_ element: E, _ builtinClass: BuiltinClass) -> Bool {
    switch builtinClass {
    case .digit: element.isASCIIDigit
    case .whitespace: element.isASCIIWhitespace
    case .hexDigit: element.isASCIIHexDigit
    case .letter: element.isASCIILetter
    }
}

/// Consumes a run of trivia (extras) at a position, returning the end index of the run.
///
/// Repeatedly applies each of the grammar's `extras` matchers at the cursor until none advances,
/// mirroring the reference engine's trivia handling so leading-trivia widths match exactly.
///
/// - Parameters:
///   - extras: The grammar's trivia matchers.
///   - input: The input view being parsed.
///   - start: The index at which to begin skipping trivia.
/// - Returns: The index one past the consumed trivia run (equal to `start` if no trivia is present).
func skipTrivia<Input: ParserInput>(
    _ extras: [TokenMatcher], in input: Input, at start: Input.Index
) -> Input.Index {
    var cursor = start
    scanning: while cursor != input.endIndex {
        for extra in extras {
            if let end = matchToken(extra, in: input, at: cursor), end != cursor {
                cursor = end
                continue scanning
            }
        }
        break
    }
    return cursor
}
