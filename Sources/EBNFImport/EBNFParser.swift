import ParsingCore

extension EBNFGrammar {
    /// A single imported production: a rule name bound to its lowered IR rule.
    struct Production {
        /// The production (rule) name.
        let name: String
        /// The lowered rule.
        let rule: Rule
    }

    /// A recursive-descent parser for the W3C EBNF dialect.
    ///
    /// The grammar of the notation, written in its own EBNF, is:
    ///
    /// ```
    /// grammar     ::= production+
    /// production  ::= name '::=' alternation
    /// alternation ::= sequence ('|' sequence)*
    /// sequence    ::= quantified+
    /// quantified  ::= atom ('?' | '*' | '+')?
    /// atom        ::= name | string | charClass | '(' alternation ')'
    /// ```
    ///
    /// Whitespace and `/* ... */` comments separate tokens and are skipped. The parser tracks the
    /// current line so that every ``ImportError`` reports where the problem occurred.
    struct Parser {
        private let characters: [Character]
        private var position = 0
        private var line = 1

        /// Creates a parser over EBNF text.
        /// - Parameter text: The EBNF grammar text.
        init(_ text: String) { self.characters = Array(text) }

        // MARK: - Cursor

        private var isAtEnd: Bool { position >= characters.count }

        private func peek(_ ahead: Int = 0) -> Character? {
            let index = position + ahead
            return index < characters.count ? characters[index] : nil
        }

        private mutating func advance() -> Character {
            let character = characters[position]
            if character == "\n" { line += 1 }
            position += 1
            return character
        }

        /// Whether the upcoming characters match `text` exactly (without consuming them).
        private func matches(_ text: String) -> Bool {
            let scalars = Array(text)
            guard position + scalars.count <= characters.count else { return false }
            for (offset, character) in scalars.enumerated() where characters[position + offset] != character {
                return false
            }
            return true
        }

        /// Consumes `text` if it is next, returning whether it was consumed.
        private mutating func consume(_ text: String) -> Bool {
            guard matches(text) else { return false }
            for _ in text { _ = advance() }
            return true
        }

        // MARK: - Trivia

        /// Skips whitespace and `/* ... */` comments at the cursor.
        /// - Throws: ``ImportError/unterminatedComment(line:)`` if a comment is opened but not closed.
        private mutating func skipTrivia() throws {
            while let character = peek() {
                if character.isWhitespace {
                    _ = advance()
                } else if matches(Notation.commentOpen) {
                    try skipComment()
                } else {
                    return
                }
            }
        }

        private mutating func skipComment() throws {
            let startLine = line
            _ = consume(Notation.commentOpen)
            while !isAtEnd {
                if consume(Notation.commentClose) { return }
                _ = advance()
            }
            throw ImportError.unterminatedComment(line: startLine)
        }

        // MARK: - Grammar

        /// Parses the whole text into an ordered list of productions.
        /// - Returns: The productions in declaration order (the first is the goal symbol).
        /// - Throws: ``ImportError`` on any malformed production.
        mutating func parseGrammar() throws -> [Production] {
            var productions: [Production] = []
            try skipTrivia()
            while !isAtEnd {
                productions.append(try parseProduction())
                try skipTrivia()
            }
            return productions
        }

        private mutating func parseProduction() throws -> Production {
            let startLine = line
            guard let name = try parseName() else { throw ImportError.expectedProductionName(line: startLine) }
            try skipTrivia()
            guard consume(Notation.define) else { throw ImportError.expectedDefinitionOperator(line: line) }
            let rule = try parseAlternation()
            return Production(name: name, rule: rule)
        }

        // MARK: - Expressions

        private mutating func parseAlternation() throws -> Rule {
            var alternatives = [try parseSequence()]
            try skipTrivia()
            while peek() == Notation.alternate {
                _ = advance()
                alternatives.append(try parseSequence())
                try skipTrivia()
            }
            return alternatives.count == 1 ? alternatives[0] : .choice(alternatives)
        }

        private mutating func parseSequence() throws -> Rule {
            var pieces: [Rule] = []
            while let term = try parseQuantified() {
                pieces.append(term)
            }
            guard !pieces.isEmpty else { throw ImportError.expectedTerm(line: line) }
            return pieces.count == 1 ? pieces[0] : .sequence(pieces)
        }

        /// Parses an atom followed by an optional postfix quantifier, returning `nil` at a boundary
        /// (end of input, `|`, `)`, or the start of the next production) where no further term is present.
        private mutating func parseQuantified() throws -> Rule? {
            try skipTrivia()
            if nextIsProductionStart() { return nil }
            guard let atom = try parseAtom() else { return nil }
            switch peek() {
            case Notation.optional: _ = advance(); return .optional(atom)
            case Notation.star: _ = advance(); return .repeatZeroOrMore(atom)
            case Notation.plus: _ = advance(); return .repeatOneOrMore(atom)
            default: return atom
            }
        }

