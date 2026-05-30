import ParsingCore

/// Parses a stream of `G4Token` values into a `G4ParsedGrammar`.
///
/// The grammar accepted is the documented supported subset: a `grammar Name;` header followed by a
/// sequence of parser rules, lexer rules, and `fragment` lexer rules. Each rule body is a `|`-separated
/// list of alternatives, where every alternative is a sequence of elements (references, string
/// literals, character sets, dot wildcards, negations, and parenthesised groups) each optionally
/// carrying an EBNF suffix `?`, `*`, or `+` (with the non-greedy markers `??`, `*?`, `+?` accepted and
/// treated as their greedy equivalents, since the native engine uses ordered choice). A lexer rule may
/// end with a `-> skip` or `-> channel(...)` command.
struct G4Parser {
    private let tokens: [G4Token]
    private var position = 0

    /// Creates a parser over a token stream.
    /// - Parameter tokens: The tokens produced by `G4Lexer`, terminated by `.endOfFile`.
    init(_ tokens: [G4Token]) {
        self.tokens = tokens
    }

    /// Parses the whole grammar.
    /// - Returns: The parsed grammar.
    /// - Throws: `G4ImportError` if the input does not conform to the supported subset.
    mutating func parse() throws(G4ImportError) -> G4ParsedGrammar {
        let name = try parseHeader()
        var rules: [G4Rule] = []
        while !check(.endOfFile) {
            rules.append(try parseRule())
        }
        return G4ParsedGrammar(name: name, rules: rules)
    }

    // MARK: - Header

    private mutating func parseHeader() throws(G4ImportError) -> String {
        guard match(.grammarKeyword) else { throw .missingGrammarHeader }
        guard case .identifier(let name) = peekToken() else {
            throw .unexpectedToken(found: describe(peekToken()), expected: "grammar name")
        }
        position += 1
        try expect(.semicolon, "';' after grammar name")
        return name
    }

    // MARK: - Rules

    private mutating func parseRule() throws(G4ImportError) -> G4Rule {
        let isFragment = match(.fragmentKeyword)
        guard case .identifier(let name) = peekToken() else {
            throw .unexpectedToken(found: describe(peekToken()), expected: "rule name")
        }
        position += 1
        try expect(.colon, "':' after rule name")

        var alternatives: [G4Alternative] = [try parseAlternative()]
        while match(.pipe) {
            alternatives.append(try parseAlternative())
        }

        let command = try parseCommand()
        try expect(.semicolon, "';' to end rule '\(name)'")
        return G4Rule(name: name, alternatives: alternatives, isFragment: isFragment, command: command)
    }

    private mutating func parseAlternative() throws(G4ImportError) -> G4Alternative {
        let associativity = parseLeadingAssociativity()
        var elements: [G4Element] = []
        while isElementStart(peekToken()) {
            elements.append(try parseSuffixedElement())
        }
        return G4Alternative(elements: elements, declaredAssociativity: associativity)
    }

    /// Consumes a leading `<assoc=left|right>` alternative option, if present, returning its
    /// associativity. In ANTLR 4 the option appears immediately after the `|` (or `:` for the first
    /// alternative) and declares the operator alternative's associativity; an undecorated alternative is
    /// left-associative by default.
    private mutating func parseLeadingAssociativity() -> Associativity {
        guard case .elementOption(let option) = peekToken() else { return .left }
        position += 1
        switch option {
        case .left: return .left
        case .right: return .right
        }
    }

    private mutating func parseSuffixedElement() throws(G4ImportError) -> G4Element {
        let label = parseLabel()
        let element = try parsePrimary()
        let suffixed: G4Element
        switch peekToken() {
        case .question: position += 1; consumeNonGreedyMarker(); suffixed = .optional(element)
        case .star: position += 1; consumeNonGreedyMarker(); suffixed = .zeroOrMore(element)
        case .plus: position += 1; consumeNonGreedyMarker(); suffixed = .oneOrMore(element)
        default: suffixed = element
        }
        let optioned = consumeTrailingOption(on: suffixed)
        return label.map { .labelled($0, optioned) } ?? optioned
    }

    /// Consumes a trailing `<assoc=...>` option written on an element (for example `e '^'<assoc=right> e`)
    /// and wraps the element so lowering can pass through to it. ANTLR accepts but ignores a trailing
    /// option; only the leading alternative option sets associativity, so the wrapped value is discarded
    /// during lowering rather than influencing precedence.
    private mutating func consumeTrailingOption(on element: G4Element) -> G4Element {
        guard case .elementOption(let option) = peekToken() else { return element }
        position += 1
        return .elementOption(option, element)
    }

    /// Recognises an element label (`name=` or `name+=`) and returns its name, leaving the cursor on the
    /// labelled element. Returns `nil` when the next tokens are not a label.
    private mutating func parseLabel() -> String? {
        guard case .identifier(let name) = peekToken(), peekToken(at: position + 1) == .equals else {
            return nil
        }
        position += 2  // consume the identifier and the '=' / '+=' operator
        return name
    }

