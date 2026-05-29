import ParsingCore

/// A grammar-rule expression produced by the Swift DSL.
///
/// `RuleExpr` is a thin wrapper over a ``Rule`` so that the result-builder DSL can compose
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

/// Result builder that assembles a flat list of ``Rule`` values from DSL statements.
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

/// A named token matching a regular expression.
/// - Parameters:
///   - name: The node-type name for the token.
///   - pattern: The anchored regular expression.
/// - Returns: A named `.token` rule expression.
public func regex(_ name: String, _ pattern: String) -> RuleExpr {
    RuleExpr(.token(name: name, pattern: .regex(pattern), isNamed: true))
}

/// An anonymous token matching a regular expression.
///
/// Use this for the body of a named rule (for example `number`), so the named node comes from the
/// rule reference and the token itself stays hidden, yielding `(number)` rather than `(number (number))`.
///
/// - Parameter pattern: The anchored regular expression.
/// - Returns: An anonymous `.token` rule expression.
public func pattern(_ pattern: String) -> RuleExpr {
    RuleExpr(.token(name: pattern, pattern: .regex(pattern), isNamed: false))
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
    ///   - extras: Trivia token patterns. Defaults to a single whitespace pattern.
    ///   - body: The DSL body producing the rule definitions.
    public init(
        name: String,
        start: String,
        extras: [TokenPattern] = [.regex("[ \\t\\r\\n]+")],
        @GrammarBuilder _ body: () -> [RuleDefinition]
    ) {
        var rules: [String: Rule] = [:]
        for def in body() { rules[def.name] = def.rule }
        self.init(name: name, startRule: start, rules: rules, extras: extras)
    }
}
