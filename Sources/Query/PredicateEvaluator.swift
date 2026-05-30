/// Evaluates a ``Predicate`` against the captures of a structural match.
///
/// The evaluator resolves capture references to their nodes' source text (via `Syntax.contentText`),
/// then applies the predicate's textual rule. A predicate that names a capture not present in the
/// match is treated as failing, so callers never see partial matches.
enum PredicateEvaluator {
    /// Whether a predicate holds for the given captures.
    ///
    /// - Parameters:
    ///   - predicate: The predicate to test.
    ///   - captures: The captures bound by the structural match.
    /// - Returns: `true` if the predicate is satisfied.
    static func evaluate(_ predicate: Predicate, captures: [QueryCapture]) -> Bool {
        switch predicate.kind {
        case .equal:
            return allOperandsEqual(predicate.arguments, captures: captures)
        case .notEqual:
            return !allOperandsEqual(predicate.arguments, captures: captures)
        case .match:
            return matches(predicate.arguments, captures: captures)
        case .notMatch:
            return !matches(predicate.arguments, captures: captures)
        case .anyOf:
            return anyOf(predicate.arguments, captures: captures)
        case .notAnyOf:
            return !anyOf(predicate.arguments, captures: captures)
        }
    }

    /// Resolves an operand to its text, or `nil` if a referenced capture is absent.
    private static func text(of argument: PredicateArgument, captures: [QueryCapture]) -> String? {
        switch argument {
        case .literal(let string):
            return string
        case .capture(let name):
            guard let capture = captures.first(where: { $0.name == name }) else { return nil }
            return capture.node.contentText
        }
    }

    /// Whether every operand resolves to the same text.
    private static func allOperandsEqual(
        _ arguments: [PredicateArgument],
        captures: [QueryCapture]
    ) -> Bool {
        var resolved: [String] = []
        for argument in arguments {
            guard let value = text(of: argument, captures: captures) else { return false }
            resolved.append(value)
        }
        guard let first = resolved.first else { return false }
        return resolved.allSatisfy { $0 == first }
    }

    /// Whether the first capture's text matches the regular expression in the second operand.
    private static func matches(_ arguments: [PredicateArgument], captures: [QueryCapture]) -> Bool {
        guard case .capture(let name) = arguments[0], case .literal(let pattern) = arguments[1],
            let capture = captures.first(where: { $0.name == name }),
            let regex = try? Regex(pattern)
        else { return false }
        let subject = capture.node.contentText
        return (try? regex.firstMatch(in: subject)) ?? nil != nil
    }

    /// Whether the first capture's text equals one of the literal operands that follow.
    private static func anyOf(_ arguments: [PredicateArgument], captures: [QueryCapture]) -> Bool {
        guard case .capture(let name) = arguments[0],
            let capture = captures.first(where: { $0.name == name })
        else { return false }
        let subject = capture.node.contentText
        for argument in arguments.dropFirst() {
            if case .literal(let candidate) = argument, candidate == subject { return true }
        }
        return false
    }
}
