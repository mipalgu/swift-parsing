import ParsingCore

/// A grammar-rule expression produced by the Swift DSL.
///
/// `RuleExpr` is a thin wrapper over a `Rule` so that the result-builder DSL can compose
/// rules ergonomically and accept string literals as anonymous token rules. A bare string
/// literal in DSL position becomes `.literal(...)`.
public struct RuleExpr: Sendable, ExpressibleByStringLiteral {
    /// The underlying intermediate-representation rule.
    public let rule: Rule

    /// Wraps an IR rule.
    /// - Parameter rule: The rule to wrap.
    public init(_ rule: Rule) { self.rule = rule }

    /// Creates an anonymous literal token rule from a string literal.
    /// - Parameter value: The exact text the token matches.
    public init(stringLiteral value: String) { self.rule = .literal(value) }
}

/// Result builder that assembles a flat list of `Rule` values from DSL statements.
///
/// Each statement may be a ``RuleExpr`` or a bare `String` (an anonymous literal token).
/// Control-flow forms (`if`, `if/else`, `for`) are supported so grammars can be generated
/// programmatically.
@resultBuilder
public enum RuleListBuilder {
    /// Lifts a rule expression into a single-element component.
    /// - Parameter expression: The rule expression.
    /// - Returns: A one-element rule list.
    public static func buildExpression(_ expression: RuleExpr) -> [Rule] { [expression.rule] }

    /// Lifts a string literal into an anonymous literal token component.
    /// - Parameter literal: The exact text to match.
    /// - Returns: A one-element rule list.
    public static func buildExpression(_ literal: String) -> [Rule] { [.literal(literal)] }

    /// Concatenates component lists in source order.
    /// - Parameter parts: The component lists.
    /// - Returns: The flattened list.
    public static func buildBlock(_ parts: [Rule]...) -> [Rule] { parts.flatMap { $0 } }

    /// Handles an `if` without `else`.
    /// - Parameter part: The optional component list.
    /// - Returns: The list, or empty if absent.
    public static func buildOptional(_ part: [Rule]?) -> [Rule] { part ?? [] }

    /// Handles the `if` branch of an `if/else`.
    /// - Parameter first: The first branch's list.
    /// - Returns: The list unchanged.
    public static func buildEither(first: [Rule]) -> [Rule] { first }

    /// Handles the `else` branch of an `if/else`.
    /// - Parameter second: The second branch's list.
    /// - Returns: The list unchanged.
    public static func buildEither(second: [Rule]) -> [Rule] { second }

    /// Handles a `for` loop.
    /// - Parameter parts: The per-iteration lists.
    /// - Returns: The flattened list.
    public static func buildArray(_ parts: [[Rule]]) -> [Rule] { parts.flatMap { $0 } }
}

/// Collapses a builder result into a single rule, wrapping in `.sequence` only when needed.
private func collapse(_ rules: [Rule]) -> Rule {
    rules.count == 1 ? rules[0] : .sequence(rules)
}

/// A reference to another named rule.
/// - Parameter name: The referenced rule name.
/// - Returns: A `.reference` rule expression.
public func ref(_ name: String) -> RuleExpr { RuleExpr(.reference(name)) }

/// An ordered sequence of sub-rules.
/// - Parameter body: The DSL body producing the sequence elements.
/// - Returns: A `.sequence` rule expression (or the single element if there is only one).
public func seq(@RuleListBuilder _ body: () -> [Rule]) -> RuleExpr { RuleExpr(collapse(body())) }

/// An ordered choice of alternatives; the first match wins.
/// - Parameter body: The DSL body producing the alternatives.
/// - Returns: A `.choice` rule expression.
public func choice(@RuleListBuilder _ body: () -> [Rule]) -> RuleExpr { RuleExpr(.choice(body())) }

/// An optional sub-rule (zero or one).
/// - Parameter body: The DSL body producing the optional content.
/// - Returns: An `.optional` rule expression.
public func optional(@RuleListBuilder _ body: () -> [Rule]) -> RuleExpr { RuleExpr(.optional(collapse(body()))) }

/// Zero or more repetitions of a sub-rule.
/// - Parameter body: The DSL body producing the repeated content.
/// - Returns: A `.repeatZeroOrMore` rule expression.
public func repeat0(@RuleListBuilder _ body: () -> [Rule]) -> RuleExpr { RuleExpr(.repeatZeroOrMore(collapse(body()))) }

/// One or more repetitions of a sub-rule.
/// - Parameter body: The DSL body producing the repeated content.
/// - Returns: A `.repeatOneOrMore` rule expression.
public func repeat1(@RuleListBuilder _ body: () -> [Rule]) -> RuleExpr { RuleExpr(.repeatOneOrMore(collapse(body()))) }

/// Labels a sub-rule with a grammar field name.
/// - Parameters:
///   - name: The field name.
///   - body: The DSL body producing the labelled content.
/// - Returns: A `.field` rule expression.
public func field(_ name: String, @RuleListBuilder _ body: () -> [Rule]) -> RuleExpr {
    RuleExpr(.field(name, collapse(body())))
}

