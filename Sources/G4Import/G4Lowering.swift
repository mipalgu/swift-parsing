import ParsingCore

/// Lowers a parsed `.g4` grammar to the `ParsingCore` grammar intermediate representation.
///
/// The lowering bridges ANTLR's lexer/parser split to the framework's scannerless representation, where
/// terminals are `TokenMatcher` matches inlined into the rules that use them:
///
/// - Lexer rules and `fragment` rules are collected into a matcher table. A fragment reference inside a
///   lexer rule is inlined; a lexer rule that carries a `-> skip` or `-> channel(...)` command becomes a
///   grammar `extra` (trivia) rather than a token rule.
/// - Parser rules become structural `Rule` values. A reference to a lexer rule lowers to an anonymous
///   `Rule.token` carrying that rule's resolved matcher, so a parser rule whose body is a single token
///   reference (such as `number : NUMBER ;`) yields a named leaf node named after the parser rule.
/// - String literals lower to anonymous literal tokens; character sets, the dot wildcard, and `~`
///   negations lower to the corresponding matchers; element labels `name=element` lower to
///   `Rule.field`.
struct G4Lowering {
    private let parsed: G4ParsedGrammar
    private let lexerMatchers: [String: TokenMatcher]
    private let extras: [TokenMatcher]
    private let parserRuleNames: Set<String>
    private let extraRuleNames: Set<String>

    /// The built-in ANTLR reference that matches the end of input; it carries no structure in the IR.
    private static let endOfFileReference = "EOF"

    /// Prepares a lowering for a parsed grammar.
    /// - Parameter parsed: The grammar produced by `G4Parser`.
    /// - Throws: `G4ImportError` if a lexer rule cannot be resolved (for example a cyclic fragment).
    init(_ parsed: G4ParsedGrammar) throws(G4ImportError) {
        self.parsed = parsed
        self.parserRuleNames = Set(parsed.rules.filter { !$0.isLexerRule }.map(\.name))

        var matchers: [String: TokenMatcher] = [:]
        var extras: [TokenMatcher] = []
        var extraNames: Set<String> = []
        let lexerRules = parsed.rules.filter(\.isLexerRule)
        let lexerRulesByName = Dictionary(uniqueKeysWithValues: lexerRules.map { ($0.name, $0) })
        for lexerRule in lexerRules {
            let matcher = try Self.resolve(lexerRule, in: lexerRulesByName, resolving: [])
            matchers[lexerRule.name] = matcher
            if let command = lexerRule.command {
                switch command {
                case .skip, .channel:
                    extras.append(matcher)
                    extraNames.insert(lexerRule.name)
                }
            }
        }
        self.lexerMatchers = matchers
        self.extras = extras.isEmpty ? [.builtin(.whitespace)] : extras
        self.extraRuleNames = extraNames
    }

    /// Lowers the grammar.
    /// - Returns: The grammar intermediate representation.
    /// - Throws: `G4ImportError` if the grammar references an undefined name or has no parser rules.
    func grammar() throws(G4ImportError) -> Grammar {
        guard let start = parsed.rules.first(where: { !$0.isLexerRule })?.name else {
            throw .noParserRules
        }
        var rules: [String: Rule] = [:]
        for rule in parsed.rules where !rule.isLexerRule {
            guard rules[rule.name] == nil else { throw .duplicateRule(rule.name) }
            rules[rule.name] = try lowerRule(rule)
        }
        return Grammar(name: parsed.name, startRule: start, rules: rules, extras: extras)
    }

    // MARK: - Parser-rule lowering

    /// Lowers one parser rule, emitting a precedence ladder when the rule is directly left-recursive.
    ///
    /// A directly left-recursive rule (one whose first element, after unwrapping any label or `<assoc>`
    /// option, refers to the rule itself) lowers to a tightest-first `.choice` of `.precedence`-wrapped
    /// operator tiers followed by its non-recursive primaries. The convention is that a HIGHER `level`
    /// binds tighter, matching `LuaGrammar` and `CGrammar`; the SwiftALLStar left-recursion rewriter then
    /// performs precedence climbing. A rule with no leading self-reference lowers exactly as before.
    private func lowerRule(_ rule: G4Rule) throws(G4ImportError) -> Rule {
        guard isDirectlyLeftRecursive(rule) else {
            return try lowerAlternatives(rule.alternatives)
        }
        return try lowerPrecedenceRule(rule)
    }

