import ParsingCore

/// Renders a `Grammar` to ANTLR `.g4` text, the inverse of `G4Lowering`.
///
/// The exporter reconstructs ANTLR's lexer/parser split that the importer flattened. Each named rule
/// becomes a parser rule; an inlined token carrying a lexer-rule name is hoisted back into a lexer rule
/// and referenced by that name, a string-literal token is rendered `'like this'`, and an anonymous
/// character-set, dot, or negation token is rendered inline. A directly left-recursive `Rule.choice` of
/// `Rule.precedence` tiers is rendered as a left-recursive rule with the tiers in tightest-first order and
/// a leading `<assoc=right>` option on each right-associative tier, so the importer recomputes the same
/// levels from alternative order. Grammar `extras` become `-> skip` lexer rules unless they are the
/// default ASCII whitespace, which the importer restores on its own.
///
/// The token's recorded kind name disambiguates how it was imported: an empty name is an inline
/// character-set or wildcard element, a name equal to the literal text is a string literal, and any other
/// name is a former lexer rule. Rendering preserves that distinction so re-importing yields the same IR.
struct G4Exporter {
    /// The grammatical precedence of a rendered fragment, used to parenthesise only where ANTLR's grammar
    /// would otherwise reassociate: alternation binds loosest, then sequence, then a postfix quantifier,
    /// then an atom (a literal, set, reference, negation, or parenthesised group).
    private enum Precedence: Int {
        case alternation = 1
        case sequence = 2
        case postfix = 3
        case atom = 4
    }

    /// The lexer rules reconstructed from inlined token matchers, keyed by the token's kind name.
    private var lexerRules: [String: TokenMatcher] = [:]

    /// Renders the whole grammar to `.g4` text terminated by a newline.
    mutating func render(_ grammar: Grammar) -> String {
        let parserOrder =
            [grammar.startRule] + grammar.rules.keys.filter { $0 != grammar.startRule }.sorted()
        var lines: [String] = []
        for name in parserOrder {
            guard let rule = grammar.rules[name] else { continue }
            lines.append("\(name) : \(renderRule(rule, atLeast: .alternation)) ;")
        }
        for name in lexerRules.keys.sorted() {
            lines.append("\(name) : \(renderMatcher(lexerRules[name]!, atLeast: .alternation)) ;")
        }
        lines.append(contentsOf: extraRules(grammar.extras))
        return "grammar \(grammar.name);\n\(lines.joined(separator: "\n"))\n"
    }

    // MARK: - Rule rendering

    /// Renders a rule, parenthesising it when its own precedence binds looser than the context requires.
    private mutating func renderRule(_ rule: Rule, atLeast minimum: Precedence) -> String {
        let (text, precedence) = renderRuleRaw(rule)
        return precedence.rawValue < minimum.rawValue ? "(\(text))" : text
    }

    /// Renders a rule to its natural text and the precedence of that text's top-level operator.
    private mutating func renderRuleRaw(_ rule: Rule) -> (String, Precedence) {
        switch rule {
        case .reference(let name):
            return (name, .atom)
        case .token(let name, let matcher, _):
            return (tokenElement(name: name, matcher), .atom)
        case .field(let label, let sub):
            return ("\(label)=\(renderRule(sub, atLeast: .postfix))", .atom)
        case .optional(let sub):
            return ("\(renderRule(sub, atLeast: .atom))?", .postfix)
        case .repeatZeroOrMore(let sub):
            return ("\(renderRule(sub, atLeast: .atom))*", .postfix)
        case .repeatOneOrMore(let sub):
            return ("\(renderRule(sub, atLeast: .atom))+", .postfix)
        case .sequence(let rules):
            let body = rules.map { renderRule($0, atLeast: .postfix) }.joined(separator: " ")
            return (body, .sequence)
        case .choice(let alternatives):
            if alternatives.contains(where: isPrecedenceTier) {
                return (renderPrecedenceLadder(alternatives), .alternation)
            }
            let body = alternatives.map { renderRule($0, atLeast: .sequence) }.joined(separator: " | ")
            return (body, .alternation)
        case .precedence(_, _, let sub):
            // A precedence tier outside the ladder it belongs to carries no `.g4` surface form; pass through.
            return renderRuleRaw(sub)
        }
    }

    /// Whether an alternative is a precedence tier (the marker of a directly left-recursive rule).
    private func isPrecedenceTier(_ rule: Rule) -> Bool {
        if case .precedence = rule { return true }
        return false
    }

    /// Renders a directly left-recursive rule's tiers (tightest first) and primaries as `|` alternatives.
    private mutating func renderPrecedenceLadder(_ alternatives: [Rule]) -> String {
        alternatives.map { alternative in
            guard case .precedence(_, let associativity, let body) = alternative else {
                return renderRule(alternative, atLeast: .sequence)
            }
            let option = associativity == .right ? "<assoc=right> " : ""
            return option + renderRule(body, atLeast: .sequence)
        }
        .joined(separator: " | ")
    }

    /// Renders a token as a `.g4` element: an inline set/wildcard, a string literal, or a lexer-rule name.
    private mutating func tokenElement(name: String, _ matcher: TokenMatcher) -> String {
        if name.isEmpty {
            return inlineMatcher(matcher)
        }
        if matcher == .literal(name) {
            return stringLiteral(name)
        }
        lexerRules[name] = matcher
        return name
    }

    // MARK: - Matcher rendering