/// Assigns a static precedence level and associativity to a sub-rule.
///
/// Use this on each recursive alternative of a directly left-recursive rule (for example a Lua-style
/// expression ladder) so the ALL(*) left-recursion rewriter can build a precedence-climbing operator
/// loop. Earlier (higher-`level`) alternatives bind more tightly. A left-associative operator forces its
/// equal-precedence right operand to be refused (left-leaning grouping); a right-associative operator
/// absorbs it (right-leaning grouping). The other engines, which consume the grammar as authored, see the
/// wrapped sub-rule unchanged, so use this combinator only in a grammar intended for the ALL(*) engine.
///
/// - Parameters:
///   - level: The binding precedence; higher binds more tightly.
///   - associativity: The operator associativity used to resolve equal-precedence grouping.
///   - body: The DSL body producing the rule the precedence applies to.
/// - Returns: A `.precedence` rule expression wrapping the body.
public func precedence(
    level: Int,
    associativity: Associativity,
    @RuleListBuilder _ body: () -> [Rule]
) -> RuleExpr {
    RuleExpr(.precedence(level: level, associativity: associativity, collapse(body())))
}

/// Token-matcher constructors for the DSL.
///
/// These build the data-only `TokenMatcher` values used by token rules, without any regular
/// expression (so grammars authored this way are Embedded-safe and granularity-agnostic). They live in
/// a namespace to avoid clashing with the rule-level combinators (`seq`, `optional`, …).
public enum Match {
    /// Matches an exact literal string.
    public static func lit(_ text: String) -> TokenMatcher { .literal(text) }
    /// Matches any single element.
    public static var any: TokenMatcher { .anyElement }
    /// Matches a single ASCII decimal digit.
    public static var digit: TokenMatcher { .builtin(.digit) }
    /// Matches a single ASCII whitespace element.
    public static var whitespace: TokenMatcher { .builtin(.whitespace) }
    /// Matches a single ASCII hexadecimal digit.
    public static var hexDigit: TokenMatcher { .builtin(.hexDigit) }
    /// Matches a single ASCII letter.
    public static var letter: TokenMatcher { .builtin(.letter) }
    /// Matches a single element whose scalar value lies in the inclusive character range.
    /// - Parameters:
    ///   - low: The lowest character (inclusive).
    ///   - high: The highest character (inclusive).
    /// - Returns: A scalar-range matcher.
    public static func range(_ low: Character, _ high: Character) -> TokenMatcher {
        .scalarRange(low.scalarValue...high.scalarValue)
    }
    /// Matches one element for which `matcher` does **not** match (one-element negation).
    /// - Parameter matcher: The matcher to negate.
    /// - Returns: A negated matcher.
    public static func not(_ matcher: TokenMatcher) -> TokenMatcher { .negated(matcher) }
    /// Matches each sub-matcher in order.
    /// - Parameter matchers: The sub-matchers.
    /// - Returns: A sequence matcher.
    public static func seq(_ matchers: TokenMatcher...) -> TokenMatcher { .sequence(matchers) }
    /// Matches the first sub-matcher that matches.
    /// - Parameter matchers: The alternatives.
    /// - Returns: An alternation matcher.
    public static func oneOf(_ matchers: TokenMatcher...) -> TokenMatcher { .alternation(matchers) }
    /// Matches zero or more repetitions.
    /// - Parameter matcher: The repeated matcher.
    /// - Returns: A repetition matcher.
    public static func zeroOrMore(_ matcher: TokenMatcher) -> TokenMatcher { .repeated(min: 0, max: nil, matcher) }
    /// Matches one or more repetitions.
    /// - Parameter matcher: The repeated matcher.
    /// - Returns: A repetition matcher.
    public static func oneOrMore(_ matcher: TokenMatcher) -> TokenMatcher { .repeated(min: 1, max: nil, matcher) }
    /// Matches zero or one (optional).
    /// - Parameter matcher: The optional matcher.
    /// - Returns: A repetition matcher allowing zero or one match.
    public static func optional(_ matcher: TokenMatcher) -> TokenMatcher { .repeated(min: 0, max: 1, matcher) }
    /// Asserts, without consuming input, that `matcher` matches at the current position (positive lookahead).
    ///
    /// The returned matcher is zero-width: it succeeds at a position exactly when `matcher` matches there
    /// and leaves the cursor unchanged, so it can be sequenced with following matchers to express a
    /// follow-requirement (for example, that a token must be followed by a particular character).
    ///
    /// - Parameter matcher: The matcher that must match at the current position.
    /// - Returns: A zero-width positive-lookahead matcher.
    public static func followedBy(_ matcher: TokenMatcher) -> TokenMatcher { .lookahead(negate: false, matcher) }
    /// Asserts, without consuming input, that `matcher` does *not* match at the current position (negative lookahead).
    ///
    /// The returned matcher is zero-width: it succeeds at a position exactly when `matcher` fails to match
    /// there and leaves the cursor unchanged, so it can be sequenced with following matchers to express a
    /// follow-restriction (for example, that the keyword `if` is a keyword only when it is not followed by
    /// a further identifier character, keeping `iffy` an identifier).
    ///
    /// - Parameter matcher: The matcher that must not match at the current position.
    /// - Returns: A zero-width negative-lookahead matcher.
    public static func notFollowedBy(_ matcher: TokenMatcher) -> TokenMatcher { .lookahead(negate: true, matcher) }
}

