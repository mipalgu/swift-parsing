import ParsingCore

/// Converts between regular-expression strings and the Embedded-safe `TokenMatcher`.
///
/// The parser core deliberately has no `Regex` dependency, but tree-sitter `grammar.json` describes
/// terminals as regular-expression `PATTERN` strings. This overlay type bridges the two: it *lowers* a
/// practical regex subset to a `TokenMatcher` (so real tree-sitter grammars can be imported), and
/// renders a `TokenMatcher` back to a regex string (for export). The supported subset is: literals and
/// escapes, `.`, `\d`/`\s`, character classes `[...]` and negated classes `[^...]` with ranges,
/// groups `(...)`/`(?:...)`, alternation `|`, and the quantifiers `*` `+` `?` `{m}` `{m,}` `{m,n}`.
public enum RegexLowering {
    // MARK: - Lower a regex string to a matcher

    /// Lowers a regular-expression string to a `TokenMatcher`.
    /// - Parameter regex: The regular expression (the supported subset).
    /// - Returns: An equivalent matcher, or `.literal(regex)` if the expression cannot be parsed.
    public static func matcher(fromRegex regex: String) -> TokenMatcher {
        var parser = RegexParser(Array(regex))
        guard let matcher = parser.parseAlternation(), parser.isAtEnd else {
            return .literal(regex)
        }
        return matcher
    }

    // MARK: - Render a matcher as a regex string

    /// Renders a `TokenMatcher` as a regular-expression string.
    /// - Parameter matcher: The matcher to render.
    /// - Returns: A regular expression matching the same input.
    public static func regexString(from matcher: TokenMatcher) -> String {
        switch matcher {
        case let .literal(text):
            return text.map(escape).joined()
        case .anyElement:
            return "."
        case let .scalarRange(range):
            return "[\(escapeScalar(range.lowerBound))-\(escapeScalar(range.upperBound))]"
        case let .builtin(builtinClass):
            switch builtinClass {
            case .digit: return "\\d"
            case .whitespace: return "\\s"
            case .hexDigit: return "[0-9A-Fa-f]"
            case .letter: return "[A-Za-z]"
            }
        case let .negated(inner):
            return "[^\(classBody(of: inner))]"
        case let .sequence(matchers):
            return matchers.map(groupedRegex).joined()
        case let .alternation(matchers):
            return "(?:\(matchers.map { regexString(from: $0) }.joined(separator: "|")))"
        case let .repeated(min, max, inner):
            return groupedRegex(inner) + quantifier(min: min, max: max)
        }
    }

    /// Renders a matcher, wrapping it in a non-capturing group when a following quantifier needs it.
    /// (Alternations already render with their own group, so they are not wrapped again.)
    private static func groupedRegex(_ matcher: TokenMatcher) -> String {
        let needsGroup: Bool
        switch matcher {
        case let .literal(text): needsGroup = text.count > 1
        case .sequence: needsGroup = true
        default: needsGroup = false
        }
        let rendered = regexString(from: matcher)
        return needsGroup ? "(?:\(rendered))" : rendered
    }

    /// The interior of a character class for a negated matcher (`[^ ... ]`).
    private static func classBody(of matcher: TokenMatcher) -> String {
        switch matcher {
        case let .literal(text): return text.map(escapeInClass).joined()
        case let .scalarRange(range): return "\(escapeScalar(range.lowerBound))-\(escapeScalar(range.upperBound))"
        case let .alternation(matchers): return matchers.map(classBody).joined()
        default: return escape(Character(regexString(from: matcher)))
        }
    }

    private static func quantifier(min: Int, max: Int?) -> String {
        switch (min, max) {
        case (0, .none): return "*"
        case (1, .none): return "+"
        case (0, .some(1)): return "?"
        case let (m, .none): return "{\(m),}"
        case let (m, .some(n)) where m == n: return "{\(m)}"
        case let (m, .some(n)): return "{\(m),\(n)}"
        }
    }

    private static let metacharacters: Set<Character> = [".", "[", "]", "(", ")", "{", "}", "*", "+", "?", "|", "\\", "^", "$", "/"]

    private static func escape(_ character: Character) -> String {
        metacharacters.contains(character) ? "\\\(character)" : String(character)
    }

    private static func escapeInClass(_ character: Character) -> String {
        (character == "]" || character == "\\" || character == "^" || character == "-") ? "\\\(character)" : String(character)
    }