    /// Whether some alternative of `rule` begins (after unwrapping a label or `<assoc>` option) with a
    /// reference to `rule` itself, mirroring `LeftRecursionRewriter.leadingReference` for direct recursion.
    private func isDirectlyLeftRecursive(_ rule: G4Rule) -> Bool {
        rule.alternatives.contains { leadsWithReference(to: rule.name, $0) }
    }

    /// Whether an alternative's first element, after unwrapping labels and `<assoc>` options, references
    /// the given rule name.
    private func leadsWithReference(to name: String, _ alternative: G4Alternative) -> Bool {
        guard let first = alternative.elements.first else { return false }
        if case .reference(name) = Self.unwrapElement(first) { return true }
        return false
    }

    /// Strips `.labelled` and `.elementOption` wrappers to reveal the underlying element.
    private static func unwrapElement(_ element: G4Element) -> G4Element {
        switch element {
        case .labelled(_, let inner), .elementOption(_, let inner): return unwrapElement(inner)
        default: return element
        }
    }

    /// Lowers a directly left-recursive rule into a tightest-first `.choice` of precedence tiers.
    ///
    /// The operator (self-recursive) alternatives are taken in source order `[alt0, ..., altK-1]`, where
    /// ANTLR ranks `alt0` as binding tightest. With `K` operator alternatives, the alternative at source
    /// index `i` becomes `.precedence(level: K - i, associativity: A_i, body)`, so `alt0` gets the highest
    /// level (binds tightest) and `altK-1` the lowest. The wrapped operator tiers are listed
    /// tightest-first, then the non-recursive primary alternatives follow unwrapped, guaranteeing the
    /// rewriter finds a base alternative. The importer does not run the rewrite itself.
    private func lowerPrecedenceRule(_ rule: G4Rule) throws(G4ImportError) -> Rule {
        var operators: [G4Alternative] = []
        var primaries: [G4Alternative] = []
        for alternative in rule.alternatives {
            if leadsWithReference(to: rule.name, alternative) {
                operators.append(alternative)
            } else {
                primaries.append(alternative)
            }
        }
        let tierCount = operators.count
        var tiers: [Rule] = []
        for (index, alternative) in operators.enumerated() {
            let body = try lowerAlternative(alternative)
            tiers.append(
                .precedence(
                    level: tierCount - index, associativity: alternative.declaredAssociativity, body))
        }
        let primaryRules = try primaries.map(lowerAlternative)
        return .choice(tiers + primaryRules)
    }

    private func lowerAlternatives(_ alternatives: [G4Alternative]) throws(G4ImportError) -> Rule {
        let lowered = try alternatives.map(lowerAlternative)
        return lowered.count == 1 ? lowered[0] : .choice(lowered)
    }

    private func lowerAlternative(_ alternative: G4Alternative) throws(G4ImportError) -> Rule {
        var rules: [Rule] = []
        for element in alternative.elements {
            if let lowered = try lowerElement(element) {
                rules.append(lowered)
            }
        }
        if rules.isEmpty { return .sequence([]) }
        return rules.count == 1 ? rules[0] : .sequence(rules)
    }

    private func lowerElement(_ element: G4Element) throws(G4ImportError) -> Rule? {
        switch element {
        case .labelled(let label, let inner):
            guard let lowered = try lowerElement(inner) else { return nil }
            return .field(label, lowered)
        case .elementOption(_, let inner):
            // A trailing `<assoc=...>` option is ignored by ANTLR; pass through to the inner element.
            return try lowerElement(inner)
        case .reference(let name):
            return try lowerReference(name)
        case .stringLiteral(let value):
            return .literal(value)
        case .characterSet(let body, let isNegated):
            return .token(
                name: "", matcher: G4CharacterSet.matcher(body: body, isNegated: isNegated), isNamed: false)
        case .negatedElement(let inner):
            return .token(name: "", matcher: .negated(try matcher(for: inner)), isNamed: false)
        case .dot:
            return .token(name: "", matcher: .anyElement, isNamed: false)
        case .group(let alternatives):
            return try lowerAlternatives(alternatives)
        case .optional(let inner):
            return try lowerElement(inner).map(Rule.optional)
        case .zeroOrMore(let inner):
            return try lowerElement(inner).map(Rule.repeatZeroOrMore)
        case .oneOrMore(let inner):
            return try lowerElement(inner).map(Rule.repeatOneOrMore)
        }
    }