/// Builds a line-comment trivia matcher for a grammar's `extras` array.
///
/// The matcher consumes the opening marker followed by every subsequent element up to (but not
/// including) the next line terminator, so the comment is captured as trivia and the newline that ends it
/// is left to be consumed as ordinary whitespace. Carriage return and line feed both terminate the run,
/// so the same matcher works for Unix, Windows, and classic-Mac line endings.
///
/// - Parameter marker: The opening sequence introducing the comment (for example `"--"` for Lua or
///   `"//"` for C-style line comments).
/// - Returns: A ``TokenMatcher`` matching one whole line comment, suitable for the `extras` array.
public func lineComment(_ marker: String) -> TokenMatcher {
    let lineEnd = Match.oneOf(Match.lit("\n"), Match.lit("\r"))
    return Match.seq(
        Match.lit(marker),
        Match.zeroOrMore(Match.not(lineEnd))
    )
}

/// Builds a block-comment trivia matcher for a grammar's `extras` array.
///
/// The matcher consumes the opening delimiter, then the shortest run of elements that reaches the closing
/// delimiter, then the closing delimiter, so a `--[[ ... ]]`-style block comment is captured as a single
/// run of trivia. The body is matched non-greedily by forbidding the closing delimiter at each step,
/// which keeps an unterminated comment from over-consuming and lets the surrounding grammar recover.
///
/// - Parameters:
///   - open: The opening delimiter (for example `"--[["` for a fixed-level Lua block comment).
///   - close: The closing delimiter (for example `"]]"`).
/// - Returns: A ``TokenMatcher`` matching one whole block comment, suitable for the `extras` array.
public func blockComment(open: String, close: String) -> TokenMatcher {
    Match.seq(
        Match.lit(open),
        Match.zeroOrMore(Match.not(Match.lit(close))),
        Match.lit(close)
    )
}

/// A named token built from a token matcher.
/// - Parameters:
///   - name: The node-type name for the token.
///   - matcher: The token matcher.
/// - Returns: A named `.token` rule expression.
public func token(_ name: String, _ matcher: TokenMatcher) -> RuleExpr {
    RuleExpr(.token(name: name, matcher: matcher, isNamed: true))
}

/// An anonymous token built from a token matcher.
///
/// Use this for the body of a named rule (for example `number`), so the named node comes from the rule
/// reference and the token itself stays hidden, yielding `(number)` rather than `(number (number))`.
///
/// - Parameter matcher: The token matcher.
/// - Returns: An anonymous `.token` rule expression.
public func token(_ matcher: TokenMatcher) -> RuleExpr {
    RuleExpr(.token(name: "_token", matcher: matcher, isNamed: false))
}

/// A definition of a single named rule, produced by ``rule(_:_:)``.
public struct RuleDefinition: Sendable {
    /// The rule's name.
    public let name: String
    /// The rule's body.
    public let rule: Rule
}

/// Defines a named grammar rule.
/// - Parameters:
///   - name: The rule name.
///   - body: The DSL body producing the rule's content.
/// - Returns: A ``RuleDefinition``.
public func rule(_ name: String, @RuleListBuilder _ body: () -> [Rule]) -> RuleDefinition {
    RuleDefinition(name: name, rule: collapse(body()))
}

/// Result builder that collects ``RuleDefinition`` values into a grammar.
@resultBuilder
public enum GrammarBuilder {
    /// Collects rule definitions.
    /// - Parameter defs: The rule definitions.
    /// - Returns: The definitions as an array.
    public static func buildBlock(_ defs: RuleDefinition...) -> [RuleDefinition] { defs }
}

extension Grammar {
    /// Builds a grammar from a DSL body of rule definitions.
    ///
    /// - Parameters:
    ///   - name: The grammar's name.
    ///   - start: The start rule name. Must be defined in the body.
    ///   - extras: Trivia token matchers. Defaults to ASCII whitespace.
    ///   - body: The DSL body producing the rule definitions.
    public init(
        name: String,
        start: String,
        extras: [TokenMatcher] = [.builtin(.whitespace)],
        @GrammarBuilder _ body: () -> [RuleDefinition]
    ) {
        var rules: [String: Rule] = [:]
        for def in body() { rules[def.name] = def.rule }
        self.init(name: name, startRule: start, rules: rules, extras: extras)
    }
}
