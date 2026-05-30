/// A forward-only scanner over query source text, tracking the current UTF-8 byte offset.
///
/// The scanner exposes the small set of primitive reads the ``QueryParser`` needs: peeking and
/// consuming characters, skipping insignificant whitespace and `;` comments, and reading the
/// lexical atoms of the query language (identifiers, quoted strings and capture names). It reports
/// positions as UTF-8 byte offsets so they align with the offsets used throughout `ParsingCore`.
struct QueryScanner {
    /// The characters of the source, in order.
    private let characters: [Character]
    /// The index of the next character to read.
    private var position: Int = 0
    /// The UTF-8 byte offset of the next character to read.
    private(set) var byteOffset: Int = 0

    /// Creates a scanner over the given source.
    /// - Parameter source: The query source text.
    init(_ source: String) {
        self.characters = Array(source)
    }

    /// Whether the scanner has consumed all input.
    var isAtEnd: Bool { position >= characters.count }

    /// The next character without consuming it, or `nil` at end of input.
    var current: Character? { isAtEnd ? nil : characters[position] }

    /// Consumes and returns the next character, advancing the byte offset.
    /// - Returns: The consumed character, or `nil` at end of input.
    @discardableResult
    mutating func advance() -> Character? {
        guard !isAtEnd else { return nil }
        let character = characters[position]
        position += 1
        byteOffset += String(character).utf8.count
        return character
    }

    /// Skips spaces, tabs, newlines and `;` line comments until the next significant character.
    mutating func skipTrivia() {
        while let character = current {
            if character == ";" {
                while let inner = current, inner != "\n" { advance() }
            } else if character.isWhitespace {
                advance()
            } else {
                break
            }
        }
    }

    /// Reads a run of identifier characters (letters, digits, `_`, `-`, `.`, `*`).
    ///
    /// Node-type names, capture names and predicate names share this lexical class. Tree-sitter
    /// permits `-`, `.` and `*` inside capture names (for example `@function.name`), and node
    /// types may carry `_`, so all are accepted here; the parser decides how to interpret the run.
    ///
    /// - Returns: The identifier text, which may be empty if no identifier character is present.
    mutating func readIdentifier() -> String {
        var result = ""
        while let character = current, Self.isIdentifierCharacter(character) {
            result.append(character)
            advance()
        }
        return result
    }

    /// Reads a double-quoted string literal, decoding the supported `\\` escapes.
    ///
    /// The opening quote must be the current character. Backslash escapes `\"`, `\\`, `\n`, `\r`
    /// and `\t` are decoded; any other escaped character stands for itself.
    ///
    /// - Returns: The decoded string contents.
    /// - Throws: ``QueryError/unexpectedEnd`` if the closing quote is missing.
    mutating func readQuotedString() throws(QueryError) -> String {
        advance()  // opening quote
        var result = ""
        while let character = current {
            if character == "\"" {
                advance()
                return result
            }
            if character == "\\" {
                advance()
                guard let escaped = current else { throw .unexpectedEnd }
                switch escaped {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                default: result.append(escaped)
                }
                advance()
            } else {
                result.append(character)
                advance()
            }
        }
        throw .unexpectedEnd
    }

    /// Whether a character may appear within an identifier (node type, capture or predicate name).
    /// - Parameter character: The character to classify.
    /// - Returns: `true` if the character continues an identifier.
    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
            || character == "." || character == "*"
    }
}
