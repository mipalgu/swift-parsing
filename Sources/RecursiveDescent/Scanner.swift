import ParsingCore

/// Compiled token patterns for a grammar, shared (immutably) across parses.
///
/// Regular-expression terminals are compiled once and cached by their source string so repeated
/// match attempts during recursive descent do not recompile them. Literal terminals need no
/// compilation. `extras` (whitespace/comments) are compiled into ordered matchers.
///
/// The cache holds compiled `Regex` values, which are not `Sendable`; the conformance is
/// `@unchecked` because those values are immutable after construction and used only for read-only
/// matching, which is safe to share across concurrency domains.
struct PatternSet: @unchecked Sendable {
    /// Matchers for the grammar's `extras` (trivia), tried in order.
    let extras: [TokenPattern]
    private let regexCache: [String: Regex<AnyRegexOutput>]

    /// Compiles the regular-expression terminals and `extras` of a grammar.
    /// - Parameter grammar: The grammar to compile patterns for.
    /// - Throws: If any regular expression fails to compile.
    init(grammar: Grammar) throws {
        var sources: Set<String> = []
        for rule in grammar.rules.values { PatternSet.collectRegexSources(rule, into: &sources) }
        for pattern in grammar.extras { if case let .regex(source) = pattern { sources.insert(source) } }
        var cache: [String: Regex<AnyRegexOutput>] = [:]
        for source in sources { cache[source] = try Regex(source) }
        self.regexCache = cache
        self.extras = grammar.extras
    }

    private static func collectRegexSources(_ rule: Rule, into out: inout Set<String>) {
        switch rule {
        case let .token(_, pattern, _):
            if case let .regex(source) = pattern { out.insert(source) }
        case .reference:
            break
        case let .sequence(rules), let .choice(rules):
            for r in rules { collectRegexSources(r, into: &out) }
        case let .repeatZeroOrMore(r), let .repeatOneOrMore(r), let .optional(r),
             let .field(_, r), let .precedence(_, _, r):
            collectRegexSources(r, into: &out)
        }
    }

    /// Matches a token pattern at the start of a substring.
    /// - Parameters:
    ///   - pattern: The pattern to match.
    ///   - sub: The substring whose start is the current position.
    /// - Returns: The matched non-empty prefix, or `nil` if the pattern does not match here.
    func match(_ pattern: TokenPattern, at sub: Substring) -> Substring? {
        switch pattern {
        case let .literal(text):
            return sub.hasPrefix(text) ? sub.prefix(text.count) : nil
        case let .regex(source):
            guard let regex = regexCache[source], let m = sub.prefixMatch(of: regex) else { return nil }
            let matched = sub[m.range]
            return matched.isEmpty ? nil : matched
        }
    }
}

/// A cursor over source text that matches grammar terminals on demand.
///
/// Scanning is parser-directed: a terminal's pattern is only attempted when the grammar expects
/// it, which makes lexing context-sensitive (for example, `string_content` is only tried inside a
/// string) and avoids the greedy-match hazards of a context-free pre-tokeniser. The cursor tracks
/// both a `String.Index` (for matching) and a UTF-8 byte offset (for source spans), and supports
/// cheap save/restore marks for ordered-choice backtracking.
final class Scanner {
    private let text: String
    private let patterns: PatternSet
    private(set) var index: String.Index
    private(set) var byteOffset: Int

    /// Creates a scanner over a source.
    /// - Parameters:
    ///   - source: The source to scan.
    ///   - patterns: The compiled grammar patterns.
    init(source: Source, patterns: PatternSet) {
        self.text = source.text
        self.patterns = patterns
        self.index = text.startIndex
        self.byteOffset = 0
    }

    /// A saved cursor position for backtracking.
    struct Mark { let index: String.Index; let byteOffset: Int }

    /// Captures the current cursor position.
    /// - Returns: A mark that can be passed to ``reset(to:)``.
    func mark() -> Mark { Mark(index: index, byteOffset: byteOffset) }

    /// Restores the cursor to a previously captured mark.
    /// - Parameter mark: The mark to restore.
    func reset(to mark: Mark) { index = mark.index; byteOffset = mark.byteOffset }

    /// Whether the cursor has reached the end of input.
    var isAtEnd: Bool { index == text.endIndex }

    /// The remaining unscanned text from the cursor to the end of input.
    var rest: Substring { text[index...] }

    private func advance(over matched: Substring) {
        index = text.index(index, offsetBy: matched.count)
        byteOffset += String(matched).utf8.count
    }

    /// Consumes a run of trivia (whitespace/comments) at the cursor.
    /// - Returns: The consumed trivia text (possibly empty).
    func consumeTrivia() -> String {
        var trivia = ""
        scanning: while index < text.endIndex {
            let sub = text[index...]
            for extra in patterns.extras {
                if let matched = patterns.match(extra, at: sub) {
                    trivia += matched
                    advance(over: matched)
                    continue scanning
                }
            }
            break
        }
        return trivia
    }

    /// Attempts to match a terminal pattern at the cursor, advancing on success.
    /// - Parameter pattern: The terminal pattern to match.
    /// - Returns: The matched text, or `nil` if the pattern does not match here.
    func match(_ pattern: TokenPattern) -> String? {
        guard index < text.endIndex else { return nil }
        guard let matched = patterns.match(pattern, at: text[index...]) else { return nil }
        advance(over: matched)
        return String(matched)
    }
}
