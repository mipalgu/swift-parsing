import ParsingCore

/// Rewrites directly left-recursive rules into an equivalent non-left-recursive form.
///
/// ALL(*) prediction requires a non-left-recursive ATN. Direct left recursion (a rule whose first symbol
/// in some alternative is a call to itself) is eliminated by turning the recursive alternatives into an
/// operator loop guarded by precedence predicates, following the ANTLR 4 transformation. Indirect left
/// recursion (a rule that reaches itself only through other rules) is rejected, matching ANTLR 4's scope,
/// because eliminating it can blow up the grammar size. Grammars with no left recursion, including the
/// JSON differential grammar, pass through unchanged.
enum LeftRecursionRewriter {
    /// Rewrites a grammar's directly left-recursive rules.
    ///
    /// - Parameter grammar: The grammar to rewrite.
    /// - Returns: An equivalent grammar with direct left recursion eliminated.
    /// - Throws: ``GrammarError/invalidGrammar(_:)`` if a rule is indirectly left-recursive.
    static func rewrite(_ grammar: Grammar) throws(GrammarError) -> Grammar {
        var rules = grammar.rules
        for (name, rule) in grammar.rules {
            let classification = classifyLeftRecursion(name, in: grammar)
            switch classification {
            case .none:
                continue
            case .indirect:
                throw .invalidGrammar("indirect left recursion in '\(name)' is unsupported")
            case .direct:
                rules[name] = try rewriteDirect(name, body: rule)
            }
        }
        return Grammar(name: grammar.name, startRule: grammar.startRule, rules: rules, extras: grammar.extras)
    }

    /// How a rule is left-recursive, if at all.
    private enum LeftRecursion {
        /// Not left-recursive.
        case none
        /// Directly left-recursive (the rule calls itself as a leading symbol).
        case direct
        /// Indirectly left-recursive (the rule reaches itself only through other rules).
        case indirect
    }

    /// Classifies a rule's left recursion within a grammar.
    private static func classifyLeftRecursion(_ name: String, in grammar: Grammar) -> LeftRecursion {
        guard let body = grammar.rules[name] else { return .none }
        if topAlternatives(body).contains(where: { leadingReference($0) == name }) {
            return .direct
        }
        // Indirect: reachable as a left corner through at least one other rule.
        var visited: Set<String> = [name]
        var frontier = leftCornerReferences(body, in: grammar)
        while let next = frontier.popFirst() {
            if next == name { return .indirect }
            if visited.insert(next).inserted, let nextBody = grammar.rules[next] {
                for reference in leftCornerReferences(nextBody, in: grammar) {
                    frontier.insert(reference)
                }
            }
        }
        return .none
    }

    /// The top-level alternatives of a rule body (the alternatives of a leading `.choice`, else itself).
    private static func topAlternatives(_ rule: Rule) -> [Rule] {
        switch rule {
        case .choice(let alts): alts
        case .precedence(_, _, let sub): topAlternatives(sub)
        default: [rule]
        }
    }

    /// The name a rule's first symbol references, if its leading symbol is a rule reference.
    private static func leadingReference(_ rule: Rule) -> String? {
        switch rule {
        case .reference(let name): name
        case .sequence(let rules): rules.first.flatMap(leadingReference)
        case .field(_, let sub), .precedence(_, _, let sub): leadingReference(sub)
        default: nil
        }
    }

    /// The rule names reachable at the left corner of a rule (its possible leading rule calls).
    private static func leftCornerReferences(_ rule: Rule, in grammar: Grammar) -> Set<String> {
        switch rule {
        case .reference(let name): [name]
        case .choice(let alts): alts.reduce(into: []) { $0.formUnion(leftCornerReferences($1, in: grammar)) }
        case .sequence(let rules): rules.first.map { leftCornerReferences($0, in: grammar) } ?? []
        case .optional(let sub), .repeatZeroOrMore(let sub):
            // An optional/star leading item may be skipped, so the next item is also a left corner.
            leftCornerReferences(sub, in: grammar)
        case .repeatOneOrMore(let sub), .field(_, let sub), .precedence(_, _, let sub):
            leftCornerReferences(sub, in: grammar)
        case .token: []
        }
    }

