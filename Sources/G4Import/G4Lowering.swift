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
            rules[rule.name] = try lowerAlternatives(rule.alternatives)
        }
        return Grammar(name: parsed.name, startRule: start, rules: rules, extras: extras)
    }

    // MARK: - Parser-rule lowering

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
        case .labelled(_, let inner):
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