    /// Renders an anonymous (empty-named) token's matcher: a character set, the dot wildcard, or a `~`
    /// negation, the only inline element forms the importer produces.
    private func inlineMatcher(_ matcher: TokenMatcher) -> String {
        switch matcher {
        case .anyElement:
            return "."
        case .negated(let inner):
            return "~\(renderMatcher(inner, atLeast: .atom))"
        case .literal(let text):
            return "[\(text.map(classMember).joined())]"
        case .scalarRange(let range):
            return "[\(rangeBody(range))]"
        case .alternation(let matchers) where matchers.allSatisfy(isClassMember):
            return "[\(matchers.map(classBody).joined())]"
        default:
            return "(\(renderMatcher(matcher, atLeast: .alternation)))"
        }
    }

    /// Renders a matcher, parenthesising it when its precedence binds looser than the context requires.
    private func renderMatcher(_ matcher: TokenMatcher, atLeast minimum: Precedence) -> String {
        let (text, precedence) = renderMatcherRaw(matcher)
        return precedence.rawValue < minimum.rawValue ? "(\(text))" : text
    }

    /// Renders a matcher to its natural text and the precedence of that text's top-level operator.
    private func renderMatcherRaw(_ matcher: TokenMatcher) -> (String, Precedence) {
        switch matcher {
        case .literal(let text):
            return (stringLiteral(text), .atom)
        case .anyElement:
            return (".", .atom)
        case .scalarRange(let range):
            return ("[\(rangeBody(range))]", .atom)
        case .builtin(let builtinClass):
            return ("[\(builtinClassBody(builtinClass))]", .atom)
        case .negated(let inner):
            return ("~\(renderMatcher(inner, atLeast: .atom))", .atom)
        case .alternation(let matchers) where matchers.allSatisfy(isClassMember):
            return ("[\(matchers.map(classBody).joined())]", .atom)
        case .alternation(let matchers):
            let body = matchers.map { renderMatcher($0, atLeast: .sequence) }.joined(separator: " | ")
            return (body, .alternation)
        case .sequence(let matchers):
            let body = matchers.map { renderMatcher($0, atLeast: .postfix) }.joined(separator: " ")
            return (body, .sequence)
        case .repeated(let minimum, let maximum, let inner):
            return (renderRepeated(min: minimum, max: maximum, inner), .postfix)
        case .lookahead(let negate, let inner):
            // ANTLR `.g4` has no zero-width-assertion form, so a lookahead is emitted as a visible comment
            // naming the construct and the matcher it guards, mirroring the EBNF exporter.
            let note = negate ? "not-followed-by" : "followed-by"
            return ("/* \(note) \(renderMatcher(inner, atLeast: .alternation)) */", .atom)
        }
    }

    /// Renders a repeated matcher with a postfix quantifier when it is `?`, `*` or `+`.
    private func renderRepeated(min: Int, max: Int?, _ inner: TokenMatcher) -> String {
        let operand = renderMatcher(inner, atLeast: .atom)
        switch (min, max) {
        case (0, 1): return "\(operand)?"
        case (0, nil): return "\(operand)*"
        case (1, nil): return "\(operand)+"
        // A bounded repetition has no `.g4` postfix; the importer never produces one, so emit the operand.
        default: return operand
        }
    }

    /// Whether a matcher can stand as a member inside a `[...]` character set.
    private func isClassMember(_ matcher: TokenMatcher) -> Bool {
        switch matcher {
        case .literal(let text): return text.count == 1
        case .scalarRange: return true
        default: return false
        }
    }

    /// The character-set body for one class member.
    private func classBody(_ matcher: TokenMatcher) -> String {
        switch matcher {
        case .literal(let text): return text.map(classMember).joined()
        case .scalarRange(let range): return rangeBody(range)
        default: return ""
        }
    }

    // MARK: - Lexical rendering

    /// Renders the `low-high` body of a scalar range inside a character set.
    private func rangeBody(_ range: ClosedRange<UInt32>) -> String {
        "\(scalarInClass(range.lowerBound))-\(scalarInClass(range.upperBound))"
    }

    /// Renders a single scalar value for use inside a character set.
    private func scalarInClass(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value) else { return "" }
        return classMember(Character(scalar))
    }

    /// Escapes a character for safe use inside a `[...]` character set.
    private func classMember(_ character: Character) -> String {
        switch character {
        case "\t": return "\\t"
        case "\n": return "\\n"
        case "\r": return "\\r"
        case "]", "-", "\\": return "\\\(character)"
        default: return String(character)
        }
    }

    /// Renders a `'single-quoted'` string literal with the escapes the importer decodes.
    private func stringLiteral(_ text: String) -> String {
        var body = ""
        for character in text {
            switch character {
            case "'", "\\": body += "\\\(character)"
            case "\t": body += "\\t"
            case "\n": body += "\\n"
            case "\r": body += "\\r"
            default: body.append(character)
            }
        }
        return "'\(body)'"
    }

    /// The character-set body that reproduces a built-in class on import (ASCII fast-path equivalents).
    private func builtinClassBody(_ builtinClass: BuiltinClass) -> String {
        switch builtinClass {
        case .digit: return "0-9"
        case .hexDigit: return "0-9a-fA-F"
        case .letter: return "a-zA-Z"
        case .whitespace: return " \\t\\n\\r"
        }
    }

    /// Renders the grammar's trivia matchers as `-> skip` lexer rules, or nothing for the default
    /// whitespace (which the importer restores when a grammar declares no skipped rule).
    private func extraRules(_ extras: [TokenMatcher]) -> [String] {
        if extras == [.builtin(.whitespace)] { return [] }
        var lines: [String] = []
        var used = Set(lexerRules.keys)
        for extra in extras {
            var name = "WS"
            var suffix = 0
            while used.contains(name) {
                suffix += 1
                name = "WS\(suffix)"
            }
            used.insert(name)
            lines.append("\(name) : \(renderMatcher(extra, atLeast: .alternation)) -> skip ;")
        }
        return lines
    }
}