    /// Consumes a trailing `?` non-greedy marker after a `*`, `+`, or `?` suffix. The native engine is
    /// ordered (PEG-like), so greedy and non-greedy collapse to the same lowering; the marker is
    /// accepted for source compatibility and discarded.
    private mutating func consumeNonGreedyMarker() {
        _ = match(.question)
    }

    private mutating func parsePrimary() throws(G4ImportError) -> G4Element {
        switch peekToken() {
        case .identifier(let name):
            position += 1
            return .reference(name)
        case .stringLiteral(let value):
            position += 1
            return .stringLiteral(value)
        case .characterSet(let body):
            position += 1
            return .characterSet(body: body, isNegated: false)
        case .dot:
            position += 1
            return .dot
        case .tilde:
            position += 1
            return try parseNegation()
        case .leftParenthesis:
            return try parseGroup()
        default:
            throw .unexpectedToken(found: describe(peekToken()), expected: "an element")
        }
    }

    private mutating func parseNegation() throws(G4ImportError) -> G4Element {
        switch peekToken() {
        case .characterSet(let body):
            position += 1
            return .characterSet(body: body, isNegated: true)
        case .stringLiteral(let value):
            position += 1
            return .negatedElement(.stringLiteral(value))
        case .identifier(let name):
            position += 1
            return .negatedElement(.reference(name))
        case .leftParenthesis:
            // ANTLR permits `~(A | B)` only over single-token alternatives; that is outside the supported
            // subset, so the group is captured and the lowering reports it as a compound negation.
            return .negatedElement(try parseGroup())
        default:
            throw .unexpectedToken(found: describe(peekToken()), expected: "a set after '~'")
        }
    }

    private mutating func parseGroup() throws(G4ImportError) -> G4Element {
        position += 1  // consume '('
        var alternatives: [G4Alternative] = [try parseAlternative()]
        while match(.pipe) {
            alternatives.append(try parseAlternative())
        }
        try expect(.rightParenthesis, "')' to close a group")
        return .group(alternatives)
    }

    // MARK: - Lexer commands

    private mutating func parseCommand() throws(G4ImportError) -> G4LexerCommand? {
        guard match(.arrow) else { return nil }
        guard case .identifier(let name) = peekToken() else {
            throw .unexpectedToken(found: describe(peekToken()), expected: "a lexer command after '->'")
        }
        position += 1
        switch name {
        case Command.skip:
            return .skip
        case Command.channel:
            let argument = try parseCommandArgument()
            return .channel(argument)
        default:
            throw .unsupportedConstruct("lexer command '\(name)'")
        }
    }

    private mutating func parseCommandArgument() throws(G4ImportError) -> String {
        try expect(.leftParenthesis, "'(' after 'channel'")
        guard case .identifier(let argument) = peekToken() else {
            throw .unexpectedToken(found: describe(peekToken()), expected: "a channel name")
        }
        position += 1
        try expect(.rightParenthesis, "')' to close 'channel(...)'")
        return argument
    }

    // MARK: - Token helpers

    private func isElementStart(_ token: G4Token) -> Bool {
        switch token {
        case .identifier, .stringLiteral, .characterSet, .dot, .tilde, .leftParenthesis:
            return true
        default:
            return false
        }
    }

    private func peekToken() -> G4Token {
        position < tokens.count ? tokens[position] : .endOfFile
    }

    private func peekToken(at index: Int) -> G4Token {
        index < tokens.count ? tokens[index] : .endOfFile
    }

    private func check(_ token: G4Token) -> Bool {
        peekToken() == token
    }

    private mutating func match(_ token: G4Token) -> Bool {
        guard check(token) else { return false }
        position += 1
        return true
    }

    private mutating func expect(_ token: G4Token, _ description: String) throws(G4ImportError) {
        guard match(token) else {
            throw .unexpectedToken(found: describe(peekToken()), expected: description)
        }
    }

    private func describe(_ token: G4Token) -> String {
        switch token {
        case .identifier(let name): return "identifier '\(name)'"
        case .stringLiteral(let value): return "string '\(value)'"
        case .characterSet(let body): return "set '[\(body)]'"
        case .grammarKeyword: return "'grammar'"
        case .fragmentKeyword: return "'fragment'"
        case .colon: return "':'"
        case .semicolon: return "';'"
        case .pipe: return "'|'"
        case .leftParenthesis: return "'('"
        case .rightParenthesis: return "')'"
        case .question: return "'?'"
        case .star: return "'*'"
        case .plus: return "'+'"
        case .tilde: return "'~'"
        case .dot: return "'.'"
        case .arrow: return "'->'"
        case .comma: return "','"
        case .equals: return "'='"
        case .elementOption(let option): return "'<assoc=\(option == .left ? "left" : "right")>'"
        case .endOfFile: return "end of input"
        }
    }

    /// The lexer-command names recognised by this importer.
    private enum Command {
        static let skip = "skip"
        static let channel = "channel"
    }
}
