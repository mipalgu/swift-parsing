/// A built-in character class, evaluated on an element's ASCII-fast-path classification.
///
/// These cover the common lexical classes without a regular-expression engine, so they are available
/// in Embedded Swift and at every input granularity. The default behaviour is ASCII-only; full-Unicode
/// classification is an opt-in concern of the non-embedded overlay.
public enum BuiltinClass: Hashable, Sendable {
    /// An ASCII decimal digit `0`-`9`.
    case digit
    /// ASCII whitespace.
    case whitespace
    /// An ASCII hexadecimal digit.
    case hexDigit
    /// An ASCII letter.
    case letter
}

/// A data-only description of how to match a single token from the input.
///
/// `TokenMatcher` replaces a regular-expression dependency in the parser core: it is a closed, value-
/// type tagged union (no closures, no existentials, no `Regex`), so it compiles under Embedded Swift,
/// works identically over UTF-8 bytes / scalars / graphemes, and is fully `Hashable`/`Sendable` and
/// round-trippable. The non-embedded overlay provides a `Regex`-string convenience that *lowers* to
/// this representation.
public enum TokenMatcher: Hashable, Sendable {
    /// Matches an exact literal string (compared at the input's granularity).
    case literal(String)
    /// Matches any single element.
    case anyElement
    /// Matches a single element whose scalar value lies in the (inclusive) range.
    case scalarRange(ClosedRange<UInt32>)
    /// Matches a single element belonging to a built-in character class.
    case builtin(BuiltinClass)
    /// Matches a single element for which the inner matcher does **not** match (one-element negation).
    indirect case negated(TokenMatcher)
    /// Matches each sub-matcher in order.
    case sequence([TokenMatcher])
    /// Matches the first sub-matcher that matches at the current position.
    case alternation([TokenMatcher])
    /// Matches the sub-matcher repeatedly, between `min` and `max` times (`max == nil` is unbounded).
    indirect case repeated(min: Int, max: Int?, TokenMatcher)
    /// Matches a zero-width lookahead: the inner matcher is evaluated at the current position but the
    /// cursor never advances.
    ///
    /// Lookahead expresses a *follow-restriction* (a boundary condition) without consuming any input, so
    /// it can be sequenced with other matchers to assert what does, or does not, come next. When `negate`
    /// is `false` it is a positive lookahead that succeeds at a position if, and only if, the inner
    /// matcher matches there; when `negate` is `true` it is a negative lookahead that succeeds at a
    /// position if, and only if, the inner matcher does *not* match there. In both cases a successful
    /// lookahead consumes nothing and the overall match continues at the unchanged position, while a
    /// failed lookahead fails the match. This is the primitive needed to distinguish a keyword from an
    /// identifier prefix (for example, `if` is a keyword only when it is not followed by a further
    /// identifier character, so `iffy` remains an identifier).
    ///
    /// - Parameters:
    ///   - negate: `false` for a positive lookahead (succeeds when the inner matcher matches);
    ///     `true` for a negative lookahead (succeeds when the inner matcher does not match).
    ///   - matcher: The inner matcher evaluated, without consuming input, at the current position.
    indirect case lookahead(negate: Bool, TokenMatcher)
}
