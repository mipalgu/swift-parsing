import ParsingCore

/// Bridges the IR's `BuiltinClass` matchers to and from their W3C EBNF character-class spelling.
///
/// The W3C EBNF used in the XML specification has no `\d`/`\s` shorthand: lexical classes are written
/// as explicit character ranges. This type renders the IR's built-in classes to those canonical
/// ranges, and recognises the same ranges on import so that exported grammars round-trip. Defining the
/// spellings here keeps the single source of truth out of the parser and the exporter.
enum CharacterClass {
    /// The EBNF spelling of "any single character", used for the `.anyElement` matcher.
    static let anyElement = "[#x0-#x10FFFF]"

    /// The canonical character-class body (without the surrounding brackets) for a built-in class.
    /// - Parameter builtinClass: The built-in class to render.
    /// - Returns: The interior text of the `[...]` class.
    static func classBody(_ builtinClass: BuiltinClass) -> String {
        switch builtinClass {
        case .digit: return "0-9"
        case .whitespace: return "#x9#xA#xD#x20"
        case .hexDigit: return "0-9A-Fa-f"
        case .letter: return "A-Za-z"
        }
    }

    /// The full character-class spelling (with brackets) for a built-in class.
    /// - Parameter builtinClass: The built-in class to render.
    /// - Returns: The `[...]` class text.
    static func export(_ builtinClass: BuiltinClass) -> String {
        "[\(classBody(builtinClass))]"
    }

    /// Recognises a parsed character-class body as a built-in class, so a class that an export produced
    /// is re-imported as the original `BuiltinClass` matcher rather than an equivalent range alternation.
    ///
    /// - Parameter members: The class members produced by the parser, in declaration order.
    /// - Returns: The matching built-in class, or `nil` when the members are not a known class.
    static func recognise(_ members: [TokenMatcher]) -> BuiltinClass? {
        for candidate in [BuiltinClass.digit, .whitespace, .hexDigit, .letter] where members == canonical(candidate) {
            return candidate
        }
        return nil
    }

    /// The parsed-member representation of a built-in class, used to recognise it on import.
    private static func canonical(_ builtinClass: BuiltinClass) -> [TokenMatcher] {
        switch builtinClass {
        case .digit:
            return [.scalarRange(0x30...0x39)]
        case .whitespace:
            return [.literal("\t"), .literal("\n"), .literal("\r"), .literal(" ")]
        case .hexDigit:
            return [.scalarRange(0x30...0x39), .scalarRange(0x41...0x46), .scalarRange(0x61...0x66)]
        case .letter:
            return [.scalarRange(0x41...0x5A), .scalarRange(0x61...0x7A)]
        }
    }
}
