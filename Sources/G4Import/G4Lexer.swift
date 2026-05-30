/// Tokenises ANTLR `.g4` grammar text into the `G4Token` vocabulary.
///
/// The lexer skips whitespace and both `//` line and `/* */` block comments, decodes the escape
/// sequences inside single-quoted string literals, and captures character sets `[...]` verbatim for the
/// lowering step to interpret. It recognises only the meta-syntax of the supported subset; any other
/// character is reported as `G4ImportError.unexpectedCharacter`.
struct G4Lexer {
    private let characters: [Character]
    private var position = 0

    /// Creates a lexer over the given grammar text.
    /// - Parameter text: The `.g4` source.
    init(_ text: String) {
        self.characters = Array(text)
    }

    /// Tokenises the entire input.
    /// - Returns: The token stream, terminated by `G4Token.endOfFile`.
    /// - Throws: `G4ImportError` if an unsupported character or an unterminated literal is encountered.
    mutating func tokenise() throws(G4ImportError) -> [G4Token] {
        var tokens: [G4Token] = []
        while true {
            try skipTrivia()
            guard let character = peek() else {
                tokens.append(.endOfFile)
                return tokens
            }
            tokens.append(try lexToken(character))
        }
    }

    // MARK: - Trivia

    private mutating func skipTrivia() throws(G4ImportError) {
        while let character = peek() {
            if character.isWhitespace {
                position += 1
            } else if character == "/" && peekAhead(1) == "/" {
                skipLineComment()
            } else if character == "/" && peekAhead(1) == "*" {
                try skipBlockComment()
            } else {
                return
            }
        }
    }

    private mutating func skipLineComment() {
        while let character = peek(), character != "\n" { position += 1 }
    }

    private mutating func skipBlockComment() throws(G4ImportError) {
        position += 2  // consume "/*"
        while let character = peek() {
            if character == "*" && peekAhead(1) == "/" {
                position += 2
                return
            }
            position += 1
        }
        throw .unterminatedLiteral
    }

    // MARK: - Tokens

    private mutating func lexToken(_ character: Character) throws(G4ImportError) -> G4Token {
        switch character {
        case ":": position += 1; return .colon
        case ";": position += 1; return .semicolon
        case "|": position += 1; return .pipe
        case "(": position += 1; return .leftParenthesis
        case ")": position += 1; return .rightParenthesis
        case "?": position += 1; return .question
        case "*": position += 1; return .star
        case "+" where peekAhead(1) == "=": position += 2; return .equals
        case "+": position += 1; return .plus
        case "~": position += 1; return .tilde
        case ".": position += 1; return .dot
        case ",": position += 1; return .comma
        case "=": position += 1; return .equals
        case "-" where peekAhead(1) == ">": position += 2; return .arrow
        case "'": return try lexStringLiteral()
        case "[": return try lexCharacterSet()
        default:
            if character.isLetter || character == "_" {
                return lexIdentifier()
            }
            throw .unexpectedCharacter(character, at: position)
        }
    }

    private mutating func lexIdentifier() -> G4Token {
        var name = ""
        while let character = peek(), character.isLetter || character.isNumber || character == "_" {
            name.append(character)
            position += 1
        }
        switch name {
        case Keyword.grammar: return .grammarKeyword
        case Keyword.fragment: return .fragmentKeyword
        default: return .identifier(name)
        }
    }

    private mutating func lexStringLiteral() throws(G4ImportError) -> G4Token {
        position += 1  // consume opening quote
        var value = ""
        while let character = peek() {
            if character == "'" {
                position += 1
                return .stringLiteral(value)
            }
            if character == "\\" {
                position += 1
                guard let escaped = peek() else { throw .unterminatedLiteral }
                value.append(G4Escapes.decode(escaped))
                position += 1
            } else {
                value.append(character)
                position += 1
            }
        }
        throw .unterminatedLiteral
    }

    private mutating func lexCharacterSet() throws(G4ImportError) -> G4Token {
        position += 1  // consume "["
        var body = ""
        while let character = peek() {
            if character == "]" {
                position += 1
                return .characterSet(body)
            }
            if character == "\\" {
                body.append(character)
                position += 1
                guard let escaped = peek() else { throw .unterminatedLiteral }
                body.append(escaped)
                position += 1
            } else {
                body.append(character)
                position += 1
            }
        }
        throw .unterminatedLiteral
    }

    // MARK: - Cursor

    private func peek() -> Character? {
        position < characters.count ? characters[position] : nil
    }

    private func peekAhead(_ offset: Int) -> Character? {
        let index = position + offset
        return index < characters.count ? characters[index] : nil
    }

    /// The `.g4` reserved words recognised by this importer.
    private enum Keyword {
        static let grammar = "grammar"
        static let fragment = "fragment"
    }
}