    private static func escapeScalar(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value) else { return "" }
        return escapeInClass(Character(scalar))
    }
}

/// A minimal recursive-descent parser for the supported regular-expression subset.
private struct RegexParser {
    private let characters: [Character]
    private var position = 0

    init(_ characters: [Character]) { self.characters = characters }

    var isAtEnd: Bool { position >= characters.count }
    private func peek() -> Character? { position < characters.count ? characters[position] : nil }
    private mutating func advance() -> Character { defer { position += 1 }; return characters[position] }

    mutating func parseAlternation() -> TokenMatcher? {
        guard var left = parseConcatenation() else { return nil }
        var alternatives = [left]
        while peek() == "|" {
            position += 1
            guard let next = parseConcatenation() else { return nil }
            alternatives.append(next)
        }
        if alternatives.count > 1 { return .alternation(alternatives) }
        left = alternatives[0]
        return left
    }

    private mutating func parseConcatenation() -> TokenMatcher? {
        var pieces: [TokenMatcher] = []
        while let character = peek(), character != "|", character != ")" {
            guard let quantified = parseQuantified() else { return nil }
            pieces.append(quantified)
        }
        let merged = mergeLiterals(pieces)
        if merged.isEmpty { return .literal("") }
        return merged.count == 1 ? merged[0] : .sequence(merged)
    }

    /// Folds runs of adjacent single-character literals into one literal (so `t`,`r`,`u`,`e` -> `true`).
    private func mergeLiterals(_ pieces: [TokenMatcher]) -> [TokenMatcher] {
        var result: [TokenMatcher] = []
        for piece in pieces {
            if case let .literal(text) = piece, case let .literal(previous)? = result.last {
                result[result.count - 1] = .literal(previous + text)
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private mutating func parseQuantified() -> TokenMatcher? {
        guard let atom = parseAtom() else { return nil }
        switch peek() {
        case "*": position += 1; return .repeated(min: 0, max: nil, atom)
        case "+": position += 1; return .repeated(min: 1, max: nil, atom)
        case "?": position += 1; return .repeated(min: 0, max: 1, atom)
        case "{": return parseBraceQuantifier(atom)
        default: return atom
        }
    }

    private mutating func parseBraceQuantifier(_ atom: TokenMatcher) -> TokenMatcher? {
        position += 1 // consume '{'
        var digits = ""
        while let character = peek(), character.isNumber { digits.append(advance()) }
        guard let min = Int(digits) else { return nil }
        var max: Int? = min
        if peek() == "," {
            position += 1
            var maxDigits = ""
            while let character = peek(), character.isNumber { maxDigits.append(advance()) }
            max = maxDigits.isEmpty ? nil : Int(maxDigits)
        }
        guard peek() == "}" else { return nil }
        position += 1
        return .repeated(min: min, max: max, atom)
    }

    private mutating func parseAtom() -> TokenMatcher? {
        guard let character = peek() else { return nil }
        switch character {
        case "(":
            position += 1
            if peek() == "?" { position += 1; if peek() == ":" { position += 1 } }
            guard let inner = parseAlternation(), peek() == ")" else { return nil }
            position += 1
            return inner
        case "[":
            return parseCharacterClass()
        case ".":
            position += 1
            return .anyElement
        case "\\":
            position += 1
            guard let escaped = peek() else { return nil }
            position += 1
            switch escaped {
            case "d": return .builtin(.digit)
            case "s": return .builtin(.whitespace)
            default: return .literal(String(escaped))
            }
        default:
            position += 1
            return .literal(String(character))
        }
    }

    private mutating func parseCharacterClass() -> TokenMatcher? {
        position += 1 // consume '['
        let negated = peek() == "^"
        if negated { position += 1 }
        var members: [TokenMatcher] = []
        while let character = peek(), character != "]" {
            let low = readClassChar()
            if peek() == "-", position + 1 < characters.count, characters[position + 1] != "]" {
                position += 1 // consume '-'
                let high = readClassChar()
                members.append(.scalarRange(low.scalarValue ... high.scalarValue))
            } else {
                members.append(.literal(String(low)))
            }
        }
        guard peek() == "]" else { return nil }
        position += 1
        let inner: TokenMatcher = members.count == 1 ? members[0] : .alternation(members)
        return negated ? .negated(inner) : inner
    }

    private mutating func readClassChar() -> Character {
        if peek() == "\\" { position += 1 }
        return advance()
    }
}