        private mutating func parseAtom() throws -> Rule? {
            guard let character = peek() else { return nil }
            switch character {
            case Notation.alternate, Notation.groupClose:
                return nil
            case Notation.groupOpen:
                return try parseGroup()
            case Notation.singleQuote, Notation.doubleQuote:
                return try parseTerminal()
            case Notation.classOpen:
                return try parseCharacterClass()
            default:
                guard let name = try parseName() else {
                    throw ImportError.unexpectedToken(String(character), line: line)
                }
                return .reference(name)
            }
        }

        /// Whether the cursor sits at the start of a new production (`name ::=`).
        ///
        /// W3C EBNF has no statement terminator, so a sequence would otherwise greedily absorb the next
        /// production's name. The boundary is recognised by lookahead: a name whose following token,
        /// after trivia, is the definition operator belongs to the next production, not this sequence.
        /// The scan is non-destructive; the cursor is restored before returning.
        private func nextIsProductionStart() -> Bool {
            guard let first = peek(), Parser.isNameStart(first) else { return false }
            var ahead = 1
            while let character = peek(ahead), Parser.isNameContinuation(character) { ahead += 1 }
            while let character = peek(ahead), character.isWhitespace { ahead += 1 }
            for (offset, character) in Array(Notation.define).enumerated() where peek(ahead + offset) != character {
                return false
            }
            return true
        }

        private mutating func parseGroup() throws -> Rule {
            let startLine = line
            _ = advance()  // consume '('
            let inner = try parseAlternation()
            try skipTrivia()
            guard consume(String(Notation.groupClose)) else { throw ImportError.unbalancedParenthesis(line: startLine) }
            return inner
        }

        // MARK: - Names

        /// Parses a production name: a letter or underscore followed by letters, digits, underscores,
        /// hyphens or dots, matching the identifier style of W3C grammars.
        private mutating func parseName() throws -> String? {
            guard let first = peek(), Parser.isNameStart(first) else { return nil }
            var name = String(advance())
            while let character = peek(), Parser.isNameContinuation(character) {
                name.append(advance())
            }
            return name
        }

        private static func isNameStart(_ character: Character) -> Bool {
            character.isLetter || character == "_"
        }

        private static func isNameContinuation(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_" || character == "-" || character == "."
        }

        // MARK: - Terminals

        private mutating func parseTerminal() throws -> Rule {
            let startLine = line
            let quote = advance()
            var text = ""
            while let character = peek(), character != quote {
                text.append(advance())
            }
            guard consume(String(quote)) else { throw ImportError.unterminatedString(line: startLine) }
            return .literal(text)
        }

        // MARK: - Character classes

        private mutating func parseCharacterClass() throws -> Rule {
            let startLine = line
            _ = advance()  // consume '['
            let negated = peek() == Notation.classNegate
            if negated { _ = advance() }

            var members: [TokenMatcher] = []
            while !isAtEnd, peek() != Notation.classClose {
                members.append(try parseClassMember(startLine: startLine))
            }
            guard consume(String(Notation.classClose)) else {
                throw ImportError.unterminatedCharacterClass(line: startLine)
            }
            return .token(name: "_class", matcher: try classMatcher(members, negated: negated), isNamed: false)
        }

        /// Parses a single class member: a literal character, an escaped character, a hexadecimal code
        /// point, or a `low-high` range of either.
        private mutating func parseClassMember(startLine: Int) throws -> TokenMatcher {
            let low = try parseClassScalar(startLine: startLine)
            if peek() == Notation.rangeMarker, let after = peek(1), after != Notation.classClose {
                _ = advance()  // consume '-'
                let high = try parseClassScalar(startLine: startLine)
                return .scalarRange(low...high)
            }
            return .literal(String(Unicode.Scalar(low) ?? Unicode.Scalar(UInt8(ascii: " "))))
        }

        /// Parses one scalar value inside a character class, decoding `#xN` hexadecimal escapes and
        /// backslash escapes.
        private mutating func parseClassScalar(startLine: Int) throws -> UInt32 {
            if matches(Notation.hexPrefix) {
                return try parseHexScalar(startLine: startLine)
            }
            if peek() == "\\" {
                _ = advance()
            }
            guard peek() != nil else {
                throw ImportError.unterminatedCharacterClass(line: startLine)
            }
            return advance().scalarValue
        }

        private mutating func parseHexScalar(startLine: Int) throws -> UInt32 {
            _ = consume(Notation.hexPrefix)
            var digits = ""
            while let character = peek(), character.isHexDigit {
                digits.append(advance())
            }
            guard let value = UInt32(digits, radix: 16) else {
                throw ImportError.invalidHexadecimal(line: startLine)
            }
            return value
        }

        /// Combines parsed class members into a single matcher, recognising known built-in classes and
        /// applying negation.
        private func classMatcher(_ members: [TokenMatcher], negated: Bool) throws -> TokenMatcher {
            if !negated, members == [.scalarRange(0x0...0x10FFFF)] {
                return .anyElement
            }
            if let builtin = CharacterClass.recognise(members) {
                return negated ? .negated(.builtin(builtin)) : .builtin(builtin)
            }
            let inner: TokenMatcher = members.count == 1 ? members[0] : .alternation(members)
            return negated ? .negated(inner) : inner
        }
    }
}