    private func lowerReference(_ name: String) throws(G4ImportError) -> Rule? {
        if name == Self.endOfFileReference { return nil }
        if parserRuleNames.contains(name) { return .reference(name) }
        if extraRuleNames.contains(name) {
            throw .unsupportedConstruct("reference to skipped lexer rule '\(name)'")
        }
        guard let matcher = lexerMatchers[name] else { throw .undefinedReference(name) }
        return .token(name: name, matcher: matcher, isNamed: false)
    }

    /// Resolves a single-element reference (for a `~ELEMENT` negation) to its matcher.
    private func matcher(for element: G4Element) throws(G4ImportError) -> TokenMatcher {
        switch element {
        case .stringLiteral(let value):
            return .literal(value)
        case .reference(let name):
            guard let matcher = lexerMatchers[name] else { throw .undefinedReference(name) }
            return matcher
        default:
            throw .unsupportedConstruct("negation of a compound element")
        }
    }

    // MARK: - Lexer-rule resolution

    /// Resolves a lexer rule to a single matcher, inlining any fragment references it makes.
    private static func resolve(
        _ rule: G4Rule, in table: [String: G4Rule], resolving: Set<String>
    ) throws(G4ImportError) -> TokenMatcher {
        guard !resolving.contains(rule.name) else {
            throw .unsupportedConstruct("recursive lexer rule '\(rule.name)'")
        }
        var visiting = resolving
        visiting.insert(rule.name)
        let alternatives = try rule.alternatives.map { (alternative) throws(G4ImportError) in
            try resolveAlternative(alternative, in: table, resolving: visiting)
        }
        return alternatives.count == 1 ? alternatives[0] : .alternation(alternatives)
    }

    private static func resolveAlternative(
        _ alternative: G4Alternative, in table: [String: G4Rule], resolving: Set<String>
    ) throws(G4ImportError) -> TokenMatcher {
        let matchers = try alternative.elements.map { (element) throws(G4ImportError) in
            try resolveElement(element, in: table, resolving: resolving)
        }
        if matchers.isEmpty { return .literal("") }
        return matchers.count == 1 ? matchers[0] : .sequence(matchers)
    }

    private static func resolveElement(
        _ element: G4Element, in table: [String: G4Rule], resolving: Set<String>
    ) throws(G4ImportError) -> TokenMatcher {
        switch element {
        case .labelled(_, let inner), .elementOption(_, let inner):
            return try resolveElement(inner, in: table, resolving: resolving)
        case .stringLiteral(let value):
            return .literal(value)
        case .characterSet(let body, let isNegated):
            return G4CharacterSet.matcher(body: body, isNegated: isNegated)
        case .dot:
            return .anyElement
        case .negatedElement(let inner):
            return .negated(try resolveElement(inner, in: table, resolving: resolving))
        case .reference(let name):
            guard let referenced = table[name] else { throw .undefinedReference(name) }
            return try resolve(referenced, in: table, resolving: resolving)
        case .group(let alternatives):
            let inner = try alternatives.map { (alternative) throws(G4ImportError) in
                try resolveAlternative(alternative, in: table, resolving: resolving)
            }
            return inner.count == 1 ? inner[0] : .alternation(inner)
        case .optional(let inner):
            return .repeated(min: 0, max: 1, try resolveElement(inner, in: table, resolving: resolving))
        case .zeroOrMore(let inner):
            return .repeated(min: 0, max: nil, try resolveElement(inner, in: table, resolving: resolving))
        case .oneOrMore(let inner):
            return .repeated(min: 1, max: nil, try resolveElement(inner, in: table, resolving: resolving))
        }
    }
}
