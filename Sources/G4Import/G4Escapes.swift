/// Decodes the backslash escape sequences that ANTLR `.g4` permits in string literals and character
/// sets.
///
/// ANTLR uses the conventional C-style escapes (`\n`, `\t`, `\r`, `\b`, `\f`) together with literal
/// escapes for its own metacharacters (`\\`, `\'`, `\]`, `\-`). Any other escaped character stands for
/// itself, which matches ANTLR's permissive behaviour.
enum G4Escapes {
    /// Decodes a single escaped character into the character it denotes.
    /// - Parameter character: The character that followed a backslash.
    /// - Returns: The decoded character.
    static func decode(_ character: Character) -> Character {
        switch character {
        case "n": return "\n"
        case "t": return "\t"
        case "r": return "\r"
        case "b": return "\u{08}"
        case "f": return "\u{0C}"
        default: return character
        }
    }
}
