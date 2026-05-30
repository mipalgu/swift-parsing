/// Compiles query source text into a list of top-level ``QueryPattern`` values.
///
/// The parser implements the tree-sitter query grammar: named nodes `(type ...)`, anonymous nodes
/// `"literal"`, wildcards `_` and `(_)`, field labels `name:`, negated fields `!name`, captures
/// `@name`, quantifiers `? * +`, alternations `[a b]`, parenthesised groups, anchors `.`, and
/// predicates `(#eq? ...)`. It produces the intermediate representation a ``Query`` later matches.
struct QueryParser {
    private var scanner: QueryScanner

    /// Creates a parser over the given query source.
    /// - Parameter source: The query source text.
    init(_ source: String) {
        self.scanner = QueryScanner(source)
    }

    /// Parses the whole source into its top-level patterns.
    ///
    /// - Returns: The ordered top-level patterns; each is matched independently against subtrees.
    /// - Throws: ``QueryError`` describing the first malformed construct encountered.
    mutating func parse() throws(QueryError) -> [QueryPattern] {
        var patterns: [QueryPattern] = []
        scanner.skipTrivia()
        while !scanner.isAtEnd {
            guard let pattern = try parsePattern() else {
                // A stray closing delimiter at top level has no opener.
                let character = scanner.current ?? " "
                throw .unbalancedDelimiter(character, offset: scanner.byteOffset)
            }
            patterns.append(pattern)
            scanner.skipTrivia()
        }
        return patterns
    }

    /// Parses a single pattern with any trailing field, capture and quantifier decoration.
    ///
    /// - Returns: The parsed pattern, or `nil` if the next significant character closes an enclosing
    ///   construct (`)` or `]`), which the caller handles.
    /// - Throws: ``QueryError`` for malformed input.
    private mutating func parsePattern() throws(QueryError) -> QueryPattern? {
        scanner.skipTrivia()
        guard let character = scanner.current else { return nil }

        // Closing delimiters terminate the enclosing list rather than starting a pattern.
        if character == ")" || character == "]" { return nil }

        // A field label `name:` prefixes the pattern it constrains.
        if character != "!", let label = try fieldLabelIfPresent() {
            let labelOffset = scanner.byteOffset
            guard let inner = try parsePattern() else {
                throw .danglingField(label, offset: labelOffset)
            }
            return try decorate(.field(label, inner))
        }

        let base: QueryPattern
        switch character {
        case "(":
            base = try parseParenthesised()
        case "[":
            base = try parseAlternation()
        case "\"":
            base = .anonymous(try scanner.readQuotedString())
        case "_":
            scanner.advance()
            base = .anyNode
        case "@":
            // A capture with no preceding pattern is invalid.
            throw .unexpectedCharacter(character, offset: scanner.byteOffset)
        case "!":
            return try parseNegatedField()
        case ".":
            scanner.advance()
            return .anchor
        case "?", "*", "+":
            throw .danglingQuantifier(character, offset: scanner.byteOffset)
        default:
            throw .unexpectedCharacter(character, offset: scanner.byteOffset)
        }
        return try decorate(base)
    }

    /// Parses a `(` form: a node, a parenthesised group, a wildcard node, or rejects a predicate.
    private mutating func parseParenthesised() throws(QueryError) -> QueryPattern {
        scanner.advance()  // `(`
        scanner.skipTrivia()

        guard let next = scanner.current else { throw .unexpectedEnd }

        // `(#predicate? ...)` is handled where children are gathered, not as a standalone pattern.
        if next == "#" {
            throw .unexpectedCharacter("#", offset: scanner.byteOffset)
        }

        // `(_)` matches any named node.
        if next == "_" {
            scanner.advance()
            scanner.skipTrivia()
            try expect(")")
            return .anyNamedNode
        }

        // A group begins where a node-type name would be: `(`, `[`, `"`, `!` or `.`.
        if next == "(" || next == "[" || next == "\"" || next == "!" || next == "." {
            let members = try parseChildList()
            try expect(")")
            return .group(members.children)
        }

        // Otherwise the first token is the node-type name.
        let type = scanner.readIdentifier()
        guard !type.isEmpty else { throw .expectedNodeName(offset: scanner.byteOffset) }
        let contents = try parseChildList()
        try expect(")")
        return .node(type: type, children: contents.children, predicates: contents.predicates)
    }

    /// The children and predicates gathered from a node or group body.
    private struct ChildListContents {
        var children: [QueryPattern] = []
        var predicates: [Predicate] = []
    }

    /// Parses the child patterns and predicates inside a node or group, up to the closing `)`.
    ///
    /// A `(#name? ...)` form is recognised as a predicate and gathered separately from the children.
    private mutating func parseChildList() throws(QueryError) -> ChildListContents {
        var contents = ChildListContents()
        while true {
            scanner.skipTrivia()
            guard let character = scanner.current else { throw .unexpectedEnd }
            if character == ")" { break }
            if character == "(", nextSignificantIsHash() {
                scanner.advance()  // `(`
                scanner.skipTrivia()
                contents.predicates.append(try parsePredicate())
                try expect(")")
                continue
            }
            guard let pattern = try parsePattern() else { break }
            contents.children.append(pattern)
        }
        return contents
    }

    /// Whether the next significant character after the current `(` is a predicate hash `#`.
    private func nextSignificantIsHash() -> Bool {
        var probe = scanner
        probe.advance()  // `(`
        probe.skipTrivia()
        return probe.current == "#"
    }