    /// Rewrites a directly left-recursive rule into a primary then a precedence-guarded operator loop.
    private static func rewriteDirect(_ name: String, body: Rule) throws(GrammarError) -> Rule {
        let alternatives = topAlternatives(body)
        var primary: [Rule] = []
        var operators: [Rule] = []
        let count = alternatives.count
        for (offset, alternative) in alternatives.enumerated() {
            // Precedence numbers: earlier productions bind tighter (ANTLR App. C: n - i + 1).
            let level = count - offset
            if let suffix = recursiveSuffix(of: alternative, ruleName: name) {
                let (associativity, declaredLevel) = precedenceOf(alternative, fallback: level)
                let predicate = Rule.precedence(level: declaredLevel, associativity: associativity, .sequence([]))
                let climbed = withRightOperandEnterPrecedence(
                    suffix, ruleName: name, level: declaredLevel, associativity: associativity)
                operators.append(.sequence([predicate] + climbed))
            } else {
                primary.append(alternative)
            }
        }
        guard !operators.isEmpty else {
            throw .invalidGrammar("rule '\(name)' is marked left-recursive but has no recursive alternative")
        }
        guard !primary.isEmpty else {
            throw .invalidGrammar("left-recursive rule '\(name)' has no base (non-recursive) alternative")
        }
        let primaryRule: Rule = primary.count == 1 ? primary[0] : .choice(primary)
        let loopBody: Rule = operators.count == 1 ? operators[0] : .choice(operators)
        return .sequence([primaryRule, .repeatZeroOrMore(loopBody)])
    }

    /// The part of a left-recursive alternative after the leading self-reference (the operator suffix).
    private static func recursiveSuffix(of alternative: Rule, ruleName: String) -> [Rule]? {
        let unwrapped = unwrapPrecedence(alternative)
        guard case .sequence(let rules) = unwrapped, let first = rules.first,
            leadingReference(first) == ruleName
        else {
            // A bare `A` alone is degenerate; treat a leading reference as recursive with empty suffix.
            if leadingReference(unwrapped) == ruleName { return [] }
            return nil
        }
        return Array(rules.dropFirst())
    }

    /// Wraps the suffix's trailing self-reference (the right operand) with its enter-at precedence.
    ///
    /// Precedence-climbing is realised by re-entering the rule at a higher minimum precedence for the right
    /// operand: `level + 1` for a left-associative operator (so an equal-precedence operator to the right is
    /// refused, forcing left-leaning grouping) and `level` for a right-associative or non-associative
    /// operator (so an equal-precedence operator is absorbed on the right, forcing right-leaning grouping).
    /// The enter-at precedence is recorded by wrapping the trailing self-reference in a `.precedence` node
    /// the ATN builder turns into the right-operand rule edge's `enterPrecedence`. Postfix operator forms
    /// (`A op`, with no trailing self-reference) are left unchanged.
    private static func withRightOperandEnterPrecedence(
        _ suffix: [Rule], ruleName: String, level: Int, associativity: Associativity
    ) -> [Rule] {
        guard let last = suffix.last, case .reference(ruleName) = last else { return suffix }
        let enterAt = associativity == .left ? level + 1 : level
        var wrapped = suffix
        wrapped[wrapped.count - 1] = .precedence(level: enterAt, associativity: .none, last)
        return wrapped
    }

    /// The declared precedence and associativity of an alternative, or a fallback level if undeclared.
    private static func precedenceOf(_ rule: Rule, fallback: Int) -> (Associativity, Int) {
        if case .precedence(let level, let associativity, _) = rule { return (associativity, level) }
        return (.left, fallback)
    }

    /// Strips a leading precedence wrapper from a rule.
    private static func unwrapPrecedence(_ rule: Rule) -> Rule {
        if case .precedence(_, _, let sub) = rule { return sub }
        return rule
    }
}
