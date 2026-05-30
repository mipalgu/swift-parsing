import ParsingCore

/// Lowers an ANTLR `.g4` character set `[...]` to a `TokenMatcher`.
///
/// A character-set body is a run of single characters, escape sequences, and `a-z` ranges. It lowers to
/// a `TokenMatcher.alternation` of single-character literals and `TokenMatcher.scalarRange` ranges (a
/// single member lowers directly, without the wrapping alternation). A negated set `~[...]` wraps the
/// result in `TokenMatcher.negated`, matching exactly one element that is not in the set.
enum G4CharacterSet {
    /// Lowers a character-set body to a matcher.
    /// - Parameters:
    ///   - body: The text between the brackets, with escapes still present as backslash pairs.
    ///   - isNegated: Whether the set was negated with a leading `~`.
    /// - Returns: A matcher for a single element drawn from (or excluded from) the set.
    static func matcher(body: String, isNegated: Bool) -> TokenMatcher {
        let members = parseMembers(Array(body))
        let inner: TokenMatcher = members.count == 1 ? members[0] : .alternation(members)
        return isNegated ? .negated(inner) : inner
    }

    private static func parseMembers(_ characters: [Character]) -> [TokenMatcher] {
        var members: [TokenMatcher] = []
        var index = 0
        while index < characters.count {
            let low = readCharacter(characters, &index)
            if index < characters.count, characters[index] == "-", index + 1 < characters.count {
                index += 1  // consume '-'
                let high = readCharacter(characters, &index)
                members.append(.scalarRange(low.unicodeScalars.first!.value...high.unicodeScalars.first!.value))
            } else {
                members.append(.literal(String(low)))
            }
        }
        return members
    }

    private static func readCharacter(_ characters: [Character], _ index: inout Int) -> Character {
        if characters[index] == "\\", index + 1 < characters.count {
            index += 1
            let decoded = G4Escapes.decode(characters[index])
            index += 1
            return decoded
        }
        let character = characters[index]
        index += 1
        return character
    }
}