    /// Parses an alternation `[a b c]` with any trailing decoration handled by the caller.
    private mutating func parseAlternation() throws(QueryError) -> QueryPattern {
        scanner.advance()  // `[`
        var alternatives: [QueryPattern] = []
        while true {
            scanner.skipTrivia()
            guard let character = scanner.current else { throw .unexpectedEnd }
            if character == "]" {
                scanner.advance()
                break
            }
            guard let pattern = try parsePattern() else {
                throw .unbalancedDelimiter(character, offset: scanner.byteOffset)
            }
            alternatives.append(pattern)
        }
        return .alternation(alternatives)
    }

    /// Parses a negated field `!name`, which asserts the enclosing node lacks that field.
    private mutating func parseNegatedField() throws(QueryError) -> QueryPattern {
        let offset = scanner.byteOffset
        scanner.advance()  // `!`
        let name = scanner.readIdentifier()
        guard !name.isEmpty else { throw .expectedNodeName(offset: offset) }
        return .negatedField(name)
    }

    /// Reads a leading `name:` field label if one is present, leaving the scanner unmoved otherwise.
    ///
    /// - Returns: The field label without its colon, or `nil` if the next atom is not a label.
    private mutating func fieldLabelIfPresent() throws(QueryError) -> String? {
        guard let character = scanner.current, character.isLetter || character == "_" else { return nil }
        var probe = scanner
        let identifier = probe.readIdentifier()
        guard probe.current == ":" else { return nil }
        scanner = probe
        scanner.advance()  // `:`
        return identifier
    }

    /// Applies any trailing capture (`@name`) and quantifier (`? * +`) decoration to a base pattern.
    ///
    /// Captures bind directly around the pattern, while a quantifier governs the whole decorated
    /// form and so is always hoisted to the outside, regardless of whether it was written before or
    /// after the captures. This mirrors tree-sitter, where `(x)? @c` and `(x) @c ?` both make the
    /// captured node optional.
    private mutating func decorate(_ pattern: QueryPattern) throws(QueryError) -> QueryPattern {
        var result = pattern
        var quantifier: Quantifier = .one
        while true {
            if let next = quantifierIfPresent() {
                // Only one quantifier may apply; a later one would be a syntax error in tree-sitter.
                quantifier = next
                continue
            }
            scanner.skipTrivia()
            guard scanner.current == "@" else { break }
            let offset = scanner.byteOffset
            scanner.advance()  // `@`
            let name = scanner.readIdentifier()
            guard !name.isEmpty else { throw .expectedCaptureName(offset: offset) }
            result = .capture(name, result)
        }
        return quantifier == .one ? result : .quantified(result, quantifier)
    }

    /// Consumes a quantifier operator if one is the immediate next character.
    /// - Returns: The quantifier, or `nil` if the next character is not `?`, `*` or `+`.
    private mutating func quantifierIfPresent() -> Quantifier? {
        switch scanner.current {
        case "?": scanner.advance(); return .zeroOrOne
        case "*": scanner.advance(); return .zeroOrMore
        case "+": scanner.advance(); return .oneOrMore
        default: return nil
        }
    }

    /// Parses a predicate `#name? arg...` inside a node's child list.
    private mutating func parsePredicate() throws(QueryError) -> Predicate {
        let offset = scanner.byteOffset
        scanner.advance()  // `#`
        var name = scanner.readIdentifier()
        // Predicate names conventionally end in `?`, which is not an identifier character.
        if scanner.current == "?" {
            name += "?"
            scanner.advance()
        }
        guard let kind = Self.predicateKinds[name] else {
            throw .unknownPredicate(name, offset: offset)
        }
        var arguments: [PredicateArgument] = []
        while true {
            scanner.skipTrivia()
            guard let character = scanner.current else { throw .unexpectedEnd }
            if character == ")" { break }
            if character == "@" {
                scanner.advance()
                let capture = scanner.readIdentifier()
                guard !capture.isEmpty else { throw .expectedCaptureName(offset: scanner.byteOffset) }
                arguments.append(.capture(capture))
            } else if character == "\"" {
                arguments.append(.literal(try scanner.readQuotedString()))
            } else {
                throw .unexpectedCharacter(character, offset: scanner.byteOffset)
            }
        }
        return try Self.validate(Predicate(kind: kind, arguments: arguments), name: name)
    }

    /// Checks that a predicate has a sensible operand count for its kind.
    private static func validate(_ predicate: Predicate, name: String) throws(QueryError) -> Predicate {
        switch predicate.kind {
        case .equal, .notEqual:
            guard predicate.arguments.count >= 2 else {
                throw .malformedPredicate("#\(name) needs at least two operands")
            }
        case .match, .notMatch:
            guard predicate.arguments.count == 2,
                case .capture = predicate.arguments[0],
                case .literal = predicate.arguments[1]
            else {
                throw .malformedPredicate("#\(name) takes a capture and a regular-expression string")
            }
        case .anyOf, .notAnyOf:
            guard predicate.arguments.count >= 2, case .capture = predicate.arguments[0] else {
                throw .malformedPredicate("#\(name) takes a capture and at least one string")
            }
            for argument in predicate.arguments.dropFirst() {
                guard case .literal = argument else {
                    throw .malformedPredicate("#\(name) operands after the capture must be strings")
                }
            }
        }
        return predicate
    }

    /// Consumes the expected delimiter or reports an imbalance.
    private mutating func expect(_ delimiter: Character) throws(QueryError) {
        scanner.skipTrivia()
        guard let character = scanner.current else { throw .unexpectedEnd }
        guard character == delimiter else {
            throw .unbalancedDelimiter(character, offset: scanner.byteOffset)
        }
        scanner.advance()
    }

    /// The predicate names this engine implements, mapped to their kinds.
    private static let predicateKinds: [String: PredicateKind] = [
        "eq?": .equal,
        "not-eq?": .notEqual,
        "match?": .match,
        "not-match?": .notMatch,
        "any-of?": .anyOf,
        "not-any-of?": .notAnyOf,
    ]
}
